//! MAME backend (ZX Spectrum 48K and Tandy CoCo 2): headless MAME driven by a Lua script
//! (`lua/gpf_mame.lua`). The two platforms share everything here; what differs is in
//! [`MameKind`]: how the image gets in (zx48: `-snapshot x.sna`; coco2: the script writes the
//! DECB segments into RAM, see `coco.rs`), the symbol file format and the register that
//! carries the buttons (Z80 `A`, 6809 `A`).
//!
//! IPC is the simplest thing that is robust: the Lua script runs inside MAME, puts a
//! debugger breakpoint on `gpf_input_ret`, and on every hit
//!   1. prints `GPF S <42 hex digits>` (gpf_state 16 B + gpf_bricks 5 B) on stdout,
//!   2. *blocks* reading a command line on stdin (MAME is parked, so there is no timing),
//!   3. `B <n>` -> writes A = n, reads A and PC back and prints `GPF ACK <A> <PC>`,
//!      then resumes. `Q` -> MAME exits.
//! This side only has to verify the ACK (the write took, and we really were parked at
//! `gpf_input_ret`) and parse the next `S` line. Everything on stdout without the
//! `GPF ` prefix is MAME chatter and is kept only as context for error messages.
//! The script is embedded and written to a temp file, so the binary has no install deps.
//!
//! Details learned the hard way are in ports/brickfall-zxspectrum48/NOTES.md.

use crate::state::{RawState, BRICKS_LEN, STATE_LEN};
use crate::target::Target;
use std::collections::HashMap;
use crate::proc::LineProc;
use std::io::Write;
use std::process::{ChildStdin, Command, Stdio};
use std::time::Duration;

/// Unique temp-file names within one process (the unit tests run several targets in parallel).
static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

const SCRIPT: &str = include_str!("../lua/gpf_mame.lua");

/// Which machine family MAME is emulating for this port.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MameKind {
    Zx48,
    Coco2,
}

impl MameKind {
    /// Name of the CPU register the Lua script writes the buttons into (MAME's own state name).
    pub fn input_reg(self) -> &'static str {
        "A" // Z80 `A` and 6809 `A` (the 6809's A is the high byte of D)
    }
}

/// Parse a sjasmplus `--sym` file: lines `name: equ 0x0000F000`.
pub fn parse_labels(text: &str) -> HashMap<String, u16> {
    let mut m = HashMap::new();
    for l in text.lines() {
        let t: Vec<&str> = l.split_whitespace().collect();
        if t.len() == 3 && t[0].ends_with(':') && t[1] == "equ" {
            let v = t[2].trim_start_matches("0x");
            if let Ok(a) = u32::from_str_radix(v, 16) {
                if a <= 0xffff {
                    m.insert(t[0].trim_end_matches(':').to_string(), a as u16);
                }
            }
        }
    }
    m
}

/// `GPF S <hex>` payload -> RawState.
pub fn parse_state_hex(hex: &str) -> Result<RawState, String> {
    let hex = hex.trim();
    if hex.len() != 2 * (STATE_LEN + BRICKS_LEN) {
        return Err(format!("state line has {} hex digits, want {}", hex.len(), 2 * (STATE_LEN + BRICKS_LEN)));
    }
    let mut bytes = Vec::with_capacity(STATE_LEN + BRICKS_LEN);
    for i in 0..STATE_LEN + BRICKS_LEN {
        bytes.push(
            u8::from_str_radix(&hex[2 * i..2 * i + 2], 16)
                .map_err(|_| format!("bad hex in state line: {hex}"))?,
        );
    }
    let mut state = [0u8; STATE_LEN];
    state.copy_from_slice(&bytes[..STATE_LEN]);
    let mut bricks = [0u8; BRICKS_LEN];
    bricks.copy_from_slice(&bytes[STATE_LEN..]);
    Ok(RawState { state, bricks })
}

/// `GPF ACK <A> <PC>` payload -> (A, PC).
pub fn parse_ack(rest: &str) -> Result<(u32, u32), String> {
    let mut it = rest.split_whitespace();
    let a = it.next().and_then(|v| v.parse().ok());
    let pc = it.next().and_then(|v| v.parse().ok());
    match (a, pc, it.next()) {
        (Some(a), Some(pc), None) => Ok((a, pc)),
        _ => Err(format!("malformed ACK `{rest}`")),
    }
}

/// The write-took check: A must read back as the injected buttons and PC must still
/// be `gpf_input_ret` (recipe: never-write-pc-from-an-emulator-script-without-checking
/// -the-jump-actually-took, here applied to a register write).
pub fn check_ack(ack: (u32, u32), buttons: u8, input_ret: u16) -> Result<(), String> {
    if ack.0 != buttons as u32 {
        return Err(format!("register write did not take: wrote A={buttons}, read back A={}", ack.0));
    }
    if ack.1 != input_ret as u32 {
        return Err(format!(
            "CPU not parked at gpf_input_ret: PC={:#06x}, expected {:#06x}",
            ack.1, input_ret
        ));
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct MameConfig {
    pub kind: MameKind,
    pub mame: String,
    pub machine: String,
    pub rompath: Option<String>,
    /// Program image: `.sna` (zx48) or DECB `.bin` (coco2).
    pub sna: String,
    pub labels: String,
    /// Per-wait timeout (boot, and each step's breakpoint hit).
    pub timeout: Duration,
    pub debug: bool,
}

pub struct MameTarget {
    cfg: MameConfig,
    gpf_state: u16,
    gpf_bricks: u16,
    input_ret: u16,
    labels: HashMap<String, u16>,
    proc: Option<LineProc>,
    stdin: Option<ChildStdin>,
    state: Option<RawState>,
    script_path: Option<std::path::PathBuf>,
    /// coco2: the load list handed to the Lua script (written to a temp file at boot).
    load_list: Option<String>,
    load_path: Option<std::path::PathBuf>,
}

impl MameTarget {
    pub fn new(cfg: MameConfig) -> Result<MameTarget, String> {
        let text = std::fs::read_to_string(&cfg.labels).map_err(|e| format!("{}: {e}", cfg.labels))?;
        let labels = match cfg.kind {
            MameKind::Zx48 => parse_labels(&text),
            MameKind::Coco2 => crate::coco::parse_labels(&text),
        };
        let get = |n: &str| {
            labels.get(n).copied().ok_or_else(|| format!("label `{n}` missing from {}", cfg.labels))
        };
        let (gpf_state, gpf_bricks, input_ret) = (get("gpf_state")?, get("gpf_bricks")?, get("gpf_input_ret")?);
        if !std::path::Path::new(&cfg.sna).is_file() {
            return Err(format!("{}: no such file", cfg.sna));
        }
        let load_list = match cfg.kind {
            MameKind::Zx48 => None,
            MameKind::Coco2 => {
                let bytes = std::fs::read(&cfg.sna).map_err(|e| format!("{}: {e}", cfg.sna))?;
                let d = crate::coco::parse_decb(&bytes).map_err(|e| format!("invalid {}: {e}", cfg.sna))?;
                if !d.covers(input_ret) || !d.covers(d.exec) {
                    return Err(format!(
                        "invalid {}: entry ${:04x} or gpf_input_ret ${input_ret:04x} is not inside a loaded segment (stale image/map pair?)",
                        cfg.sna, d.exec
                    ));
                }
                Some(d.load_list())
            }
        };
        Ok(MameTarget {
            gpf_state,
            gpf_bricks,
            input_ret,
            labels,
            cfg,
            proc: None,
            stdin: None,
            state: None,
            script_path: None,
            load_list,
            load_path: None,
        })
    }

    fn dbg(&self, m: impl FnOnce() -> String) {
        if self.cfg.debug {
            eprintln!("[mame] {}", m());
        }
    }

    fn context(&self) -> String {
        self.proc.as_ref().map(|p| p.context()).unwrap_or_default()
    }

    /// Next `GPF ` line (prefix stripped), skipping chatter; a script `ERR` line is an error.
    fn next_gpf(&mut self) -> Result<String, String> {
        let (timeout, debug) = (self.cfg.timeout, self.cfg.debug);
        let l = self.proc.as_mut().ok_or("not started")?.next_gpf(timeout, debug)?;
        if let Some(e) = l.strip_prefix("ERR ") {
            return Err(format!("script error: {e}{}", self.context()));
        }
        Ok(l)
    }

    fn next_state(&mut self) -> Result<(), String> {
        let l = self.next_gpf()?;
        let hex = l.strip_prefix("S ").ok_or_else(|| format!("expected a state line, got `{l}`"))?;
        self.state = Some(parse_state_hex(hex)?);
        Ok(())
    }
}

impl Target for MameTarget {
    fn boot(&mut self) -> Result<(), String> {
        let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let script = std::env::temp_dir().join(format!("gpfdiff_mame_{}_{seq}_{}.lua", std::process::id(), self.input_ret));
        std::fs::write(&script, SCRIPT).map_err(|e| format!("{}: {e}", script.display()))?;
        let mut cmd = Command::new(&self.cfg.mame);
        cmd.arg(&self.cfg.machine);
        if let Some(r) = &self.cfg.rompath {
            cmd.arg("-rompath").arg(r);
        }
        match (&self.load_list, self.cfg.kind) {
            (Some(list), MameKind::Coco2) => {
                let p = std::env::temp_dir().join(format!("gpfdiff_mame_{}_{seq}_{}.load", std::process::id(), self.input_ret));
                std::fs::write(&p, list).map_err(|e| format!("{}: {e}", p.display()))?;
                // no cartridge/disk extension: BASIC boots straight to its prompt, the script loads the image
                cmd.arg("-ext").arg("");
                cmd.env("GPF_LOAD", &p);
                self.load_path = Some(p);
            }
            _ => {
                cmd.arg("-snapshot").arg(&self.cfg.sna);
            }
        }
        cmd.env("GPF_REG", self.cfg.kind.input_reg());
        cmd.arg("-autoboot_script")
            .arg(&script)
            // headless and fast; -debug is needed for breakpoints, `-debugger none`
            // keeps it from opening a Qt window; -noreadconfig = ignore ~/.mame cfg.
            .args(["-video", "none", "-sound", "none", "-nothrottle", "-nowindow"])
            .args(["-debug", "-debugger", "none", "-noreadconfig", "-skip_gameinfo"])
            .args(["-seconds_to_run", "36000"])
            // MAME writes cfg/ into the cwd on exit; keep it out of the source tree.
            .arg("-cfg_directory")
            .arg(std::env::temp_dir().join("gpfdiff_mame_cfg"))
            .env("GPF_STATE", self.gpf_state.to_string())
            .env("GPF_BRICKS", self.gpf_bricks.to_string())
            .env("GPF_RET", self.input_ret.to_string())
            .stdin(Stdio::piped());
        self.dbg(|| format!("spawn {cmd:?}"));
        let mut lp = LineProc::spawn(&mut cmd, &self.cfg.mame)?;
        self.stdin = lp.child.stdin.take();
        self.proc = Some(lp);
        self.script_path = Some(script);
        let l = self.next_gpf()?;
        if l != "READY" {
            return Err(format!("expected READY from the Lua script, got `{l}`"));
        }
        self.next_state()
    }

    fn read_state(&mut self) -> Result<RawState, String> {
        self.state.clone().ok_or_else(|| "no state yet (boot first)".to_string())
    }

    fn provide_input(&mut self, buttons: u8) -> Result<(), String> {
        self.state = None;
        let w = self.stdin.as_mut().ok_or("not started")?;
        writeln!(w, "B {buttons}").and_then(|_| w.flush()).map_err(|e| format!("MAME stdin: {e}"))?;
        let l = self.next_gpf()?;
        let rest = l.strip_prefix("ACK ").ok_or_else(|| format!("expected ACK, got `{l}`"))?;
        check_ack(parse_ack(rest)?, buttons, self.input_ret)?;
        self.next_state()
    }

    fn label(&self, name: &str) -> Option<u16> {
        self.labels.get(name).copied()
    }

    /// `P <addr> <len>` -> `GPF M <hex>`: read RAM while parked (the script answers and keeps waiting).
    fn peek(&mut self, addr: u16, len: usize) -> Result<Vec<u8>, String> {
        if self.state.is_none() {
            return Err("cannot peek: the target is not parked at an input point".into());
        }
        let w = self.stdin.as_mut().ok_or("not started")?;
        writeln!(w, "P {addr} {len}").and_then(|_| w.flush()).map_err(|e| format!("MAME stdin: {e}"))?;
        let l = self.next_gpf()?;
        let hex = l.strip_prefix("M ").ok_or_else(|| format!("expected a memory line, got `{l}`"))?.trim();
        if hex.len() != 2 * len {
            return Err(format!("memory line has {} hex digits, want {}", hex.len(), 2 * len));
        }
        (0..len)
            .map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).map_err(|_| format!("bad hex in memory line: {hex}")))
            .collect()
    }

    fn shutdown(&mut self) {
        if let Some(mut w) = self.stdin.take() {
            let _ = writeln!(w, "Q");
            let _ = w.flush();
        }
        if let Some(mut p) = self.proc.take() {
            p.reap();
        }
        if let Some(p) = self.script_path.take() {
            let _ = std::fs::remove_file(p);
        }
        if let Some(p) = self.load_path.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

impl Drop for MameTarget {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fields::FieldMap;
    use crate::scenario::Scenario;
    use crate::target::run_scenario;

    #[test]
    fn parses_sjasmplus_sym() {
        let m = parse_labels("gpf_state: equ 0x0000F000\ngpf_input_ret: equ 0x00008071\nbogus\nx: equ 0x00012345\nW.l: equ zz\n");
        assert_eq!(m["gpf_state"], 0xf000);
        assert_eq!(m["gpf_input_ret"], 0x8071);
        assert_eq!(m.len(), 2); // out-of-range and malformed lines are dropped
    }

    #[test]
    fn parses_state_line() {
        let r = parse_state_hex("0500010300").unwrap_err();
        assert!(r.contains("hex digits"), "{r}");
        let ok = parse_state_hex("050001032c016c07007e00a980ff80feffffffff0f").unwrap();
        assert_eq!(ok.step(), 5);
        assert_eq!(ok.state[4], 0x2c);
        assert_eq!(ok.to_line().to_string(), "5 1 3 300 108 7 32256 43264 -128 -384 ffffffff0f");
        assert_eq!(ok.bricks, [0xff, 0xff, 0xff, 0xff, 0x0f]);
        assert!(parse_state_hex(&"zz".repeat(21)).is_err());
    }

    #[test]
    fn ack_is_verified() {
        assert_eq!(parse_ack("4 32881").unwrap(), (4, 32881));
        assert!(parse_ack("4").is_err());
        assert!(parse_ack("4 32881 9").is_err());
        assert!(check_ack((4, 32881), 4, 32881).is_ok());
        let e = check_ack((0, 32881), 4, 32881).unwrap_err();
        assert!(e.contains("did not take"), "{e}");
        let e = check_ack((4, 0x1234), 4, 32881).unwrap_err();
        assert!(e.contains("not parked"), "{e}");
    }

    /// A fake "MAME": a shell script speaking the script protocol, so the transport
    /// (READY, state lines, chatter, ACK verification, desync via the core) is tested
    /// without MAME. State = step counter only; the 3rd ACK can lie to prove detection.
    fn fake(lie: bool) -> (MameTarget, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("gpfdiff_fake_{}_{}", std::process::id(), lie));
        std::fs::create_dir_all(&dir).unwrap();
        let sh = dir.join("fakemame.sh");
        let body = format!(
            r#"#!/bin/bash
echo "some MAME chatter"
echo "GPF READY"
n=0
emit() {{ printf 'GPF S %02x%02x0003%s\n' $((n&255)) $((n>>8)) "000000000000000000000000ffffffffff"; }}
emit
while read -r cmd arg; do
  [ "$cmd" = Q ] && exit 0
  n=$((n+1))
  a=$arg; [ {lie} = 1 ] && [ $n = 3 ] && a=0
  echo "GPF ACK $a 32881"
  emit
done
"#,
            lie = if lie { 1 } else { 0 }
        );
        std::fs::write(&sh, body).unwrap();
        std::fs::write(dir.join("l.sym"), "gpf_state: equ 0x0000F000\ngpf_bricks: equ 0x0000F010\ngpf_input_ret: equ 0x00008071\n").unwrap();
        std::fs::write(dir.join("x.sna"), b"x").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let t = MameTarget::new(MameConfig {
            kind: MameKind::Zx48,
            mame: sh.to_string_lossy().into(),
            machine: "spectrum".into(),
            rompath: None,
            sna: dir.join("x.sna").to_string_lossy().into(),
            labels: dir.join("l.sym").to_string_lossy().into(),
            timeout: Duration::from_secs(10),
            debug: false,
        })
        .unwrap();
        (t, dir)
    }

    #[test]
    fn transport_roundtrip_with_fake_mame() {
        let (mut t, dir) = fake(false);
        let sc = Scenario::parse("steps = 6\nsample_every = 2\n[[input]]\nstep = 1\nbuttons = 5\n").unwrap();
        let tr = run_scenario(&mut t, &sc, &FieldMap::builtin()).unwrap();
        t.shutdown();
        t.shutdown(); // safe twice
        assert_eq!((0..tr.len()).map(|i| tr.step_at(i).unwrap()).collect::<Vec<_>>(), vec![0, 2, 4, 6]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn lying_ack_is_a_harness_error() {
        let (mut t, dir) = fake(true);
        let sc = Scenario::parse("steps = 6\n[[input]]\nstep = 0\nbuttons = 5\n").unwrap();
        let e = run_scenario(&mut t, &sc, &FieldMap::builtin()).unwrap_err();
        t.shutdown();
        assert!(e.contains("did not take"), "{e}");
        let _ = std::fs::remove_dir_all(dir);
    }

    /// coco2: the fake MAME verifies what the backend hands the Lua script (machine name, `-ext ""`,
    /// GPF_REG=A, and that GPF_LOAD names a file holding the DECB segment and the entry point), and
    /// answers `GPF ERR` otherwise; so a green run proves the load plumbing, not just the protocol.
    fn fake_coco(dir: &std::path::Path, image: &[u8], map: &str) -> MameTarget {
        std::fs::create_dir_all(dir).unwrap();
        let sh = dir.join("fakemame.sh");
        std::fs::write(
            &sh,
            r#"#!/bin/bash
[ "$1" = coco2b ] || { echo "GPF ERR machine is $1"; exit 1; }
case " $* " in *" -ext  "*|*" -ext "*) ;; *) echo "GPF ERR no -ext"; exit 1;; esac
[ "$GPF_REG" = A ] || { echo "GPF ERR GPF_REG=$GPF_REG"; exit 1; }
[ "$(cat "$GPF_LOAD")" = "$(printf 'S 16384 8ebeef39
X 16384')" ] || { echo "GPF ERR load list: $(cat "$GPF_LOAD" 2>&1)"; exit 1; }
echo "GPF READY"
n=0
emit() { printf 'GPF S %02x%02x0003%s
' $((n&255)) $((n>>8)) "000000000000000000000000ffffffffff"; }
emit
while read -r cmd arg; do
  [ "$cmd" = Q ] && exit 0
  n=$((n+1))
  echo "GPF ACK $arg 16387"
  emit
done
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("x.bin"), image).unwrap();
        std::fs::write(dir.join("x.map"), map).unwrap();
        MameTarget::new(MameConfig {
            kind: MameKind::Coco2,
            mame: sh.to_string_lossy().into(),
            machine: "coco2b".into(),
            rompath: None,
            sna: dir.join("x.bin").to_string_lossy().into(),
            labels: dir.join("x.map").to_string_lossy().into(),
            timeout: Duration::from_secs(10),
            debug: false,
        })
        .unwrap()
    }

    const COCO_MAP: &str = "Symbol: gpf_state (x.bin) = 1000\nSymbol: gpf_bricks (x.bin) = 1010\nSymbol: gpf_input_ret (x.bin) = 4003\n";
    // DECB: one segment `ldx #$beef; rts` at $4000, entry $4000.  gpf_input_ret = $4003 = the RTS.
    const COCO_BIN: &[u8] = &[0, 0, 4, 0x40, 0, 0x8e, 0xbe, 0xef, 0x39, 0xff, 0, 0, 0x40, 0];

    #[test]
    fn coco2_transport_loads_the_image_and_verifies_the_ack() {
        let dir = std::env::temp_dir().join(format!("gpfdiff_fakecoco_{}", std::process::id()));
        let mut t = fake_coco(&dir, COCO_BIN, COCO_MAP);
        let sc = Scenario::parse("steps = 4
sample_every = 2
[[input]]
step = 1
buttons = 6
").unwrap();
        let tr = run_scenario(&mut t, &sc, &FieldMap::builtin()).unwrap();
        t.shutdown();
        assert_eq!((0..tr.len()).map(|i| tr.step_at(i).unwrap()).collect::<Vec<_>>(), vec![0, 2, 4]);
        // the temp load list is cleaned up
        assert!(t.load_path.is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn coco2_rejects_a_stale_or_broken_image_before_starting_mame() {
        let dir = std::env::temp_dir().join(format!("gpfdiff_cocobad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mk = |image: &[u8], map: &str| {
            std::fs::write(dir.join("x.bin"), image).unwrap();
            std::fs::write(dir.join("x.map"), map).unwrap();
            MameTarget::new(MameConfig {
                kind: MameKind::Coco2,
                mame: "x".into(),
                machine: "coco2b".into(),
                rompath: None,
                sna: dir.join("x.bin").to_string_lossy().into(),
                labels: dir.join("x.map").to_string_lossy().into(),
                timeout: Duration::from_secs(1),
                debug: false,
            })
            .err()
            .expect("must be rejected")
        };
        // map from another build: gpf_input_ret is outside the image
        let e = mk(COCO_BIN, &COCO_MAP.replace("4003", "4100"));
        assert!(e.contains("invalid") && e.contains("not inside a loaded segment"), "{e}");
        // not a DECB file at all
        let e = mk(b"\x7fELF", COCO_MAP);
        assert!(e.contains("invalid") && e.contains("DECB"), "{e}");
        // a sjasmplus symbol file is not an lwasm map: the labels are missing
        let e = mk(COCO_BIN, "gpf_state: equ 0x0000F000\n");
        assert!(e.contains("label `gpf_state` missing"), "{e}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn missing_label_is_reported() {
        let dir = std::env::temp_dir().join(format!("gpfdiff_nolabel_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("l.sym"), "gpf_state: equ 0x0000F000\n").unwrap();
        let e = MameTarget::new(MameConfig {
            kind: MameKind::Zx48,
            mame: "x".into(),
            machine: "spectrum".into(),
            rompath: None,
            sna: "y".into(),
            labels: dir.join("l.sym").to_string_lossy().into(),
            timeout: Duration::from_secs(1),
            debug: false,
        })
        .err()
        .unwrap();
        assert!(e.contains("gpf_bricks"), "{e}");
        let _ = std::fs::remove_dir_all(dir);
    }
}
