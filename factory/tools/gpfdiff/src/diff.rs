//! Trace comparison: platform independent. Values are compared as text (exact) unless the
//! column declares a tolerance, in which case both sides are parsed as numbers and may differ
//! by up to that much (absolute, in normalised units).

use crate::fields::format_num;
use crate::trace::Trace;
use std::fmt;

/// How one column is compared.
#[derive(Clone, Debug, PartialEq)]
pub struct ColRule {
    pub name: String,
    /// Absolute tolerance in normalised units; 0 = exact.
    pub tolerance: f64,
    /// Collected and printed, never compared.
    pub ignore: bool,
}

impl ColRule {
    pub fn exact(name: &str) -> ColRule {
        ColRule { name: name.into(), tolerance: 0.0, ignore: false }
    }

    fn same(&self, e: &str, g: &str) -> bool {
        if e == g {
            return true;
        }
        if self.tolerance > 0.0 {
            if let (Ok(a), Ok(b)) = (e.parse::<f64>(), g.parse::<f64>()) {
                return (a - b).abs() <= self.tolerance + 1e-9;
            }
        }
        false
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mismatch {
    /// Index into the sampled trace (0-based).
    pub index: usize,
    /// Simulation step of the expected line (or of the got line if expected is missing), when the trace has a `step` column.
    pub step: Option<u32>,
    pub field: String,
    pub expected: String,
    pub got: String,
    /// Set (to the formatted tolerance) when the column has one, so a report shows that
    /// "different" here already means "beyond the tolerance".
    pub tolerance: Option<String>,
}

impl fmt::Display for Mismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.step {
            Some(s) => write!(f, "MISMATCH step {s} (sample #{})", self.index)?,
            None => write!(f, "MISMATCH sample #{}", self.index)?,
        }
        write!(f, " field {}: expected {} got {}", self.field, self.expected, self.got)?;
        if let Some(t) = &self.tolerance {
            write!(f, " (tolerance {t})")?;
        }
        Ok(())
    }
}

/// First difference of one column, and how many samples differ in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldDiff {
    pub field: String,
    pub col: usize,
    pub first: Mismatch,
    pub count: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diffs {
    /// Differing columns, in column order.
    pub fields: Vec<FieldDiff>,
    /// Set when the traces have different lengths (a `<line>` mismatch).
    pub length: Option<Mismatch>,
}

impl Diffs {
    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.fields.is_empty() && self.length.is_none()
    }

    /// The first difference by (sample, column); a length mismatch only when no value differs.
    pub fn first(&self) -> Option<Mismatch> {
        self.fields
            .iter()
            .min_by_key(|f| (f.first.index, f.col))
            .map(|f| f.first.clone())
            .or_else(|| self.length.clone())
    }
}

/// Compare every column of two traces that have the same columns (project first).
pub fn compare(rules: &[ColRule], exp: &Trace, got: &Trace) -> Diffs {
    let mut fields: Vec<FieldDiff> = vec![];
    for (c, name) in exp.columns.iter().enumerate() {
        let rule = rules.iter().find(|r| &r.name == name).cloned().unwrap_or_else(|| ColRule::exact(name));
        if rule.ignore {
            continue;
        }
        let mut first: Option<Mismatch> = None;
        let mut count = 0;
        for (i, (e, g)) in exp.lines.iter().zip(got.lines.iter()).enumerate() {
            if !rule.same(&e.cols[c], &g.cols[c]) {
                count += 1;
                if first.is_none() {
                    first = Some(Mismatch {
                        index: i,
                        step: exp.step_at(i),
                        field: name.clone(),
                        expected: e.cols[c].clone(),
                        got: g.cols[c].clone(),
                        tolerance: (rule.tolerance > 0.0).then(|| format_num(rule.tolerance)),
                    });
                }
            }
        }
        if let Some(first) = first {
            fields.push(FieldDiff { field: name.clone(), col: c, first, count });
        }
    }
    let n = exp.lines.len().min(got.lines.len());
    let length = if exp.lines.len() > got.lines.len() {
        Some(Mismatch {
            index: n,
            step: exp.step_at(n),
            field: "<line>".into(),
            expected: exp.lines[n].to_string(),
            got: "<end of trace>".into(),
            tolerance: None,
        })
    } else if got.lines.len() > exp.lines.len() {
        Some(Mismatch {
            index: n,
            step: got.step_at(n),
            field: "<line>".into(),
            expected: "<end of trace>".into(),
            got: got.lines[n].to_string(),
            tolerance: None,
        })
    } else {
        None
    };
    Diffs { fields, length }
}

/// Exact comparison of two traces with identical columns; `None` = every line matches.
/// (Run-vs-run determinism and the legacy golden comparison.)
pub fn first_diff(expected: &Trace, got: &Trace) -> Option<Mismatch> {
    compare(&[], expected, got).first()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trace::{parse_trace, Trace};

    const G: &str = "0 0 3 0 112 0 32256 44032 0 0 ffffffffff\n\
                     5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff\n\
                     10 1 3 0 108 0 30080 40576 -128 -384 ffffffffff\n";

    #[test]
    fn identical_traces_match() {
        let t = parse_trace(G).unwrap();
        assert_eq!(first_diff(&t, &t), None);
    }

    #[test]
    fn reports_step_field_expected_got() {
        let exp = parse_trace(G).unwrap();
        let got = parse_trace(&G.replace("30080 40576", "30081 40576")).unwrap();
        let m = first_diff(&exp, &got).unwrap();
        assert_eq!(m.step, Some(10));
        assert_eq!(m.tolerance, None);
        assert_eq!(m.field, "ball_x");
        assert_eq!(m.expected, "30080");
        assert_eq!(m.got, "30081");
        assert_eq!(m.index, 2);
        let s = m.to_string();
        assert!(s.contains("step 10") && s.contains("field ball_x") && s.contains("expected 30080") && s.contains("got 30081"), "{s}");
    }

    #[test]
    fn first_diff_wins_over_later_ones() {
        let exp = parse_trace(G).unwrap();
        let mutated = G.replace("108 0 30720", "109 0 30720").replace("30080", "30081");
        let got = parse_trace(&mutated).unwrap();
        let m = first_diff(&exp, &got).unwrap();
        assert_eq!((m.step, m.field.as_str()), (Some(5), "paddle_x"));
    }

    #[test]
    fn brick_mask_diff_is_named() {
        let exp = parse_trace(G).unwrap();
        let got = parse_trace(&G.replacen("ffffffffff", "fffffffffe", 3).replace("fffffffffe", "ffffffff7f")).unwrap();
        let m = first_diff(&exp, &got).unwrap();
        assert_eq!(m.field, "bricks");
        assert_eq!(m.step, Some(0));
    }

    #[test]
    fn length_mismatches() {
        let exp = parse_trace(G).unwrap();
        let short = Trace { columns: exp.columns.clone(), lines: exp.lines[..2].to_vec() };
        let m = first_diff(&exp, &short).unwrap();
        assert_eq!((m.index, m.step), (2, Some(10)));
        assert_eq!(m.got, "<end of trace>");
        let m = first_diff(&short, &exp).unwrap();
        assert_eq!((m.index, m.expected.as_str()), (2, "<end of trace>"));
    }

    fn tr(cols: &str, rows: &[&str]) -> Trace {
        parse_trace(&format!("# columns: {cols}\n{}\n", rows.join("\n"))).unwrap()
    }

    #[test]
    fn tolerance_absorbs_jitter_and_zero_rejects_it() {
        let exp = tr("step x", &["0 10", "1 11", "2 12"]);
        let got = tr("step x", &["0 11", "1 10", "2 12"]); // +-1 jitter
        let rule = |t: f64| vec![ColRule { name: "x".into(), tolerance: t, ignore: false }];
        assert!(compare(&rule(1.0), &exp, &got).is_empty());
        let d = compare(&rule(0.0), &exp, &got);
        assert_eq!(d.fields.len(), 1);
        assert_eq!((d.fields[0].count, d.fields[0].first.index), (2, 0));
        assert_eq!(d.fields[0].first.tolerance, None);
        // 2 apart is beyond tolerance 1, and the report says so
        let far = tr("step x", &["0 12", "1 11", "2 12"]);
        let m = compare(&rule(1.0), &exp, &far).first().unwrap();
        assert_eq!((m.expected.as_str(), m.got.as_str(), m.tolerance.as_deref()), ("10", "12", Some("1")));
        assert!(m.to_string().ends_with("expected 10 got 12 (tolerance 1)"), "{m}");
    }

    #[test]
    fn ignored_columns_are_not_compared_and_non_numbers_stay_exact() {
        let exp = tr("step x hex", &["0 1 ffff"]);
        let got = tr("step x hex", &["0 9 fffe"]);
        let rules = vec![
            ColRule { name: "x".into(), tolerance: 0.0, ignore: true },
            ColRule { name: "hex".into(), tolerance: 5.0, ignore: false },
        ];
        let d = compare(&rules, &exp, &got);
        assert_eq!(d.fields.len(), 1, "{d:?}");
        assert_eq!(d.fields[0].field, "hex"); // tolerance only applies to numbers
    }

    #[test]
    fn mismatch_without_a_step_column_names_the_sample() {
        let m = first_diff(&tr("x", &["1"]), &tr("x", &["2"])).unwrap();
        assert_eq!(m.step, None);
        assert_eq!(m.to_string(), "MISMATCH sample #0 field x: expected 1 got 2");
    }
}
