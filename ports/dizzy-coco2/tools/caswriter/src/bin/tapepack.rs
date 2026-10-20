//! Builds target/room36.cas: a CLOADM-loadable ML file carrying
//! tape_stage1.asm, followed by that stage's own segment stream --
//! every (addr, data) block parsed straight out of a `lwasm --decb`
//! build (today, target/room36.bin unmodified) plus any extra
//! tape-only segments, terminated by the real game's exec address.
//! See tools/tape_pack.sh, which computes stage1's load address and
//! invokes this.

use caswriter::*;
use clap::Parser;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Assembled tape_stage1 binary (lwasm --format=raw)
    #[arg(long)]
    stage1_bin: PathBuf,
    /// stage1's load/exec address (hex) -- CLOADM loads it there and
    /// EXECs it immediately, same address (stage1 starts at its own
    /// first byte, no relocation)
    #[arg(long)]
    stage1_addr: String,
    /// The existing DECB build (target/room36.bin) to replay as the
    /// segment stream's main body
    #[arg(long)]
    decb: PathBuf,
    /// Extra tape-only segments, `addr:file` (hex addr), destined for
    /// $8000+ -- appended after the DECB body's segments, before the
    /// exec sentinel. Repeatable. Empty this round (T0228 Phase 2
    /// first cut): proves the mechanism before using it for headroom.
    #[arg(long = "extra-segment")]
    extra_segments: Vec<String>,
    #[arg(long, default_value_t = 128)]
    leader_len: usize,
    #[arg(long, default_value_t = 255)]
    max_chunk: usize,
    #[arg(long)]
    out: PathBuf,
}

fn parse_hex_u16(s: &str) -> u16 {
    u16::from_str_radix(s.trim_start_matches("0x").trim_start_matches('$'), 16)
        .unwrap_or_else(|e| panic!("bad hex address {s:?}: {e}"))
}

fn main() {
    let args = Args::parse();
    let stage1 = fs::read(&args.stage1_bin).unwrap_or_else(|e| panic!("{:?}: {e}", args.stage1_bin));
    let stage1_addr = parse_hex_u16(&args.stage1_addr);

    let decb = fs::read(&args.decb).unwrap_or_else(|e| panic!("{:?}: {e}", args.decb));
    let (mut segments, exec_addr) = parse_decb(&decb);

    for spec in &args.extra_segments {
        let (addr_s, path) = spec.split_once(':').unwrap_or_else(|| panic!("expected addr:file, got {spec:?}"));
        let addr = parse_hex_u16(addr_s);
        let data = fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        segments.push((addr, data));
    }

    let mut cas = Vec::new();
    write_ml_file(&mut cas, args.leader_len, "STAGE1", stage1_addr, stage1_addr, &stage1, 255);
    write_segment_stream(&mut cas, args.leader_len, &segments, exec_addr, args.max_chunk);

    fs::write(&args.out, &cas).unwrap_or_else(|e| panic!("{:?}: {e}", args.out));
    let total_data: usize = segments.iter().map(|(_, d)| d.len()).sum();
    let blocks = segments.iter().map(|(_, d)| d.len().div_ceil(args.max_chunk)).sum::<usize>() * 2 + 2;
    eprintln!(
        "wrote {} bytes to {:?}: stage1 {} bytes @ ${:04X}, {} segments ({} bytes) as {} blocks, exec ${:04X}",
        cas.len(), args.out, stage1.len(), stage1_addr, segments.len(), total_data, blocks, exec_addr,
    );
}
