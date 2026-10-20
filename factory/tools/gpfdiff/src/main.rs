//! gpfdiff: drive an emulator step by step through a scenario, sample `gpf_state`,
//! and compare against a golden trace. Exit 0 only on an exact match of every
//! sampled line (and, with --repeat N, identical traces across all N runs).
//! Exit 1 = the port failed a comparison; exit 2 = the harness/environment could not
//! answer (missing tool, timeout, desync, bad manifest). See README.md.

mod c64;
mod capture;
mod check;
mod coco;
mod diff;
mod doctor;
mod errors;
mod expect;
mod fields;
mod keys;
mod keysrun;
mod mame;
mod manifest;
mod png;
mod report;
mod runner;
mod scenario;
mod state;
mod target;
mod trace;
mod watch;

use clap::{Parser, Subcommand};
use runner::{BackendOpts, RunResult, RunSpec};
use std::process::ExitCode;
use std::time::Duration;

#[derive(Parser)]
#[command(name = "gpfdiff", about = "gpf_state trace differ", version)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run one scenario on a platform backend and diff against a golden trace.
    Run {
        #[arg(long)]
        platform: String,
        /// Program image: .prg (c64), .sna snapshot (zx48) or DECB .bin (coco2).
        #[arg(long, visible_alias = "sna")]
        prg: String,
        /// Assembler symbol file (acme --vicelabels for c64, sjasmplus --sym for zx48, lwasm --map for coco2).
        #[arg(long)]
        labels: String,
        #[arg(long)]
        scenario: String,
        #[arg(long)]
        golden: String,
        /// Run the scenario N times (fresh emulator each); fail if traces differ.
        #[arg(long, default_value_t = 1)]
        repeat: u32,
        #[arg(long, default_value = "x64sc")]
        x64sc: String,
        /// auto | always | never: run x64sc under xvfb-run (no window on your desktop).
        #[arg(long, default_value = "auto")]
        xvfb: String,
        /// Seconds to wait for the emulator at each step.
        #[arg(long, default_value_t = 30)]
        timeout: u64,
        /// zx48/coco2: MAME executable.
        #[arg(long, default_value = "mame")]
        mame: String,
        /// zx48/coco2: MAME machine name (default: spectrum for zx48, coco2b for coco2).
        #[arg(long)]
        machine: Option<String>,
        /// zx48/coco2: MAME -rompath (default: $ZX_ROMPATH / $COCO_ROMPATH, then ~/.mame/roms).
        #[arg(long)]
        rompath: Option<String>,
        /// Print the monitor protocol and emulator output.
        #[arg(long)]
        debug: bool,
        /// Write the first run's trace here (for diffing by hand).
        #[arg(long)]
        dump: Option<String>,
    },
    /// Run a scenario (warp) and print every step at which a RAM region changes
    /// (`step hexbytes`); lets a script assert on side effects such as sound state.
    Probe {
        #[arg(long)]
        platform: String,
        #[arg(long)]
        prg: String,
        #[arg(long)]
        labels: String,
        #[arg(long)]
        scenario: String,
        /// Start address (hex).
        #[arg(long)]
        addr: String,
        #[arg(long)]
        len: usize,
        #[arg(long, default_value = "x64sc")]
        x64sc: String,
        #[arg(long, default_value = "auto")]
        xvfb: String,
        #[arg(long, default_value_t = 60)]
        timeout: u64,
    },
    /// Run a scenario to a given step and save a screenshot (c64 only): real-time
    /// x64sc, integer nearest-neighbour upscale, PNG.
    Shot {
        #[arg(long)]
        platform: String,
        #[arg(long)]
        prg: String,
        #[arg(long)]
        labels: String,
        #[arg(long)]
        scenario: String,
        /// Input point (step) at which to grab the frame.
        #[arg(long)]
        at: u32,
        #[arg(long)]
        out: String,
        /// Integer upscale factor.
        #[arg(long, default_value_t = 3)]
        scale: usize,
        #[arg(long, default_value = "x64sc")]
        x64sc: String,
        #[arg(long, default_value = "auto")]
        xvfb: String,
        #[arg(long, default_value_t = 60)]
        timeout: u64,
        #[arg(long)]
        debug: bool,
    },
    /// Check prerequisites (emulators, assemblers, the Spectrum ROM) and print the
    /// install command for anything missing. Installs nothing. Exit 2 if a REQUIRED
    /// item is missing.
    Doctor {
        /// c64 | zx48 | coco2 | all
        #[arg(long, default_value = "all")]
        platform: String,
        /// zx48/coco2: where to look for the `spectrum` / `coco2b` romset (else $ZX_ROMPATH / $COCO_ROMPATH, then ~/.mame/roms).
        #[arg(long)]
        rompath: Option<String>,
    },
    /// Run every scenario of a port (from its harness.toml) sequentially, then the
    /// built-in canary; print a table. Exit 0 pass, 1 game FAIL, 2 harness/environment error.
    Check {
        /// Port directory containing harness.toml (or the harness.toml itself).
        port_dir: String,
        /// Use this manifest (a file name inside the port dir) instead of harness.toml, e.g. harness.live.toml.
        #[arg(long)]
        manifest: Option<String>,
        /// Comma-separated scenario names to run.
        #[arg(long, value_delimiter = ',')]
        only: Vec<String>,
        /// List the scenarios and exit.
        #[arg(long)]
        list: bool,
        /// Runs per scenario, fresh emulator each (default: harness.toml `repeat`, else 2).
        #[arg(long)]
        repeat: Option<u32>,
        /// One JSON document on stdout instead of the table (schema in README.md).
        #[arg(long)]
        json: bool,
        /// Skip the mutated-golden canary.
        #[arg(long)]
        no_canary: bool,
        /// Keep running after a failure (the default).
        #[arg(long, conflicts_with = "fail_fast")]
        keep_going: bool,
        /// Stop at the first scenario that does not pass.
        #[arg(long)]
        fail_fast: bool,
        /// Seconds to wait for the emulator at each step (default: harness.toml, else 30).
        #[arg(long)]
        timeout: Option<u64>,
        #[arg(long)]
        x64sc: Option<String>,
        #[arg(long)]
        xvfb: Option<String>,
        #[arg(long)]
        mame: Option<String>,
        #[arg(long)]
        machine: Option<String>,
        #[arg(long)]
        rompath: Option<String>,
        /// Print the monitor protocol and emulator output; keeps error hints short.
        #[arg(long)]
        debug: bool,
    },
    /// Run the program free (keys mode), tap scripted keys and print every RAM change in a region by frame:
    /// press a key, see which bytes move. The tool for finding an original's state addresses.
    Watch {
        /// Port directory containing harness.toml (or the harness.toml itself).
        port_dir: String,
        /// Use this manifest (a file name inside the port dir) instead of harness.toml.
        #[arg(long)]
        manifest: Option<String>,
        /// Inclusive address range START:END (0x1234, $1234 or decimal). Default: the platform's RAM without the video buffer.
        #[arg(long)]
        region: Option<String>,
        /// Taps NAME@TIME[+HOLD], comma-separated, e.g. "RIGHT@500ms,FIRE@1s+250ms" (default hold 100 ms). NAME is a button of
        /// [input.keys] or a key of the platform.
        #[arg(long)]
        keys: Option<String>,
        /// Frames to watch from the start of the timeline (default 100).
        #[arg(long)]
        frames: Option<u32>,
        /// Ignore [boot] ready / ready_keys: frame 0 is the first frame (to see what the program does while booting).
        #[arg(long)]
        no_gate: bool,
        /// Lines printed before the rest is summarised (default 200).
        #[arg(long)]
        max_lines: Option<usize>,
        #[arg(long)]
        timeout: Option<u64>,
        #[arg(long)]
        mame: Option<String>,
        #[arg(long)]
        machine: Option<String>,
        #[arg(long)]
        rompath: Option<String>,
        #[arg(long)]
        debug: bool,
    },
    /// Run a port's own target on scenarios and write its normalised traces (with a
    /// `# columns:` header) to a directory: how a trace is recorded from an original or another port.
    Capture {
        /// Port directory containing harness.toml (or the harness.toml itself).
        port_dir: String,
        /// Use this manifest (a file name inside the port dir) instead of harness.toml.
        #[arg(long)]
        manifest: Option<String>,
        /// Scenario names (comma-separated) or `all` (default).
        #[arg(long, value_delimiter = ',')]
        scenario: Vec<String>,
        /// Output directory (default: <recipe>/captured/<port-name>/).
        #[arg(long)]
        out: Option<String>,
        /// Runs per scenario, fresh emulator each; the traces must be identical (default: harness.toml `repeat`, else 2).
        #[arg(long)]
        repeat: Option<u32>,
        #[arg(long)]
        timeout: Option<u64>,
        #[arg(long)]
        x64sc: Option<String>,
        #[arg(long)]
        xvfb: Option<String>,
        #[arg(long)]
        mame: Option<String>,
        #[arg(long)]
        machine: Option<String>,
        #[arg(long)]
        rompath: Option<String>,
        #[arg(long)]
        debug: bool,
    },
}

fn read(p: &str) -> Result<String, String> {
    std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))
}

/// Print a failure the way every command does: first line `FAIL <what>: <msg>`, then
/// cause / next-command hints for environment errors.
fn print_error(what: &str, msg: &str, platform: &str, debug: bool) {
    println!("FAIL {what}: {}", errors::render(msg, platform, debug));
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Doctor { platform, rompath } => {
            let st = report::Style::detect();
            match doctor::doctor(&platform, rompath.as_deref(), &st) {
                Ok((text, missing)) => {
                    print!("{text}");
                    ExitCode::from(if missing { errors::EXIT_ENV } else { errors::EXIT_PASS })
                }
                Err(e) => {
                    println!("{e}");
                    ExitCode::from(errors::EXIT_ENV)
                }
            }
        }
        Cmd::Check { port_dir, manifest, only, list, repeat, json, no_canary, keep_going: _, fail_fast, timeout, x64sc, xvfb, mame, machine, rompath, debug } => {
            use std::io::IsTerminal;
            let a = check::CheckArgs {
                port: port_dir.into(),
                manifest,
                only,
                list,
                repeat,
                json,
                no_canary,
                fail_fast,
                timeout,
                debug,
                x64sc,
                xvfb,
                mame,
                machine,
                rompath,
                color: report::Style::from_env(std::io::stdout().is_terminal(), std::env::var_os("NO_COLOR").as_deref()).color,
            };
            ExitCode::from(check::run_check(&a, &mut std::io::stdout()))
        }
        Cmd::Capture { port_dir, manifest, scenario, out, repeat, timeout, x64sc, xvfb, mame, machine, rompath, debug } => {
            let a = capture::CaptureArgs {
                port: port_dir.into(),
                manifest,
                scenarios: scenario,
                out: out.map(Into::into),
                repeat,
                ov: check::Overrides { timeout, debug, x64sc, xvfb, mame, machine, rompath },
            };
            ExitCode::from(capture::run_capture(&a, &mut std::io::stdout()))
        }
        Cmd::Watch { port_dir, manifest, region, keys, frames, no_gate, max_lines, timeout, mame, machine, rompath, debug } => {
            let a = watch::WatchArgs {
                port: port_dir.into(),
                manifest,
                region,
                keys,
                frames,
                no_gate,
                max_lines,
                ov: check::Overrides { timeout, debug, x64sc: None, xvfb: None, mame, machine, rompath },
            };
            ExitCode::from(watch::run_watch(&a, &mut std::io::stdout()))
        }
        Cmd::Probe { platform, prg, labels, scenario, addr, len, x64sc, xvfb, timeout } => {
            let go = || -> Result<(), String> {
                if platform != "c64" {
                    return Err("probe supports --platform c64 only".into());
                }
                let a = u16::from_str_radix(addr.trim_start_matches("0x").trim_start_matches('$'), 16)
                    .map_err(|e| format!("invalid --addr: {e}"))?;
                let sc = scenario::Scenario::parse(&read(&scenario)?).map_err(|e| format!("invalid scenario {scenario}: {e}"))?;
                doctor::preflight_exe("c64", &x64sc, "")?;
                let mut t = c64::C64Target::new(c64::C64Config {
                    x64sc,
                    prg,
                    labels,
                    xvfb,
                    timeout: Duration::from_secs(timeout),
                    debug: false,
                    warp: true,
                })?;
                let r = target::run_probe(&mut t, &sc, a, len);
                target::Target::shutdown(&mut t);
                for (s, v) in r? {
                    println!("{s} {}", v.iter().map(|b| format!("{b:02x}")).collect::<String>());
                }
                Ok(())
            };
            match go() {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    print_error("probe", &e, "c64", false);
                    ExitCode::from(1)
                }
            }
        }
        Cmd::Shot { platform, prg, labels, scenario, at, out, scale, x64sc, xvfb, timeout, debug } => {
            let go = || -> Result<String, String> {
                if platform != "c64" {
                    return Err("shot supports --platform c64 only".into());
                }
                let sc = scenario::Scenario::parse(&read(&scenario)?).map_err(|e| format!("invalid scenario {scenario}: {e}"))?;
                doctor::preflight_exe("c64", &x64sc, "")?;
                let mut t = c64::C64Target::new(c64::C64Config {
                    x64sc,
                    prg,
                    labels,
                    xvfb,
                    timeout: Duration::from_secs(timeout),
                    debug,
                    warp: false,
                })?;
                let r = target::run_to_shot(&mut t, &sc, at);
                target::Target::shutdown(&mut t);
                let im = r?.scaled(scale);
                std::fs::write(&out, im.to_png()).map_err(|e| format!("{out}: {e}"))?;
                Ok(format!("SHOT {out} ({}x{}, step {at}, x{scale})", im.w, im.h))
            };
            match go() {
                Ok(s) => {
                    println!("{s}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    print_error("shot", &e, "c64", debug);
                    ExitCode::from(1)
                }
            }
        }
        Cmd::Run { platform, prg, labels, scenario, golden, repeat, x64sc, xvfb, timeout, mame, machine, rompath, debug, dump } => {
            let machine = machine.unwrap_or_else(|| runner::default_machine(&platform).to_string());
            let mut opts = BackendOpts { x64sc, xvfb, timeout, mame, machine, rompath, debug };
            let mut pre = || -> Result<(), String> {
                if !matches!(platform.as_str(), "c64" | "zx48" | "coco2") {
                    return Err(format!("unknown platform `{platform}` (supported: c64, zx48, coco2)"));
                }
                doctor::preflight_exe(&platform, &opts.x64sc, &opts.mame)?;
                if let Some(var) = doctor::rompath_env_var(&platform) {
                    let env = std::env::var(var).ok();
                    let rp = doctor::resolve_rompath_named(opts.rompath.as_deref(), env.as_deref(), None, doctor::home_dir().as_deref(), &opts.machine, var)?;
                    opts.rompath = Some(rp);
                }
                Ok(())
            };
            if let Err(e) = pre() {
                print_error(&scenario, &e, &platform, debug);
                return ExitCode::from(errors::EXIT_ENV);
            }
            let spec = RunSpec {
                platform: platform.clone(),
                image: prg,
                labels,
                scenario: scenario.clone().into(),
                golden: golden.into(),
                repeat,
                opts,
                dump,
                fields: fields::FieldMap::builtin(),
            };
            match runner::run_spec(&spec) {
                RunResult::Pass(p) => {
                    println!(
                        "PASS {} ({} sampled lines, {} run{}, {} steps)",
                        scenario,
                        p.samples,
                        p.runs,
                        if p.runs == 1 { "" } else { "s, deterministic" },
                        p.steps
                    );
                    ExitCode::SUCCESS
                }
                RunResult::Fail(f) => {
                    println!("FAIL {scenario}: {}", f.headline());
                    println!("{}", f.context);
                    ExitCode::from(errors::EXIT_FAIL)
                }
                RunResult::Error(e) => {
                    print_error(&scenario, &e, &platform, debug);
                    ExitCode::from(errors::EXIT_ENV)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn cli_definition_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn check_and_doctor_parse() {
        assert!(Cli::try_parse_from(["gpfdiff", "doctor", "--platform", "coco2"]).is_ok());
        let c = Cli::try_parse_from(["gpfdiff", "check", "p", "--only", "a,b", "--repeat", "3", "--json", "--fail-fast"]).unwrap();
        match c.cmd {
            Cmd::Check { only, repeat, json, fail_fast, .. } => {
                assert_eq!(only, vec!["a", "b"]);
                assert_eq!(repeat, Some(3));
                assert!(json && fail_fast);
            }
            _ => panic!(),
        }
        assert!(Cli::try_parse_from(["gpfdiff", "check", "p", "--keep-going", "--fail-fast"]).is_err());
        assert!(Cli::try_parse_from(["gpfdiff", "doctor", "--platform", "zx48"]).is_ok());
    }

    #[test]
    fn capture_and_manifest_flags_parse() {
        let c = Cli::try_parse_from(["gpfdiff", "capture", "p", "--scenario", "a,b", "--out", "d", "--repeat", "3", "--manifest", "h.toml"]).unwrap();
        match c.cmd {
            Cmd::Capture { scenario, out, repeat, manifest, .. } => {
                assert_eq!((scenario, out.as_deref(), repeat, manifest.as_deref()), (vec!["a".to_string(), "b".to_string()], Some("d"), Some(3), Some("h.toml")));
            }
            _ => panic!(),
        }
        assert!(Cli::try_parse_from(["gpfdiff", "capture", "p", "--scenario", "all"]).is_ok());
        assert!(Cli::try_parse_from(["gpfdiff", "check", "p", "--manifest", "harness.live.toml"]).is_ok());
    }

    #[test]
    fn watch_flags_parse() {
        let c = Cli::try_parse_from([
            "gpfdiff", "watch", "p", "--region", "0xF000:0xF0FF", "--keys", "LEFT@0ms+1s,FIRE@2s", "--frames", "120", "--no-gate", "--manifest", "bb.toml",
        ])
        .unwrap();
        match c.cmd {
            Cmd::Watch { region, keys, frames, no_gate, manifest, .. } => {
                assert_eq!((region.as_deref(), keys.as_deref(), frames, no_gate, manifest.as_deref()), (Some("0xF000:0xF0FF"), Some("LEFT@0ms+1s,FIRE@2s"), Some(120), true, Some("bb.toml")));
            }
            _ => panic!(),
        }
        assert!(Cli::try_parse_from(["gpfdiff", "watch"]).is_err());
    }

    #[test]
    fn run_keeps_its_old_flags() {
        let c = Cli::try_parse_from([
            "gpfdiff", "run", "--platform", "zx48", "--sna", "a.sna", "--labels", "a.sym", "--scenario", "s.toml", "--golden", "g.trace",
            "--repeat", "2", "--mame", "mame", "--rompath", "", "--debug", "--dump", "d",
        ]);
        assert!(c.is_ok());
    }
}
