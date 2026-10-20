//! `expectations.toml`: named, visible, reasoned deviations of a port from its oracle.
//!
//! ```toml
//! [[expected_deviation]]
//! axis      = "ball_x"                  # a field (column) name
//! scenarios = ["wall_bounces"]          # optional; default = every scenario
//! reason    = "CoCo PMODE4 has no sub-pixel ball"
//! until     = "T0123"                   # optional task id, informational
//! ```
//!
//! Verdicts per field and per scenario: PASS (no difference beyond tolerance), EXPECTED (every
//! differing field matches a deviation), FAIL (some differing field does not, or the trace length
//! or determinism is wrong). FAIL always beats EXPECTED. A deviation that never triggered in the
//! run is STALE: a warning, never an error.

use crate::diff::{Diffs, Mismatch};
use crate::manifest::{parse_string, parse_string_array, strip_comment};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Deviation {
    pub axis: String,
    pub scenarios: Vec<String>,
    pub reason: String,
    pub until: Option<String>,
}

impl Deviation {
    pub fn applies_to(&self, scenario: &str) -> bool {
        self.scenarios.is_empty() || self.scenarios.iter().any(|s| s == scenario)
    }
}

pub fn parse(text: &str) -> Result<Vec<Deviation>, String> {
    let mut out: Vec<Deviation> = vec![];
    let mut cur: Option<(usize, Option<String>, Vec<String>, Option<String>, Option<String>)> = None;
    fn flush(cur: &mut Option<(usize, Option<String>, Vec<String>, Option<String>, Option<String>)>, out: &mut Vec<Deviation>) -> Result<(), String> {
        if let Some((n, axis, scenarios, reason, until)) = cur.take() {
            let at = |e: &str| format!("line {n}: [[expected_deviation]] {e}");
            out.push(Deviation {
                axis: axis.ok_or_else(|| at("is missing `axis`"))?,
                scenarios,
                reason: reason.ok_or_else(|| at("is missing `reason` (a deviation without a reason is a silent one)"))?,
                until,
            });
        }
        Ok(())
    }
    for (n, raw) in text.lines().enumerate() {
        let at = |e: String| format!("line {}: {e}", n + 1);
        let line = strip_comment(raw).trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && !line.contains('=') {
            if line != "[[expected_deviation]]" {
                return Err(at(format!("unknown table `{line}` (only [[expected_deviation]] exists)")));
            }
            flush(&mut cur, &mut out)?;
            cur = Some((n + 1, None, vec![], None, None));
            continue;
        }
        let (k, v) = line.split_once('=').ok_or_else(|| at(format!("expected `key = value`: {raw}")))?;
        let c = cur.as_mut().ok_or_else(|| at("key outside an [[expected_deviation]] table".into()))?;
        match k.trim() {
            "axis" => c.1 = Some(parse_string(v).map_err(at)?),
            "scenarios" => c.2 = parse_string_array(v).map_err(at)?,
            "reason" => c.3 = Some(parse_string(v).map_err(at)?),
            "until" => c.4 = Some(parse_string(v).map_err(at)?),
            other => return Err(at(format!("unknown key `{other}` (axis, scenarios, reason, until)"))),
        }
    }
    flush(&mut cur, &mut out)?;
    Ok(out)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Pass,
    Expected,
    Fail,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Pass => "pass",
            Verdict::Expected => "expected",
            Verdict::Fail => "fail",
        }
    }
}

/// One differing field of one scenario and what was decided about it.
#[derive(Clone, Debug)]
pub struct FieldVerdict {
    pub field: String,
    pub verdict: Verdict, // Expected or Fail
    pub reason: Option<String>,
    pub until: Option<String>,
    /// Number of differing samples, and the first one.
    pub count: usize,
    pub first: Mismatch,
}

#[derive(Clone, Debug)]
pub struct Judged {
    pub verdict: Verdict,
    /// Only the fields that differ (expected or fail), in column order.
    pub fields: Vec<FieldVerdict>,
    /// The mismatch to report as THE failure (earliest failing field, else a length mismatch).
    pub fail: Option<Mismatch>,
    /// Indices of the deviations that matched a differing field.
    pub triggered: Vec<usize>,
}

pub fn judge(scenario: &str, diffs: &Diffs, devs: &[Deviation]) -> Judged {
    let mut fields = vec![];
    let mut triggered: Vec<usize> = vec![];
    let mut fail: Option<(usize, usize, Mismatch)> = None;
    for fd in &diffs.fields {
        let hits: Vec<usize> = devs.iter().enumerate().filter(|(_, d)| d.axis == fd.field && d.applies_to(scenario)).map(|(i, _)| i).collect();
        for h in &hits {
            if !triggered.contains(h) {
                triggered.push(*h);
            }
        }
        match hits.first() {
            Some(&h) => fields.push(FieldVerdict {
                field: fd.field.clone(),
                verdict: Verdict::Expected,
                reason: Some(devs[h].reason.clone()),
                until: devs[h].until.clone(),
                count: fd.count,
                first: fd.first.clone(),
            }),
            None => {
                let key = (fd.first.index, fd.col);
                if fail.as_ref().map_or(true, |(i, c, _)| key < (*i, *c)) {
                    fail = Some((key.0, key.1, fd.first.clone()));
                }
                fields.push(FieldVerdict { field: fd.field.clone(), verdict: Verdict::Fail, reason: None, until: None, count: fd.count, first: fd.first.clone() });
            }
        }
    }
    triggered.sort_unstable();
    let fail = fail.map(|f| f.2).or_else(|| diffs.length.clone());
    let verdict = if fail.is_some() {
        Verdict::Fail
    } else if fields.is_empty() {
        Verdict::Pass
    } else {
        Verdict::Expected
    };
    Judged { verdict, fields, fail, triggered }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stale {
    pub axis: String,
    pub scenarios: Vec<String>,
    pub reason: String,
    pub until: Option<String>,
    pub why: String,
}

/// Deviations that did not trigger. `ran` = (scenario, triggered deviation indices) for every
/// scenario that produced a comparison. A deviation is only judged over scenarios that actually
/// ran (so `--only` does not make everything stale); a deviation that names a field the port does
/// not have, or a scenario the recipe does not have, is stale regardless.
pub fn stale(devs: &[Deviation], columns: &[String], all_scenarios: &[String], ran: &[(String, Vec<usize>)]) -> Vec<Stale> {
    let mut out = vec![];
    for (i, d) in devs.iter().enumerate() {
        let mk = |why: String| Stale { axis: d.axis.clone(), scenarios: d.scenarios.clone(), reason: d.reason.clone(), until: d.until.clone(), why };
        if !columns.contains(&d.axis) {
            out.push(mk(format!("the port has no field `{}`", d.axis)));
            continue;
        }
        if let Some(s) = d.scenarios.iter().find(|s| !all_scenarios.contains(s)) {
            out.push(mk(format!("no scenario `{s}` in the recipe")));
            continue;
        }
        let judged: Vec<&(String, Vec<usize>)> = ran.iter().filter(|(s, _)| d.applies_to(s)).collect();
        if !judged.is_empty() && judged.iter().all(|(_, t)| !t.contains(&i)) {
            out.push(mk(if d.scenarios.is_empty() { "field never differed in any scenario".into() } else { "field never differed in the listed scenarios".into() }));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::FieldDiff;

    fn mm(i: usize, f: &str) -> Mismatch {
        Mismatch { index: i, step: Some(i as u32), field: f.into(), expected: "1".into(), got: "2".into(), tolerance: None }
    }
    fn fd(f: &str, col: usize, idx: usize) -> FieldDiff {
        FieldDiff { field: f.into(), col, first: mm(idx, f), count: 3 }
    }
    const T: &str = "# c\n[[expected_deviation]]\naxis = \"ball_x\"\nreason = \"sub-pixel\" # why\nuntil = \"T9\"\n\n[[expected_deviation]]\naxis=\"lives\"\nscenarios = [\"a\", \"b\"]\nreason = \"r2\"\n";

    #[test]
    fn parses_deviations() {
        let d = parse(T).unwrap();
        assert_eq!(d.len(), 2);
        assert_eq!((d[0].axis.as_str(), d[0].until.as_deref()), ("ball_x", Some("T9")));
        assert!(d[0].applies_to("anything"));
        assert_eq!(d[1].scenarios, vec!["a", "b"]);
        assert!(d[1].applies_to("a") && !d[1].applies_to("c"));
        assert!(parse("").unwrap().is_empty());
    }

    #[test]
    fn parse_errors_are_specific() {
        assert!(parse("[[expected_deviation]]\naxis = \"x\"\n").unwrap_err().contains("missing `reason`"));
        assert!(parse("[[expected_deviation]]\nreason = \"x\"\n").unwrap_err().contains("missing `axis`"));
        assert!(parse("axis = \"x\"\n").unwrap_err().contains("outside"));
        assert!(parse("[[expected_deviation]]\naxis = \"x\"\nreason = \"r\"\nbogus = 1\n").unwrap_err().contains("unknown key `bogus`"));
        assert!(parse("[wat]\n").unwrap_err().contains("unknown table"));
    }

    #[test]
    fn verdicts_fail_beats_expected() {
        let devs = parse(T).unwrap();
        let none = Diffs { fields: vec![], length: None };
        assert_eq!(judge("s", &none, &devs).verdict, Verdict::Pass);
        let exp = Diffs { fields: vec![fd("ball_x", 6, 4)], length: None };
        let j = judge("s", &exp, &devs);
        assert_eq!(j.verdict, Verdict::Expected);
        assert_eq!(j.fields[0].reason.as_deref(), Some("sub-pixel"));
        assert_eq!(j.triggered, vec![0]);
        assert!(j.fail.is_none());
        // an undeclared field makes the scenario FAIL, the declared one stays EXPECTED in the list
        let both = Diffs { fields: vec![fd("ball_x", 6, 4), fd("score", 3, 7)], length: None };
        let j = judge("s", &both, &devs);
        assert_eq!(j.verdict, Verdict::Fail);
        assert_eq!(j.fail.unwrap().field, "score");
        assert_eq!(j.fields.iter().map(|f| f.verdict).collect::<Vec<_>>(), vec![Verdict::Expected, Verdict::Fail]);
        // a deviation scoped to other scenarios does not apply
        let lives = Diffs { fields: vec![fd("lives", 2, 1)], length: None };
        assert_eq!(judge("a", &lives, &devs).verdict, Verdict::Expected);
        assert_eq!(judge("c", &lives, &devs).verdict, Verdict::Fail);
        // a length mismatch is never expected
        let len = Diffs { fields: vec![fd("ball_x", 6, 4)], length: Some(mm(9, "<line>")) };
        let j = judge("s", &len, &devs);
        assert_eq!((j.verdict, j.fail.unwrap().field.as_str()), (Verdict::Fail, "<line>"));
    }

    #[test]
    fn earliest_failing_field_is_the_reported_one() {
        let d = Diffs { fields: vec![fd("lives", 2, 5), fd("score", 3, 2)], length: None };
        assert_eq!(judge("s", &d, &[]).fail.unwrap().field, "score");
    }

    #[test]
    fn staleness() {
        let devs = parse(T).unwrap();
        let cols: Vec<String> = ["ball_x", "lives"].iter().map(|s| s.to_string()).collect();
        let all: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        // dev 0 triggered in `a`; dev 1 (a,b) never triggered although a and b ran
        let ran = vec![("a".to_string(), vec![0usize]), ("b".to_string(), vec![]), ("c".to_string(), vec![])];
        let s = stale(&devs, &cols, &all, &ran);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].axis, "lives");
        // dev 1's scenarios were filtered out by --only: not judged
        let ran = vec![("c".to_string(), vec![0usize])];
        assert!(stale(&devs, &cols, &all, &ran).is_empty());
        // unknown field / scenario
        let s = stale(&devs, &["ball_x".to_string()], &all, &ran);
        assert!(s[0].why.contains("no field `lives`"), "{:?}", s);
        let s = stale(&devs, &cols, &["a".to_string()], &ran);
        assert!(s[0].why.contains("no scenario `b`"), "{:?}", s);
    }
}
