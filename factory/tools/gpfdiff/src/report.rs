//! Everything `gpfdiff check` prints: colour, the results table, diff context and the
//! machine-readable JSON (schema documented in README.md, "check --json").

use crate::diff::Mismatch;
use crate::errors::{self, Kind};
use crate::expect::{FieldVerdict, Stale, Verdict};
use crate::runner::{FailInfo, FailKind};
use crate::trace::Trace;
use std::io::IsTerminal;

// ------------------------------------------------------------------ colour

#[derive(Clone, Copy, Debug)]
pub struct Style {
    pub color: bool,
}

impl Style {
    /// Colour only when stdout is a terminal and NO_COLOR is unset (or empty).
    pub fn detect() -> Style {
        Style::from_env(std::io::stdout().is_terminal(), std::env::var_os("NO_COLOR").as_deref())
    }
    pub fn from_env(is_tty: bool, no_color: Option<&std::ffi::OsStr>) -> Style {
        Style { color: is_tty && no_color.map_or(true, |v| v.is_empty()) }
    }
    fn paint(&self, code: &str, s: &str) -> String {
        if self.color {
            format!("\x1b[{code}m{s}\x1b[0m")
        } else {
            s.to_string()
        }
    }
    pub fn green(&self, s: &str) -> String {
        self.paint("32", s)
    }
    pub fn red(&self, s: &str) -> String {
        self.paint("31", s)
    }
    pub fn yellow(&self, s: &str) -> String {
        self.paint("33", s)
    }
    pub fn bold(&self, s: &str) -> String {
        self.paint("1", s)
    }
}

// ------------------------------------------------------------------ data

#[derive(Clone, Debug)]
pub enum Outcome {
    Pass,
    /// Differences exist, every one of them declared in expectations.toml (exit 0).
    Expected,
    Fail(FailInfo),
    Error { kind: Kind, message: String },
}

impl Outcome {
    pub fn label(&self) -> &'static str {
        match self {
            Outcome::Pass => "PASS",
            Outcome::Expected => "EXPECTED",
            Outcome::Fail(_) => "FAIL",
            Outcome::Error { .. } => "ERROR",
        }
    }
}

#[derive(Clone, Debug)]
pub struct ScenarioReport {
    pub name: String,
    pub steps: Option<u32>,
    pub samples: Option<usize>,
    pub runs: usize,
    pub secs: f64,
    pub outcome: Outcome,
    /// The differing fields (expected or fail) with their verdicts; empty for pass and error.
    pub fields: Vec<FieldVerdict>,
}

#[derive(Clone, Debug)]
pub struct CanaryReport {
    /// Was it executed at all (false: no scenario passed, nothing to mutate)?
    pub ran: bool,
    /// The harness rejected the mutated golden (what we want).
    pub rejected: bool,
    pub detail: String,
}

#[derive(Clone, Debug)]
pub struct CheckReport {
    pub port: String,
    pub platform: String,
    pub repeat: u32,
    pub scenarios: Vec<ScenarioReport>,
    pub canary: Option<CanaryReport>,
    /// Set when the run could not start at all (missing tool, bad manifest ...).
    pub environment_error: Option<(Kind, String)>,
    pub secs: f64,
    /// expectations.toml entries that never triggered (warnings, never fatal).
    pub stale: Vec<Stale>,
    /// (source, detail) of the oracle: `("recipe", "<recipe>/golden")`, `("trace", dir)`, `("live", port)`.
    pub oracle: Option<(String, String)>,
}

impl CheckReport {
    pub fn expected_count(&self) -> usize {
        self.scenarios.iter().filter(|s| matches!(s.outcome, Outcome::Expected)).count()
    }

    pub fn counts(&self) -> (usize, usize, usize) {
        let n = |f: fn(&Outcome) -> bool| self.scenarios.iter().filter(|s| f(&s.outcome)).count();
        (n(|o| matches!(o, Outcome::Pass)), n(|o| matches!(o, Outcome::Fail(_))), n(|o| matches!(o, Outcome::Error { .. })))
    }

    /// A canary that ran and was NOT rejected means the harness cannot fail: harness error.
    pub fn canary_broken(&self) -> bool {
        self.canary.as_ref().map_or(false, |c| c.ran && !c.rejected)
    }

    pub fn exit_code(&self) -> u8 {
        let (_, failed, errors) = self.counts();
        let env = errors + usize::from(self.canary_broken()) + usize::from(self.environment_error.is_some());
        errors::exit_code(failed, env)
    }

    pub fn verdict(&self) -> &'static str {
        match self.exit_code() {
            errors::EXIT_PASS if self.expected_count() > 0 => "expected",
            errors::EXIT_PASS => "pass",
            errors::EXIT_FAIL => "fail",
            _ => "error",
        }
    }

    /// The one-line summary that ends the run.
    pub fn summary_line(&self, st: &Style) -> String {
        let (p, f, e) = self.counts();
        let total = self.scenarios.len();
        let canary = match &self.canary {
            None => "canary skipped".to_string(),
            Some(c) if !c.ran => "canary not run".to_string(),
            Some(c) if c.rejected => "canary rejected".to_string(),
            Some(_) => "CANARY NOT REJECTED".to_string(),
        };
        let det = if self.repeat > 1 { format!(", x{} runs deterministic", self.repeat) } else { String::new() };
        let x = self.expected_count();
        let xs = if x > 0 { format!(", {x} expected") } else { String::new() };
        let stale = if self.stale.is_empty() { String::new() } else { format!(", {} STALE expectation{}", self.stale.len(), if self.stale.len() == 1 { "" } else { "s" }) };
        match self.exit_code() {
            errors::EXIT_PASS if x > 0 => st.green(&format!("CHECK EXPECTED: {p} passed, {x} with expected deviations of {total} scenarios{det}, {canary}{stale}, {:.1}s", self.secs)),
            errors::EXIT_PASS => st.green(&format!("CHECK PASS: {p}/{total} scenarios passed{det}, {canary}{stale}, {:.1}s", self.secs)),
            errors::EXIT_FAIL => st.red(&format!("CHECK FAIL: {f} of {total} scenarios failed ({p} passed{xs}), {canary}{stale}, {:.1}s", self.secs)),
            _ => st.yellow(&format!(
                "CHECK ERROR (exit 2, harness/environment, not a game failure): {p} passed, {f} failed, {e} errored of {total}{xs}, {canary}{stale}, {:.1}s",
                self.secs
            )),
        }
    }
}

// ------------------------------------------------------------------ table

pub fn name_width(names: impl Iterator<Item = usize>) -> usize {
    names.max().unwrap_or(0).max("scenario".len())
}

/// `rw` = width of the result column: 6 normally, 8 when expectations are in play ("EXPECTED").
pub fn table_header_w(w: usize, rw: usize) -> String {
    format!(
        "{:<w$}  {:>6}  {:>7}  {:<rw$}  {:>6}\n{:-<w$}  {:-<6}  {:-<7}  {:-<rw$}  {:-<6}",
        "scenario", "steps", "samples", "result", "secs", "", "", "", "", "",
        w = w,
        rw = rw
    )
}

pub fn table_row_w(r: &ScenarioReport, w: usize, rw: usize, st: &Style) -> String {
    let num = |o: Option<String>| o.unwrap_or_else(|| "-".into());
    let label = format!("{:<rw$}", r.outcome.label(), rw = rw);
    let label = match r.outcome {
        Outcome::Pass => st.green(&label),
        Outcome::Expected => st.yellow(&label),
        Outcome::Fail(_) => st.red(&label),
        Outcome::Error { .. } => st.yellow(&label),
    };
    format!(
        "{:<w$}  {:>6}  {:>7}  {}  {:>6.1}",
        r.name,
        num(r.steps.map(|v| v.to_string())),
        num(r.samples.map(|v| v.to_string())),
        label,
        r.secs,
        w = w
    )
}

/// Indented details printed under a failing/erroring row.
pub fn details(r: &ScenarioReport, platform: &str, debug: bool) -> String {
    let ind = |s: &str| s.lines().map(|l| format!("    {l}")).collect::<Vec<_>>().join("\n");
    let expected_lines = || -> Vec<String> {
        r.fields
            .iter()
            .filter(|f| f.verdict == Verdict::Expected)
            .map(|f| {
                let until = f.until.as_ref().map_or(String::new(), |u| format!(" [until {u}]"));
                ind(&format!(
                    "{}: expected deviation `{}`: {}{until} ({} sample{} differ; first {})",
                    r.name,
                    f.field,
                    f.reason.as_deref().unwrap_or(""),
                    f.count,
                    if f.count == 1 { "" } else { "s" },
                    f.first
                ))
            })
            .collect()
    };
    match &r.outcome {
        Outcome::Pass => String::new(),
        Outcome::Expected => expected_lines().join("\n"),
        Outcome::Fail(f) => {
            let mut s = ind(&format!("{}: {}", r.name, f.headline()));
            s.push('\n');
            s.push_str(&ind(&f.context));
            for l in expected_lines() {
                s.push('\n');
                s.push_str(&l);
            }
            s
        }
        Outcome::Error { message, .. } => ind(&format!("{}: {}", r.name, errors::render(message, platform, debug))),
    }
}

// ------------------------------------------------------------------ diff context

/// +-`ctx` sample lines around a mismatch. `-` = expected, `+` = got; a caret marks the
/// differing field.
pub fn render_context(exp: &Trace, got: &Trace, m: &Mismatch, ctx: usize) -> String {
    let lo = m.index.saturating_sub(ctx);
    let hi = m.index + ctx;
    let fld = exp.col(&m.field);
    let mut out = vec![];
    let fmt = |mark: char, i: usize, text: &str| format!("{mark} #{i:<4} {text}");
    for i in lo..=hi {
        if i == m.index {
            let e = exp.lines.get(i).map_or("<end of trace>".to_string(), |l| l.to_string());
            let g = got.lines.get(i).map_or("<end of trace>".to_string(), |l| l.to_string());
            out.push(fmt('-', i, &e));
            out.push(fmt('+', i, &g));
            if let (Some(c), Some(l)) = (fld, got.lines.get(i)) {
                let off: usize = l.cols[..c].iter().map(|s| s.len() + 1).sum();
                let w = l.cols[c].len().max(1);
                out.push(format!("{}{}{}", " ".repeat(8), " ".repeat(off), "^".repeat(w)));
            }
        } else if let Some(l) = exp.lines.get(i) {
            // identical in both traces up to the mismatch; after it, show the expected side
            out.push(fmt(' ', i, &l.to_string()));
        }
    }
    let cols = exp.columns.join(" ");
    let which = match fld {
        Some(c) => format!("differing field: {} (column {} of {})", m.field, c + 1, exp.columns.len()),
        None => format!("differing: {} (trace length)", m.field),
    };
    out.push(which);
    if let Some(t) = &m.tolerance {
        out.push(format!("tolerance: field {} allows +-{t} (normalised units); this difference is beyond it", m.field));
    }
    out.push(format!("columns: {cols}"));
    out.join("\n")
}

// ------------------------------------------------------------------ JSON

pub fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn opt<T>(v: &Option<T>, f: impl Fn(&T) -> String) -> String {
    v.as_ref().map_or("null".into(), f)
}

fn json_tol(t: &Option<String>) -> String {
    opt(t, |v| v.clone())
}

fn json_mismatch_tail(m: &Mismatch, with_field: bool) -> String {
    format!(
        "\"sample\":{},\"step\":{},{}\"expected\":{},\"got\":{},\"tolerance\":{}",
        m.index,
        opt(&m.step, |v| v.to_string()),
        if with_field { format!("\"field\":{},", json_str(&m.field)) } else { String::new() },
        json_str(&m.expected),
        json_str(&m.got),
        json_tol(&m.tolerance)
    )
}

fn json_opt_str(v: &Option<String>) -> String {
    opt(v, |s| json_str(s))
}

fn json_field(f: &FieldVerdict) -> String {
    format!(
        "{{\"field\":{},\"verdict\":{},\"count\":{},{},\"reason\":{},\"until\":{}}}",
        json_str(&f.field),
        json_str(f.verdict.as_str()),
        f.count,
        json_mismatch_tail(&f.first, false),
        json_opt_str(&f.reason),
        json_opt_str(&f.until)
    )
}

/// Schema version 2 (version 1 plus: `result` may be `expected`, `scenarios[].fields`,
/// `diff.tolerance`, `summary.expected`/`stale`, and the trailing `expected`, `stale`,
/// `oracle`). Field order and names are the contract; see README.md.
pub fn to_json(r: &CheckReport) -> String {
    let (p, f, e) = r.counts();
    let scen: Vec<String> = r
        .scenarios
        .iter()
        .map(|s| {
            let (result, diff, error) = match &s.outcome {
                Outcome::Pass => ("pass", "null".to_string(), "null".to_string()),
                Outcome::Expected => ("expected", "null".to_string(), "null".to_string()),
                Outcome::Fail(fi) => (
                    "fail",
                    format!(
                        "{{\"kind\":{},\"run\":{},\"of\":{},{}}}",
                        json_str(match fi.kind {
                            FailKind::Mismatch => "mismatch",
                            FailKind::NonDeterministic => "nondeterministic",
                        }),
                        fi.run,
                        fi.of,
                        json_mismatch_tail(&fi.mismatch, true)
                    ),
                    "null".to_string(),
                ),
                Outcome::Error { kind, message } => (
                    "error",
                    "null".to_string(),
                    format!("{{\"kind\":{},\"message\":{}}}", json_str(kind.as_str()), json_str(message)),
                ),
            };
            format!(
                "{{\"name\":{},\"steps\":{},\"samples\":{},\"runs\":{},\"result\":{},\"secs\":{:.3},\"diff\":{},\"error\":{},\"fields\":[{}]}}",
                json_str(&s.name),
                opt(&s.steps, |v| v.to_string()),
                opt(&s.samples, |v| v.to_string()),
                s.runs,
                json_str(result),
                s.secs,
                diff,
                error,
                s.fields.iter().map(json_field).collect::<Vec<_>>().join(",")
            )
        })
        .collect();
    let canary = opt(&r.canary, |c| {
        format!("{{\"ran\":{},\"rejected\":{},\"detail\":{}}}", c.ran, c.rejected, json_str(&c.detail))
    });
    let envv = opt(&r.environment_error, |(k, m)| format!("{{\"kind\":{},\"message\":{}}}", json_str(k.as_str()), json_str(m)));
    let expected: Vec<String> = r
        .scenarios
        .iter()
        .flat_map(|s| {
            s.fields.iter().filter(|f| f.verdict == Verdict::Expected).map(move |f| {
                format!(
                    "{{\"scenario\":{},\"field\":{},\"reason\":{},\"until\":{},\"count\":{}}}",
                    json_str(&s.name),
                    json_str(&f.field),
                    json_opt_str(&f.reason),
                    json_opt_str(&f.until),
                    f.count
                )
            })
        })
        .collect();
    let stale: Vec<String> = r
        .stale
        .iter()
        .map(|d| {
            format!(
                "{{\"axis\":{},\"scenarios\":[{}],\"reason\":{},\"until\":{},\"why\":{}}}",
                json_str(&d.axis),
                d.scenarios.iter().map(|x| json_str(x)).collect::<Vec<_>>().join(","),
                json_str(&d.reason),
                json_opt_str(&d.until),
                json_str(&d.why)
            )
        })
        .collect();
    let oracle = opt(&r.oracle, |(src, d)| format!("{{\"source\":{},\"detail\":{}}}", json_str(src), json_str(d)));
    format!(
        "{{\"schema\":2,\"port\":{},\"platform\":{},\"repeat\":{},\"environment_error\":{},\"scenarios\":[{}],\"canary\":{},\"summary\":{{\"total\":{},\"passed\":{p},\"failed\":{f},\"errors\":{e},\"secs\":{:.3},\"verdict\":{},\"expected\":{},\"stale\":{}}},\"exit_code\":{},\"expected\":[{}],\"stale\":[{}],\"oracle\":{}}}",
        json_str(&r.port),
        json_str(&r.platform),
        r.repeat,
        envv,
        scen.join(","),
        canary,
        r.scenarios.len(),
        r.secs,
        json_str(r.verdict()),
        r.expected_count(),
        r.stale.len(),
        r.exit_code(),
        expected.join(","),
        stale.join(","),
        oracle
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::compare_runs;
    use crate::trace::parse_trace;

    const G: &str = "0 0 3 0 112 0 32256 44032 0 0 ffffffffff\n\
                     5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff\n\
                     10 1 3 0 108 0 30080 40576 -128 -384 ffffffffff\n\
                     15 1 3 0 108 0 29440 38656 -128 -384 ffffffffff\n\
                     20 1 3 0 108 0 28800 36736 -128 -384 ffffffffff\n";

    fn failing() -> FailInfo {
        let got = parse_trace(G).unwrap();
        let gold = parse_trace(&G.replace("30080 40576 -128", "30080 40576 1")).unwrap();
        compare_runs(&gold, &[got], 20).unwrap_err()
    }

    fn rep(outcomes: Vec<Outcome>, canary: Option<CanaryReport>) -> CheckReport {
        CheckReport {
            port: "p".into(),
            platform: "c64".into(),
            repeat: 2,
            scenarios: outcomes
                .into_iter()
                .enumerate()
                .map(|(i, o)| ScenarioReport { name: format!("s{i}"), steps: Some(20), samples: Some(5), runs: 2, secs: 1.25, outcome: o, fields: vec![] })
                .collect(),
            canary,
            environment_error: None,
            secs: 2.5,
            stale: vec![],
            oracle: None,
        }
    }

    fn ok_canary() -> Option<CanaryReport> {
        Some(CanaryReport { ran: true, rejected: true, detail: "d".into() })
    }

    #[test]
    fn colour_only_on_tty_without_no_color() {
        use std::ffi::OsStr;
        assert!(Style::from_env(true, None).color);
        assert!(!Style::from_env(false, None).color);
        assert!(!Style::from_env(true, Some(OsStr::new("1"))).color);
        assert!(Style::from_env(true, Some(OsStr::new(""))).color); // empty NO_COLOR counts as unset
        assert_eq!(Style { color: false }.green("x"), "x");
        assert_eq!(Style { color: true }.green("x"), "\x1b[32mx\x1b[0m");
    }

    #[test]
    fn table_rows_align() {
        let st = Style { color: false };
        let w = name_width([10usize].into_iter());
        let r = ScenarioReport { name: "launch_left".into(), steps: Some(300), samples: Some(61), runs: 2, secs: 12.34, outcome: Outcome::Pass, fields: vec![] };
        let h = table_header_w(w, 6);
        assert!(h.starts_with("scenario    "), "{h}");
        let row = table_row_w(&r, 11, 6, &st);
        assert_eq!(row, "launch_left     300       61  PASS      12.3");
        let r2 = ScenarioReport { steps: None, samples: None, outcome: Outcome::Error { kind: Kind::Timeout, message: "x".into() }, ..r };
        assert!(table_row_w(&r2, 11, 6, &st).contains("-  ERROR"));
    }

    #[test]
    fn context_marks_the_differing_line_and_field() {
        let f = failing();
        assert_eq!(f.mismatch.field, "ball_vx");
        let c = &f.context;
        // +-2 lines around sample #2: samples 0..=4 all shown, - / + pair at #2
        assert!(c.contains("  #0   ") || c.contains("  #0 "), "{c}");
        assert!(c.contains("- #2    10 1 3 0 108 0 30080 40576 1 -384 ffffffffff"), "{c}");
        assert!(c.contains("+ #2    10 1 3 0 108 0 30080 40576 -128 -384 ffffffffff"), "{c}");
        assert!(c.contains("differing field: ball_vx (column 9 of 11)"), "{c}");
        // caret sits under the 9th column of the "+" line
        let plus = c.lines().find(|l| l.starts_with("+ #2")).unwrap();
        let caret = c.lines().find(|l| l.trim_start().starts_with('^')).unwrap();
        assert_eq!(caret.find('^').unwrap(), plus.find("-128").unwrap(), "{c}");
        assert!(c.contains("  #4 "), "{c}");
        assert!(!c.contains("#5"), "{c}");
    }

    #[test]
    fn context_at_trace_end() {
        let exp = parse_trace(G).unwrap();
        let short = Trace { columns: exp.columns.clone(), lines: exp.lines[..2].to_vec() };
        let m = crate::diff::first_diff(&exp, &short).unwrap();
        let c = render_context(&exp, &short, &m, 2);
        assert!(c.contains("+ #2    <end of trace>"), "{c}");
        assert!(c.contains("differing: <line> (trace length)"), "{c}");
    }

    #[test]
    fn json_escaping() {
        assert_eq!(json_str("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
    }

    #[test]
    fn json_schema_pass_fail_error() {
        let r = rep(
            vec![
                Outcome::Pass,
                Outcome::Fail(failing()),
                Outcome::Error { kind: Kind::Timeout, message: "timed out \"x\"".into() },
            ],
            ok_canary(),
        );
        let j = to_json(&r);
        assert!(j.starts_with("{\"schema\":2,\"port\":\"p\",\"platform\":\"c64\",\"repeat\":2,"), "{j}");
        assert!(j.contains("\"result\":\"pass\""), "{j}");
        assert!(j.contains("\"diff\":{\"kind\":\"mismatch\",\"run\":1,\"of\":1,\"sample\":2,\"step\":10,\"field\":\"ball_vx\",\"expected\":\"1\",\"got\":\"-128\",\"tolerance\":null}"), "{j}");
        assert!(j.contains("\"error\":{\"kind\":\"timeout\",\"message\":\"timed out \\\"x\\\"\"}"), "{j}");
        assert!(j.contains("\"canary\":{\"ran\":true,\"rejected\":true,\"detail\":\"d\"}"), "{j}");
        assert!(j.contains("\"summary\":{\"total\":3,\"passed\":1,\"failed\":1,\"errors\":1,\"secs\":2.500,\"verdict\":\"error\",\"expected\":0,\"stale\":0},\"exit_code\":2,"), "{j}");
        // balanced braces/brackets outside strings: cheap structural sanity
        let (mut depth, mut in_s, mut esc) = (0i32, false, false);
        for c in j.chars() {
            if in_s {
                match (esc, c) {
                    (true, _) => esc = false,
                    (false, '\\') => esc = true,
                    (false, '"') => in_s = false,
                    _ => {}
                }
            } else {
                match c {
                    '"' => in_s = true,
                    '{' | '[' => depth += 1,
                    '}' | ']' => depth -= 1,
                    _ => {}
                }
            }
        }
        assert_eq!(depth, 0, "{j}");
    }

    #[test]
    fn json_null_canary_and_env_error() {
        let mut r = rep(vec![], None);
        r.environment_error = Some((Kind::EmulatorMissing, "cannot start `x`".into()));
        let j = to_json(&r);
        assert!(j.contains("\"canary\":null") && j.contains("\"environment_error\":{\"kind\":\"emulator_missing\""), "{j}");
        assert!(j.contains("\"exit_code\":2"), "{j}");
    }

    #[test]
    fn exit_codes_and_summary() {
        let pass = rep(vec![Outcome::Pass, Outcome::Pass], ok_canary());
        assert_eq!(pass.exit_code(), 0);
        assert!(pass.summary_line(&Style { color: false }).starts_with("CHECK PASS: 2/2 scenarios passed, x2 runs deterministic, canary rejected"));
        let fail = rep(vec![Outcome::Pass, Outcome::Fail(failing())], ok_canary());
        assert_eq!(fail.exit_code(), 1);
        assert!(fail.summary_line(&Style { color: false }).starts_with("CHECK FAIL: 1 of 2"));
        let err = rep(vec![Outcome::Pass, Outcome::Error { kind: Kind::Desync, message: "d".into() }], ok_canary());
        assert_eq!(err.exit_code(), 2);
        // a canary that is not rejected = a harness that cannot fail = exit 2, even if all pass
        let broken = rep(vec![Outcome::Pass], Some(CanaryReport { ran: true, rejected: false, detail: "x".into() }));
        assert_eq!(broken.exit_code(), 2);
        assert!(broken.summary_line(&Style { color: false }).contains("CANARY NOT REJECTED"));
        // canary skipped by --no-canary does not matter
        assert_eq!(rep(vec![Outcome::Pass], None).exit_code(), 0);
    }

    #[test]
    fn details_for_fail_and_error() {
        let st_r = rep(vec![Outcome::Fail(failing()), Outcome::Error { kind: Kind::Timeout, message: "cannot start `mame`: not found on PATH".into() }], None);
        let d0 = details(&st_r.scenarios[0], "c64", false);
        assert!(d0.contains("s0: run 1/1: MISMATCH step 10"), "{d0}");
        assert!(d0.contains("differing field: ball_vx"), "{d0}");
        let d1 = details(&st_r.scenarios[1], "zx48", false);
        assert!(d1.contains("likely cause:") && d1.contains("gpfdiff doctor --platform zx48"), "{d1}");
    }
}
