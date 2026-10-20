//! T0089: collapse an aycapture CSV (14 raw AY registers per changed
//! frame, 50Hz Spectrum ticks) down to a CoCo2 play_tone note table.
//!
//! WHY ONE CHANNEL, NOT 3-VOICE: the target's only sound output is the
//! T0088 DAC driver (play_tone), a BLOCKING single square-wave
//! generator -- there is no background mixer, no second voice, and
//! adding one is a much bigger feature than "port the existing tunes".
//!
//! WHICH channel, though, is the whole ballgame, and "loudest this
//! frame" (T0089's first answer) is WRONG. The AY's per-channel volume
//! envelopes ramp constantly, so as soon as two channels cross, the
//! selection flips -- and since the bass and the melody are usually the
//! two loudest, the output zigzagged between them, two octaves apart,
//! every few frames. That is not a melody with occasional wrong notes;
//! it is an unrecognisable jitter, and it is most of why the title tune
//! came back from a playtest as "not right".
//!
//! Instead: score each channel over the WHOLE capture and commit to one
//! lead for the tune. The melody is the voice that MOVES -- it has the
//! most distinct pitches -- with higher register as the tie-break. On
//! the real captures this picks channel C for the title tune (57
//! distinct pitches, 154-887Hz) over the 8-pitch bass drone on A, and
//! still picks A for the jump sfx, where B and C never sound at all.
//! The chosen channel is PRINTED so the call can be sanity-checked
//! rather than trusted blindly.
//!
//! RESTS ARE REAL NOTES. T0089 dropped silent runs entirely, on the
//! theory that a gap is cosmetic. It is not: dropping the melody's rests
//! (27% of the title tune's frames) compresses the rhythm into a
//! continuous run of notes and is the second reason it did not sound
//! like the tune. A rest is emitted as period $FFFF with the count byte
//! holding ~1ms units, and play_tune burns that time without toggling
//! the DAC.
//!
//! AY clock: 1773400 Hz (Spectrum), period reg -> Hz is clock/(16*period).
//! CoCo2 DAC period: period_for_hz(f) = round((894780/f - 72)/16), the
//! calibration from play_tone's own header in room36.asm (T0089 widened
//! it from 8 to 16 bits precisely because this reduction's output was
//! ~90% notes below the 8-bit floor).
//!
//! DO NOT re-derive this constant with `audiocheck.py --scan`. T0089
//! did, shipped it, and the user heard it immediately: --scan's pitch
//! reading was 25-34% low AND the error varied with frequency, so notes
//! came out 6-40 semitones sharp with every interval stretched. The
//! same WAVs read correctly in audiocheck.py's DEFAULT (tail-window)
//! mode, which agrees with the hand-derived 6809 cycle count to within
//! 1%. NOTES.md already warned that --scan's pitch is untrustworthy;
//! the warning was about short blips and got applied to a sustained
//! tone anyway. Sustained tone + default mode, cross-checked against
//! the instruction cycle counts, is the only trusted method here.
use std::env;
use std::fs;

struct Row {
    frame: u32,
    regs: [u32; 14],
}

/// Sentinel period meaning "rest": delay without toggling the DAC.
/// play_tune in room36.asm knows this value; $0000 still terminates.
const REST: u16 = 0xFFFF;

/// T0111: NOISE entries. The AY's noise generator has no pitch to reduce
/// -- fx10, the dragon's breath, runs with every tone bit off -- so it gets
/// its own entry type: period field $F00 | step delay (0..254; 255 is
/// excluded so amplitude 15 can never spell REST). Tone periods must stay
/// below NOISE_BASE, which the assert in main enforces.
const NOISE_BASE: u16 = 0x0F00;

/// play_noise's step cost is 42 + 8*delay cycles (average of its two LFSR
/// paths, 46 and 38 -- counted in room36.asm). Rates above the CoCo's
/// ~18kHz ceiling clamp to delay 1; the brightness of a noise burst does
/// not need to be exact the way a note's pitch does.
fn noise_delay_for_rate(rate_hz: f64) -> u16 {
    ((894780.0 / rate_hz - 42.0) / 8.0).round().clamp(1.0, 254.0) as u16
}

/// No single entry may block longer than this. Splitting a long note
/// into several entries of the same pitch does not change what you
/// hear -- play_tone no longer resets the wave phase between them -- but
/// it bounds how long a caller is stuck inside one entry. That matters
/// on the title screen, whose loop can only test for SPACE between
/// entries: at full length its longest note was 721ms, so the keypress
/// that starts the game could hang for most of a second.
const SPLIT_MS: f64 = 120.0;

/// play_tone's loop: 36 + 8*period cycles per half wave since the toggle
/// became `eora pt_amp` (extended, 3 cycles more than the old immediate
/// `eora #$40`), so 72 + 16*period per full wave. Measured with
/// harness/tonecal.asm in DEFAULT mode: 69.5Hz at period 800 exactly.
fn period_for_hz(f: f64) -> u16 {
    let p = ((894780.0 / f - 72.0) / 16.0).round();
    p.clamp(1.0, 65535.0) as u16
}

/// AY-3-8912 output level for each 4-bit volume setting, normalised to
/// full scale. The AY is logarithmic -- roughly 3dB a step at the top --
/// so mapping volume linearly onto the CoCo's DAC would squash the whole
/// melody (which lives at 9-15) into a barely-varying loud band.
const AY_LEVEL: [f64; 16] = [
    0.0, 0.0128, 0.0185, 0.0271, 0.0400, 0.0591, 0.0824, 0.1346, 0.1586, 0.2549, 0.3561,
    0.4470, 0.5641, 0.7083, 0.8422, 1.0,
];

/// AY volume 0-15 -> the 4-bit amplitude index play_tone uses.
fn amp_index(ay_vol: u32) -> u8 {
    (15.0 * AY_LEVEL[(ay_vol & 15) as usize]).round() as u8
}

/// Groups periods within ~4% (a quarter-tone) of each other so a
/// portamento/vibrato slide -- the AY engine nudges the period by a
/// handful of units almost every frame -- collapses into one run
/// instead of emitting a near-duplicate note every frame. Without this
/// the title tune alone reduced to 741 entries (2.2KB), more than the
/// target's entire remaining data budget; ROM budget forced this, not
/// a quality target picked in isolation.
fn bucket(p: u16, divisor: u16) -> u16 {
    let step = (p / divisor).max(1);
    p / step
}

/// Real 6809 wall-clock cost of one (period,halfwaves) entry, from
/// play_tone's own cost model (room36.asm's header): 16 cycles per unit
/// of period plus a 72-cycle fixed cost per full wave. The fixed part
/// is small, so cost is dominated by the PERIOD -- i.e. by how LOW the
/// note is. There is still no such thing as a cheap bass note (a single
/// half-wave at ~70Hz is ~7ms), which is why anything that can fire
/// during active gameplay needs a cap; but the caps this now computes
/// are far less brutal than the ones T0089 first shipped off a cost
/// model that was overestimating by 1.5-2.6x.
fn entry_ms(period: u16, half_waves: u32) -> f64 {
    // A rest's count byte is already in ~1ms units.
    if period == REST {
        return half_waves as f64;
    }
    // A noise entry's count is LFSR steps at 42 + 8*delay cycles each.
    if period >= NOISE_BASE {
        return half_waves as f64 * (42.0 + 8.0 * (period & 0xFF) as f64) / 894_780.0 * 1000.0;
    }
    // 16*p+72 is cycles per FULL wave (2 half-wave toggles, matching how
    // tonecal.asm measures -- a continuous toggle loop read back as a
    // frequency, i.e. one full cycle). One toggle costs half that.
    let cycles_per_halfwave = (16.0 * period as f64 + 72.0) / 2.0;
    half_waves as f64 * cycles_per_halfwave / 894_780.0 * 1000.0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 9 {
        eprintln!("usage: reduce <capture.csv> <total_frames> <label> <out.asm> <bucket_divisor> <max_ms> <max_halfwaves_per_run> <vol_step>");
        eprintln!("  vol_step: start a new entry when the amplitude index (0-15) moves by at");
        eprintln!("  least this much within a held pitch -- 1 follows every envelope step,");
        eprintln!("  16 never splits on volume (one level per note, the run's median).");
        eprintln!("  bucket_divisor: larger = coarser pitch quantization = fewer/smaller table");
        eprintln!("  entries. Use ~10 for long continuous tunes (ROM budget), ~24+ for short");
        eprintln!("  one-shot sfx where a few bytes don't matter but character does.");
        eprintln!("  max_ms: hard cap on TOTAL real blocking time -- a safety backstop that");
        eprintln!("  truncates trailing notes if still exceeded after the per-run cap below.");
        eprintln!("  max_halfwaves_per_run: caps how long any single held note plays --");
        eprintln!("  the real fix for one-shot sfx budget, since it shortens every pitch");
        eprintln!("  step while KEEPING the whole contour (e.g. a rising sweep stays a full");
        eprintln!("  sweep, just a quicker one), unlike max_ms which drops trailing notes");
        eprintln!("  outright. Use 255 (no extra cap) for tunes; single digits for sfx that");
        eprintln!("  can fire during active gameplay (walk/jump).");
        std::process::exit(2);
    }
    let csv = fs::read_to_string(&args[1]).expect("read csv");
    let total_frames: u32 = args[2].parse().expect("total_frames");
    let label = &args[3];
    let divisor: u16 = args[5].parse().expect("bucket_divisor");
    let max_ms: f64 = args[6].parse().expect("max_ms");
    let max_hw_per_run: u32 = args[7].parse().expect("max_halfwaves_per_run");
    let vol_step: i32 = args[8].parse().expect("vol_step");

    let rows: Vec<Row> = csv
        .lines()
        .skip(1)
        .filter(|l| !l.is_empty())
        .map(|l| {
            let v: Vec<u32> = l.split(',').map(|s| s.parse().unwrap()).collect();
            let mut regs = [0u32; 14];
            regs.copy_from_slice(&v[1..15]);
            Row { frame: v[0], regs }
        })
        .collect();

    // Channels: A = regs 0/1 + vol reg 8, B = 2/3 + 9, C = 4/5 + 10.
    // Volume's low nibble is the level; bit 4 means "use the envelope
    // generator", which none of these captures set. period==0 is silence
    // regardless of volume (the AY can't divide by zero).
    // The MIXER (reg 7) matters: bits 0-2 low = tone enabled on A/B/C. A
    // channel with its tone bit set is not playing its period register at
    // all -- the dragon-breath sfx (fx10) is pure noise with tone off on
    // every channel, and its tone register holds 65533, which used to be
    // reduced into a "note" at 1.7Hz. Honouring the bit turns it into
    // silence here instead, which is what a tone-only reduction should
    // say about a noise effect.
    let chan_of = |r: &Row, ch: usize| -> Option<(u32, u32)> {
        let (lo, hi, vol) = [(0, 1, 8), (2, 3, 9), (4, 5, 10)][ch];
        let period = r.regs[lo] + r.regs[hi] * 256;
        let v = r.regs[vol] & 0x0F;
        let tone_on = (r.regs[7] >> ch) & 1 == 0;
        if period > 0 && v > 0 && tone_on {
            Some((period, v))
        } else {
            None
        }
    };

    // A channel playing NOISE ONLY (tone bit off, noise bit on). A channel
    // mixing tone AND noise (fx1, fx25) stays on the tone path; only its
    // tone half is ported, as before.
    let noise_of = |r: &Row, ch: usize| -> Option<(u32, u32)> {
        let v = r.regs[[8, 9, 10][ch]] & 0x0F;
        let tone_on = (r.regs[7] >> ch) & 1 == 0;
        let noise_on = (r.regs[7] >> (ch + 3)) & 1 == 0;
        if v > 0 && noise_on && !tone_on {
            Some(((r.regs[6] & 31).max(1), v))
        } else {
            None
        }
    };

    // Pick ONE lead channel for the whole capture -- see this file's
    // header for why per-frame "loudest" is wrong. Melody = the voice
    // that moves most (most distinct pitches), higher register breaking
    // ties (a smaller AY period is a higher note).
    let lead_tone = (0..3)
        .max_by_key(|&ch| {
            let ps: Vec<u32> = rows.iter().filter_map(|r| chan_of(r, ch)).map(|c| c.0).collect();
            let distinct = ps.iter().collect::<std::collections::HashSet<_>>().len();
            let median_period = if ps.is_empty() {
                u32::MAX
            } else {
                let mut s = ps.clone();
                s.sort_unstable();
                s[s.len() / 2]
            };
            // higher register = smaller period, so negate for max_by_key
            (distinct, std::cmp::Reverse(median_period))
        })
        .unwrap();

    // A capture with no tone anywhere (fx10) is led by its busiest NOISE
    // channel instead; with no tone, "most distinct pitches" ties at zero
    // and would pick a silent channel.
    let any_tone = (0..3).any(|ch| rows.iter().any(|r| chan_of(r, ch).is_some()));
    let lead = if any_tone {
        lead_tone
    } else {
        (0..3)
            .max_by_key(|&ch| rows.iter().filter(|r| noise_of(r, ch).is_some()).count())
            .unwrap()
    };

    struct Note {
        start_frame: u32,
        hz: Option<f64>, // None = a rest, or noise if `noise` is set
        noise: Option<u32>, // AY noise period (reg 6, 1..31)
        amp: u8,
    }
    let notes: Vec<Note> = rows
        .iter()
        .map(|r| match (chan_of(r, lead), noise_of(r, lead)) {
            (Some((p, v)), _) => Note {
                start_frame: r.frame,
                hz: Some(1_773_400.0 / (16.0 * p as f64)),
                noise: None,
                amp: amp_index(v),
            },
            (None, Some((np, v))) => Note {
                start_frame: r.frame,
                hz: None,
                noise: Some(np),
                amp: amp_index(v),
            },
            (None, None) => Note {
                start_frame: r.frame,
                hz: None,
                noise: None,
                amp: 0,
            },
        })
        .collect();

    // Collapse consecutive frames that map to the same pitch bucket (and,
    // per vol_step, a close enough amplitude) or are both silent into
    // runs; compute each run's duration in real seconds from Spectrum
    // frame deltas (50Hz), converting to a half-wave count at the run's
    // own frequency.
    struct Entry {
        coco_period: u16,
        half_waves: u32,
        amp: u8,
    }
    let mut entries: Vec<Entry> = Vec::new();
    let mut i = 0;
    while i < notes.len() {
        let hz = notes[i].hz;
        let start = notes[i].start_frame;
        let mut j = i + 1;
        let this_bucket = hz.map(|h| bucket(period_for_hz(h), divisor));
        while j < notes.len() {
            let same = match (hz, notes[j].hz) {
                (Some(_), Some(h2)) => {
                    Some(bucket(period_for_hz(h2), divisor)) == this_bucket
                        && (notes[j].amp as i32 - notes[i].amp as i32).abs() < vol_step
                }
                // rests group with rests, noise with noise (split on the
                // volume swell per vol_step; the rate is the run's median)
                (None, None) => {
                    notes[i].noise.is_some() == notes[j].noise.is_some()
                        && (notes[i].noise.is_none()
                            || (notes[j].amp as i32 - notes[i].amp as i32).abs() < vol_step)
                }
                _ => false,
            };
            if !same {
                break;
            }
            j += 1;
        }
        let end = if j < notes.len() {
            notes[j].start_frame
        } else {
            total_frames
        };
        let dur_s = (end - start) as f64 / 50.0;
        // The run's MEDIAN pitch and level, not its first frame's. A run
        // often opens on the tail of a slide from the previous note, so
        // the first frame was the least representative one to pick.
        let mut run_hz: Vec<f64> = notes[i..j].iter().filter_map(|n| n.hz).collect();
        run_hz.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mut run_amp: Vec<u8> = notes[i..j].iter().map(|n| n.amp).collect();
        run_amp.sort_unstable();
        let amp = run_amp[run_amp.len() / 2];
        let hz = run_hz.get(run_hz.len() / 2).copied();
        let this_period = hz.map(period_for_hz);
        match (hz, this_period) {
            (Some(h), Some(p)) => {
                assert!(
                    p < NOISE_BASE,
                    "{label}: period {p} would collide with the $0Fxx noise entries pt_step decodes"
                );
                let mut half_waves = (2.0 * h * dur_s).round() as u32;
                if half_waves == 0 {
                    half_waves = 1;
                }
                // max_hw_per_run SHORTENS a held note on purpose (sfx
                // budget). Anything left over after that is split into
                // 255-sized entries rather than lost -- T0089 passed 255
                // here for tunes, which silently CLAMPED every long note
                // to 255 half-waves and cost the title tune most of its
                // length (20s of source played back as 4.2s).
                half_waves = half_waves.min(max_hw_per_run);
                // chunk = whichever is smaller, 255 (the count byte) or
                // SPLIT_MS worth of half-waves at this pitch
                let chunk = (((SPLIT_MS / 1000.0) * 2.0 * h).round().max(1.0) as u32).min(255);
                while half_waves > 0 {
                    let take = half_waves.min(chunk);
                    entries.push(Entry {
                        coco_period: p,
                        half_waves: take,
                        amp,
                    });
                    half_waves -= take;
                }
            }
            // NOISE run: count = LFSR steps at the CoCo rate nearest the
            // AY's median noise rate for the run; max_hw_per_run caps steps.
            (None, _) if notes[i].noise.is_some() => {
                let mut nps: Vec<u32> = notes[i..j].iter().filter_map(|n| n.noise).collect();
                nps.sort_unstable();
                let np = nps[nps.len() / 2].max(1);
                let d = noise_delay_for_rate(1_773_400.0 / (16.0 * np as f64));
                let actual = 894_780.0 / (42.0 + 8.0 * d as f64);
                let mut steps = ((dur_s * actual).round() as u32).max(1).min(max_hw_per_run);
                let chunk = (((SPLIT_MS / 1000.0) * actual).round().max(1.0) as u32).min(255);
                while steps > 0 {
                    let take = steps.min(chunk);
                    entries.push(Entry {
                        coco_period: NOISE_BASE | d,
                        half_waves: take,
                        amp,
                    });
                    steps -= take;
                }
            }
            // A real rest: period $FFFF, count in ~1ms units. Keeping
            // these is what preserves the tune's rhythm.
            _ => {
                let mut ms = (dur_s * 1000.0).round() as u32;
                while ms > 0 {
                    let take = ms.min(SPLIT_MS as u32);
                    entries.push(Entry {
                        coco_period: REST,
                        half_waves: take,
                        amp: 0,
                    });
                    ms -= take;
                }
            }
        }
        i = j;
    }

    // Rests at either END are just capture window, not music. Trailing:
    // tune1 is ~1.3s of music inside a 20s capture and would otherwise
    // emit ~75 rest entries of dead air, holding up the respawn it plays
    // during. Leading: the lead channel often starts a few frames after
    // the other two, and that silence ate the ENTIRE max_ms budget of
    // the pickup sfx once, reducing it to a single rest -- i.e. to
    // nothing. Both ends get trimmed; rests BETWEEN notes are music and
    // stay.
    while entries.last().map_or(false, |e| e.coco_period == REST) {
        entries.pop();
    }
    let lead_in = entries
        .iter()
        .position(|e| e.coco_period != REST)
        .unwrap_or(entries.len());
    entries.drain(..lead_in);

    let total_entries = entries.len();
    let mut budget_ms = max_ms;
    let mut kept = Vec::new();
    for e in entries {
        let cost = entry_ms(e.coco_period, e.half_waves);
        if cost > budget_ms {
            break;
        }
        budget_ms -= cost;
        kept.push(e);
    }
    let truncated = total_entries - kept.len();
    let entries = kept;

    let mut asm = format!(
        "; Auto-generated by tools/aycapture/reduce from a real MUSIC128.SPC\n\
         ; capture -- loudest-channel reduction, silence dropped. See\n\
         ; tools/aycapture/src/bin/reduce.rs for the method. Format matches\n\
         ; play_tune: (period:fdb, halfwaves:fcb) triples, fdb 0 terminates.\n\
         {label}_notes\n"
    );
    for e in &entries {
        let word = if e.coco_period == REST {
            REST
        } else {
            ((e.amp as u16) << 12) | e.coco_period
        };
        asm.push_str(&format!("        fdb ${:04x}\n        fcb {}\n", word, e.half_waves));
    }
    asm.push_str("        fdb 0\n");

    fs::write(&args[4], &asm).expect("write out.asm");
    let rests = entries.iter().filter(|e| e.coco_period == REST).count();
    println!(
        "{}: lead=ch{} | {} rows -> {} entries ({} notes + {} noise + {} rests), ~{:.0}ms playback ({} truncated by max_ms)",
        label,
        ['A', 'B', 'C'][lead],
        rows.len(),
        entries.len(),
        entries.len() - rests - entries.iter().filter(|e| e.coco_period != REST && e.coco_period >= NOISE_BASE).count(),
        entries.iter().filter(|e| e.coco_period != REST && e.coco_period >= NOISE_BASE).count(),
        rests,
        max_ms - budget_ms,
        truncated
    );
}
