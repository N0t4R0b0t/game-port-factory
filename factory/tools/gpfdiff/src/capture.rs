//! `gpfdiff capture <port-dir>`: run a port's own target on recipe scenarios and write its
//! normalised traces (with the `# columns:` header) to a directory. This is how a trace is
//! recorded from an original or from another port; `[oracle] source = "trace"` then verifies
//! other ports against it with no emulator for the original.

use crate::check::{self, Overrides};
use crate::errors;
use crate::manifest;
use crate::runner;
use crate::scenario::Scenario;
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Clone, Debug, Default)]
pub struct CaptureArgs {
    pub port: PathBuf,
    pub manifest: Option<String>,
    /// Scenario names, or `all` (also the default when empty).
    pub scenarios: Vec<String>,
    pub out: Option<PathBuf>,
    pub repeat: Option<u32>,
    pub ov: Overrides,
}

/// Exit 0: every requested trace written. 2: the harness or environment could not answer, including a
/// scenario whose runs differ from each other (NON-DETERMINISTIC; nothing is written for it): a recording that
/// differs from itself is not a result about the game, and a live oracle behaves the same way. There is no exit 1:
/// `capture` compares nothing against a golden.
pub fn run_capture(a: &CaptureArgs, out: &mut dyn Write) -> u8 {
    let t0 = Instant::now();
    let mut say = |s: &str| {
        let _ = writeln!(out, "{s}");
        let _ = out.flush();
    };
    let platform_of = |m: &manifest::Manifest| m.platform.clone();
    let fail_env = |say: &mut dyn FnMut(&str), platform: &str, e: String| {
        say(&format!("ERROR: {}", errors::render(&e, platform, a.ov.debug)));
        errors::EXIT_ENV
    };
    let (m, dir) = match check::load_manifest(&a.port, a.manifest.as_deref()) {
        Ok(v) => v,
        Err(e) => return fail_env(&mut say, "", e),
    };
    let platform = platform_of(&m);
    let repeat = a.repeat.or(m.repeat).unwrap_or(2).max(1);
    let recipe = match check::recipe_dir(&m, &dir) {
        Ok(r) => r,
        Err(e) => return fail_env(&mut say, &platform, e),
    };
    let all = match check::discover(&recipe) {
        Ok(v) => v,
        Err(e) => return fail_env(&mut say, &platform, e),
    };
    let want: Vec<String> = if a.scenarios.is_empty() || a.scenarios.iter().any(|s| s == "all") { vec![] } else { a.scenarios.clone() };
    let names = match check::select(&all, &want) {
        Ok(v) => v,
        Err(e) => return fail_env(&mut say, &platform, e.replace("--only", "--scenario")),
    };
    let spec = match check::build_target(&m, &dir, &a.ov, repeat) {
        Ok(s) => s,
        Err(e) => return fail_env(&mut say, &platform, e),
    };
    let name = check::port_name(&dir);
    let outdir = a.out.clone().unwrap_or_else(|| recipe.join("captured").join(&name));
    if let Err(e) = std::fs::create_dir_all(&outdir) {
        return fail_env(&mut say, &platform, format!("{}: {e}", outdir.display()));
    }
    let (mut nondet, mut written) = (0usize, 0usize);
    for n in &names {
        let p = recipe.join("scenarios").join(format!("{n}.toml"));
        let sc = match std::fs::read_to_string(&p)
            .map_err(|e| format!("{}: {e}", p.display()))
            .and_then(|t| Scenario::parse_with(&t, m.time.step_ms).map_err(|e| format!("invalid scenario {}: {e}", p.display())))
        {
            Ok(s) => s,
            Err(e) => return fail_env(&mut say, &platform, e),
        };
        let runs = match runner::run_traces(&spec, &sc) {
            Ok(r) => r,
            Err(e) => return fail_env(&mut say, &platform, format!("{n}: {e}")),
        };
        if let Err(f) = runner::determinism(&runs, sc.steps) {
            say(&format!("FAIL {n}: {} (not written)\n{}", f.headline(), f.context));
            nondet += 1;
            continue;
        }
        let file = outdir.join(format!("{n}.trace"));
        let body = format!("# captured by gpfdiff capture from {name} ({platform}), scenario {n}, {} steps\n{}", sc.steps, runs[0].render());
        if let Err(e) = std::fs::write(&file, body) {
            return fail_env(&mut say, &platform, format!("{}: {e}", file.display()));
        }
        written += 1;
        say(&format!("captured {n}: {} samples, x{repeat} deterministic -> {}", runs[0].len(), file.display()));
    }
    if nondet > 0 {
        say(&format!(
            "CAPTURE ERROR: {nondet} of {} scenarios NON-DETERMINISTIC ({written} written), {:.1}s; a recording that differs from itself cannot be trusted (harness/environment error, exit 2)",
            names.len(),
            t0.elapsed().as_secs_f64()
        ));
        return errors::EXIT_ENV;
    }
    say(&format!("CAPTURE OK: {written} scenario{} -> {}, {:.1}s", if written == 1 { "" } else { "s" }, outdir.display(), t0.elapsed().as_secs_f64()));
    errors::EXIT_PASS
}
