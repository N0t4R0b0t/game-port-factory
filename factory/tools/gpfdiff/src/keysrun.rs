//! Keys mode, the MAME side: start MAME with `lua/gpf_keys.lua` and a plan file, collect what the script
//! prints (`GPF READY`, `GPF F` samples, `GPF C` changes, `GPF DONE`), turn it into a trace.
//!
//! Nothing is injected into the program, nothing is parked: the emulator runs free and the script only
//! presses keys and reads RAM on a frame clock (see `keys.rs` for the frame semantics). So there is no
//! protocol dialogue and no stdin: the script runs to its `END` frame and prints as it goes.

use crate::fields::{FieldMap, Source};
use crate::keys::{self, KeysCfg, Plan};
use crate::mame::MameKind;
use crate::runner::BackendOpts;
use crate::scenario::Scenario;
use crate::trace::Trace;
use crate::proc::LineProc;
use std::process::{Command, Stdio};
use std::time::Duration;

const SCRIPT: &str = include_str!("../lua/gpf_keys.lua");

static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

#[derive(Clone, Debug)]
pub struct MameKeysCfg {
    pub kind: MameKind,
    pub mame: String,
    pub machine: String,
    pub rompath: Option<String>,
    /// zx48: `.sna` snapshot; coco2: DECB `.bin`.
    pub image: String,
    /// Per-line wait (wall clock).
    pub timeout: Duration,
    pub debug: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub frame: u32,
    pub addr: u16,
    pub old: u8,
    pub new: u8,
}

#[derive(Clone, Debug, Default)]
pub struct Outcome {
    /// The boot frame at which the gate held (= timeline frame 0) and the value it saw.
    pub ready: (u32, u64),
    /// (timeline frame, bytes) per sample, in plan order.
    pub samples: Vec<(u32, Vec<u8>)>,
    pub changes: Vec<Change>,
    /// Frames in which more bytes changed than the script lists, with the count.
    pub bulk: Vec<(u32, u32)>,
}

/// One MAME process (shared line plumbing in `proc.rs`) and the temp files to remove afterwards.
struct Proc {
    lp: LineProc,
    files: Vec<std::path::PathBuf>,
}

impl Proc {
    fn context(&self) -> String {
        self.lp.context()
    }

    fn note(&mut self, l: String) {
        self.lp.note(l)
    }

    /// Next `GPF ` line (prefix stripped), skipping chatter.
    fn next_gpf(&mut self, timeout: Duration, debug: bool) -> Result<String, String> {
        self.lp.next_gpf(timeout, debug)
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        self.lp.reap();
        for f in &self.files {
            let _ = std::fs::remove_file(f);
        }
    }
}

fn spawn(cfg: &MameKeysCfg, plan: &Plan, load_list: Option<&str>) -> Result<Proc, String> {
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = std::env::temp_dir();
    let tag = format!("gpfdiff_keys_{}_{seq}", std::process::id());
    let script = tmp.join(format!("{tag}.lua"));
    let planf = tmp.join(format!("{tag}.plan"));
    let mut files = vec![script.clone(), planf.clone()];
    std::fs::write(&script, SCRIPT).map_err(|e| format!("{}: {e}", script.display()))?;
    std::fs::write(&planf, plan.to_text()).map_err(|e| format!("{}: {e}", planf.display()))?;
    let mut cmd = Command::new(&cfg.mame);
    cmd.arg(&cfg.machine);
    if let Some(r) = &cfg.rompath {
        cmd.arg("-rompath").arg(r);
    }
    match (cfg.kind, load_list) {
        (MameKind::Coco2, Some(list)) => {
            let p = tmp.join(format!("{tag}.load"));
            std::fs::write(&p, list).map_err(|e| format!("{}: {e}", p.display()))?;
            cmd.arg("-ext").arg("").env("GPF_LOAD", &p);
            files.push(p);
        }
        _ => {
            cmd.arg("-snapshot").arg(&cfg.image);
        }
    }
    // No -debug: nothing is stopped, nothing is written. Headless and as fast as the host allows.
    cmd.arg("-autoboot_script")
        .arg(&script)
        .args(["-video", "none", "-sound", "none", "-nothrottle", "-nowindow"])
        .args(["-noreadconfig", "-skip_gameinfo", "-seconds_to_run", "36000"])
        .arg("-cfg_directory")
        .arg(tmp.join("gpfdiff_mame_cfg"))
        .env("GPF_PLAN", &planf)
        .stdin(Stdio::null());
    if cfg.debug {
        eprintln!("[mame] spawn {cmd:?}");
    }
    let lp = LineProc::spawn(&mut cmd, &cfg.mame)?;
    Ok(Proc { lp, files })
}

fn parse_hex(h: &str) -> Result<Vec<u8>, String> {
    if h.len() % 2 != 0 {
        return Err(format!("odd number of hex digits in `{h}`"));
    }
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).map_err(|_| format!("bad hex in `{h}`"))).collect()
}

/// Outcome of one attempt: either complete, or the gate timed out (with what was seen).
enum Attempt {
    Done(Outcome),
    GateTimeout { boot_frame: u32, value: u64, pc: u32 },
}

fn attempt(cfg: &MameKeysCfg, plan: &Plan, load_list: Option<&str>) -> Result<Attempt, String> {
    let mut p = spawn(cfg, plan, load_list)?;
    let mut o = Outcome::default();
    let mut ready = false;
    loop {
        let l = p.next_gpf(cfg.timeout, cfg.debug)?;
        let (tag, rest) = l.split_once(' ').unwrap_or((l.as_str(), ""));
        let nums = |s: &str| -> Result<Vec<u64>, String> {
            s.split_whitespace().map(|x| x.parse::<u64>().map_err(|_| format!("script error: malformed line `GPF {l}`"))).collect()
        };
        match tag {
            "ERR" => return Err(format!("script error: {rest}{}", p.context())),
            "READY" => {
                let n = nums(rest)?;
                if n.len() != 2 {
                    return Err(format!("script error: malformed line `GPF {l}`"));
                }
                if let Some(g) = &plan.gate {
                    if !g.holds(n[1]) {
                        return Err(format!("script error: the Lua gate says it holds at value {} but gate {} does not", n[1], g.describe()));
                    }
                }
                o.ready = (n[0] as u32, n[1]);
                ready = true;
            }
            "F" => {
                let (f, hex) = rest.split_once(' ').unwrap_or((rest, ""));
                let f: u32 = f.parse().map_err(|_| format!("script error: malformed line `GPF {l}`"))?;
                let bytes = parse_hex(hex).map_err(|e| format!("script error: {e}"))?;
                let want = plan.samples.get(o.samples.len()).copied();
                if want != Some(f) || bytes.len() != plan.sample_bytes() {
                    return Err(format!(
                        "harness desync: sample #{} arrived for frame {f} with {} bytes, the plan says frame {:?} with {} bytes",
                        o.samples.len(),
                        bytes.len(),
                        want,
                        plan.sample_bytes()
                    ));
                }
                o.samples.push((f, bytes));
            }
            "C" => {
                let n = nums(rest)?;
                if n.len() != 4 {
                    return Err(format!("script error: malformed line `GPF {l}`"));
                }
                o.changes.push(Change { frame: n[0] as u32, addr: n[1] as u16, old: n[2] as u8, new: n[3] as u8 });
            }
            "N" => {
                let n = nums(rest)?;
                if n.len() != 2 {
                    return Err(format!("script error: malformed line `GPF {l}`"));
                }
                o.bulk.push((n[0] as u32, n[1] as u32));
            }
            "GATE_TIMEOUT" => {
                let n = nums(rest)?;
                if n.len() != 3 {
                    return Err(format!("script error: malformed line `GPF {l}`"));
                }
                return Ok(Attempt::GateTimeout { boot_frame: n[0] as u32, value: n[1], pc: n[2] as u32 });
            }
            "DONE" => {
                if !ready {
                    return Err("script error: finished without ever reporting READY".into());
                }
                if plan.watch.is_none() && o.samples.len() != plan.samples.len() {
                    return Err(format!("harness desync: {} samples arrived, the plan has {}", o.samples.len(), plan.samples.len()));
                }
                return Ok(Attempt::Done(o));
            }
            _ => p.note(format!("GPF {l}")),
        }
    }
}

/// The message of a gate timeout: names the gate, the clock and the last value the script saw.
pub fn gate_timeout_message(plan: &Plan, timeout_ms: u64, boot_frame: u32, value: u64, fps: u32) -> String {
    let g = plan.gate.as_ref().map(|g| g.describe()).unwrap_or_else(|| "(no gate)".into());
    format!(
        "timed out waiting for the ready gate: [boot] ready ({g}) never held within {timeout_ms} ms ({boot_frame} frames at {fps} fps); last observed value {value} (0x{value:X})"
    )
}

/// Boot the program under MAME and play `plan`. For coco2 the DECB image is loaded by the script; if the gate then
/// times out with the CPU outside the loaded image (the PC write did not start the program: MAME can resume a
/// half-done BASIC instruction) the whole boot is retried, at most 3 times.
pub fn run(cfg: &MameKeysCfg, plan: &Plan, timeout_ms: u64, fps: u32) -> Result<Outcome, String> {
    let (load_list, covers): (Option<String>, Option<crate::coco::Decb>) = match cfg.kind {
        MameKind::Zx48 => (None, None),
        MameKind::Coco2 => {
            let bytes = std::fs::read(&cfg.image).map_err(|e| format!("{}: {e}", cfg.image))?;
            let d = crate::coco::parse_decb(&bytes).map_err(|e| format!("invalid {}: {e}", cfg.image))?;
            if !d.covers(d.exec) {
                return Err(format!("invalid {}: the entry ${:04x} is not inside a loaded segment", cfg.image, d.exec));
            }
            (Some(d.load_list()), Some(d))
        }
    };
    let tries = if covers.is_some() { 3 } else { 1 };
    for k in 1..=tries {
        match attempt(cfg, plan, load_list.as_deref())? {
            Attempt::Done(o) => return Ok(o),
            Attempt::GateTimeout { boot_frame, value, pc } => {
                let lost = covers.as_ref().map_or(false, |d| !d.covers(pc as u16));
                if lost && k < tries {
                    continue;
                }
                let mut m = gate_timeout_message(plan, timeout_ms, boot_frame, value, fps);
                if covers.is_some() {
                    m.push_str(&format!("; the CPU was at PC=${pc:04X}{}", if lost { " (outside the loaded image: the program did not start)" } else { "" }));
                }
                return Err(m);
            }
        }
    }
    unreachable!("the loop returns")
}

/// The byte ranges of a resolved field map, in field order (what every sample reads).
pub fn regions_of(map: &FieldMap) -> Result<Vec<(u16, usize)>, String> {
    map.fields
        .iter()
        .map(|f| match &f.source {
            Source::Addr(a) => Ok((*a, f.size)),
            _ => Err(format!("field `{}`: keys mode reads raw addresses (addr or a label from the symbol file)", f.name)),
        })
        .collect()
}

pub fn mame_cfg(platform: &str, image: &str, o: &BackendOpts) -> MameKeysCfg {
    MameKeysCfg {
        kind: if platform == "coco2" { MameKind::Coco2 } else { MameKind::Zx48 },
        mame: o.mame.clone(),
        machine: o.machine.clone(),
        rompath: o.rompath.clone().filter(|s| !s.is_empty()),
        image: image.into(),
        timeout: Duration::from_secs(o.timeout),
        debug: o.debug,
    }
}

/// Run one scenario in keys mode and return its trace.
pub fn run_scenario(cfg: &KeysCfg, image: &str, o: &BackendOpts, fields: &FieldMap, sc: &Scenario) -> Result<Trace, String> {
    let map = fields.resolve(&mut |n| cfg.labels.get(n).copied().ok_or_else(|| format!("label `{n}` missing from the labels file (keys mode reads `label` fields through `labels = \"...\"`)")))?;
    let regions = regions_of(&map)?;
    let plan = keys::scenario_plan(cfg, sc, regions.clone())?;
    let out = run(&mame_cfg(&cfg.platform, image, o), &plan, cfg.timeout_ms, cfg.time.fps)?;
    let samples: Vec<Vec<u8>> = out.samples.into_iter().map(|s| s.1).collect();
    keys::samples_to_trace(&map, &regions, &samples)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Cond, Gate};

    #[test]
    fn gate_timeout_message_names_gate_clock_and_last_value() {
        let plan = Plan { gate: Some(Gate { addr: 0xF046, size: 1, big_endian: false, cond: Cond::In(1, 254) }), ..Plan::default() };
        let m = gate_timeout_message(&plan, 500, 25, 255, 50);
        assert!(m.contains("ready gate") && m.contains("1 byte at $F046 in [1, 254]") && m.contains("500 ms (25 frames at 50 fps)") && m.contains("last observed value 255 (0xFF)"), "{m}");
        assert_eq!(crate::errors::classify(&m), crate::errors::Kind::Gate);
    }

    #[test]
    fn hex_parsing() {
        assert_eq!(parse_hex("00ff7a").unwrap(), vec![0, 255, 0x7a]);
        assert!(parse_hex("0").is_err() && parse_hex("zz").is_err());
        assert_eq!(parse_hex("").unwrap(), Vec::<u8>::new());
    }
}
