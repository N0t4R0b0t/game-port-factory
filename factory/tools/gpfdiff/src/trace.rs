//! Trace lines (golden files and emulator output): platform independent.
//!
//! One line = whitespace-separated columns. Without a header, the 11 Brickfall columns:
//! `step mode lives score paddle_x cleared ball_x ball_y ball_vx ball_vy bricks_hex`.
//! With a `# columns: a b c` header (what `gpfdiff capture` writes), whatever the port's field map says.

use std::fmt;

pub const FIELDS: [&str; 11] = [
    "step", "mode", "lives", "score", "paddle_x", "cleared", "ball_x", "ball_y", "ball_vx",
    "ball_vy", "bricks",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub cols: Vec<String>,
}

impl Line {
    /// Parse a line of the *default* (11 Brickfall column) layout, validating each column.
    pub fn parse(s: &str) -> Result<Line, String> {
        let toks: Vec<&str> = s.split_whitespace().collect();
        if toks.len() != FIELDS.len() {
            return Err(format!("expected {} columns, got {}: `{s}`", FIELDS.len(), toks.len()));
        }
        for (i, t) in toks.iter().enumerate().take(10) {
            t.parse::<i64>()
                .map_err(|_| format!("column {} ({}) not an integer: `{t}`", i + 1, FIELDS[i]))?;
        }
        let b = toks[10];
        if b.len() != 10 || !b.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(format!("column 11 (bricks) must be 10 hex digits: `{b}`"));
        }
        Ok(Line { cols: toks.iter().map(|t| t.to_ascii_lowercase()).collect() })
    }
}

impl fmt::Display for Line {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.cols.join(" "))
    }
}

/// The header that makes a trace self-describing: `# columns: a b c`.
pub const COLUMNS_HEADER: &str = "# columns:";

/// A trace: column names plus lines. Files without a header are the legacy 11-column
/// layout (and are validated as such); files with `# columns: ...` carry any columns.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Trace {
    pub columns: Vec<String>,
    pub lines: Vec<Line>,
}

impl Trace {
    pub fn default_columns() -> Vec<String> {
        FIELDS.iter().map(|s| s.to_string()).collect()
    }

    pub fn len(&self) -> usize {
        self.lines.len()
    }

    pub fn col(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c == name)
    }

    /// The simulation step of sample `i`, if the trace has a `step` column.
    pub fn step_at(&self, i: usize) -> Option<u32> {
        let c = self.col("step")?;
        self.lines.get(i)?.cols.get(c)?.parse().ok()
    }

    /// Header line plus one line per sample (what `capture` writes).
    pub fn render(&self) -> String {
        let mut s = format!("{COLUMNS_HEADER} {}\n", self.columns.join(" "));
        for l in &self.lines {
            s.push_str(&l.to_string());
            s.push('\n');
        }
        s
    }

    /// Samples only, no header (the legacy golden layout; `gpfdiff run --dump`).
    pub fn render_plain(&self) -> String {
        self.lines.iter().map(|l| format!("{l}\n")).collect()
    }

    /// Keep only `names`, in that order. Every name must exist.
    pub fn project(&self, names: &[String]) -> Result<Trace, String> {
        let mut idx = vec![];
        for n in names {
            idx.push(self.col(n).ok_or_else(|| {
                format!("the oracle trace has no column `{n}` (it has: {})", self.columns.join(" "))
            })?);
        }
        Ok(Trace {
            columns: names.to_vec(),
            lines: self.lines.iter().map(|l| Line { cols: idx.iter().map(|&i| l.cols[i].clone()).collect() }).collect(),
        })
    }

    /// Parse a whole trace file. Blank lines and `#` comments are skipped; `# columns:` names
    /// the columns (must precede the first sample).
    pub fn parse(text: &str) -> Result<Trace, String> {
        let mut columns: Option<Vec<String>> = None;
        let mut lines = vec![];
        for (n, raw) in text.lines().enumerate() {
            if let Some(h) = raw.trim_start().strip_prefix(COLUMNS_HEADER) {
                if !lines.is_empty() {
                    return Err(format!("trace line {}: `# columns:` must come before the first sample", n + 1));
                }
                let cols: Vec<String> = h.split_whitespace().map(|s| s.to_string()).collect();
                if cols.is_empty() {
                    return Err(format!("trace line {}: empty `# columns:` header", n + 1));
                }
                for (i, c) in cols.iter().enumerate() {
                    if cols[..i].contains(c) {
                        return Err(format!("trace line {}: duplicate column `{c}`", n + 1));
                    }
                }
                columns = Some(cols);
                continue;
            }
            let l = raw.split('#').next().unwrap().trim();
            if l.is_empty() {
                continue;
            }
            let line = match &columns {
                None => Line::parse(l),
                Some(c) => {
                    let toks: Vec<String> = l.split_whitespace().map(|t| t.to_ascii_lowercase()).collect();
                    if toks.len() != c.len() {
                        Err(format!("expected {} columns ({}), got {}: `{l}`", c.len(), c.join(" "), toks.len()))
                    } else {
                        Ok(Line { cols: toks })
                    }
                }
            };
            lines.push(line.map_err(|e| format!("trace line {}: {e}", n + 1))?);
        }
        Ok(Trace { columns: columns.unwrap_or_else(Trace::default_columns), lines })
    }
}

/// Parse a whole trace file (see [`Trace::parse`]).
pub fn parse_trace(text: &str) -> Result<Trace, String> {
    Trace::parse(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const L: &str = "5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff";

    #[test]
    fn parses_a_golden_line() {
        let l = Line::parse(L).unwrap();
        assert_eq!(l.cols[8], "-128");
        assert_eq!(l.cols[10], "ffffffffff");
        assert_eq!(l.to_string(), L);
    }

    #[test]
    fn rejects_bad_lines() {
        assert!(Line::parse("1 2 3").is_err());
        assert!(Line::parse("5 1 3 0 108 0 30720 42496 -128 x ffffffffff").is_err());
        assert!(Line::parse("5 1 3 0 108 0 30720 42496 -128 -384 fff").is_err());
        assert!(Line::parse("5 1 3 0 108 0 30720 42496 -128 -384 zzzzzzzzzz").is_err());
    }

    #[test]
    fn hex_case_is_normalised() {
        let a = Line::parse("0 0 3 0 112 0 1 2 0 0 FFFFFFFFFF").unwrap();
        let b = Line::parse("0 0 3 0 112 0 1 2 0 0 ffffffffff").unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn parse_trace_skips_blanks_and_comments() {
        let t = parse_trace(&format!("# hdr\n\n{L}\n{L} # x\n")).unwrap();
        assert_eq!(t.len(), 2);
        assert_eq!(t.columns, Trace::default_columns());
        assert_eq!(t.step_at(0), Some(5));
        let e = parse_trace("1 2\n").unwrap_err();
        assert!(e.starts_with("trace line 1"), "{e}");
    }

    #[test]
    fn checked_in_golden_files_parse_if_present() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../games/brickfall/recipe/golden");
        let Ok(rd) = std::fs::read_dir(&dir) else { return };
        let mut n = 0;
        for e in rd.flatten() {
            if e.path().extension().map_or(false, |x| x == "trace") {
                let t = std::fs::read_to_string(e.path()).unwrap();
                let tr = parse_trace(&t).unwrap_or_else(|e| panic!("{:?}: {e}", e));
                assert!(tr.len() > 0);
                assert_eq!(tr.step_at(0), Some(0));
                n += 1;
            }
        }
        assert!(n > 0);
    }

    #[test]
    fn header_makes_a_trace_self_describing() {
        let t = parse_trace("# columns: x room score\n# comment\n1 2 3\n4 5 6 # c\n").unwrap();
        assert_eq!(t.columns, vec!["x", "room", "score"]);
        assert_eq!(t.len(), 2);
        assert_eq!(t.step_at(0), None); // no `step` column
        let e = parse_trace("# columns: x room\n1 2 3\n").unwrap_err();
        assert!(e.starts_with("trace line 2") && e.contains("expected 2 columns"), "{e}");
        assert!(parse_trace("# columns: x\n1\n# columns: y\n").unwrap_err().contains("before the first sample"));
        assert!(parse_trace("# columns: x x\n").unwrap_err().contains("duplicate column `x`"));
        assert!(parse_trace("# columns:\n").unwrap_err().contains("empty"));
    }

    #[test]
    fn render_round_trips_and_projects() {
        let t = parse_trace("# columns: a b c\n1 2 3\n4 5 6\n").unwrap();
        assert_eq!(t.render(), "# columns: a b c\n1 2 3\n4 5 6\n");
        assert_eq!(parse_trace(&t.render()).unwrap(), t);
        let p = t.project(&["c".to_string(), "a".to_string()]).unwrap();
        assert_eq!(p.render_plain(), "3 1\n6 4\n");
        let e = t.project(&["zz".to_string()]).unwrap_err();
        assert!(e.contains("no column `zz`") && e.contains("a b c"), "{e}");
    }

    #[test]
    fn default_trace_with_header_equals_without() {
        let plain = parse_trace(&format!("{L}\n")).unwrap();
        let hdr = parse_trace(&format!("{COLUMNS_HEADER} {}\n{L}\n", FIELDS.join(" "))).unwrap();
        assert_eq!(plain, hdr);
    }
}
