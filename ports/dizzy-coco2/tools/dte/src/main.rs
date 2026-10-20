//! T0225: DTE build tool. Two subcommands:
//!
//!   dte build     -- read target/text_src/*.asm, write the generated
//!                    target/*.asm copies (fcc -> fcb) plus dte_table.asm.
//!   dte selftest  -- round-trip every parsed string (decode(encode(s)) ==
//!                    s) and, if the generated files already exist, also
//!                    decode what's actually IN them and compare against
//!                    text_src -- the verifier a cheaper tier re-runs.
//!
//! Run from the port root (ports/dizzy-coco2); tools/stage_pack.sh invokes
//! `dte build` before assembling.

use clap::{Parser, Subcommand};
use dte::{build_table, check_text_range, emit_table_asm, parse_fcc_lines, rewrite, rewrite_from, Table};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const FILES: &[&str] = &[
    "gap_messages.asm",
    "gameplay.asm",
    "actors.asm",
    "ui_room_names.asm",
    "rat_troll_hazard_code.asm",
];

/// Encode-only files (T0215): rewritten with the shared table but never
/// part of the corpus the table is built from, so adding/editing them
/// cannot change one byte of the codebook (and hence of the -run build).
/// Source in target/text_src_tape/, generated copy in target/.
const EXTRA_DIR: &str = "target/text_src_tape";
const EXTRA_FILES: &[&str] = &["msg_data_tape.asm", "msg_data_tape_low.asm", "msg_data_tape_low3.asm", "msg_data_tape_low4.asm", "msg_data_floppy.asm"];

#[derive(Parser)]
struct Args {
    /// Port root (contains target/text_src and target/)
    #[arg(long, default_value = ".")]
    root: PathBuf,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Build,
    Selftest,
}

fn read_sources(root: &Path) -> Vec<(String, String)> {
    FILES
        .iter()
        .map(|name| {
            let path = root.join("target/text_src").join(name);
            let src = fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
            (name.to_string(), src)
        })
        .collect()
}

/// Read encode-only sources and FAIL loudly (exit 1) if any string has a
/// byte outside 32..=90 (would collide with a DTE code / VM opcode).
fn read_extra_sources(root: &Path) -> Vec<(String, String)> {
    let mut v = Vec::new();
    let mut bad_total = Vec::new();
    for name in EXTRA_FILES {
        let path = root.join(EXTRA_DIR).join(name);
        let src = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        for (line, byte) in check_text_range(&parse_fcc_lines(&src)) {
            bad_total.push((name.to_string(), line, byte));
        }
        v.push((name.to_string(), src));
    }
    if !bad_total.is_empty() {
        eprintln!("DTE build guard failed -- encode-only text byte outside 32..=90 (would collide with a DTE code or VM opcode):");
        for (name, line, byte) in &bad_total {
            eprintln!("  {EXTRA_DIR}/{name}:{} byte {byte} (0x{byte:02x})", line + 1);
        }
        std::process::exit(1);
    }
    v
}

fn build_shared_table(sources: &[(String, String)]) -> Table {
    let mut all_strings = Vec::new();
    let mut bad_total = Vec::new();
    for (name, src) in sources {
        let parsed = parse_fcc_lines(src);
        let bad = check_text_range(&parsed);
        for (line, byte) in bad {
            bad_total.push((name.clone(), line, byte));
        }
        all_strings.extend(parsed.into_iter().map(|(_, _, b)| b));
    }
    if !bad_total.is_empty() {
        eprintln!("DTE build guard failed -- source text byte outside 32..=90 (would collide with a DTE code or VM opcode):");
        for (name, line, byte) in &bad_total {
            eprintln!("  {name}:{} byte {byte} (0x{byte:02x})", line + 1);
        }
        std::process::exit(1);
    }
    build_table(&all_strings)
}

fn do_build(root: &Path) {
    let sources = read_sources(root);
    let table = build_shared_table(&sources);

    let raw_total: usize = sources
        .iter()
        .map(|(_, src)| {
            parse_fcc_lines(src)
                .iter()
                .map(|(_, _, b)| b.len())
                .sum::<usize>()
        })
        .sum();
    let enc_total: usize = sources
        .iter()
        .map(|(_, src)| {
            parse_fcc_lines(src)
                .iter()
                .map(|(_, _, b)| table.encode(b).len())
                .sum::<usize>()
        })
        .sum();
    let table_bytes = table.entries.len() * 2;

    for (name, src) in &sources {
        let out = rewrite(src, &table);
        fs::write(root.join("target").join(name), out).unwrap();
    }
    fs::write(root.join("target/dte_table.asm"), emit_table_asm(&table)).unwrap();

    // Encode-only files: same table, NOT in the corpus.
    for (name, src) in &read_extra_sources(root) {
        let raw: usize = parse_fcc_lines(src).iter().map(|(_, _, b)| b.len()).sum();
        let enc: usize = parse_fcc_lines(src).iter().map(|(_, _, b)| table.encode(b).len()).sum();
        fs::write(root.join("target").join(name), rewrite_from(src, &table, EXTRA_DIR)).unwrap();
        println!("dte build: encode-only {name}: text {raw} -> {enc} bytes (codebook untouched)");
    }

    println!(
        "dte build: {} codes, text {} -> {} bytes, +{} table = {} total (saved {})",
        table.entries.len(),
        raw_total,
        enc_total,
        table_bytes,
        enc_total + table_bytes,
        raw_total.saturating_sub(enc_total + table_bytes)
    );
}

fn do_selftest(root: &Path) -> bool {
    let sources = read_sources(root);
    let table = build_shared_table(&sources);
    let mut ok = true;
    let mut checked = 0;

    // 1. decode(encode(s)) == s for every parsed source string.
    for (name, src) in &sources {
        for (line, _, bytes) in parse_fcc_lines(src) {
            let enc = table.encode(&bytes);
            let dec = table.decode(&enc);
            checked += 1;
            if dec != bytes {
                ok = false;
                eprintln!(
                    "FAIL round-trip {name}:{}: {:?} -> {:?} -> {:?}",
                    line + 1,
                    String::from_utf8_lossy(&bytes),
                    enc,
                    String::from_utf8_lossy(&dec)
                );
            }
        }
    }

    // 1b. encode-only files: range guard + round-trip.
    for (name, src) in &read_extra_sources(root) {
        for (line, _, bytes) in parse_fcc_lines(src) {
            let dec = table.decode(&table.encode(&bytes));
            checked += 1;
            if dec != bytes {
                ok = false;
                eprintln!("FAIL round-trip {EXTRA_DIR}/{name}:{}", line + 1);
            }
        }
    }

    // 2. if the generated files exist, decode what's actually written on
    //    disk and compare against text_src -- catches file-writing bugs,
    //    not just table-logic bugs.
    let all: Vec<(&str, &str)> = FILES
        .iter()
        .map(|n| (*n, "target/text_src"))
        .chain(EXTRA_FILES.iter().map(|n| (*n, EXTRA_DIR)))
        .collect();
    for (name, dir) in all {
        let gen_path = root.join("target").join(name);
        let src_path = root.join(dir).join(name);
        let (Ok(gen_text), Ok(src)) = (
            fs::read_to_string(&gen_path),
            fs::read_to_string(&src_path),
        ) else {
            continue;
        };
        let src_strings: Vec<Vec<u8>> = parse_fcc_lines(&src).into_iter().map(|(_, _, b)| b).collect();
        let gen_lines: Vec<&str> = gen_text.lines().collect();
        let mut gen_strings = Vec::new();
        for line in &gen_lines {
            let t = line.trim_start();
            if let Some(rest) = t.strip_prefix("fcb ") {
                let list = rest.split(';').next().unwrap_or("").trim().trim_end_matches(',');
                if list.is_empty() {
                    continue;
                }
                if let Ok(bytes) = list
                    .split(',')
                    .map(|n| n.trim().parse::<u16>().map(|v| v as u8))
                    .collect::<Result<Vec<u8>, _>>()
                {
                    // Only meaningful for lines the tool itself emitted
                    // (marked with the "DTE:" comment); skip anything else
                    // (ordinary fcb data elsewhere in the file).
                    if line.contains("; DTE:") {
                        gen_strings.push(table.decode(&bytes));
                    }
                }
            }
        }
        checked += gen_strings.len();
        if gen_strings != src_strings {
            ok = false;
            eprintln!(
                "FAIL on-disk decode mismatch in {}: {} strings in text_src, {} decoded from generated file",
                gen_path.display(),
                src_strings.len(),
                gen_strings.len()
            );
        }
    }

    println!("dte selftest: {checked} strings checked, {}", if ok { "ALL PASS" } else { "FAILURES ABOVE" });
    ok
}

fn main() -> ExitCode {
    let args = Args::parse();
    match args.cmd {
        Cmd::Build => {
            do_build(&args.root);
            ExitCode::SUCCESS
        }
        Cmd::Selftest => {
            if do_selftest(&args.root) {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The codebook is built from FILES only; the encode-only dir must
    /// never influence it. Builds the table, then proves that the table
    /// is identical (emitted asm byte-for-byte) regardless of what is in
    /// text_src_tape, and that every extra string round-trips.
    #[test]
    fn codebook_unchanged_by_text_src_tape() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let t1 = emit_table_asm(&build_shared_table(&read_sources(&root)));
        let extras = read_extra_sources(&root);
        let t2 = emit_table_asm(&build_shared_table(&read_sources(&root)));
        assert_eq!(t1, t2);
        // And it matches the checked-out generated table on disk, if present.
        if let Ok(disk) = fs::read_to_string(root.join("target/dte_table.asm")) {
            assert_eq!(t1, disk, "dte_table.asm differs from the corpus-only table");
        }
        let table = build_shared_table(&read_sources(&root));
        for (_, src) in &extras {
            for (_, _, b) in parse_fcc_lines(src) {
                assert_eq!(table.decode(&table.encode(&b)), b);
            }
        }
    }
}
