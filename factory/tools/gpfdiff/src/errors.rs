//! Turn the backends' terse error strings into "what happened / likely cause / next
//! command", and map outcomes to process exit codes.
//!
//! Backends keep returning plain `String` errors (they are produced deep inside IPC
//! code); [`classify`] recognises them by their stable wording, so a new backend only
//! has to reuse the same phrases (see README, "Adding a backend").

/// Exit codes. 0 = pass, 1 = the game (port) FAILED a comparison, 2 = the harness or
/// environment could not give an answer (missing tool, timeout, desync, bad manifest).
pub const EXIT_PASS: u8 = 0;
pub const EXIT_FAIL: u8 = 1;
pub const EXIT_ENV: u8 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    EmulatorMissing,
    EmulatorExited,
    Timeout,
    Gate,
    Desync,
    MissingLabel,
    MissingRom,
    MissingFile,
    ScriptError,
    Config,
    Other,
}

impl Kind {
    /// Stable identifier used in the `--json` output.
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::EmulatorMissing => "emulator_missing",
            Kind::EmulatorExited => "emulator_exited",
            Kind::Timeout => "timeout",
            Kind::Gate => "ready_gate",
            Kind::Desync => "desync",
            Kind::MissingLabel => "missing_label",
            Kind::MissingRom => "missing_rom",
            Kind::MissingFile => "missing_file",
            Kind::ScriptError => "script_error",
            Kind::Config => "config",
            Kind::Other => "other",
        }
    }
}

/// Recognise an error string by its wording. Order matters: the most specific first.
pub fn classify(msg: &str) -> Kind {
    let m = msg.to_ascii_lowercase();
    if m.contains("harness desync") {
        Kind::Desync
    } else if m.contains("label `") && m.contains("missing from") {
        Kind::MissingLabel
    } else if m.contains("romset") || m.contains("rom not found") || m.contains("required files are missing") {
        Kind::MissingRom
    } else if m.contains("ready gate") {
        Kind::Gate
    } else if m.contains("timed out") {
        Kind::Timeout
    } else if m.contains("cannot start `") || m.contains("not found on path") {
        Kind::EmulatorMissing
    } else if m.contains("exited") || m.contains("closed the monitor") || m.contains("could not connect") {
        Kind::EmulatorExited
    } else if m.contains("script error") {
        Kind::ScriptError
    } else if m.starts_with("invalid ") || m.contains("invalid scenario") || m.contains("harness.toml") || m.contains("unknown platform") {
        Kind::Config
    } else if m.contains("no such file") || m.contains("not found") || m.contains("not a file") {
        Kind::MissingFile
    } else {
        Kind::Other
    }
}

/// (likely cause, next command) for an error kind on a platform.
pub fn hint(kind: Kind, platform: &str) -> (String, String) {
    let emu = if matches!(platform, "zx48" | "coco2") { "MAME" } else { "x64sc (VICE)" };
    let doctor = format!("gpfdiff doctor --platform {}", if platform.is_empty() { "all" } else { platform });
    let (cause, next): (String, String) = match kind {
        Kind::EmulatorMissing => (
            format!("{emu} is not installed, or is not on PATH"),
            format!("{doctor}   (prints the install command for your OS; installs nothing)"),
        ),
        Kind::EmulatorExited => (
            match platform {
                "zx48" => "MAME crashed or refused to start: usually the `spectrum` ROM is missing, or the .sna is unreadable".into(),
                "coco2" => "MAME crashed or refused to start: usually the `coco2b` ROM is missing, or the .bin is unreadable".into(),
                _ => "x64sc crashed or refused to start: no X display (install xvfb-run or use --xvfb never), or a bad .prg".into(),
            },
            format!("{doctor}; then re-run the same command with --debug to see the emulator's own output"),
        ),
        Kind::Timeout => (
            "the program never reached the next input point (gpf_input_ret): hung, image and symbol file out of sync, or the machine is overloaded".into(),
            "rebuild image and symbol file together (make -C <port>/target), then re-run with --timeout 120 --debug".into(),
        ),
        Kind::Gate => (
            "the `[boot] ready` condition never became true: wrong address or condition, the program never started (coco2: the image load did not take), a title screen that needs `ready_keys`, or a boot slower than `timeout_ms`".into(),
            "see what the program writes while it boots: gpfdiff watch <port> --no-gate --region <a:b> --frames 300; then fix [boot] ready, add ready_keys, or raise timeout_ms".into(),
        ),
        Kind::Desync => (
            "the program's own step counter disagrees with the harness (a missed or doubled breakpoint hit); diffs after this point are meaningless".into(),
            "rebuild, then run ONE scenario with --debug; check that gpf_input_ret labels the ret/RTS of read_input".into(),
        ),
        Kind::MissingLabel => (
            "the symbol file lacks a required label: stale .vs/.sym, or the source no longer exports it".into(),
            "rebuild the target, then grep the symbol file for gpf_state, gpf_bricks and gpf_input_ret".into(),
        ),
        Kind::MissingRom if platform == "coco2" => (
            "MAME cannot find the `coco2b` romset. The ROM is your own and is never distributed with this repo".into(),
            "put coco2b.zip (or a coco2b/ folder with bas13.rom + extbas11.rom) in ~/.mame/roms, or set COCO_ROMPATH / pass --rompath; then run: gpfdiff doctor --platform coco2".into(),
        ),
        Kind::MissingRom => (
            "MAME cannot find the `spectrum` romset. The ROM is your own and is never distributed with this repo".into(),
            "put spectrum.zip in ~/.mame/roms, or set ZX_ROMPATH / pass --rompath; then run: gpfdiff doctor --platform zx48".into(),
        ),
        Kind::MissingFile => (
            "a file named on the command line or in harness.toml does not exist (image not built yet?)".into(),
            "build the port (make -C <port>/target all) and check the paths in harness.toml".into(),
        ),
        Kind::ScriptError => (
            "the Lua script running inside MAME reported an error".into(),
            "re-run with --debug and read the `[mame] <- GPF ERR` line".into(),
        ),
        Kind::Config => (
            "a scenario, golden or harness.toml file is malformed or incomplete".into(),
            "fix the file; formats are in factory/tools/gpfdiff/README.md".into(),
        ),
        Kind::Other => (
            "unexpected harness or emulator error".into(),
            format!("re-run with --debug; if it persists: {doctor}"),
        ),
    };
    (cause, next)
}

/// Multi-line, human-oriented rendering of one environment/harness error.
pub fn render(msg: &str, platform: &str, debug: bool) -> String {
    let kind = classify(msg);
    let (cause, next) = hint(kind, platform);
    let mut s = format!("{msg}\n  likely cause: {cause}\n  next:         {next}");
    let debuggable = matches!(kind, Kind::Timeout | Kind::Gate | Kind::EmulatorExited | Kind::Desync | Kind::ScriptError | Kind::Other);
    if !debug && debuggable {
        s.push_str("\n  more:         re-run with --debug to see the monitor protocol and emulator output");
    }
    s
}

/// Overall verdict of a set of results -> exit code. An environment error anywhere
/// dominates (the answer is incomplete), then a game failure, else pass.
pub fn exit_code(failed: usize, errors: usize) -> u8 {
    if errors > 0 {
        EXIT_ENV
    } else if failed > 0 {
        EXIT_FAIL
    } else {
        EXIT_PASS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_the_real_backend_messages() {
        assert_eq!(classify("run 1: harness desync: at input point 3 the target reports step 4"), Kind::Desync);
        assert_eq!(classify("label `gpf_bricks` missing from x.sym"), Kind::MissingLabel);
        assert_eq!(classify("timed out waiting for MAME (last MAME output: a | b)"), Kind::Timeout);
        assert_eq!(classify("timed out waiting for the emulator"), Kind::Timeout);
        assert_eq!(classify("timed out waiting for the ready gate: [boot] ready (...) never held"), Kind::Gate);
        assert_eq!(classify("cannot start `mame`: No such file or directory (os error 2)"), Kind::EmulatorMissing);
        assert_eq!(classify("MAME exited unexpectedly (last MAME output: x)"), Kind::EmulatorExited);
        assert_eq!(classify("x64sc exited early (exit status: 1); run with --debug"), Kind::EmulatorExited);
        assert_eq!(classify("MAME romset `spectrum` not found (searched: /a)"), Kind::MissingRom);
        assert_eq!(classify("script error: boom"), Kind::ScriptError);
        assert_eq!(classify("invalid scenario s.toml: line 2"), Kind::Config);
        assert_eq!(classify("run 1: invalid scenario: an input at 0 ms is earlier than input_latency_frames = 1"), Kind::Config);
        assert_eq!(classify("a.prg: no such file (not built?)"), Kind::MissingFile);
        assert_eq!(classify("something odd"), Kind::Other);
    }

    #[test]
    fn rom_beats_timeout_and_exit_wording() {
        // MAME with a missing ROM exits and prints the romset complaint: the ROM is the cause.
        assert_eq!(classify("MAME exited unexpectedly (last MAME output: spectrum romset not found)"), Kind::MissingRom);
    }

    #[test]
    fn every_kind_says_cause_and_next_and_points_at_doctor_where_relevant() {
        for k in [
            Kind::EmulatorMissing, Kind::EmulatorExited, Kind::Timeout, Kind::Gate, Kind::Desync, Kind::MissingLabel,
            Kind::MissingRom, Kind::MissingFile, Kind::ScriptError, Kind::Config, Kind::Other,
        ] {
            let (c, n) = hint(k, "zx48");
            assert!(!c.is_empty() && !n.is_empty(), "{k:?}");
        }
        assert!(hint(Kind::EmulatorMissing, "c64").1.contains("gpfdiff doctor --platform c64"));
        assert!(hint(Kind::MissingRom, "zx48").1.contains("ZX_ROMPATH"));
        let (c, n) = hint(Kind::MissingRom, "coco2");
        assert!(c.contains("coco2b") && n.contains("COCO_ROMPATH") && n.contains("doctor --platform coco2"), "{c} / {n}");
        assert!(!n.contains("ZX_ROMPATH"));
        assert!(hint(Kind::EmulatorMissing, "coco2").0.contains("MAME"));
        assert_eq!(classify("MAME romset `coco2b` not found (searched: /a); the ROM is your own"), Kind::MissingRom);
    }

    #[test]
    fn render_has_what_cause_next_and_debug_hint() {
        let r = render("timed out waiting for MAME", "zx48", false);
        assert!(r.starts_with("timed out waiting for MAME\n"));
        assert!(r.contains("likely cause:") && r.contains("next:") && r.contains("--debug"));
        let r = render("timed out waiting for MAME", "zx48", true);
        assert!(!r.contains("more:"));
        // the hint is only useful where --debug shows something
        assert!(!render("cannot start `mame`: not found on PATH", "zx48", false).contains("more:"));
    }

    #[test]
    fn exit_code_mapping() {
        assert_eq!(exit_code(0, 0), 0);
        assert_eq!(exit_code(3, 0), 1);
        assert_eq!(exit_code(0, 1), 2);
        assert_eq!(exit_code(3, 1), 2); // incomplete answer dominates
    }
}
