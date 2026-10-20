//! T0089: run MUSIC128.SPC's AY player in an isolated Z80 sandbox and log
//! every register write it makes -- no Spectrum ROM, no MAME machine
//! driver, no network at runtime. The player is a small (8777-byte),
//! fully self-contained Z80 code blob (org $C000, its own header gives
//! initune/refresh/turnoff/initfx as fixed jump-table addresses at
//! $C000/$C003/$C006/$C009) that talks to the AY-3-8912 through exactly
//! two I/O ports -- that's all a capture needs, and it's small enough to
//! interpret directly rather than emulate a whole 128K machine for it.
//!
//! WHY NOT A FULL MACHINE: getting this game's actual sound working
//! needed a Spectrum 128K ROM this session does not have and should not
//! fetch without asking (128K editor+syntax-check ROM is a separate,
//! copyrighted pair from the 48K ROM already vendored under source/zx/).
//! The player blob needs none of that -- it never calls the ROM, it only
//! reads its own tune tables and writes two ports.
//!
//! HOW THE CALLS ARE DRIVEN: the `z80` crate (2.0.0) exposes pc/sp/ix/iy
//! and interrupt state as public fields, but NOT the general-purpose
//! registers (A/BC/DE/HL are buried in private c2rust-transpiled union
//! fields with no accessors). Rather than fight the crate's internals,
//! this writes tiny bootstrap STUBS as real Z80 machine code into the
//! emulated RAM (e.g. `LD A,n / CALL initune / HALT`) and lets the CPU's
//! OWN instructions set up its OWN registers -- sidesteps the missing
//! accessors entirely, and is exactly what the real caller code in
//! X-ALL.TXT does anyway (`ld a,0 / call starttune`).
//!
//! Usage:
//!   aycapture <MUSIC128.SPC> <tune|fx> <id> <frames> <out.csv>
//!
//! `frames` is refresh() calls, one per 50Hz tick (matching how
//! `updatemusicingame`/`refresh` is driven once per real interrupt in
//! the original). Output is one CSV row per refresh tick: the AY's 14
//! registers after that tick, so downstream tooling can read off
//! per-channel period (regs 0/1, 2/3, 4/5) and volume (regs 8/9/10)
//! without needing to know anything about the Z80 side again.
use std::fs;
use z80::{Z80, Z80_io};

/// MUSIC128.SPC (like the .SCR title asset) is assembler SOURCE TEXT, not
/// a raw binary: a header of `name equ &addr` lines followed by `HEX ...`
/// lines with no `org` directive, meant to be assembled/included right at
/// music128 ($C000, per X-ALL.TXT line 47). Concatenating every HEX line's
/// bytes in file order reproduces the blob exactly as it would land in
/// memory. (Confirmed by the very first bytes decoding to `C3 0C C0` =
/// `JP $C00C`, matching the `initune equ &c000` jump-table trampoline.)
fn read_hex_source(path: &str) -> Vec<u8> {
    let text = fs::read(path).expect("read source");
    let text = String::from_utf8_lossy(&text);
    let mut hex = String::new();
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix("HEX ") {
            hex.push_str(rest.trim());
        }
    }
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).expect("hex digit"))
        .collect()
}

const INITUNE: u16 = 0xC000;
const REFRESH: u16 = 0xC003;
const INITFX: u16 = 0xC009;
const STUB_ADDR: u16 = 0x8000; // well clear of the $C000 player and its
                                // own variables (observed up to ~$C3xx)
const STACK_TOP: u16 = 0xFF00; // ample RAM, far from the player and stub

struct Sandbox {
    mem: [u8; 0x10000],
    ay_selected: u8,
    ay_regs: [u8; 16],
    /// Set true by port_out whenever a WRITE actually changes a
    /// register's value -- lets the caller log only real changes
    /// instead of 14 redundant identical rows every single tick.
    ay_dirty: bool,
}

impl Z80_io for Sandbox {
    fn read_byte(&self, addr: u16) -> u8 {
        self.mem[addr as usize]
    }
    fn write_byte(&mut self, addr: u16, value: u8) {
        self.mem[addr as usize] = value;
    }
    fn port_in(&self, _addr: u16) -> u8 {
        0xff // nothing this player reads back from hardware
    }
    fn port_out(&mut self, addr: u16, value: u8) {
        // Real 128K AY I/O: BC=$FFFD selects the register (low byte of
        // BC doesn't matter to real hardware decoding, only that A14 is
        // set and A15 clear-ish per the ULA's partial decode -- but the
        // ORIGINAL CODE always loads the full 16-bit port literally as
        // $FFFD/$BFFD, so matching those two exact values is both
        // correct AND simplest; no partial-decode guessing needed).
        match addr {
            0xFFFD => self.ay_selected = value & 0x0F,
            0xBFFD => {
                let r = self.ay_selected as usize;
                if self.ay_regs[r] != value {
                    self.ay_dirty = true;
                }
                self.ay_regs[r] = value;
            }
            _ => {}
        }
    }
}

/// Run from STUB_ADDR until the CPU halts (the stub's own trailing HALT),
/// or bail out after a generous instruction budget -- a player bug or a
/// wrong entry address must not spin this tool forever.
fn run_stub(cpu: &mut Z80, io: &mut Sandbox, code: &[u8]) {
    for (i, b) in code.iter().enumerate() {
        io.mem[STUB_ADDR as usize + i] = *b;
    }
    cpu.pc = STUB_ADDR;
    cpu.sp = STACK_TOP;
    cpu.halted = false;
    let mut budget = 2_000_000u32; // generous; a real tick is <<1000 T-states
    while !cpu.halted && budget > 0 {
        cpu.step(io);
        budget -= 1;
    }
    if budget == 0 {
        eprintln!("WARNING: stub at ${STUB_ADDR:04x} never halted -- instruction budget exhausted");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 {
        eprintln!("usage: aycapture <MUSIC128.SPC> <tune|fx> <id> <frames> <out.csv>");
        std::process::exit(2);
    }
    let spc_path = &args[1];
    let kind = &args[2];
    let id: u8 = args[3].parse().expect("id must be 0-255");
    let frames: u32 = args[4].parse().expect("frames must be a number");
    let out_path = &args[5];

    let blob = read_hex_source(spc_path);

    let mut io = Sandbox {
        mem: [0u8; 0x10000],
        ay_selected: 0,
        ay_regs: [0u8; 16],
        ay_dirty: false,
    };
    io.mem[0xC000..0xC000 + blob.len()].copy_from_slice(&blob);

    let mut cpu = Z80::new();
    cpu.reset();

    // `ld a,id / call ENTRY / halt` -- 3E xx / CD lo hi / 76
    let entry = if kind == "fx" { INITFX } else { INITUNE };
    let init_stub = [0x3E, id, 0xCD, (entry & 0xFF) as u8, (entry >> 8) as u8, 0x76];
    run_stub(&mut cpu, &mut io, &init_stub);

    // `call REFRESH / halt` -- CD lo hi / 76, run once per captured frame
    let refresh_stub = [0xCD, (REFRESH & 0xFF) as u8, (REFRESH >> 8) as u8, 0x76];

    let mut rows: Vec<(u32, [u8; 16])> = Vec::new();
    for f in 0..frames {
        io.ay_dirty = false;
        run_stub(&mut cpu, &mut io, &refresh_stub);
        if io.ay_dirty || f == 0 {
            rows.push((f, io.ay_regs));
        }
    }

    let mut csv = String::from("frame,r0,r1,r2,r3,r4,r5,r6,r7,r8,r9,r10,r11,r12,r13\n");
    for (f, regs) in &rows {
        csv.push_str(&f.to_string());
        for r in regs.iter().take(14) {
            csv.push(',');
            csv.push_str(&r.to_string());
        }
        csv.push('\n');
    }
    fs::write(out_path, &csv).expect("write output csv");
    println!(
        "captured {frames} frames, {} rows with a real register change -> {out_path}",
        rows.len()
    );
}
