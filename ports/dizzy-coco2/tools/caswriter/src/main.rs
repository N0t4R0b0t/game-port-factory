//! Builds tapeloader_spike's .cas image: one normal CLOADM-visible ML
//! file (the stage-1 loader) followed, on the SAME tape with no second
//! namefile/EOF, by raw data blocks carrying a known test pattern.
//! Stage 1 reads those raw blocks itself via BLKIN, after CLOADM/EXEC
//! has already handed it control -- see tools/tapeloader_spike/README.

use caswriter::*;
use clap::Parser;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Assembled stage-1 raw binary (lwasm --format=raw output)
    #[arg(long)]
    stage1_bin: PathBuf,
    /// Load address of stage-1 (hex, e.g. 3000)
    #[arg(long)]
    load_addr: String,
    /// Exec address of stage-1 (hex, e.g. 3000)
    #[arg(long)]
    exec_addr: String,
    /// Namefile name (<=8 chars)
    #[arg(long, default_value = "SPIKE1")]
    name: String,
    /// Number of pattern bytes to append as raw blocks after stage 1
    #[arg(long, default_value_t = 8192)]
    pattern_len: usize,
    /// Max payload bytes per raw block (<=255)
    #[arg(long, default_value_t = 200)]
    raw_block_size: usize,
    /// Leader length in $55 bytes before each block
    #[arg(long, default_value_t = 128)]
    leader_len: usize,
    /// Skip the namefile+EOF framing and emit ONLY the raw pattern
    /// blocks -- for isolating stage1's own BLKIN reads from CLOADM's,
    /// e.g. when the loader is put in place directly (gdb/`-run`)
    /// rather than tape-loaded, and the tape need only supply what
    /// stage1 itself reads.
    #[arg(long, default_value_t = false)]
    raw_only: bool,
    #[arg(long)]
    out: PathBuf,
}

fn parse_hex_u16(s: &str) -> u16 {
    u16::from_str_radix(s.trim_start_matches("0x").trim_start_matches('$'), 16)
        .unwrap_or_else(|e| panic!("bad hex address {s:?}: {e}"))
}

fn main() {
    let args = Args::parse();
    let stage1 = fs::read(&args.stage1_bin)
        .unwrap_or_else(|e| panic!("reading {:?}: {e}", args.stage1_bin));
    let load_addr = parse_hex_u16(&args.load_addr);
    let exec_addr = parse_hex_u16(&args.exec_addr);

    let mut cas = Vec::new();
    if !args.raw_only {
        write_ml_file(&mut cas, args.leader_len, &args.name, load_addr, exec_addr, &stage1, 255);
    }

    // Known pattern: a repeating 0..255 counter, so the harness's
    // expectation is a one-line formula, not a stored blob.
    let pattern: Vec<u8> = (0..args.pattern_len as u32).map(|i| (i % 256) as u8).collect();
    write_raw_blocks(&mut cas, args.leader_len, &pattern, args.raw_block_size);

    fs::write(&args.out, &cas).unwrap_or_else(|e| panic!("writing {:?}: {e}", args.out));
    eprintln!(
        "wrote {} bytes to {:?} ({} stage1 bytes @ ${:04X}, exec ${:04X}, {} pattern bytes in {}-byte raw blocks)",
        cas.len(),
        args.out,
        stage1.len(),
        load_addr,
        exec_addr,
        args.pattern_len,
        args.raw_block_size,
    );
}
