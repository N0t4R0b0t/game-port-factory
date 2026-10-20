//! Split the port's hand-edited text_src*/ files into public templates
//! (code + keys + port-only strings) and the original game's strings, and
//! put them back together byte-for-byte.
//!
//! Key scheme (the only thing a template says about an original string):
//!
//! ```text
//! fcc "@orig(X-ALL:296/13)"      source tag, 1-based line, byte length
//! fcc "@orig(X-ALL:981#1/9)"     second string on a line that holds several
//! ```
//!
//! The length is a sanity check against a different X-ALL.TXT revision; it
//! is not a transform. The transform set is EMPTY: all 352 original-derived
//! strings in the port equal the extractor's `raw` field exactly.

use std::collections::{BTreeMap, HashMap};
use std::fmt;

/// What an original string is, for the text policy: identifiers (room titles, item names, UI
/// labels) may be named in docs and comments; running message text never.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cat {
    Message,
    Room,
    Item,
    Ui,
}

impl Cat {
    pub fn is_identifier(self) -> bool {
        self != Cat::Message
    }
    pub fn name(self) -> &'static str {
        match self {
            Cat::Message => "message",
            Cat::Room => "room",
            Cat::Item => "item",
            Cat::Ui => "ui",
        }
    }
}

/// Category rules (`categories.txt`): source tag + line range -> category. First match wins; a line
/// no rule covers is a Message (fail closed).
#[derive(Debug, Clone, Default)]
pub struct Rules(Vec<(String, u64, u64, Cat)>);

pub const DEFAULT_RULES: &str = include_str!("../categories.txt");

impl Rules {
    pub fn parse(text: &str) -> Result<Rules, String> {
        let mut v = Vec::new();
        for (i, l) in text.lines().enumerate() {
            let l = l.split('#').next().unwrap_or("").trim();
            if l.is_empty() {
                continue;
            }
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() != 4 {
                return Err(format!("categories line {}: want `TAG FIRST LAST CATEGORY`", i + 1));
            }
            let num = |s: &str| s.parse::<u64>().map_err(|_| format!("categories line {}: bad number {s:?}", i + 1));
            let cat = match f[3] {
                "message" => Cat::Message,
                "room" => Cat::Room,
                "item" => Cat::Item,
                "ui" => Cat::Ui,
                c => return Err(format!("categories line {}: unknown category {c:?}", i + 1)),
            };
            v.push((f[0].to_string(), num(f[1])?, num(f[2])?, cat));
        }
        Ok(Rules(v))
    }
    pub fn cat(&self, tag: &str, line: u64) -> Cat {
        self.0.iter().find(|(t, a, b, _)| t == tag && (*a..=*b).contains(&line)).map(|r| r.3).unwrap_or(Cat::Message)
    }
    pub fn apply(&self, list: &mut [Orig]) {
        for o in list {
            o.cat = self.cat(&o.tag, o.line);
        }
    }
}

/// One original string as extracted into game_text.json.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Orig {
    pub tag: String,
    pub line: u64,
    pub nth: u32,
    pub raw: String,
    pub cat: Cat,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Key {
    pub tag: String,
    pub line: u64,
    /// 0-based ordinal among the strings on that line (almost always 0)
    pub nth: u32,
    pub len: usize,
}

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.nth == 0 {
            write!(f, "@orig({}:{}/{})", self.tag, self.line, self.len)
        } else {
            write!(f, "@orig({}:{}#{}/{})", self.tag, self.line, self.nth, self.len)
        }
    }
}

/// Parse `@orig(TAG:LINE/LEN)`. Returns None if `s` is not a key at all,
/// Some(Err) if it starts like one but is malformed.
pub fn parse_key(s: &str) -> Option<Result<Key, String>> {
    let rest = s.strip_prefix("@orig(")?;
    Some(parse_key_body(rest))
}

fn parse_key_body(rest: &str) -> Result<Key, String> {
    let body = rest.strip_suffix(')').ok_or("missing ')'")?;
    let (tag, nums) = body.rsplit_once(':').ok_or("missing ':'")?;
    let (line, len) = nums.split_once('/').ok_or("missing '/'")?;
    let (line, nth) = match line.split_once('#') {
        Some((l, n)) => (l, n.parse().map_err(|_| format!("bad ordinal {n:?}"))?),
        None => (line, 0),
    };
    if tag.is_empty() || !tag.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err(format!("bad tag {tag:?}"));
    }
    Ok(Key {
        tag: tag.to_string(),
        line: line.parse().map_err(|_| format!("bad line {line:?}"))?,
        nth,
        len: len.parse().map_err(|_| format!("bad length {len:?}"))?,
    })
}

/// Source tag from a path: file stem ("X-ALL.TXT" -> "X-ALL").
pub fn tag_of(path: &str) -> String {
    let base = path.rsplit(['/', '\\']).next().unwrap_or(path);
    base.rsplit_once('.').map(|(s, _)| s).unwrap_or(base).to_string()
}

/// Load game_text.json (array of {file,line,raw,...}).
pub fn load_orig(json: &str) -> Result<Vec<Orig>, String> {
    let v: serde_json::Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let arr = v.as_array().ok_or("game_text.json: not an array")?;
    let mut out: Vec<Orig> = Vec::new();
    for e in arr {
        let file = e["file"].as_str().ok_or("entry without file")?;
        let tag = tag_of(file);
        let line = e["line"].as_u64().ok_or("entry without line")?;
        let nth = out.iter().filter(|o| o.tag == tag && o.line == line).count() as u32;
        out.push(Orig {
            tag,
            line,
            nth,
            raw: e["raw"].as_str().ok_or("entry without raw")?.to_string(),
            cat: Cat::Message,
        });
    }
    Ok(out)
}

/// The original set indexed both ways.
pub struct OrigSet {
    by_key: BTreeMap<(String, u64, u32), String>,
    by_raw: HashMap<String, (String, u64, u32)>,
    /// normalised word sequences (len >= 4) for leak scanning
    words: HashMap<String, Vec<Vec<String>>>,
    norm_all: HashMap<String, (String, u64, u32)>,
    /// word-joined strings allowed to appear in code/comment prose (never in an fcc operand)
    allow: std::collections::HashSet<String>,
    /// message-category strings, by first word, for the docs scan: (words, key)
    msgs: HashMap<String, Vec<(Vec<String>, Key)>>,
    /// identifier-category strings (word sequences), by first word: a message string that sits inside
    /// one of these is part of the identifier ("SOME SLEEPING POTION"), not a quote
    ids: HashMap<String, Vec<Vec<String>>>,
}

/// Case-fold, `:` = space, trim, collapse runs of spaces.
pub fn normalise(s: &str) -> String {
    s.chars()
        .map(|c| if c == ':' { ' ' } else { c.to_ascii_uppercase() })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Maximal runs of ASCII alphanumerics, upper-cased. `:` and everything
/// else is a separator.
pub fn words(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| w.to_ascii_uppercase())
        .collect()
}

pub const MIN_LEAK_LEN: usize = 4;

impl OrigSet {
    pub fn new(list: &[Orig]) -> Result<OrigSet, String> {
        let mut by_key = BTreeMap::new();
        let mut by_raw = HashMap::new();
        let mut wordsm: HashMap<String, Vec<Vec<String>>> = HashMap::new();
        let mut norm_all = HashMap::new();
        let mut cats: HashMap<String, Cat> = HashMap::new();
        for o in list {
            if by_key.insert((o.tag.clone(), o.line, o.nth), o.raw.clone()).is_some() {
                return Err(format!("duplicate original id {}:{}#{}", o.tag, o.line, o.nth));
            }
            if let Some(prev) = by_raw.insert(o.raw.clone(), (o.tag.clone(), o.line, o.nth)) {
                return Err(format!("original string {:?} occurs at {}:{} and {}:{}; split would be ambiguous", o.raw, prev.0, prev.1, o.tag, o.line));
            }
            norm_all.insert(normalise(&o.raw), (o.tag.clone(), o.line, o.nth));
            let w = words(&o.raw);
            let c = cats.entry(w.join(" ")).or_insert(o.cat);
            if o.cat.is_identifier() {
                *c = o.cat; // a string that is also an identifier may be named
            }
            if w.join(" ").len() >= MIN_LEAK_LEN {
                wordsm.entry(w[0].clone()).or_default().push(w);
            }
        }
        let mut msgs: HashMap<String, Vec<(Vec<String>, Key)>> = HashMap::new();
        for o in list {
            let w = words(&o.raw);
            if o.cat == Cat::Message && cats.get(&w.join(" ")) == Some(&Cat::Message) && w.join(" ").len() >= MIN_LEAK_LEN {
                let key = Key { tag: o.tag.clone(), line: o.line, nth: o.nth, len: o.raw.len() };
                msgs.entry(w[0].clone()).or_default().push((w, key));
            }
        }
        let mut ids: HashMap<String, Vec<Vec<String>>> = HashMap::new();
        for o in list.iter().filter(|o| o.cat.is_identifier()) {
            let w = words(&o.raw);
            if !w.is_empty() {
                ids.entry(w[0].clone()).or_default().push(w);
            }
        }
        Ok(OrigSet { by_key, by_raw, words: wordsm, norm_all, allow: Default::default(), msgs, ids })
    }

    /// Parse an allow file: one string per line, `#` comments, blank lines
    /// ignored. Entries are normalised to word sequences.
    pub fn set_allow(&mut self, text: &str) {
        self.allow = text
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .map(|l| words(l).join(" "))
            .filter(|l| !l.is_empty())
            .collect();
    }

    /// (tag, line, nth, raw) of every original string, in key order.
    pub fn entries(&self) -> impl Iterator<Item = (&str, u64, u32, &str)> {
        self.by_key.iter().map(|((t, l, n), r)| (t.as_str(), *l, *n, r.as_str()))
    }

    pub fn resolve(&self, k: &Key) -> Result<&str, String> {
        let raw = self
            .by_key
            .get(&(k.tag.clone(), k.line, k.nth))
            .ok_or_else(|| format!("{}: no original string at {}:{}", k, k.tag, k.line))?;
        if raw.len() != k.len {
            return Err(format!("{}: original at {}:{} has length {} (different revision?)", k, k.tag, k.line, raw.len()));
        }
        Ok(raw)
    }

    pub fn key_for(&self, raw: &str) -> Option<Key> {
        self.by_raw.get(raw).map(|(t, l, n)| Key { tag: t.clone(), line: *l, nth: *n, len: raw.len() })
    }

    /// An original string equal to `s` only after normalisation (would need
    /// a transform we do not define).
    pub fn near_match(&self, s: &str) -> Option<&(String, u64, u32)> {
        self.norm_all.get(&normalise(s))
    }

    /// Original strings (as normalised text) found in `line` as whole word sequences.
    pub fn leaks_in_line(&self, line: &str) -> Vec<String> {
        // Inside an fcc operand nothing is allowed: strings there must be keys.
        let strict = matches!(classify(line), Line::Fcc { .. } | Line::BadFcc);
        let w = words(line);
        let mut hits = Vec::new();
        for i in 0..w.len() {
            if let Some(cands) = self.words.get(&w[i]) {
                for c in cands {
                    if w.len() - i >= c.len() && w[i..i + c.len()] == c[..] {
                        let j = c.join(" ");
                        if strict || !self.allow.contains(&j) {
                            hits.push(j);
                        }
                    }
                }
            }
        }
        hits
    }
}

/// A source line, classified.
#[derive(Debug, PartialEq, Eq)]
pub enum Line<'a> {
    /// `<indent>fcc "<text>"<suffix>` (suffix is whitespace/newline only)
    Fcc { indent: &'a str, text: &'a str, suffix: &'a str },
    /// starts with `fcc` but is not the simple form we can handle
    BadFcc,
    Other,
}

pub fn classify(line: &str) -> Line<'_> {
    let trimmed = line.trim_start();
    let indent = &line[..line.len() - trimmed.len()];
    if let Some(rest) = trimmed.strip_prefix("fcc \"") {
        if let Some(end) = rest.find('"') {
            let suffix = &rest[end + 1..];
            if suffix.trim().is_empty() {
                return Line::Fcc { indent, text: &rest[..end], suffix };
            }
        }
        return Line::BadFcc;
    }
    if trimmed.starts_with("fcc") && trimmed[3..].starts_with(|c: char| c.is_whitespace()) {
        return Line::BadFcc;
    }
    Line::Other
}

#[derive(Debug, Default)]
pub struct SplitReport {
    pub keyed: usize,
    pub port_only: Vec<(usize, String)>,
    /// (1-based line, text, reason)
    pub problems: Vec<(usize, String, String)>,
}

/// Split one file's text into a template.
pub fn split_text(src: &str, orig: &OrigSet) -> (String, SplitReport) {
    let mut out = String::with_capacity(src.len());
    let mut rep = SplitReport::default();
    for (i, line) in src.split_inclusive('\n').enumerate() {
        match classify(line) {
            Line::Fcc { indent, text, suffix } => {
                if text.starts_with("@orig(") {
                    rep.problems.push((i + 1, text.into(), "string starts with the key marker @orig(".into()));
                } else if let Some(k) = orig.key_for(text) {
                    rep.keyed += 1;
                    out.push_str(&format!("{indent}fcc \"{k}\"{suffix}"));
                    continue;
                } else if let Some((t, l, _)) = orig.near_match(text) {
                    rep.problems.push((i + 1, text.into(), format!("equals original {t}:{l} only after normalisation; no transform defined")));
                } else {
                    rep.port_only.push((i + 1, text.to_string()));
                }
                out.push_str(line);
            }
            Line::BadFcc => {
                rep.problems.push((i + 1, line.trim_end().into(), "fcc line not in the simple `fcc \"...\"` form".into()));
                out.push_str(line);
            }
            Line::Other => out.push_str(line),
        }
    }
    (out, rep)
}

/// Fill one template back into source.
pub fn fill_text(tpl: &str, orig: &OrigSet) -> Result<String, Vec<String>> {
    let mut out = String::with_capacity(tpl.len());
    let mut errs = Vec::new();
    for (i, line) in tpl.split_inclusive('\n').enumerate() {
        if let Line::Fcc { indent, text, suffix } = classify(line) {
            if let Some(k) = parse_key(text) {
                match k.and_then(|k| orig.resolve(&k).map(|s| s.to_string())) {
                    Ok(s) => {
                        out.push_str(&format!("{indent}fcc \"{s}\"{suffix}"));
                        continue;
                    }
                    Err(e) => errs.push(format!("line {}: {e}", i + 1)),
                }
            }
        }
        out.push_str(line);
    }
    if errs.is_empty() { Ok(out) } else { Err(errs) }
}

/// Leak scan of arbitrary text: (1-based first line, original string).
/// Runs of consecutive comment lines are scanned as one stream, so a phrase
/// wrapped across comment lines is still found.
pub fn leaks_in_text(text: &str, orig: &OrigSet) -> Vec<(usize, String)> {
    let mut v = Vec::new();
    let mut run = String::new();
    let mut run_start = 0;
    let is_comment = |l: &str| l.trim_start().starts_with(';');
    let lines: Vec<&str> = text.lines().collect();
    for (i, l) in lines.iter().enumerate() {
        if is_comment(l) {
            if run.is_empty() {
                run_start = i + 1;
            }
            run.push_str(l);
            run.push(' ');
            if lines.get(i + 1).is_some_and(|n| is_comment(n)) {
                continue;
            }
            for h in orig.leaks_in_line(&run) {
                v.push((run_start, h));
            }
            run.clear();
        } else {
            for h in orig.leaks_in_line(l) {
                v.push((i + 1, h));
            }
        }
    }
    v
}


// ---------------------------------------------------------------------------------------------
// Docs scan: running message text must not appear in any tracked file; identifiers may.
// ---------------------------------------------------------------------------------------------

/// A word (maximal run of ASCII alphanumerics) with its position in the file.
#[derive(Debug, Clone)]
pub struct Tok {
    pub w: String,
    /// 1-based line
    pub line: usize,
    pub start: usize,
    pub end: usize,
}

pub fn tokens(text: &str) -> Vec<Tok> {
    let b = text.as_bytes();
    let (mut v, mut line, mut i) = (Vec::new(), 1usize, 0usize);
    while i < b.len() {
        if b[i] == b'\n' {
            line += 1;
            i += 1;
        } else if b[i].is_ascii_alphanumeric() {
            let s = i;
            while i < b.len() && b[i].is_ascii_alphanumeric() {
                i += 1;
            }
            v.push(Tok { w: text[s..i].to_ascii_uppercase(), line, start: s, end: i });
        } else {
            i += 1;
        }
    }
    v
}

/// A message string found in a file.
#[derive(Debug, Clone)]
pub struct Hit {
    pub key: Key,
    pub line: usize,
    pub start: usize,
    pub end: usize,
    pub nwords: usize,
    pub nchars: usize,
    /// the matched text has no lowercase letter: written the way the source writes it (a quote),
    /// not as ordinary prose
    pub upper: bool,
}

/// An UPPER-CASE message string (a quote in the source's own form) is dialogue on its own when it has
/// this many words ...
pub const STRONG_WORDS: usize = 3;
/// ... or this many characters (word-joined). Shorter ones only count in a run (see WINDOW_*).
pub const STRONG_CHARS: usize = 12;
/// A string in ordinary-prose case needs this many words: two or three words of lower-case English
/// ("see ya later") are indistinguishable from prose that happens to share the words.
pub const PROSE_WORDS: usize = 4;
/// Backstop for dialogue split across short rows: this many message strings ...
pub const WINDOW_COUNT: usize = 3;
/// ... starting within this many consecutive lines (a 6-line window).
pub const WINDOW_LINES: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FindKind {
    /// a message string long enough to be dialogue by itself
    Message,
    /// part of a run of >= WINDOW_COUNT message strings in a WINDOW_LINES window
    Window,
}

#[derive(Debug, Clone)]
pub struct DocFinding {
    pub kind: FindKind,
    pub hit: Hit,
}

/// All message-category strings in `text`, longest-first and non-overlapping, minus the allow list.
pub fn message_hits(text: &str, orig: &OrigSet) -> Vec<Hit> {
    let toks = tokens(text);
    let mut all: Vec<(usize, usize, &Key, usize, bool)> = Vec::new(); // (start tok, n toks, key, nchars, upper)
    for i in 0..toks.len() {
        if let Some(cands) = orig.msgs.get(&toks[i].w) {
            for (w, k) in cands {
                if toks.len() - i >= w.len() && toks[i..i + w.len()].iter().map(|t| &t.w).eq(w.iter()) {
                    let j = w.join(" ");
                    let upper = !text[toks[i].start..toks[i + w.len() - 1].end].bytes().any(|b| b.is_ascii_lowercase());
                    // allow.txt names ordinary prose (and single words, e.g. UNTIL); several words written as a source-form quote are still a quote
                    if !(orig.allow.contains(&j) && (!upper || w.len() == 1)) {
                        all.push((i, w.len(), k, j.len(), upper));
                    }
                }
            }
        }
    }
    // identifier spans: (start tok, end tok exclusive)
    let mut idspans: Vec<(usize, usize)> = Vec::new();
    for i in 0..toks.len() {
        if let Some(cands) = orig.ids.get(&toks[i].w) {
            for w in cands {
                if toks.len() - i >= w.len() && toks[i..i + w.len()].iter().map(|t| &t.w).eq(w.iter()) {
                    idspans.push((i, i + w.len()));
                }
            }
        }
    }
    all.retain(|&(i, n, _, _, _)| !idspans.iter().any(|&(a, b)| a <= i && i + n <= b && (b - a) > n));
    all.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)));
    let (mut out, mut next_free) = (Vec::new(), 0usize);
    for (i, n, k, nchars, upper) in all {
        if i < next_free {
            continue;
        }
        next_free = i + n;
        out.push(Hit { key: k.clone(), line: toks[i].line, start: toks[i].start, end: toks[i + n - 1].end, nwords: n, nchars, upper });
    }
    out
}

/// Findings in one file's text: strong message strings, plus every message string in a run.
pub fn doc_findings(text: &str, orig: &OrigSet) -> Vec<DocFinding> {
    let hits = message_hits(text, orig);
    let mut flag = vec![None; hits.len()];
    for (i, h) in hits.iter().enumerate() {
        let strong = if h.upper { h.nwords >= STRONG_WORDS || h.nchars >= STRONG_CHARS } else { h.nwords >= PROSE_WORDS };
        if strong {
            flag[i] = Some(FindKind::Message);
        }
    }
    // only strings that read as quotes count towards a run
    let hits: Vec<Hit> = hits.into_iter().collect();
    let counts = |h: &Hit| h.upper || h.nwords >= STRONG_WORDS;
    for i in 0..hits.len() {
        if !counts(&hits[i]) {
            continue;
        }
        let j = (i..hits.len()).take_while(|&j| hits[j].line < hits[i].line + WINDOW_LINES).last().unwrap();
        let idx: Vec<usize> = (i..=j).filter(|&k| counts(&hits[k])).collect();
        if idx.len() >= WINDOW_COUNT {
            for k in idx {
                flag[k].get_or_insert(FindKind::Window);
            }
        }
    }
    hits.into_iter().zip(flag).filter_map(|(hit, k)| k.map(|kind| DocFinding { kind, hit })).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set() -> OrigSet {
        OrigSet::new(&[
            Orig { tag: "X-ALL".into(), line: 296, nth: 0, raw: "FANTASY:WORLD".into(), cat: Cat::Ui },
            Orig { tag: "X-ALL".into(), line: 10, nth: 0, raw: "KEY".into(), cat: Cat::Ui },
            Orig { tag: "PRTDIZZY".into(), line: 191, nth: 0, raw: "Memory overflowed".into(), cat: Cat::Ui },
        ])
        .unwrap()
    }

    #[test]
    fn normalise_cases() {
        assert_eq!(normalise(":Fantasy::world "), "FANTASY WORLD");
        assert_eq!(normalise(""), "");
    }

    #[test]
    fn words_split() {
        assert_eq!(words("KEEP:OUT@:DOZY;S"), vec!["KEEP", "OUT", "DOZY", "S"]);
    }

    #[test]
    fn key_roundtrip() {
        let k = Key { tag: "X-ALL".into(), line: 296, nth: 0, len: 13 };
        let k2 = Key { nth: 1, ..k.clone() };
        assert_eq!(k2.to_string(), "@orig(X-ALL:296#1/13)");
        assert_eq!(parse_key(&k2.to_string()).unwrap().unwrap(), k2);
        assert_eq!(k.to_string(), "@orig(X-ALL:296/13)");
        assert_eq!(parse_key(&k.to_string()).unwrap().unwrap(), k);
        assert!(parse_key("GAME:OVER").is_none());
        assert!(parse_key("@orig(X-ALL:296)").unwrap().is_err());
        assert!(parse_key("@orig(X-ALL:x/3)").unwrap().is_err());
        assert!(parse_key("@orig(:1/3)").unwrap().is_err());
    }

    #[test]
    fn tags() {
        assert_eq!(tag_of("/a/b/X-ALL.TXT"), "X-ALL");
        assert_eq!(tag_of("PRTDIZZY.PDS"), "PRTDIZZY");
    }

    #[test]
    fn classify_lines() {
        assert!(matches!(classify("        fcc \"A:B\"\n"), Line::Fcc { text: "A:B", .. }));
        assert_eq!(classify("        fcc \"A\" ; c\n"), Line::BadFcc);
        assert_eq!(classify("        fcb 1,2\n"), Line::Other);
        assert_eq!(classify("; fcc \"A\"\n"), Line::Other);
    }

    #[test]
    fn split_and_fill() {
        let o = set();
        let src = "        fcb 1\n        fcc \"FANTASY:WORLD\"\n  fcc \"GAME:OVER\"\n        fcc \"Memory overflowed\"  \nlast";
        let (tpl, rep) = split_text(src, &o);
        assert_eq!(rep.keyed, 2);
        assert_eq!(rep.port_only, vec![(3, "GAME:OVER".to_string())]);
        assert!(rep.problems.is_empty());
        assert!(!tpl.contains("FANTASY"));
        assert!(tpl.contains("@orig(X-ALL:296/13)"));
        assert_eq!(fill_text(&tpl, &o).unwrap(), src);
    }

    #[test]
    fn near_match_is_a_problem() {
        let (_, rep) = split_text("fcc \"fantasy world\"\n", &set());
        assert_eq!(rep.problems.len(), 1);
        assert!(rep.port_only.is_empty());
    }

    #[test]
    fn fill_rejects_wrong_revision() {
        let o = set();
        assert!(fill_text("fcc \"@orig(X-ALL:296/12)\"\n", &o).is_err());
        assert!(fill_text("fcc \"@orig(X-ALL:999/3)\"\n", &o).is_err());
    }

    #[test]
    fn leak_scan() {
        let o = set();
        assert!(leaks_in_text("fcc \"FANTASY:WORLD\"\n", &o).len() == 1);
        assert!(leaks_in_text("; the fantasy world is\n", &o).len() == 1);
        assert!(leaks_in_text("fcc \"FANTASY:WORLDS\"\n", &o).is_empty());
        assert!(leaks_in_text("fcc \"KEY\"\n", &o).is_empty(), "under 4 chars is not scanned");
        assert!(leaks_in_text("fcc \"GAME:OVER\"\n", &o).is_empty());
        assert_eq!(leaks_in_text("; the fantasy\n; world is\n", &o), vec![(1, "FANTASY WORLD".to_string())]);
        assert!(leaks_in_text("        fcb 1 ; fantasy\n        fcb 2 ; world\n", &o).is_empty());
    }

    #[test]
    fn allow_applies_to_prose_only() {
        let mut o = set();
        o.set_allow("# names\nfantasy world\n");
        assert!(leaks_in_text("; the fantasy world\n", &o).is_empty());
        assert_eq!(leaks_in_text("        fcc \"FANTASY:WORLD\"\n", &o).len(), 1);
    }

    #[test]
    fn duplicate_raw_is_rejected() {
        let r = OrigSet::new(&[
            Orig { tag: "A".into(), line: 1, nth: 0, raw: "X".into(), cat: Cat::Message },
            Orig { tag: "A".into(), line: 2, nth: 0, raw: "X".into(), cat: Cat::Message },
        ]);
        assert!(r.is_err());
    }

    fn docset() -> OrigSet {
        let mut v = Vec::new();
        for (l, raw, cat) in [
            (437, ":THE:TEST:HARBOUR:", Cat::Room),
            (296, "FANTASY:WORLD", Cat::Ui),
            (1100, "A:BRASS:TEST:LAMP", Cat::Item),
            (733, "&GREETINGS:TRAVELLER<:I", Cat::Message),
            (734, "WON;T:YOU:HELP:ME", Cat::Message),
            (735, "WILL:YOU:FIND:IT?", Cat::Message),
            (736, "THANKS@", Cat::Message),
            (751, "SEE:YA:LATER", Cat::Message),
            (752, "THE:TEST:GATE", Cat::Message),
        ] {
            v.push(Orig { tag: "X-ALL".into(), line: l, nth: 0, raw: raw.into(), cat });
        }
        let mut o = OrigSet::new(&v).unwrap();
        o.set_allow("the test gate\n");
        o
    }

    #[test]
    fn rules_classify_by_region_and_fail_closed() {
        let r = Rules::parse(DEFAULT_RULES).unwrap();
        assert_eq!(r.cat("X-ALL", 437), Cat::Room);
        assert_eq!(r.cat("X-ALL", 296), Cat::Ui);
        assert_eq!(r.cat("X-ALL", 733), Cat::Message);
        assert_eq!(r.cat("X-ALL", 1100), Cat::Item);
        assert_eq!(r.cat("X-ALL", 99999), Cat::Message, "unknown line: fail closed");
        assert_eq!(r.cat("OTHER", 5), Cat::Message, "unknown source: fail closed");
        assert!(Rules::parse("X-ALL 1 2 bogus").is_err());
        assert!(Rules::parse("X-ALL 1 2").is_err());
    }

    #[test]
    fn docs_allow_identifiers_in_any_number() {
        let o = docset();
        let t = "rooms: :THE:TEST:HARBOUR: and A:BRASS:TEST:LAMP\nFANTASY WORLD\nThe test harbour, a brass test lamp, fantasy world\n";
        assert!(doc_findings(t, &o).is_empty());
    }

    #[test]
    fn docs_flag_message_text_in_either_encoding() {
        let o = docset();
        let f = doc_findings("x = \"WON;T:YOU:HELP:ME\"\n", &o);
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].kind, FindKind::Message);
        assert_eq!(f[0].hit.key.line, 734);
        assert_eq!(doc_findings("He says: WON'T YOU HELP ME.\n", &o).len(), 1);
        // a source-form quote wrapped over two lines is still found
        assert_eq!(doc_findings("# WON;T YOU\n# HELP ME\n", &o).len(), 1);
        // lower-case prose needs 4 words
        assert!(doc_findings("see ya later\n", &o).is_empty());
        assert_eq!(doc_findings("he won't you help me\n", &o).len(), 1);
        assert!(doc_findings("greetings traveller i\n", &o).is_empty());
    }

    #[test]
    fn docs_window_catches_dialogue_split_into_short_rows() {
        let o = docset();
        // each row alone is too short to fail ...
        assert!(doc_findings("THANKS\n", &o).is_empty());
        assert!(doc_findings("{1,\"THANKS@\"},\n{2,\"THANKS@\"}\n", &o).is_empty());
        // ... three message rows inside 6 lines are not
        let t = "{1,\"THANKS@\"},\n{2,\"SEE:YA:LATER\"},\n{3,\"WILL:YOU:FIND:IT?\"}\n";
        let f = doc_findings(t, &o);
        assert!(f.iter().any(|x| x.kind == FindKind::Window), "{f:?}");
        // the same three, spread over more than 6 lines, are not a run
        let t = "THANKS@\n\n\n\n\n\n\nTHANKS@\n\n\n\n\n\n\nTHANKS@\n";
        assert!(doc_findings(t, &o).is_empty());
        // three IDENTIFIERS in a window are fine
        let t = ":THE:TEST:HARBOUR:\nFANTASY:WORLD\nA:BRASS:TEST:LAMP\n";
        assert!(doc_findings(t, &o).is_empty());
    }

    #[test]
    fn message_inside_an_identifier_is_not_a_quote() {
        let o = OrigSet::new(&[
            Orig { tag: "X-ALL".into(), line: 642, nth: 0, raw: "[X-ALL.TXT line 642]<".into(), cat: Cat::Message },
            Orig { tag: "X-ALL".into(), line: 1085, nth: 0, raw: "SOME:SLEEPING:POTION".into(), cat: Cat::Item },
        ])
        .unwrap();
        assert!(doc_findings("find_text(d,\"SOME:SLEEPING:POTION\")\n", &o).is_empty());
        assert_eq!(doc_findings("find_text(d,\"[X-ALL.TXT line 642]\")\n", &o).len(), 1);
    }

    #[test]
    fn docs_allow_list_is_prose_only() {
        let o = docset();
        assert!(doc_findings("the test gate rises\n", &o).is_empty());
        assert_eq!(doc_findings("\"THE TEST GATE\"\n", &o).len(), 1, "source-form quote");
    }

    #[test]
    fn tokens_track_lines_and_offsets() {
        let t = tokens("ab cd\n  ef");
        assert_eq!((t[2].w.as_str(), t[2].line, t[2].start, t[2].end), ("EF", 2, 8, 10));
    }
}
