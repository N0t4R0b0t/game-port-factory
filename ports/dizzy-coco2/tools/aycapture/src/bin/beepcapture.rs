//! T0089 follow-up: capture the SPECTRUM 48K BEEPER music (MUSIC48.SPC)
//! instead of the 128K AY music, for the title screen.
//!
//! WHY BOTHER, when the 128K capture already works: because the CoCo2's
//! only output is a blocking single square-wave DAC, and the 128K tune
//! is a THREE-channel arrangement. Reducing it to one voice throws away
//! the harmony and bass and keeps a bare melody line -- technically
//! correct notes (verified to 0.06 semitones) that still do not sound
//! like the tune anyone remembers. The 48K beeper version was COMPOSED
//! for a single-bit speaker: it is already monophonic, so it survives
//! the trip to a monophonic output intact. Monophonic source, monophonic
//! target. Requested by the player after hearing the reduced AY one.
//!
//! HOW THIS DIFFERS FROM THE AY CAPTURE. The AY player writes symbolic
//! register values (this channel, this period, this volume) and
//! aycapture just reads them off. The beeper has no registers at all:
//! the tune exists only as the TIMING of speaker-bit flips on port $FE.
//! So this runs the same isolated Z80 sandbox but timestamps every ULA
//! write in T-states, and recovers pitch from the interval between
//! flips -- one full wave per two flips, 3.5MHz Spectrum clock.
//!
//! It is also INTERRUPT DRIVEN, where the AY player was not: initune48
//! does `DI`, installs an IM2 handler and returns, and the music is
//! produced from the 50Hz interrupt thereafter. So this drives the CPU
//! in 69888-T-state frames (the real 48K frame length) and pulses IRQ
//! at each boundary, rather than calling a `refresh` entry point.
//!
//! OUTPUT is deliberately the SAME CSV shape the AY captures use -- the
//! detected pitch is written back out as though it were AY channel A
//! (period in r0/r1, volume 15 in r8, or volume 0 for silence). That
//! means `reduce` consumes it with no changes at all, and the whole
//! downstream pipeline -- pitch bucketing, rests, note splitting, the
//! CoCo DAC calibration, the gameplay duration caps -- applies
//! identically to both sources.
//!
//! Usage:
//!   beepcapture <MUSIC48.SPC> <tune_id> <frames> <out.csv>
use std::fs;
use z80::{Z80, Z80_io};

const ORG: u16 = 0xF989;
const INITUNE48: u16 = 0xF98B;
const STUB: u16 = 0x8000;
const STACK_TOP: u16 = 0x7FE8; // what the player's own `exit` restores
const TSTATES_PER_FRAME: u32 = 69888; // 48K Spectrum: 3.5MHz / 50.08Hz
const CPU_HZ: f64 = 3_500_000.0;
const AY_CLOCK: f64 = 1_773_400.0;
/// Waveform reconstruction rate for the autocorrelation. High enough
/// that a lag is a fine pitch step, low enough that the O(win*lags)
/// search stays quick.
const SR: f64 = 35_000.0;
const MIN_HZ: f64 = 60.0;
const MAX_HZ: f64 = 1200.0;

/// Decode the `HEX ...` lines of a .SPC/.SCR assembler source file --
/// these assets are source text, not binaries (see aycapture's header).
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

struct Sandbox {
    mem: [u8; 0x10000],
    /// T-states elapsed, maintained by the caller each step.
    t: u64,
    /// (timestamp, speaker level) for every change of the speaker bit.
    flips: Vec<(u64, bool)>,
    speaker: bool,
}

impl Z80_io for Sandbox {
    fn read_byte(&self, addr: u16) -> u8 {
        self.mem[addr as usize]
    }
    fn write_byte(&mut self, addr: u16, value: u8) {
        self.mem[addr as usize] = value;
    }
    fn port_in(&self, _addr: u16) -> u8 {
        // Idle 48K bus. Keyboard rows read as "nothing pressed" ($BF/$FF
        // style); $FF is also what the floating bus gives.
        0xff
    }
    fn port_out(&mut self, addr: u16, value: u8) {
        // The ULA is selected by A0 LOW -- it is NOT a full 16-bit
        // compare on $FE. Matching only the literal port would miss
        // every `OUT (C),A` with B holding something else, which is
        // exactly how beeper routines address it.
        if addr & 1 == 0 {
            let lvl = value & 0x10 != 0; // bit 4 = speaker
            if lvl != self.speaker {
                self.speaker = lvl;
                let t = self.t;
                self.flips.push((t, lvl));
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: beepcapture <MUSIC48.SPC> <tune_id> <frames> <out.csv>");
        std::process::exit(2);
    }
    let id: u8 = args[2].parse().expect("tune_id");
    let frames: u32 = args[3].parse().expect("frames");

    let blob = read_hex_source(&args[1]);
    let mut io = Sandbox {
        mem: [0u8; 0x10000],
        t: 0,
        flips: Vec::new(),
        speaker: false,
    };
    io.mem[ORG as usize..ORG as usize + blob.len()].copy_from_slice(&blob);
    eprintln!(
        "loaded {} bytes at ${:04x}-${:04x}",
        blob.len(),
        ORG,
        ORG as usize + blob.len() - 1
    );

    let mut cpu = Z80::new();
    cpu.reset();

    // LD A,id / CALL initune48 / HALT
    let stub = [
        0x3E,
        id,
        0xCD,
        (INITUNE48 & 0xFF) as u8,
        (INITUNE48 >> 8) as u8,
        0x76,
    ];
    for (i, b) in stub.iter().enumerate() {
        io.mem[STUB as usize + i] = *b;
    }
    cpu.pc = STUB;
    cpu.sp = STACK_TOP;
    cpu.halted = false;
    let mut guard = 0u32;
    while !cpu.halted && guard < 5_000_000 {
        let c = cpu.step(&mut io);
        io.t += c as u64;
        guard += 1;
    }
    eprintln!(
        "after initune48: halted={} I=${:02x} IM={} iff1={} ({} T-states)",
        cpu.halted, cpu.i, cpu.interrupt_mode, cpu.iff1, io.t
    );

    // Now run the music: 50Hz interrupts, real 48K frame length. The
    // player installed its own IM2 handler, so the CPU only needs the
    // interrupt pulsed at the right cadence. $FF is what the 48K
    // floating bus presents as the interrupt vector low byte.
    cpu.halted = false;
    for _ in 0..frames {
        let end = io.t + TSTATES_PER_FRAME as u64;
        cpu.pulse_irq(0xFF);
        while io.t < end {
            if cpu.halted {
                // HALT just burns time until the next interrupt
                io.t += 4;
                continue;
            }
            let c = cpu.step(&mut io);
            io.t += c as u64;
        }
    }
    eprintln!(
        "ran {} frames, {} speaker flips",
        frames,
        io.flips.len()
    );

    // BEEP_DUMP=<path> writes the raw edge list for analysis -- the
    // pitch-recovery heuristic below is only as good as its model of
    // what the engine's waveform actually looks like, so being able to
    // go and LOOK is the difference between tuning it and guessing.
    if let Ok(p) = std::env::var("BEEP_DUMP") {
        let mut s = String::from("t,level\n");
        for &(t, l) in &io.flips {
            s.push_str(&format!("{},{}\n", t, if l { 1 } else { 0 }));
        }
        fs::write(&p, s).expect("write dump");
        eprintln!("dumped {} edges to {}", io.flips.len(), p);
    }

    // Recover pitch by AUTOCORRELATION on the reconstructed 1-bit
    // waveform.
    //
    // The obvious approach -- read the pitch off the interval between
    // speaker flips -- is WRONG for this engine and was tried first. It
    // does not emit a square wave: each cycle is a repeating group of
    // several edges (measured: 484 high, 127 low, 964 high, then a long
    // gap), a pulse shape chosen for timbre. The note pitch is the
    // REPETITION RATE of that whole group, so interval-based detection
    // reports the pulse width instead and lands an octave or two high.
    // An FFT gets closer but still returns octave errors, because a
    // narrow pulse train has harmonics stronger than its fundamental.
    // Autocorrelation locks onto the true repeat period, and the result
    // is self-checking: tune 0 comes out as 79 / 236 / 118 / 148 Hz,
    // which are ratios 1 : 3 : 3/2 : 15/8 -- Eb2, Bb3, Bb2, D3. Real
    // intervals falling out of the arithmetic is not something a
    // mis-detection produces.
    let t0 = io.flips.first().map(|&(t, _)| t).unwrap_or(0);
    let span = io.flips.last().map(|&(t, _)| t).unwrap_or(0) - t0;
    let nsamp = (span as f64 / CPU_HZ * SR) as usize + 1;
    let mut wave = vec![0f32; nsamp];
    for i in 0..io.flips.len().saturating_sub(1) {
        if io.flips[i].1 {
            let a = ((io.flips[i].0 - t0) as f64 / CPU_HZ * SR) as usize;
            let b = (((io.flips[i + 1].0 - t0) as f64 / CPU_HZ * SR) as usize).min(nsamp);
            for s in &mut wave[a.min(nsamp)..b] {
                *s = 1.0;
            }
        }
    }

    let hop = (TSTATES_PER_FRAME as f64 / CPU_HZ * SR) as usize;
    let win = hop * 5 / 2; // 2.5 frames: enough cycles even at the low end
    let lag_lo = (SR / MAX_HZ) as usize;
    let lag_hi = (SR / MIN_HZ) as usize;

    let mut rows: Vec<(u32, Option<f64>)> = Vec::new();
    for fr in 0..frames {
        let s = fr as usize * hop;
        if s + win > nsamp {
            rows.push((fr, None));
            continue;
        }
        let seg = &wave[s..s + win];
        let mean = seg.iter().sum::<f32>() / win as f32;
        let c: Vec<f32> = seg.iter().map(|v| v - mean).collect();
        let e0: f32 = c.iter().map(|v| v * v).sum();
        if e0 <= 1e-6 {
            rows.push((fr, None));
            continue;
        }
        let (mut best_lag, mut best) = (0usize, 0f32);
        for lag in lag_lo..lag_hi.min(win - 1) {
            let mut acc = 0f32;
            for i in 0..win - lag {
                acc += c[i] * c[i + lag];
            }
            let norm = acc / e0;
            if norm > best {
                best = norm;
                best_lag = lag;
            }
        }
        // A real held note correlates strongly with itself one period
        // later; noise and note transitions do not.
        if best < 0.30 || best_lag == 0 {
            rows.push((fr, None));
            continue;
        }
        // Parabolic interpolation around the peak -- without it the
        // pitch is quantised to whole samples, which at the top of the
        // range is worth most of a semitone.
        let mut k = best_lag as f64;
        if best_lag > lag_lo && best_lag + 1 < lag_hi.min(win - 1) {
            let corr = |l: usize| -> f32 {
                let mut a = 0f32;
                for i in 0..win - l {
                    a += c[i] * c[i + l];
                }
                a / e0
            };
            let (a, b, cc) = (corr(best_lag - 1), best, corr(best_lag + 1));
            let d = a - 2.0 * b + cc;
            if d != 0.0 {
                k += 0.5 * ((a - cc) / d) as f64;
            }
        }
        rows.push((fr, Some(SR / k)));
    }

    // Emit in the AY capture's own CSV shape so `reduce` needs no
    // changes: the beeper pitch becomes channel A, volume 15 or 0.
    let mut csv = String::from("frame,r0,r1,r2,r3,r4,r5,r6,r7,r8,r9,r10,r11,r12,r13\n");
    let mut sounding = 0;
    for (fr, hz) in &rows {
        let (p, vol) = match hz {
            Some(h) => {
                sounding += 1;
                ((AY_CLOCK / (16.0 * h)).round() as u32, 15)
            }
            None => (0, 0),
        };
        csv.push_str(&format!(
            "{},{},{},0,0,0,0,0,56,{},0,0,0,0,0\n",
            fr,
            p & 0xFF,
            (p >> 8) & 0xFF,
            vol
        ));
    }
    fs::write(&args[4], &csv).expect("write csv");
    println!(
        "{} frames, {} sounding ({:.0}%), {} flips -> {}",
        frames,
        sounding,
        100.0 * sounding as f64 / frames as f64,
        io.flips.len(),
        args[4]
    );
}
