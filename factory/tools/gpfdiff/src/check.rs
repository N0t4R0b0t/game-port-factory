//! `gpfdiff check <port-dir>`: run every recipe scenario of a port sequentially (never in
//! parallel: emulator concurrency is capped), then the built-in canary, and report.
//!
//! Where the expected trace comes from is the manifest's `[oracle]` block: the recipe's golden
//! files (default), traces recorded with `gpfdiff capture`, or another port run live. Verdicts
//! per scenario are PASS / EXPECTED / FAIL (see `expect.rs`).

use crate::diff::{self, ColRule};
use crate::doctor;
use crate::errors::{self, Kind};
use crate::expect::{self, Deviation, Verdict};
use crate::fields::{format_num, FieldMap};
use crate::keys;
use crate::manifest::{self, FieldDef, InputMode, Manifest, OracleSource, StateSource};
use crate::report::*;
use crate::runner::{self, BackendOpts, FailInfo, FailKind, TargetSpec};
use crate::scenario::Scenario;
use crate::trace::Trace;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Clone, Debug, Default)]
pub struct CheckArgs {
    pub port: PathBuf,
    /// Alternate manifest file name inside the port dir (e.g. `harness.live.toml`).
    pub manifest: Option<String>,
    pub only: Vec<String>,
    pub list: bool,
    pub repeat: Option<u32>,
    pub json: bool,
    pub no_canary: bool,
    pub fail_fast: bool,
    pub timeout: Option<u64>,
    pub debug: bool,
    pub x64sc: Option<String>,
    pub xvfb: Option<String>,
    pub mame: Option<String>,
    pub machine: Option<String>,
    pub rompath: Option<String>,
    pub color: bool,
}

/// Command-line overrides for the emulator settings, shared by `check` and `capture`.
#[derive(Clone, Debug, Default)]
pub struct Overrides {
    pub timeout: Option<u64>,
    pub debug: bool,
    pub x64sc: Option<String>,
    pub xvfb: Option<String>,
    pub mame: Option<String>,
    pub machine: Option<String>,
    pub rompath: Option<String>,
}

impl CheckArgs {
    pub fn overrides(&self) -> Overrides {
        Overrides {
            timeout: self.timeout,
            debug: self.debug,
            x64sc: self.x64sc.clone(),
            xvfb: self.xvfb.clone(),
            mame: self.mame.clone(),
            machine: self.machine.clone(),
            rompath: self.rompath.clone(),
        }
    }
}

impl Overrides {
    /// What applies to a live oracle port: the tool paths and timeout, but not the machine
    /// or ROM path (those belong to the oracle's own platform).
    pub fn for_oracle(&self) -> Overrides {
        Overrides { machine: None, rompath: None, ..self.clone() }
    }
}

/// The field map a manifest declares (`labels` = the built-in Brickfall columns).
pub fn field_map(m: &Manifest) -> FieldMap {
    match m.state_source {
        StateSource::Labels => FieldMap::builtin(),
        StateSource::Map => FieldMap::from_defs(&m.fields as &[FieldDef]),
    }
}

/// Scenario names (file stems of `<recipe>/scenarios/*.toml`), sorted.
pub fn discover(recipe: &Path) -> Result<Vec<String>, String> {
    let dir = recipe.join("scenarios");
    let rd = std::fs::read_dir(&dir).map_err(|e| format!("invalid recipe dir: {}: {e}", dir.display()))?;
    let mut v: Vec<String> = rd
        .flatten()
        .filter(|e| e.path().extension().map_or(false, |x| x == "toml"))
        .filter_map(|e| e.path().file_stem().map(|s| s.to_string_lossy().to_string()))
        .collect();
    v.sort();
    if v.is_empty() {
        return Err(format!("invalid recipe dir: no scenarios/*.toml under {}", recipe.display()));
    }
    Ok(v)
}

/// Apply `--only a,b`; unknown names are an error that lists what exists.
pub fn select(all: &[String], only: &[String]) -> Result<Vec<String>, String> {
    if only.is_empty() {
        return Ok(all.to_vec());
    }
    for o in only {
        if !all.contains(o) {
            return Err(format!("invalid --only: no scenario `{o}` (available: {})", all.join(", ")));
        }
    }
    Ok(all.iter().filter(|a| only.contains(a)).cloned().collect())
}

/// The canary: mutate one sample in memory and demand that the comparison rejects it, naming
/// the right sample and field. A harness that cannot fail is a harness error. No emulator run
/// is needed: the comparison is a pure function of the two traces, and `trace` is what the
/// emulator really produced for a passing scenario. The mutated column is `ball_vx` when the
/// trace has it, else the first column that is compared; the mutation exceeds its tolerance.
pub fn canary(trace: &Trace, rules: &[ColRule]) -> CanaryReport {
    let Some(idx) = trace.len().checked_sub(1).map(|l| l.min(2)) else {
        return CanaryReport { ran: true, rejected: false, detail: "golden trace is empty, nothing to mutate".into() };
    };
    let rule_of = |c: &str| rules.iter().find(|r| r.name == c).cloned().unwrap_or_else(|| ColRule::exact(c));
    let usable = |c: &str| !rule_of(c).ignore;
    let Some(col) = trace
        .columns
        .iter()
        .position(|c| c == "ball_vx" && usable(c))
        .or_else(|| trace.columns.iter().position(|c| usable(c)))
    else {
        return CanaryReport { ran: true, rejected: false, detail: "every column is ignored, nothing to compare".into() };
    };
    let name = trace.columns[col].clone();
    let tol = rule_of(&name).tolerance;
    let orig = trace.lines[idx].cols[col].clone();
    let new = if name == "ball_vx" && tol == 0.0 {
        if orig == "1" { "2".to_string() } else { "1".to_string() }
    } else if let Ok(v) = orig.parse::<f64>() {
        format_num(v + tol + 1.0)
    } else {
        format!("{orig}x")
    };
    let mut mutated = trace.clone();
    mutated.lines[idx].cols[col] = new.clone();
    let step = trace.step_at(idx).map_or(String::new(), |s| format!(" (step {s})"));
    let what = format!("sample #{idx}{step} {name} {new} (was {orig})");
    match runner::compare_runs_with(rules, &mutated, &[trace.clone()], 0) {
        Err(f) if f.kind == FailKind::Mismatch && f.mismatch.index == idx && f.mismatch.field == name && f.mismatch.expected == new && f.mismatch.got == orig => {
            CanaryReport { ran: true, rejected: true, detail: format!("mutated {what}; rejected: {}", f.mismatch) }
        }
        Err(f) => CanaryReport { ran: true, rejected: false, detail: format!("mutated {what}; rejected with the WRONG report: {}", f.mismatch) },
        Ok(()) => CanaryReport { ran: true, rejected: false, detail: format!("mutated {what}; the harness accepted it") },
    }
}

fn env_report(port: &str, platform: &str, repeat: u32, e: String, t0: Instant) -> CheckReport {
    CheckReport {
        port: port.into(),
        platform: platform.into(),
        repeat,
        scenarios: vec![],
        canary: None,
        environment_error: Some((errors::classify(&e), e)),
        secs: t0.elapsed().as_secs_f64(),
        stale: vec![],
        oracle: None,
    }
}

/// A port's name for reports: its directory name; for a manifest kept in a sub-directory of a port
/// (`ports/x/blackbox`) `x/blackbox`, so two manifests of one port are told apart.
pub fn port_name(dir: &Path) -> String {
    let abs = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
    let last = abs.file_name().map(|n| n.to_string_lossy().to_string());
    let parent = abs.parent();
    match (last, parent) {
        (Some(l), Some(p)) if !abs.join("PORT.toml").is_file() && p.join("PORT.toml").is_file() => {
            format!("{}/{l}", p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default())
        }
        (Some(l), _) => l,
        _ => dir.display().to_string(),
    }
}

/// Find a live oracle port: relative to the manifest dir first, then up through its parents
/// (so `ports/other` works from any port of the same repo).
pub fn resolve_port(dir: &Path, p: &str) -> Result<PathBuf, String> {
    let pb = Path::new(p);
    if pb.is_absolute() {
        return if pb.exists() { Ok(pb.to_path_buf()) } else { Err(format!("invalid [oracle] port: `{p}` does not exist")) };
    }
    let direct = dir.join(pb);
    if direct.exists() {
        return Ok(direct);
    }
    if let Ok(abs) = dir.canonicalize() {
        for anc in abs.ancestors().skip(1) {
            if anc.join(pb).exists() {
                return Ok(anc.join(pb));
            }
        }
    }
    Err(format!("invalid [oracle] port: `{p}` not found relative to {} or any parent directory", dir.display()))
}

/// Backend options and pre-flight for one manifest: CLI override > harness.toml `[emulator]` > default.
/// Everything here must hold before an emulator is started.
pub fn build_target(m: &Manifest, dir: &Path, o: &Overrides, repeat: u32) -> Result<TargetSpec, String> {
    let platform = m.platform.clone();
    let mut opts = BackendOpts { timeout: o.timeout.or(m.timeout).unwrap_or(30), debug: o.debug, ..BackendOpts::default() };
    if let Some(v) = o.x64sc.clone().or(m.emulator.x64sc.clone()) {
        opts.x64sc = v;
    }
    if let Some(v) = o.xvfb.clone().or(m.emulator.xvfb.clone()) {
        opts.xvfb = v;
    }
    if let Some(v) = o.mame.clone().or(m.emulator.mame.clone()) {
        opts.mame = v;
    }
    opts.machine = runner::default_machine(&platform).to_string();
    if let Some(v) = o.machine.clone().or(m.emulator.machine.clone()) {
        opts.machine = v;
    }
    let image = manifest::resolve(dir, &m.image);
    let labels = m.labels.as_ref().map(|l| manifest::resolve(dir, l));
    doctor::preflight_exe(&platform, &opts.x64sc, &opts.mame)?;
    match (m.input_mode, &labels) {
        (InputMode::Breakpoint, Some(l)) => doctor::preflight_files(&platform, &image, l, &m.required_labels)?,
        (InputMode::Breakpoint, None) => return Err("invalid harness.toml: missing required key `labels`".into()),
        (InputMode::Keys, Some(l)) => doctor::preflight_files(&platform, &image, l, &m.required_labels)?,
        (InputMode::Keys, None) => {
            if !image.is_file() {
                return Err(format!("{}: no such file (image not built?)", image.display()));
            }
            if let Some(l) = m.required_labels.first() {
                return Err(format!("label `{l}` missing from harness.toml: `required_labels` needs a `labels` symbol file"));
            }
        }
    }
    if let Some(var) = doctor::rompath_env_var(&platform) {
        let env = std::env::var(var).ok();
        let rp = doctor::resolve_rompath_named(o.rompath.as_deref(), env.as_deref(), m.emulator.rompath.as_deref(), doctor::home_dir().as_deref(), &opts.machine, var)?;
        opts.rompath = Some(rp);
    }
    let keys = match m.input_mode {
        InputMode::Breakpoint => None,
        InputMode::Keys => {
            let label_map = match &labels {
                Some(l) => {
                    let text = std::fs::read_to_string(l).map_err(|e| format!("{}: {e}", l.display()))?;
                    if platform == "coco2" { crate::coco::parse_labels(&text) } else { crate::mame::parse_labels(&text) }
                }
                None => Default::default(),
            };
            Some(keys::KeysCfg {
                platform: platform.clone(),
                time: keys::TimeAxis { fps: m.time.fps.unwrap_or_else(|| keys::default_fps(&platform)), step_ms: m.time.step_ms },
                latency: m.time.input_latency_frames,
                keymap: m.input_keys.clone(),
                gate: m.boot.ready,
                ready_keys: m.boot.ready_keys.clone(),
                timeout_ms: m.boot.timeout_ms,
                labels: label_map,
            })
        }
    };
    Ok(TargetSpec {
        platform,
        image: image.to_string_lossy().to_string(),
        labels: labels.map(|l| l.to_string_lossy().to_string()).unwrap_or_default(),
        repeat,
        opts,
        fields: field_map(m),
        keys,
    })
}

/// The recipe directory a manifest names (scenarios, goldens). `check` and `capture` need it; `watch` does not.
pub fn recipe_dir(m: &Manifest, dir: &Path) -> Result<PathBuf, String> {
    m.recipe.as_ref().map(|r| manifest::resolve(dir, r)).ok_or_else(|| "invalid harness.toml: missing required key `recipe` (check and capture run its scenarios)".to_string())
}

/// Load the manifest `check`/`capture` run from: `<port>/<manifest>` or `<port>/harness.toml`.
pub fn load_manifest(port: &Path, alt: Option<&str>) -> Result<(Manifest, PathBuf), String> {
    match alt {
        Some(name) if !port.is_file() => Manifest::load(&port.join(name)),
        _ => Manifest::load(port),
    }
}

/// `expectations.toml` of a manifest: explicit path (must exist) or `<dir>/expectations.toml` (optional).
fn load_expectations(m: &Manifest, dir: &Path) -> Result<Vec<Deviation>, String> {
    let (path, required) = match &m.expectations {
        Some(p) => (manifest::resolve(dir, p), true),
        None => (dir.join("expectations.toml"), false),
    };
    match std::fs::read_to_string(&path) {
        Ok(t) => expect::parse(&t).map_err(|e| format!("invalid {}: {e}", path.display())),
        Err(e) if !required && e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(format!("invalid expectations file {}: {e}", path.display())),
    }
}

/// Where the expected trace of each scenario comes from.
enum Oracle {
    Files { dir: PathBuf, label: Option<String> },
    Live { name: String, spec: TargetSpec },
}

fn read_trace_file(p: &Path, what: &str) -> Result<Trace, String> {
    let t = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
    Trace::parse(&t).map_err(|e| format!("invalid {what} {}: {e}", p.display()))
}

/// Run `check`; returns the exit code. All human/JSON output goes to `out`.
pub fn run_check(a: &CheckArgs, out: &mut dyn Write) -> u8 {
    let t0 = Instant::now();
    let st = Style { color: a.color && !a.json };
    let port_s = a.port.display().to_string();
    let mut say = |s: &str| {
        let _ = writeln!(out, "{s}");
        let _ = out.flush();
    };

    // Everything before the first scenario is an environment error: exit 2, nothing ran.
    let abort = |say: &mut dyn FnMut(&str), platform: &str, repeat: u32, e: String| -> u8 {
        let rep = env_report(&port_s, platform, repeat, e.clone(), t0);
        if a.json {
            say(&to_json(&rep));
        } else {
            say(&st.yellow(&format!("ERROR: {}", errors::render(&e, platform, a.debug))));
        }
        errors::EXIT_ENV
    };

    let (m, dir): (Manifest, PathBuf) = match load_manifest(&a.port, a.manifest.as_deref()) {
        Ok(v) => v,
        Err(e) => return abort(&mut say, "", a.repeat.unwrap_or(2), e),
    };
    let repeat = a.repeat.or(m.repeat).unwrap_or(2).max(1);
    let platform = m.platform.clone();
    let recipe = match recipe_dir(&m, &dir) {
        Ok(r) => r,
        Err(e) => return abort(&mut say, &platform, repeat, e),
    };
    let all = match discover(&recipe) {
        Ok(v) => v,
        Err(e) => return abort(&mut say, &platform, repeat, e),
    };
    let names = match select(&all, &a.only) {
        Ok(v) => v,
        Err(e) => return abort(&mut say, &platform, repeat, e),
    };

    if a.list {
        if a.json {
            say(&format!("[{}]", names.iter().map(|n| json_str(n)).collect::<Vec<_>>().join(",")));
        } else {
            for n in &names {
                let steps = std::fs::read_to_string(recipe.join("scenarios").join(format!("{n}.toml")))
                    .ok()
                    .and_then(|t| Scenario::parse(&t).ok())
                    .map_or("?".to_string(), |s| s.steps.to_string());
                say(&format!("{n}  ({steps} steps)"));
            }
        }
        return errors::EXIT_PASS;
    }

    let devs = match load_expectations(&m, &dir) {
        Ok(d) => d,
        Err(e) => return abort(&mut say, &platform, repeat, e),
    };
    let ov = a.overrides();
    let spec = match build_target(&m, &dir, &ov, repeat) {
        Ok(s) => s,
        Err(e) => return abort(&mut say, &platform, repeat, e),
    };
    let (oracle, oracle_desc): (Oracle, (String, String)) = match &m.oracle {
        OracleSource::Recipe => (Oracle::Files { dir: recipe.join("golden"), label: None }, ("recipe".into(), recipe.join("golden").display().to_string())),
        OracleSource::Trace { dir: d } => {
            let p = manifest::resolve(&dir, d);
            let desc = p.display().to_string();
            (Oracle::Files { dir: p, label: Some(format!("captured trace {desc}")) }, ("trace".into(), desc))
        }
        OracleSource::Live { port, manifest: mf } => {
            let built = resolve_port(&dir, port).and_then(|pdir| {
                let (om, odir) = Manifest::load(&pdir.join(mf.as_deref().unwrap_or("harness.toml")))?;
                let ospec = build_target(&om, &odir, &ov.for_oracle(), repeat)?;
                Ok((port_name(&odir), ospec))
            });
            match built {
                Ok((name, ospec)) => (Oracle::Live { name: name.clone(), spec: ospec }, ("live".into(), name)),
                Err(e) => return abort(&mut say, &platform, repeat, format!("live oracle: {e}")),
            }
        }
    };
    let rules = spec.fields.rules();
    let columns = spec.fields.columns();
    let my_name = port_name(&dir);

    let w = name_width(names.iter().map(|n| n.len()));
    let rw = if devs.is_empty() { 6 } else { 8 };
    if !a.json {
        say(&st.bold(&format!("gpfdiff check {port_s} ({platform}, {} scenarios, repeat {repeat})", names.len())));
        if oracle_desc.0 != "recipe" {
            let what = match &oracle {
                Oracle::Live { spec: o, .. } => format!("oracle: live port {} ({}); port: {my_name} ({platform}); runs sequential", oracle_desc.1, o.platform),
                Oracle::Files { .. } => format!("oracle: captured traces in {}", oracle_desc.1),
            };
            say(&what);
        }
        say(&table_header_w(w, rw));
    }
    let mut rows: Vec<ScenarioReport> = vec![];
    let mut ran: Vec<(String, Vec<usize>)> = vec![];
    let mut first_pass_trace: Option<Trace> = None;
    for n in &names {
        let t1 = Instant::now();
        let scen_path = recipe.join("scenarios").join(format!("{n}.toml"));
        let err_row = |e: String| ScenarioReport {
            name: n.clone(),
            steps: None,
            samples: None,
            runs: 0,
            secs: t1.elapsed().as_secs_f64(),
            outcome: Outcome::Error { kind: errors::classify(&e), message: e },
            fields: vec![],
        };
        let one = || -> Result<(ScenarioReport, Option<Vec<usize>>, Option<Trace>), String> {
            let sc = std::fs::read_to_string(&scen_path)
                .map_err(|e| format!("{}: {e}", scen_path.display()))
                .and_then(|t| Scenario::parse_with(&t, m.time.step_ms).map_err(|e| format!("invalid scenario {}: {e}", scen_path.display())))?;
            // the expected trace
            let (oracle_trace, oracle_label): (Trace, Option<String>) = match &oracle {
                Oracle::Files { dir: d, label } => {
                    let f = d.join(format!("{n}.trace"));
                    let what = if label.is_some() { "captured trace" } else { "golden" };
                    (read_trace_file(&f, what)?, label.as_ref().map(|l| format!("{l}/{n}.trace")))
                }
                Oracle::Live { name, spec: ospec } => {
                    let runs = runner::run_traces(ospec, &sc).map_err(|e| format!("live oracle `{name}`: {e}"))?;
                    if let Err(f) = runner::determinism(&runs, sc.steps) {
                        return Err(format!("live oracle `{name}` failed its own determinism gate (an oracle that differs from itself cannot judge anything): {}", f.headline()));
                    }
                    (runs[0].clone(), Some(format!("live port {name}")))
                }
            };
            let oracle_trace = runner::align(&oracle_trace, &columns)?;
            // the port under test (the oracle's emulator has already exited: sequential)
            let runs = runner::run_traces(&spec, &sc)?;
            let mk = |outcome: Outcome, fields: Vec<expect::FieldVerdict>, steps: u32, samples: usize| ScenarioReport {
                name: n.clone(),
                steps: Some(steps),
                samples: Some(samples),
                runs: runs.len(),
                secs: t1.elapsed().as_secs_f64(),
                outcome,
                fields,
            };
            let annotate = |mut f: FailInfo| {
                if let Some(l) = &oracle_label {
                    f.context.push_str(&format!("\n- expected = oracle: {l}\n+ got      = port:   {my_name}"));
                }
                f
            };
            if let Err(f) = runner::determinism(&runs, sc.steps) {
                let (steps, samples) = (f.steps, f.samples);
                return Ok((mk(Outcome::Fail(annotate(f)), vec![], steps, samples), None, None));
            }
            let diffs = diff::compare(&rules, &oracle_trace, &runs[0]);
            let j = expect::judge(n, &diffs, &devs);
            let samples = oracle_trace.len();
            let triggered = j.triggered.clone();
            Ok(match j.verdict {
                Verdict::Pass => (mk(Outcome::Pass, vec![], sc.steps, samples), Some(triggered), Some(runs[0].clone())),
                Verdict::Expected => (mk(Outcome::Expected, j.fields, sc.steps, samples), Some(triggered), None),
                Verdict::Fail => {
                    let m = j.fail.clone().expect("a failing verdict carries its mismatch");
                    let fi = annotate(runner::fail_info(FailKind::Mismatch, 1, runs.len(), m, &oracle_trace, &runs[0], sc.steps));
                    let (steps, samples) = (fi.steps, fi.samples);
                    (mk(Outcome::Fail(fi), j.fields, steps, samples), Some(triggered), None)
                }
            })
        };
        let row = match one() {
            Ok((row, trig, pass_trace)) => {
                if let Some(t) = trig {
                    ran.push((n.clone(), t));
                }
                if let Some(t) = pass_trace {
                    first_pass_trace.get_or_insert(t);
                }
                row
            }
            Err(e) => err_row(e),
        };
        if !a.json {
            say(&table_row_w(&row, w, rw, &st));
            let d = details(&row, &platform, a.debug);
            if !d.is_empty() {
                say(&d);
            }
        }
        let bad = matches!(row.outcome, Outcome::Fail(_) | Outcome::Error { .. });
        rows.push(row);
        if bad && a.fail_fast {
            break;
        }
    }

    let stale = expect::stale(&devs, &columns, &all, &ran);
    let canary_rep = if a.no_canary {
        None
    } else {
        Some(match &first_pass_trace {
            Some(t) => canary(t, &rules),
            None => CanaryReport { ran: false, rejected: false, detail: "no scenario passed, nothing to mutate".into() },
        })
    };
    let rep = CheckReport {
        port: port_s,
        platform: platform.clone(),
        repeat,
        scenarios: rows,
        canary: canary_rep,
        environment_error: None,
        secs: t0.elapsed().as_secs_f64(),
        stale,
        oracle: Some(oracle_desc),
    };
    if a.json {
        say(&to_json(&rep));
    } else {
        for s in &rep.stale {
            let until = s.until.as_ref().map_or(String::new(), |u| format!(" [until {u}]"));
            let sc = if s.scenarios.is_empty() { String::new() } else { format!(" in {}", s.scenarios.join(",")) };
            say(&st.yellow(&format!("warning: STALE expectation: axis `{}`{sc}{until}: {} (reason was: {}); fix the port or delete the entry", s.axis, s.why, s.reason)));
        }
        if let Some(c) = &rep.canary {
            let line = format!("canary: {}", c.detail);
            say(&if c.ran && !c.rejected { st.red(&line) } else { line });
        }
        say(&rep.summary_line(&st));
    }
    rep.exit_code()
}

#[allow(dead_code)]
pub fn kind_of(e: &str) -> Kind {
    errors::classify(e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trace::parse_trace;
    use std::os::unix::fs::PermissionsExt;

    const G: &str = "0 0 3 0 112 0 32256 44032 0 0 ffffffffff\n\
                     5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff\n\
                     10 1 3 0 108 0 30080 40576 -128 -384 ffffffffff\n";

    #[test]
    fn canary_rejects_when_the_comparison_works() {
        let c = canary(&parse_trace(G).unwrap(), &[]);
        assert!(c.ran && c.rejected, "{}", c.detail);
        assert!(c.detail.contains("sample #2 (step 10) ball_vx 1 (was -128)"), "{}", c.detail);
        // one-line trace: mutates sample #0
        let c = canary(&parse_trace(&G.lines().next().unwrap().to_string()).unwrap(), &[]);
        assert!(c.rejected && c.detail.contains("sample #0"), "{}", c.detail);
        // original value 1 is mutated to 2, never to itself
        let c = canary(&parse_trace(&G.replace("-128 -384 ffffffffff\n10", "1 -384 ffffffffff\n10")).unwrap(), &[]);
        assert!(c.rejected, "{}", c.detail);
        assert!(!canary(&Trace { columns: Trace::default_columns(), lines: vec![] }, &[]).rejected);
    }

    #[test]
    fn select_filters_and_rejects_unknown() {
        let all: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        assert_eq!(select(&all, &[]).unwrap(), all);
        assert_eq!(select(&all, &["c".into(), "a".into()]).unwrap(), vec!["a", "c"]);
        let e = select(&all, &["zz".into()]).unwrap_err();
        assert!(e.contains("no scenario `zz`") && e.contains("a, b, c"), "{e}");
    }

    // ---- end-to-end against a fake MAME (a shell script speaking the Lua protocol) ----

    struct Port {
        dir: PathBuf,
    }

    impl Port {
        fn new(tag: &str) -> Port {
            let dir = std::env::temp_dir().join(format!("gpfdiff_check_{}_{tag}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            for d in ["target", "roms", "recipe/scenarios", "recipe/golden"] {
                std::fs::create_dir_all(dir.join(d)).unwrap();
            }
            let sh = dir.join("fakemame.sh");
            std::fs::write(
                &sh,
                "#!/bin/bash\necho chatter\necho 'GPF READY'\nn=0\n\
                 emit() { printf 'GPF S %02x%02x0003%s\\n' $((n&255)) $((n>>8)) '000000000000000000000000ffffffffff'; }\n\
                 emit\nwhile read -r cmd arg; do\n  [ \"$cmd\" = Q ] && exit 0\n  n=$((n+1))\n  echo \"GPF ACK $arg 32881\"\n  emit\ndone\n",
            )
            .unwrap();
            std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
            std::fs::write(dir.join("roms/spectrum.zip"), b"z").unwrap();
            std::fs::write(dir.join("target/x.sna"), b"x").unwrap();
            std::fs::write(dir.join("target/l.sym"), "gpf_state: equ 0x0000F000\ngpf_bricks: equ 0x0000F010\ngpf_input_ret: equ 0x00008071\n").unwrap();
            std::fs::write(
                dir.join("harness.toml"),
                format!(
                    "platform = \"zx48\"\nimage = \"target/x.sna\"\nlabels = \"target/l.sym\"\nrecipe = \"recipe\"\nrepeat = 2\n[emulator]\nmame = \"{}\"\nrompath = \"{}\"\n",
                    sh.display(),
                    dir.join("roms").display()
                ),
            )
            .unwrap();
            let p = Port { dir };
            p.scenario("alpha", 4);
            p.scenario("beta", 6);
            p
        }

        fn golden_text(steps: u32) -> String {
            (0..=steps).map(|n| format!("{n} 0 3 0 0 0 0 0 0 0 ffffffffff\n")).collect()
        }

        fn scenario(&self, name: &str, steps: u32) {
            std::fs::write(self.dir.join(format!("recipe/scenarios/{name}.toml")), format!("steps = {steps}\n[[input]]\nstep = 0\nbuttons = 1\n")).unwrap();
            std::fs::write(self.dir.join(format!("recipe/golden/{name}.trace")), Port::golden_text(steps)).unwrap();
        }

        fn run(&self, f: impl FnOnce(&mut CheckArgs)) -> (u8, String) {
            let mut a = CheckArgs { port: self.dir.clone(), ..CheckArgs::default() };
            f(&mut a);
            let mut buf: Vec<u8> = vec![];
            let code = run_check(&a, &mut buf);
            (code, String::from_utf8(buf).unwrap())
        }
    }

    impl Drop for Port {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn happy_path_two_scenarios_and_canary() {
        let p = Port::new("ok");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("alpha") && out.contains("beta") && out.contains("PASS"), "{out}");
        assert!(out.contains("canary: mutated sample #2"), "{out}");
        assert!(out.trim_end().ends_with(|c: char| c == 's'), "{out}");
        assert!(out.contains("CHECK PASS: 2/2 scenarios passed, x2 runs deterministic, canary rejected"), "{out}");
    }

    /// A coco2 port directory: DECB image, lwasm map, `coco2b` folder-style romset, fake MAME
    /// that refuses to start unless it is handed the coco2b machine, `-ext ""` and a load list.
    #[test]
    fn coco2_pipeline_end_to_end_and_its_environment_errors() {
        let p = Port::new("coco");
        let sh = p.dir.join("fakecoco.sh");
        let fake = std::fs::read_to_string(p.dir.join("fakemame.sh")).unwrap().replace("32881", "16387");
        let guard = "#!/bin/bash\n[ \"$1\" = coco2b ] || { echo \"GPF ERR machine is $1\"; exit 1; }\n\
                     grep -q '^X 16384$' \"$GPF_LOAD\" || { echo 'GPF ERR no entry in load list'; exit 1; }\n";
        std::fs::write(&sh, fake.replacen("#!/bin/bash\n", guard, 1)).unwrap();
        std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::create_dir_all(p.dir.join("roms/coco2b")).unwrap();
        std::fs::write(p.dir.join("roms/coco2b/bas13.rom"), b"r").unwrap();
        std::fs::write(p.dir.join("target/x.bin"), [0u8, 0, 4, 0x40, 0, 0x8e, 0xbe, 0xef, 0x39, 0xff, 0, 0, 0x40, 0]).unwrap();
        std::fs::write(
            p.dir.join("target/x.map"),
            "Symbol: gpf_state (x.bin) = 1000\nSymbol: gpf_bricks (x.bin) = 1010\nSymbol: gpf_input_ret (x.bin) = 4003\n",
        )
        .unwrap();
        std::fs::write(
            p.dir.join("harness.toml"),
            format!(
                "platform = \"coco2\"\nimage = \"target/x.bin\"\nlabels = \"target/x.map\"\nrecipe = \"recipe\"\nrepeat = 2\n[emulator]\nmame = \"{}\"\nrompath = \"{}\"\n",
                sh.display(),
                p.dir.join("roms").display()
            ),
        )
        .unwrap();
        // default machine for coco2 is coco2b (the fake exits with an ERR otherwise)
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("gpfdiff check") && out.contains("(coco2, 2 scenarios, repeat 2)"), "{out}");
        assert!(out.contains("CHECK PASS: 2/2 scenarios passed, x2 runs deterministic, canary rejected"), "{out}");
        // a wrong machine really reaches MAME (the fake answers ERR -> script error, exit 2)
        std::fs::create_dir_all(p.dir.join("roms/coco3")).unwrap();
        std::fs::write(p.dir.join("roms/coco3/x.rom"), b"r").unwrap();
        let (code, out) = p.run(|a| a.machine = Some("coco3".into()));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("machine is coco3"), "{out}");
        // ROM missing: coco wording, COCO_ROMPATH, doctor --platform coco2
        let (code, out) = p.run(|a| a.rompath = Some(p.dir.join("target").to_string_lossy().to_string()));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("romset `coco2b` not found") && out.contains("COCO_ROMPATH") && out.contains("doctor --platform coco2"), "{out}");
        assert!(!out.contains("ZX_ROMPATH"), "{out}");
        // stale map: gpf_input_ret outside the image
        std::fs::write(
            p.dir.join("target/x.map"),
            "Symbol: gpf_state (x.bin) = 1000\nSymbol: gpf_bricks (x.bin) = 1010\nSymbol: gpf_input_ret (x.bin) = 5000\n",
        )
        .unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("not inside a loaded segment"), "{out}");
    }

    #[test]
    fn broken_golden_is_exit_1_with_the_right_diff_line() {
        let p = Port::new("broken");
        // sample #3 of beta: ball_vx expected 7, the emulator reports 0
        let g = std::fs::read_to_string(p.dir.join("recipe/golden/beta.trace")).unwrap();
        std::fs::write(p.dir.join("recipe/golden/beta.trace"), g.replace("\n3 0 3 0 0 0 0 0 0 0 ffffffffff", "\n3 0 3 0 0 0 0 0 0 7 ffffffffff")).unwrap();
        let (code, out) = p.run(|a| a.only = vec!["beta".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("FAIL"), "{out}");
        assert!(out.contains("MISMATCH step 3 (sample #3) field ball_vy: expected 7 got 0"), "{out}");
        assert!(out.contains("- #3") && out.contains("+ #3") && out.contains("differing field: ball_vy"), "{out}");
        assert!(out.contains("CHECK FAIL: 1 of 1"), "{out}");
        // the unaffected scenario still passes on its own
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 0, "{out}");
    }

    #[test]
    fn fail_fast_stops_after_the_first_failure() {
        let p = Port::new("ff");
        std::fs::write(p.dir.join("recipe/golden/alpha.trace"), Port::golden_text(4).replace("2 0 3 0 0 0 0 0 0 0", "2 0 3 9 0 0 0 0 0 0")).unwrap();
        let (code, out) = p.run(|a| a.fail_fast = true);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("alpha") && !out.contains("\nbeta"), "{out}");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("\nbeta"), "keep-going is the default: {out}");
    }

    #[test]
    fn environment_error_is_exit_2() {
        let p = Port::new("env");
        // emulator missing
        let (code, out) = p.run(|a| a.mame = Some("/nonexistent/mame".into()));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("cannot start") && out.contains("gpfdiff doctor --platform zx48"), "{out}");
        // ROM missing
        let (code, out) = p.run(|a| a.rompath = Some(p.dir.join("target").to_string_lossy().to_string()));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("romset `spectrum` not found") && out.contains("ZX_ROMPATH"), "{out}");
        // missing label
        std::fs::write(p.dir.join("target/l.sym"), "gpf_state: equ 0x0000F000\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("label `gpf_bricks` missing"), "{out}");
        // no manifest
        let (code, out) = p.run(|a| a.port = p.dir.join("recipe"));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("harness.toml"), "{out}");
    }

    #[test]
    fn timeout_is_exit_2_not_a_game_failure() {
        let p = Port::new("to");
        let sh = p.dir.join("hang.sh");
        std::fs::write(&sh, "#!/bin/bash\necho 'GPF READY'\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let (code, out) = p.run(|a| {
            a.mame = Some(sh.to_string_lossy().to_string());
            a.timeout = Some(1);
            a.only = vec!["alpha".into()];
        });
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("ERROR") && out.contains("timed out") && out.contains("likely cause:"), "{out}");
    }

    #[test]
    fn json_mode_emits_one_document_and_list_works() {
        let p = Port::new("json");
        let (code, out) = p.run(|a| {
            a.json = true;
            a.only = vec!["alpha".into()];
            a.no_canary = true;
        });
        assert_eq!(code, 0, "{out}");
        assert_eq!(out.lines().count(), 1, "{out}");
        assert!(out.contains("\"name\":\"alpha\"") && out.contains("\"canary\":null") && out.contains("\"verdict\":\"pass\""), "{out}");
        let (code, out) = p.run(|a| a.list = true);
        assert_eq!(code, 0);
        assert_eq!(out, "alpha  (4 steps)\nbeta  (6 steps)\n");
        let (_, out) = p.run(|a| {
            a.list = true;
            a.json = true;
        });
        assert_eq!(out.trim(), "[\"alpha\",\"beta\"]");
    }

    // ---- field maps, normalisation, tolerance, expectations, capture, oracle sources ----
    // The fake MAME below also answers `P addr len` (RAM reads): address 0x9000 holds x
    // (a bash expression of the step counter `n`), 0x9001 holds `room` = 7.

    fn map_fake(xexpr: &str) -> String {
        format!(
            "#!/bin/bash\necho chatter\necho 'GPF READY'\nn=0\n\
             emit() {{ printf 'GPF S %02x%02x0003%s\\n' $((n&255)) $((n>>8)) '000000000000000000000000ffffffffff'; }}\n\
             emit\nwhile read -r cmd a1 a2; do\n  case \"$cmd\" in\n    Q) exit 0;;\n\
             P) o=''; for ((i=0;i<a2;i++)); do ad=$((a1+i)); case $ad in 36864) v=$(({xexpr}));; 36865) v=7;; *) v=0;; esac; o=\"$o$(printf '%02x' $((v&255)))\"; done; echo \"GPF M $o\";;\n\
             B) n=$((n+1)); echo \"GPF ACK $a1 32881\"; emit;;\n  esac\ndone\n"
        )
    }

    /// Turn a `Port` into a map-mode port: x = `xexpr` raw, golden x = 10+n, room = 7.
    /// `x_extra` / `room_extra` add keys to the two [[field]] entries, `top` goes before the
    /// tables, `tail` after the fields (e.g. an `[oracle]` block).
    fn map_port(p: &Port, xexpr: &str, x_extra: &str, room_extra: &str, top: &str, tail: &str, file: &str) {
        let sh = p.dir.join("fakemame.sh");
        std::fs::write(&sh, map_fake(xexpr)).unwrap();
        std::fs::write(p.dir.join("target/l.sym"), "gpf_state: equ 0x0000F000\ngpf_bricks: equ 0x0000F010\ngpf_input_ret: equ 0x00008071\nplayer_x: equ 0x00009000\n").unwrap();
        std::fs::write(
            p.dir.join(file),
            format!(
                "platform = \"zx48\"\nimage = \"target/x.sna\"\nlabels = \"target/l.sym\"\nrecipe = \"recipe\"\nrepeat = 2\n{top}\n[emulator]\nmame = \"{}\"\nrompath = \"{}\"\n[state]\nsource = \"map\"\n[[field]]\nname = \"x\"\nlabel = \"player_x\"\n{x_extra}\n[[field]]\nname = \"room\"\naddr = 0x9001\n{room_extra}\n{tail}\n",
                sh.display(),
                p.dir.join("roms").display()
            ),
        )
        .unwrap();
    }

    fn map_golden(p: &Port, room: u32) {
        for (name, steps) in [("alpha", 4u32), ("beta", 6)] {
            let g: String = (0..=steps).map(|n| format!("{} {room}\n", 10 + n)).collect();
            std::fs::write(p.dir.join(format!("recipe/golden/{name}.trace")), format!("# columns: x room\n{g}")).unwrap();
        }
    }

    #[test]
    fn scale_makes_a_x4_port_pass_and_its_absence_fails() {
        let p = Port::new("scale");
        map_golden(&p, 7);
        map_port(&p, "(10+n)*4", "scale = 0.25", "", "", "", "harness.toml");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("CHECK PASS: 2/2 scenarios passed") && out.contains("canary: mutated sample #2 x 13 (was 12)"), "{out}");
        // same raw values, no scale: the first sample differs (10 expected, 40 read)
        map_port(&p, "(10+n)*4", "", "", "", "", "harness.toml");
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("MISMATCH sample #0 field x: expected 10 got 40"), "{out}");
        assert!(out.contains("differing field: x (column 1 of 2)") && out.contains("columns: x room"), "{out}");
    }

    #[test]
    fn tolerance_absorbs_plus_minus_one_and_zero_rejects_it() {
        let p = Port::new("tol");
        map_golden(&p, 7);
        let jitter = "10+n+(n%3)-1"; // -1, 0, +1, -1, 0 ...
        map_port(&p, jitter, "tolerance = 1", "", "", "", "harness.toml");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        map_port(&p, jitter, "tolerance = 0", "", "", "", "harness.toml");
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("MISMATCH sample #0 field x: expected 10 got 9") && !out.contains("(tolerance"), "{out}");
        // +-2 jitter beats tolerance 1, and the report says the tolerance was in play
        map_port(&p, "10+n+(n%3)*2-2", "tolerance = 1", "", "", "", "harness.toml");
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("expected 10 got 8 (tolerance 1)") && out.contains("tolerance: field x allows +-1"), "{out}");
    }

    #[test]
    fn ignored_fields_are_printed_not_compared() {
        let p = Port::new("ign");
        map_golden(&p, 8); // room differs everywhere
        map_port(&p, "10+n", "", "ignore = true", "", "", "harness.toml");
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 0, "{out}");
        map_port(&p, "10+n", "", "", "", "", "harness.toml");
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("field room: expected 8 got 7"), "{out}");
    }

    #[test]
    fn expected_deviation_fail_and_stale() {
        let p = Port::new("exp");
        map_golden(&p, 7);
        map_port(&p, "10+n+5", "", "", "", "", "harness.toml"); // x is 5 too high everywhere
        // not declared: FAIL, exit 1
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("FAIL") && out.contains("CHECK FAIL: 1 of 1"), "{out}");
        // declared: EXPECTED, exit 0, shown with its reason
        std::fs::write(p.dir.join("expectations.toml"), "[[expected_deviation]]\naxis = \"x\"\nreason = \"port offsets x by 5\"\nuntil = \"T0001\"\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("EXPECTED") && out.contains("expected deviation `x`: port offsets x by 5 [until T0001]"), "{out}");
        assert!(out.contains("CHECK EXPECTED: 0 passed, 2 with expected deviations of 2 scenarios") && !out.contains("STALE"), "{out}");
        // the table keeps its columns aligned when EXPECTED is possible
        let row = out.lines().find(|l| l.starts_with("alpha")).unwrap();
        let hdr = out.lines().find(|l| l.starts_with("scenario")).unwrap();
        assert_eq!(row.len(), hdr.len(), "{out}");
        // --json: verdicts per scenario and per field, expected list, no stale
        let (code, out) = p.run(|a| {
            a.json = true;
            a.no_canary = true;
        });
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("\"result\":\"expected\"") && out.contains("\"verdict\":\"expected\",\"count\":5"), "{out}");
        assert_eq!(out.matches("\"field\":").count(), 4, "no duplicate keys in a field entry: {out}"); // 2 field entries + 2 expected-list entries
        assert!(out.contains("\"verdict\":\"expected\",\"expected\":2,\"stale\":0}") && out.contains("\"stale\":[]"), "{out}");
        assert!(out.contains("\"expected\":[{\"scenario\":\"alpha\",\"field\":\"x\",\"reason\":\"port offsets x by 5\",\"until\":\"T0001\",\"count\":5}"), "{out}");
        // FAIL beats EXPECTED: room also differs and is not declared
        map_golden(&p, 8);
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("field room: expected 8 got 7") && out.contains("expected deviation `x`"), "{out}");
        let (_, js) = p.run(|a| {
            a.json = true;
            a.only = vec!["alpha".into()];
            a.no_canary = true;
        });
        assert!(js.contains("\"result\":\"fail\"") && js.contains("\"field\":\"x\",\"verdict\":\"expected\"") && js.contains("\"field\":\"room\",\"verdict\":\"fail\""), "{js}");
        // an unused deviation is a STALE warning, never an error
        map_golden(&p, 7);
        map_port(&p, "10+n", "", "", "", "", "harness.toml"); // the port now matches: x deviation never triggers
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("warning: STALE expectation: axis `x`") && out.contains("never differed") && out.contains("1 STALE expectation"), "{out}");
        assert!(out.contains("CHECK PASS: 2/2 scenarios passed"), "{out}");
        let (_, js) = p.run(|a| {
            a.json = true;
            a.no_canary = true;
        });
        assert!(js.contains("\"stale\":[{\"axis\":\"x\"") && js.contains("\"stale\":1}"), "{js}");
        // with --only, a deviation scoped to a scenario that did not run is not judged
        std::fs::write(p.dir.join("expectations.toml"), "[[expected_deviation]]\naxis = \"x\"\nscenarios = [\"beta\"]\nreason = \"r\"\n").unwrap();
        let (_, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert!(!out.contains("STALE"), "{out}");
        // a typo'd field name or scenario is stale too
        std::fs::write(p.dir.join("expectations.toml"), "[[expected_deviation]]\naxis = \"xx\"\nreason = \"r\"\n[[expected_deviation]]\naxis = \"x\"\nscenarios = [\"nope\"]\nreason = \"r\"\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("the port has no field `xx`") && out.contains("no scenario `nope` in the recipe"), "{out}");
        // a malformed expectations file is an environment error
        std::fs::write(p.dir.join("expectations.toml"), "[[expected_deviation]]\naxis = \"x\"\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("expectations.toml") && out.contains("missing `reason`"), "{out}");
    }

    #[test]
    fn expectations_path_can_be_set_in_the_manifest() {
        let p = Port::new("exp2");
        map_golden(&p, 7);
        std::fs::write(p.dir.join("my_exp.toml"), "[[expected_deviation]]\naxis = \"x\"\nreason = \"mine\"\n").unwrap();
        map_port(&p, "10+n+5", "", "", "expectations = \"my_exp.toml\"", "", "harness.toml");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("expected deviation `x`: mine"), "{out}");
        std::fs::remove_file(p.dir.join("my_exp.toml")).unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}"); // an explicit path must exist
        assert!(out.contains("my_exp.toml"), "{out}");
    }

    #[test]
    fn capture_writes_headed_traces_and_trace_oracle_uses_them() {
        let p = Port::new("cap");
        map_golden(&p, 7);
        map_port(&p, "(10+n)*4", "scale = 0.25", "", "", "", "harness.toml");
        let out_dir = p.dir.join("captured");
        let mut buf: Vec<u8> = vec![];
        let code = crate::capture::run_capture(
            &crate::capture::CaptureArgs { port: p.dir.clone(), scenarios: vec!["all".into()], out: Some(out_dir.clone()), ..Default::default() },
            &mut buf,
        );
        let o = String::from_utf8(buf).unwrap();
        assert_eq!(code, 0, "{o}");
        assert!(o.contains("captured alpha: 5 samples, x2 deterministic") && o.contains("CAPTURE OK: 2 scenarios"), "{o}");
        let alpha = std::fs::read_to_string(out_dir.join("alpha.trace")).unwrap();
        assert!(alpha.lines().next().unwrap().starts_with("# captured by gpfdiff capture from "), "{alpha}");
        let body: Vec<&str> = alpha.lines().filter(|l| !l.starts_with("# captured")).collect();
        assert_eq!(body, vec!["# columns: x room", "10 7", "11 7", "12 7", "13 7", "14 7"]);
        // a capture equals the golden (modulo comments/header)
        let g = std::fs::read_to_string(p.dir.join("recipe/golden/alpha.trace")).unwrap();
        assert_eq!(body, g.lines().collect::<Vec<_>>());
        // --scenario selects; an unknown name is an environment error
        let mut buf: Vec<u8> = vec![];
        let code = crate::capture::run_capture(
            &crate::capture::CaptureArgs { port: p.dir.clone(), scenarios: vec!["zz".into()], out: Some(out_dir.clone()), ..Default::default() },
            &mut buf,
        );
        assert_eq!(code, 2, "{}", String::from_utf8_lossy(&buf));
        assert!(String::from_utf8_lossy(&buf).contains("no scenario `zz`") && String::from_utf8_lossy(&buf).contains("--scenario"));
        // golden dir emptied, oracle = the captured traces: still PASS; a corrupted capture FAILs and names the file
        std::fs::remove_dir_all(p.dir.join("recipe/golden")).unwrap();
        map_port(&p, "(10+n)*4", "scale = 0.25", "", "", "[oracle]\nsource = \"trace\"\ndir = \"captured\"", "harness.toml");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("oracle: captured traces in "), "{out}");
        std::fs::write(out_dir.join("alpha.trace"), alpha.replace("12 7", "12 8")).unwrap();
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("field room: expected 8 got 7") && out.contains("oracle: captured trace ") && out.contains("alpha.trace"), "{out}");
        // a missing capture is exit 2
        std::fs::remove_file(out_dir.join("beta.trace")).unwrap();
        let (code, out) = p.run(|a| a.only = vec!["beta".into()]);
        assert_eq!(code, 2, "{out}");
    }

    #[test]
    fn capture_refuses_a_non_deterministic_scenario_with_exit_2() {
        let p = Port::new("capnd");
        map_golden(&p, 7);
        map_port(&p, "10+n+(RANDOM%40)", "", "", "", "", "harness.toml");
        let out_dir = p.dir.join("captured");
        let mut buf: Vec<u8> = vec![];
        let code = crate::capture::run_capture(&crate::capture::CaptureArgs { port: p.dir.clone(), out: Some(out_dir.clone()), ..Default::default() }, &mut buf);
        let o = String::from_utf8(buf).unwrap();
        assert_eq!(code, 2, "{o}"); // a recording that differs from itself is a harness/environment problem
        assert!(o.contains("NON-DETERMINISTIC") && o.contains("not written") && o.contains("CAPTURE ERROR") && o.contains("exit 2"), "{o}");
        assert!(!out_dir.join("alpha.trace").exists());
    }

    /// Live oracle: a second port directory is run on the same scenario and the two are diffed.
    fn live_pair(tag: &str, oracle_x: &str, port_x: &str, port_x_extra: &str) -> (Port, Port) {
        let oracle = Port::new(&format!("{tag}_o"));
        map_port(&oracle, oracle_x, "", "", "", "", "harness.toml");
        let port = Port::new(&format!("{tag}_p"));
        map_golden(&port, 99); // the recipe golden must NOT be consulted in live mode
        let tail = format!("[oracle]\nsource = \"live\"\nport = \"{}\"", oracle.dir.display());
        map_port(&port, port_x, port_x_extra, "", "", &tail, "harness.live.toml");
        (oracle, port)
    }

    #[test]
    fn live_oracle_normalises_both_sides_and_names_both_ports() {
        // the oracle runs in "ZX" units, the port in x4 units with scale = 0.25
        let (oracle, port) = live_pair("live", "10+n", "(10+n)*4", "scale = 0.25");
        let (code, out) = port.run(|a| a.manifest = Some("harness.live.toml".into()));
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("oracle: live port ") && out.contains("runs sequential") && out.contains("CHECK PASS: 2/2"), "{out}");
        // the same port without its scale diverges from the live oracle on the first sample
        map_port(&port, "(10+n)*4", "", "", "", &format!("[oracle]\nsource = \"live\"\nport = \"{}\"", oracle.dir.display()), "harness.live.toml");
        let (code, out) = port.run(|a| {
            a.manifest = Some("harness.live.toml".into());
            a.only = vec!["alpha".into()];
        });
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("MISMATCH sample #0 field x: expected 10 got 40"), "{out}");
        assert!(out.contains(&format!("oracle: live port {}", port_name(&oracle.dir))) && out.contains(&format!("port:   {}", port_name(&port.dir))), "{out}");
        // json carries the oracle source
        let (_, js) = port.run(|a| {
            a.manifest = Some("harness.live.toml".into());
            a.json = true;
            a.only = vec!["alpha".into()];
            a.no_canary = true;
        });
        assert!(js.contains("\"oracle\":{\"source\":\"live\",\"detail\":\""), "{js}");
        // plain harness.toml still means the recipe golden (which says x=10.. and room=99: no live run involved)
        map_port(&port, "(10+n)*4", "scale = 0.25", "", "", "", "harness.toml");
        let (code, out) = port.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("field room: expected 99 got 7"), "{out}");
    }

    #[test]
    fn live_oracle_that_is_not_deterministic_is_an_environment_error() {
        let (_o, port) = live_pair("livend", "10+n+(RANDOM%40)", "10+n", "");
        let (code, out) = port.run(|a| a.manifest = Some("harness.live.toml".into()));
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("live oracle") && out.contains("determinism gate") && out.contains("NON-DETERMINISTIC"), "{out}");
        assert!(out.contains("CHECK ERROR"), "{out}");
    }

    #[test]
    fn live_oracle_port_must_exist() {
        let p = Port::new("livemiss");
        map_golden(&p, 7);
        map_port(&p, "10+n", "", "", "", "[oracle]\nsource = \"live\"\nport = \"ports/definitely-not-here\"", "harness.toml");
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("live oracle") && out.contains("definitely-not-here"), "{out}");
    }

    #[test]
    fn port_resolution_walks_up_to_find_a_repo_relative_path() {
        let root = std::env::temp_dir().join(format!("gpfdiff_resolve_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("ports/a")).unwrap();
        std::fs::create_dir_all(root.join("ports/b")).unwrap();
        assert_eq!(resolve_port(&root.join("ports/a"), "ports/b").unwrap(), root.canonicalize().unwrap().join("ports/b"));
        assert_eq!(resolve_port(&root.join("ports/a"), "../b").unwrap(), root.join("ports/a/../b"));
        assert!(resolve_port(&root.join("ports/a"), "ports/zz").unwrap_err().contains("not found relative to"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn label_missing_from_the_symbol_file_is_an_environment_error() {
        let p = Port::new("nolabel");
        map_golden(&p, 7);
        map_port(&p, "10+n", "", "", "", "", "harness.toml");
        std::fs::write(p.dir.join("target/l.sym"), "gpf_state: equ 0x0000F000\ngpf_bricks: equ 0x0000F010\ngpf_input_ret: equ 0x00008071\n").unwrap();
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("field `x`") && out.contains("label `player_x` missing from"), "{out}");
    }

    #[test]
    fn the_oracle_must_have_every_column_the_port_reads() {
        let p = Port::new("cols");
        map_golden(&p, 7);
        map_port(&p, "10+n", "", "", "", "", "harness.toml");
        std::fs::write(p.dir.join("recipe/golden/alpha.trace"), "# columns: x\n10\n11\n12\n13\n14\n").unwrap();
        let (code, out) = p.run(|a| a.only = vec!["alpha".into()]);
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("invalid oracle trace") && out.contains("no column `room`"), "{out}");
    }

    // ---- keys mode (black-box): a fake MAME that plays the plan file the way gpf_keys.lua does ----

    /// A free-running "program": x starts at 100 and moves -1 per frame while Z is held, +1 while X is; it sees the keys
    /// applied at hook `t - 1 - LAT` in frame `t` (LAT = extra latency of the program/emulator). Reads the plan
    /// like the Lua script and prints the same `GPF` lines. Refuses to run with -debug or without -snapshot.
    fn keys_fake(lat: u32, gate_fail: bool) -> String {
        r#"#!/bin/bash
case " $* " in *" -debug "*) echo "GPF ERR keys mode must not use -debug"; exit 1;; esac
case " $* " in *" -snapshot "*) ;; *) echo "GPF ERR no -snapshot"; exit 1;; esac
[ -r "$GPF_PLAN" ] || { echo "GPF ERR no plan"; exit 1; }
LAT=__LAT__
declare -A samp evk
endf=0; watch=0
while read -r tag a rest; do
  case $tag in
    S) samp[$a]=1;;
    E) evk[$a]="$rest";;
    END) endf=$a;;
    W) watch=1;;
  esac
done < "$GPF_PLAN"
if [ __GATEFAIL__ = 1 ]; then echo "GPF GATE_TIMEOUT 25 255 0"; exit 0; fi
echo chatter
echo "GPF READY 3 7"
x=100
declare -A applied
cur=""
for ((t=0; t<=endf; t++)); do
  if [ $t -gt 0 ]; then
    old=$x; f=$((t-1-LAT)); k=""
    [ $f -ge 0 ] && k="${applied[$f]}"
    case " $k " in *" Z "*) x=$((x-1));; esac
    case " $k " in *" X "*) x=$((x+1));; esac
    [ $watch = 1 ] && [ $x != $old ] && echo "GPF C $t 36864 $old $x"
  fi
  [ -n "${samp[$t]}" ] && printf 'GPF F %d %02x\n' $t $x
  if [ -n "${evk[$t]+x}" ]; then cur="${evk[$t]}"; [ "$cur" = "-" ] && cur=""; fi
  applied[$t]="$cur"
done
echo "GPF DONE"
"#
        .replace("__LAT__", &lat.to_string())
        .replace("__GATEFAIL__", if gate_fail { "1" } else { "0" })
    }

    fn keys_port(tag: &str, lat: u32, knob: u32, gate_fail: bool) -> Port {
        let p = Port::new(tag);
        let sh = p.dir.join("fakemame.sh");
        std::fs::write(&sh, keys_fake(lat, gate_fail)).unwrap();
        std::fs::write(p.dir.join("recipe/scenarios/alpha.toml"), "steps = 6\n[[input]]\nstep = 2\nbuttons = 1\n").unwrap();
        std::fs::write(p.dir.join("recipe/golden/alpha.trace"), "# columns: x\n100\n100\n100\n99\n98\n97\n96\n").unwrap();
        std::fs::remove_file(p.dir.join("recipe/scenarios/beta.toml")).unwrap();
        std::fs::remove_file(p.dir.join("recipe/golden/beta.trace")).unwrap();
        std::fs::write(
            p.dir.join("harness.toml"),
            format!(
                "platform = \"zx48\"\nrecipe = \"recipe\"\nrepeat = 2\n[emulator]\nmame = \"{}\"\nrompath = \"{}\"\n[input]\nmode = \"keys\"\n[input.keys]\nLEFT = \"Z\"\nRIGHT = \"X\"\n[time]\ninput_latency_frames = {knob}\n[boot]\nimage = \"target/x.sna\"\nready = {{ addr = 0x9001, eq = 7 }}\ntimeout_ms = 1000\n[state]\nsource = \"map\"\n[[field]]\nname = \"x\"\naddr = 0x9000\n",
                sh.display(),
                p.dir.join("roms").display()
            ),
        )
        .unwrap();
        p
    }

    #[test]
    fn keys_mode_passes_with_the_right_latency_knob_and_fails_without_it() {
        // a program that sees keys on the frame after they are applied: knob 0
        let p = keys_port("keys0", 0, 0, false);
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("CHECK PASS: 1/1 scenarios passed, x2 runs deterministic, canary rejected"), "{out}");
        // a program (or emulator) with one extra frame of input latency: the same manifest now misses by a frame ...
        let p = keys_port("keys1a", 1, 0, false);
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 1, "{out}");
        assert!(out.contains("MISMATCH sample #3 field x: expected 99 got 100"), "{out}");
        // ... and `input_latency_frames = 1` (apply every key one frame earlier) aligns it
        let p = keys_port("keys1b", 1, 1, false);
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 0, "{out}");
        // the knob cannot move an input before the timeline starts: that is an error, not a silent clamp
        std::fs::write(p.dir.join("recipe/scenarios/alpha.toml"), "steps = 6\n[[input]]\nstep = 0\nbuttons = 1\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("earlier than input_latency_frames = 1"), "{out}");
    }

    #[test]
    fn keys_mode_capture_equals_the_golden_and_a_gate_timeout_is_exit_2() {
        let p = keys_port("keyscap", 0, 0, false);
        let out_dir = p.dir.join("captured");
        let mut buf: Vec<u8> = vec![];
        let code = crate::capture::run_capture(&crate::capture::CaptureArgs { port: p.dir.clone(), out: Some(out_dir.clone()), ..Default::default() }, &mut buf);
        assert_eq!(code, 0, "{}", String::from_utf8_lossy(&buf));
        let cap = std::fs::read_to_string(out_dir.join("alpha.trace")).unwrap();
        let body: Vec<&str> = cap.lines().filter(|l| !l.starts_with("# captured")).collect();
        assert_eq!(body, std::fs::read_to_string(p.dir.join("recipe/golden/alpha.trace")).unwrap().lines().collect::<Vec<_>>());
        // a ready gate that never holds: exit 2, the message names the gate and the last observed value
        let p = keys_port("keysgate", 0, 0, true);
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("timed out waiting for the ready gate") && out.contains("1 byte at $9001 == 7") && out.contains("last observed value 255"), "{out}");
        assert!(out.contains("watch <port> --no-gate"), "{out}");
        let (code, js) = p.run(|a| a.json = true);
        assert_eq!(code, 2, "{js}");
        assert!(js.contains("\"kind\":\"ready_gate\""), "{js}");
        // and capture agrees
        let mut buf: Vec<u8> = vec![];
        let code = crate::capture::run_capture(&crate::capture::CaptureArgs { port: p.dir.clone(), out: Some(out_dir), ..Default::default() }, &mut buf);
        assert_eq!(code, 2, "{}", String::from_utf8_lossy(&buf));
    }

    #[test]
    fn an_unknown_key_name_is_a_config_error_listing_the_valid_names() {
        let p = keys_port("keysbad", 0, 0, false);
        let h = std::fs::read_to_string(p.dir.join("harness.toml")).unwrap();
        std::fs::write(p.dir.join("harness.toml"), h.replace("LEFT = \"Z\"", "LEFT = \"CURSORLEFT\"")).unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("unknown key name `CURSORLEFT`") && out.contains("valid names: A-Z, 0-9, SPACE, ENTER, CAPSSHIFT, SYMSHIFT"), "{out}");
        // a scenario pressing a button with no key says how to fix it
        std::fs::write(p.dir.join("harness.toml"), h).unwrap();
        std::fs::write(p.dir.join("recipe/scenarios/alpha.toml"), "steps = 6\n[[input]]\nstep = 2\nbuttons = 4\n").unwrap();
        let (code, out) = p.run(|_| {});
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("button FIRE has no key") && out.contains("[input.keys]"), "{out}");
    }

    #[test]
    fn keys_mode_works_as_a_live_oracle_for_a_cooperative_port() {
        // the oracle: a black-box keys-mode port (x starts at 10, nothing pressed; room = 7); the port under test: cooperative,
        // its fake MAME serves x = 10 (xexpr) and room = 7 through RAM reads. Both normalise through their own maps.
        let oracle = keys_port("liveb_o", 0, 0, false);
        let sh = oracle.dir.join("fakemame.sh");
        std::fs::write(&sh, keys_fake(0, false).replace("x=100", "x=10").replace("%02x\\n' $t $x", "%02x07\\n' $t $x")).unwrap();
        let h = std::fs::read_to_string(oracle.dir.join("harness.toml")).unwrap();
        std::fs::write(oracle.dir.join("harness.toml"), format!("{h}[[field]]\nname = \"room\"\naddr = 0x9001\n")).unwrap();
        let port = Port::new("liveb_p");
        std::fs::remove_file(port.dir.join("recipe/scenarios/beta.toml")).unwrap();
        std::fs::remove_file(port.dir.join("recipe/golden/beta.trace")).unwrap();
        std::fs::write(port.dir.join("recipe/scenarios/alpha.toml"), "steps = 4\n").unwrap(); // scenarios come from the checked port
        let tail = format!("[oracle]\nsource = \"live\"\nport = \"{}\"", oracle.dir.display());
        map_port(&port, "10", "", "", "", &tail, "harness.live.toml");
        // the port's fake reports x = 10 constantly (xexpr "10"), the keys-mode oracle holds 10 with no key pressed
        let (code, out) = port.run(|a| a.manifest = Some("harness.live.toml".into()));
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("oracle: live port ") && out.contains("CHECK PASS: 1/1"), "{out}");
    }

    #[test]
    fn watch_prints_the_moved_address_by_frame_and_needs_a_keys_manifest() {
        let p = keys_port("watch", 0, 0, false);
        let args = |p: &Port| crate::watch::WatchArgs {
            port: p.dir.clone(),
            keys: Some("LEFT@40ms+100ms".into()),
            frames: Some(8),
            region: Some("0x9000:0x9001".into()),
            ..Default::default()
        };
        let mut buf: Vec<u8> = vec![];
        let code = crate::watch::run_watch(&args(&p), &mut buf);
        let out = String::from_utf8(buf).unwrap();
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("region 0x9000..0x9001, 8 frames = 160 ms at 50 fps") && out.contains("gate: 1 byte at $9001 == 7"), "{out}");
        assert!(out.contains("timeline starts at boot frame 3 (the gate saw value 7)"), "{out}");
        // LEFT pressed at frame 2 (40 ms), seen by the program in frames 3..7: one burst, x 100 -> 95
        let line = out.lines().find(|l| l.contains("0x9000") && l.contains("->")).expect("the changed address is listed");
        assert!(line.contains("3..7") && line.contains("60..140") && line.contains("64 -> 5f") && line.contains("x5 frames"), "{out}");
        assert!(out.contains("5 byte changes at 1 addresses in 5 frames"), "{out}");
        // a cooperative manifest cannot be watched
        std::fs::write(p.dir.join("harness.coop.toml"), "platform = \"zx48\"\nimage = \"a\"\nlabels = \"b\"\nrecipe = \"recipe\"\n").unwrap();
        let mut buf: Vec<u8> = vec![];
        let mut a = args(&p);
        a.manifest = Some("harness.coop.toml".into());
        assert_eq!(crate::watch::run_watch(&a, &mut buf), 2);
        assert!(String::from_utf8_lossy(&buf).contains("watch needs `[input] mode = \"keys\"`"), "{}", String::from_utf8_lossy(&buf));
        // a bad --keys or --region is an environment/usage error, exit 2
        for (k, r, want) in [("LEFT", "0x9000:0x9001", "invalid --keys"), ("LEFT@1ms", "9000", "invalid --region"), ("NOPE@1ms", "0x9000:0x9001", "unknown key name `NOPE`")] {
            let mut a = args(&p);
            a.keys = Some(k.into());
            a.region = Some(r.into());
            let mut buf: Vec<u8> = vec![];
            assert_eq!(crate::watch::run_watch(&a, &mut buf), 2, "{k} {r}");
            assert!(String::from_utf8_lossy(&buf).contains(want), "{want}: {}", String::from_utf8_lossy(&buf));
        }
    }
}
