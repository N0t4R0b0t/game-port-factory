//! Running one scenario against one golden trace, with structured results. Shared by
//! `gpfdiff run` and `gpfdiff check`.

use crate::diff::{self, ColRule, Mismatch};
use crate::fields::FieldMap;
use crate::scenario::Scenario;
use crate::trace::{self, Trace};
use crate::{c64, mame, scenario, target};
use std::path::PathBuf;
use std::time::Duration;

/// Backend options that only some platforms use.
#[derive(Clone, Debug)]
pub struct BackendOpts {
    pub x64sc: String,
    pub xvfb: String,
    pub timeout: u64,
    pub mame: String,
    pub machine: String,
    pub rompath: Option<String>,
    pub debug: bool,
}

impl Default for BackendOpts {
    fn default() -> Self {
        BackendOpts {
            x64sc: "x64sc".into(),
            xvfb: "auto".into(),
            timeout: 30,
            mame: "mame".into(),
            machine: "spectrum".into(),
            rompath: None,
            debug: false,
        }
    }
}

/// The MAME machine used when neither the flag nor harness.toml names one.
pub fn default_machine(platform: &str) -> &'static str {
    if platform == "coco2" {
        crate::coco::DEFAULT_MACHINE
    } else {
        "spectrum"
    }
}

pub fn make_target(platform: &str, image: &str, labels: &str, o: &BackendOpts) -> Result<Box<dyn target::Target>, String> {
    match platform {
        "zx48" | "coco2" => Ok(Box::new(mame::MameTarget::new(mame::MameConfig {
            kind: if platform == "coco2" { mame::MameKind::Coco2 } else { mame::MameKind::Zx48 },
            mame: o.mame.clone(),
            machine: o.machine.clone(),
            rompath: o.rompath.clone().filter(|s| !s.is_empty()),
            sna: image.into(),
            labels: labels.into(),
            timeout: Duration::from_secs(o.timeout),
            debug: o.debug,
        })?)),
        "c64" => Ok(Box::new(c64::C64Target::new(c64::C64Config {
            x64sc: o.x64sc.clone(),
            prg: image.into(),
            labels: labels.into(),
            xvfb: o.xvfb.clone(),
            timeout: Duration::from_secs(o.timeout),
            debug: o.debug,
            warp: true,
        })?)),
        other => Err(format!("unknown platform `{other}` (supported: c64, zx48, coco2)")),
    }
}

/// Everything needed to start fresh emulators for one port and read its field map.
#[derive(Clone, Debug)]
pub struct TargetSpec {
    pub platform: String,
    pub image: String,
    pub labels: String,
    pub repeat: u32,
    pub opts: BackendOpts,
    pub fields: FieldMap,
    /// `Some` = keys mode (`[input] mode = "keys"`): the program runs free and is read on a frame clock.
    pub keys: Option<crate::keys::KeysCfg>,
}

/// Run `sc` `repeat` times, a fresh emulator each, and return every run's trace. Sequential
/// by construction. Errors are harness/environment errors.
pub fn run_traces(t: &TargetSpec, sc: &Scenario) -> Result<Vec<Trace>, String> {
    let mut runs = vec![];
    if let Some(kc) = &t.keys {
        for k in 0..t.repeat.max(1) {
            let r = crate::keysrun::run_scenario(kc, &t.image, &t.opts, &t.fields, sc);
            runs.push(r.map_err(|e| format!("run {}: {e}", k + 1))?);
        }
        return Ok(runs);
    }
    if let Some(n) = sc.uses_key_names() {
        return Err(format!("invalid scenario: it presses `{n}`, a key name; only `[input] mode = \"keys\"` can press keys other than LEFT/RIGHT/FIRE"));
    }
    for k in 0..t.repeat.max(1) {
        let mut tg = make_target(&t.platform, &t.image, &t.labels, &t.opts)?;
        let r = target::run_scenario(tg.as_mut(), sc, &t.fields);
        tg.shutdown();
        runs.push(r.map_err(|e| format!("run {}: {e}", k + 1))?);
    }
    Ok(runs)
}

#[derive(Clone, Debug)]
pub struct RunSpec {
    pub platform: String,
    pub image: String,
    pub labels: String,
    pub scenario: PathBuf,
    pub golden: PathBuf,
    pub repeat: u32,
    pub opts: BackendOpts,
    pub dump: Option<String>,
    pub fields: FieldMap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailKind {
    /// A run differs from the golden trace.
    Mismatch,
    /// Two runs of the same scenario differ from each other (reported before any golden diff).
    NonDeterministic,
}

#[derive(Clone, Debug)]
pub struct FailInfo {
    pub kind: FailKind,
    /// 1-based run number that differed, out of `of`.
    pub run: usize,
    pub of: usize,
    pub mismatch: Mismatch,
    /// Pre-rendered +-2 lines of context around the mismatch.
    pub context: String,
    pub steps: u32,
    pub samples: usize,
}

impl FailInfo {
    /// The classic one-line report (kept stable: the old Makefile canary grepped it).
    pub fn headline(&self) -> String {
        match self.kind {
            FailKind::NonDeterministic => format!("NON-DETERMINISTIC: run {} differs from run 1: {}", self.run, self.mismatch),
            FailKind::Mismatch => format!("run {}/{}: {}", self.run, self.of, self.mismatch),
        }
    }
}

#[derive(Clone, Debug)]
pub struct PassInfo {
    pub samples: usize,
    pub steps: u32,
    pub runs: usize,
}

pub enum RunResult {
    Pass(PassInfo),
    Fail(FailInfo),
    /// Harness / environment error (never a game failure). Free-form message, see `errors::classify`.
    Error(String),
}

pub fn fail_info(kind: FailKind, run: usize, of: usize, m: Mismatch, exp: &Trace, got: &Trace, steps: u32) -> FailInfo {
    FailInfo {
        kind,
        run,
        of,
        context: crate::report::render_context(exp, got, &m, 2),
        mismatch: m,
        steps,
        samples: exp.len(),
    }
}

/// Determinism gate: every run must equal run 1, exactly, in every column (ignored ones too).
/// A diff from a flaky harness must not be believed.
pub fn determinism(runs: &[Trace], steps: u32) -> Result<(), FailInfo> {
    for (k, r) in runs.iter().enumerate().skip(1) {
        if let Some(m) = diff::first_diff(&runs[0], r) {
            return Err(fail_info(FailKind::NonDeterministic, k + 1, runs.len(), m, &runs[0], r, steps));
        }
    }
    Ok(())
}

/// Make the oracle trace comparable with a port that reads `columns`: keep those columns, in
/// that order. The oracle must have all of them (it may have more).
pub fn align(oracle: &Trace, columns: &[String]) -> Result<Trace, String> {
    oracle.project(columns).map_err(|e| format!("invalid oracle trace: {e}"))
}

/// Compare runs against the golden (determinism first), honouring tolerance / ignore.
pub fn compare_runs_with(rules: &[ColRule], golden: &Trace, runs: &[Trace], steps: u32) -> Result<(), FailInfo> {
    determinism(runs, steps)?;
    for (k, r) in runs.iter().enumerate() {
        if let Some(m) = diff::compare(rules, golden, r).first() {
            return Err(fail_info(FailKind::Mismatch, k + 1, runs.len(), m, golden, r, steps));
        }
    }
    Ok(())
}

/// Exact comparison (no tolerance, nothing ignored): the canary and the legacy golden check.
pub fn compare_runs(golden: &Trace, runs: &[Trace], steps: u32) -> Result<(), FailInfo> {
    compare_runs_with(&[], golden, runs, steps)
}

/// Plain-string form of [`compare_runs`] (used by the unit tests).
#[allow(dead_code)]
pub fn check_runs(golden: &Trace, runs: &[Trace]) -> Result<(), String> {
    compare_runs(golden, runs, 0).map_err(|f| f.headline())
}

pub fn run_spec(spec: &RunSpec) -> RunResult {
    let read = |p: &std::path::Path| std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()));
    let sc = match read(&spec.scenario).and_then(|t| {
        scenario::Scenario::parse(&t).map_err(|e| format!("invalid scenario {}: {e}", spec.scenario.display()))
    }) {
        Ok(s) => s,
        Err(e) => return RunResult::Error(e),
    };
    let gold = match read(&spec.golden).and_then(|t| {
        trace::parse_trace(&t).map_err(|e| format!("invalid golden {}: {e}", spec.golden.display()))
    }) {
        Ok(g) => g,
        Err(e) => return RunResult::Error(e),
    };
    let gold = match align(&gold, &spec.fields.columns()) {
        Ok(g) => g,
        Err(e) => return RunResult::Error(format!("{e} ({})", spec.golden.display())),
    };
    let ts = TargetSpec {
        platform: spec.platform.clone(),
        image: spec.image.clone(),
        labels: spec.labels.clone(),
        repeat: spec.repeat,
        opts: spec.opts.clone(),
        fields: spec.fields.clone(),
        keys: None,
    };
    let runs = match run_traces(&ts, &sc) {
        Ok(r) => r,
        Err(e) => return RunResult::Error(e),
    };
    if let Some(d) = &spec.dump {
        if let Err(e) = std::fs::write(d, runs[0].render_plain()) {
            return RunResult::Error(format!("{d}: {e}"));
        }
    }
    match compare_runs_with(&spec.fields.rules(), &gold, &runs, sc.steps) {
        Ok(()) => RunResult::Pass(PassInfo { samples: gold.len(), steps: sc.steps, runs: runs.len() }),
        Err(f) => RunResult::Fail(f),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use trace::parse_trace;

    const G: &str = "0 0 3 0 112 0 32256 44032 0 0 ffffffffff\n\
                     5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff\n";

    #[test]
    fn exact_match_passes() {
        let g = parse_trace(G).unwrap();
        assert!(check_runs(&g, &[g.clone(), g.clone()]).is_ok());
    }

    /// Deliberate regression: one mutated golden line must FAIL with the right report.
    #[test]
    fn mutated_golden_line_fails_with_right_report() {
        let got = parse_trace(G).unwrap();
        let golden = parse_trace(&G.replace("-384", "-385")).unwrap();
        let e = check_runs(&golden, &[got]).unwrap_err();
        assert!(e.contains("step 5"), "{e}");
        assert!(e.contains("field ball_vy"), "{e}");
        assert!(e.contains("expected -385"), "{e}");
        assert!(e.contains("got -384"), "{e}");
    }

    #[test]
    fn differing_repeats_are_flagged_nondeterministic() {
        let g = parse_trace(G).unwrap();
        let other = parse_trace(&G.replace("30720", "30721")).unwrap();
        let e = check_runs(&g, &[g.clone(), other]).unwrap_err();
        assert!(e.starts_with("NON-DETERMINISTIC: run 2 differs from run 1"), "{e}");
        assert!(e.contains("ball_x"), "{e}");
    }

    #[test]
    fn structured_fail_carries_kind_run_and_context() {
        let got = parse_trace(G).unwrap();
        let golden = parse_trace(&G.replace("-384", "-385")).unwrap();
        let f = compare_runs(&golden, &[got.clone(), got], 10).unwrap_err();
        assert_eq!((f.kind, f.run, f.of), (FailKind::Mismatch, 1, 2));
        assert_eq!(f.mismatch.field, "ball_vy");
        assert_eq!(f.mismatch.tolerance, None);
        assert!(f.context.contains("- #1") && f.context.contains("+ #1"), "{}", f.context);
    }

    #[test]
    fn unknown_platform_is_an_error() {
        assert!(make_target("zx", "a", "b", &BackendOpts::default()).is_err());
    }

    #[test]
    fn unreadable_inputs_are_errors_not_failures() {
        let spec = RunSpec {
            platform: "c64".into(),
            image: "a.prg".into(),
            labels: "a.vs".into(),
            scenario: "/no/such/scenario.toml".into(),
            golden: "/no/such/golden.trace".into(),
            repeat: 1,
            opts: BackendOpts::default(),
            dump: None,
            fields: FieldMap::builtin(),
        };
        match run_spec(&spec) {
            RunResult::Error(e) => assert!(e.contains("no such file") || e.contains("No such file"), "{e}"),
            _ => panic!("expected an Error"),
        }
    }
}
