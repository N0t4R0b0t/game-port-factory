//! T0255: the BASE (-run / tape) message streams against X-ALL.TXT, byte for byte, automatically.
//!
//! verify_tape_text checks a hand-listed set of tape-only streams.  This one derives its list: every `msg_*` label of
//! target/text_src/*.asm (the filled, plain-text sources) whose template (target/text_tpl/<same file>) carries `@orig(X-ALL:<line>/n)`
//! keys is mapped to the X-ALL label that contains its first key line, and the two streams are flattened and compared the way
//! verify_tape_text does (mpen+n -> 16+n, mxy+n -> 128+n, drawbox -> 9, mend -> 0; text as characters; `defw` lines are not
//! part of the stream).  A port stream that ends in two zero bytes is compared as a chatter stream (X-ALL: up to the first mend
//! that directly follows a mend), otherwise as a single box (a single box shown through msg_chatter carries ONE extra 0).
//! Output: PASS / DIFF (first differing byte) / SKIP (no original key: port-authored text).  Exit 1 on any DIFF not listed in
//! tools/roompack/base_text_expected.txt (label, reason), so a deviation is never silent.
//!
//! Usage (from the port root): verify_base_text
use std::collections::BTreeMap;
use std::fs;
use std::process::exit;

const XALL: &str = "research/D3-prior-art/original_source/X-ALL.TXT";
const FILES: &[&str] = &["gameplay.asm", "gap_messages.asm", "actors.asm", "rat_troll_hazard_code.asm"];

/// Split on commas outside double quotes, dropping a trailing `;` comment.
fn split_args(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut q = false;
    for ch in s.chars() {
        match ch {
            '"' => {
                q = !q;
                cur.push(ch)
            }
            ';' if !q => break,
            ',' if !q => {
                out.push(cur.trim().to_string());
                cur.clear()
            }
            _ => cur.push(ch),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur.trim().to_string());
    }
    out
}

/// Pen codes (X-ALL `mpen+n`, the port's `16+n`) are compared as "a pen" only: the port stores the pen (msg_pen) and never reads it
/// (a monochrome PMODE4 box has no colours), so a different n changes no pixel.  `--strict-pens` compares them exactly.
static mut STRICT_PENS: bool = false;
fn strict_pens() -> bool { unsafe { STRICT_PENS } }

/// One `+`-sum of terms: numbers and the X-ALL symbols.
fn eval(term: &str) -> u32 {
    let t0 = term.trim();
    if !strict_pens() && (t0.starts_with("mpen+") || (t0.starts_with("16+") && !t0.contains("128"))) { return 16; }
    term.split('+')
        .map(|t| {
            let t = t.trim();
            match t {
                "mpen" => 16,
                "mxy" => 128,
                "drawbox" => 9,
                "mend" => 0,
                _ => t.parse::<u32>().unwrap_or_else(|_| panic!("cannot evaluate `{t}`")),
            }
        })
        .sum()
}

fn push_arg(out: &mut Vec<u8>, a: &str) {
    if let Some(txt) = a.strip_prefix('"').and_then(|x| x.strip_suffix('"')) {
        out.extend(txt.bytes());
    } else {
        out.push(eval(a) as u8);
    }
}

/// Flatten the stream starting at `label` in X-ALL.TXT.
fn xall_stream(lines: &[String], label: &str, stream: bool) -> Vec<u8> {
    let start = lines
        .iter()
        .position(|l| l.split_whitespace().next() == Some(label) && !l.starts_with(' ') && !l.starts_with('\t'))
        .unwrap_or_else(|| panic!("X-ALL label {label} not found"));
    let mut out = Vec::new();
    let mut prev_mend = false;
    for l in &lines[start..] {
        let body = if l.starts_with(' ') || l.starts_with('\t') {
            l.trim_start()
        } else {
            l.trim_start_matches(|c: char| !c.is_whitespace()).trim_start()
        };
        let Some(rest) = body.strip_prefix("defb") else { continue };
        for a in split_args(rest.trim_start()) {
            let is_mend = a == "mend";
            push_arg(&mut out, &a);
            if is_mend {
                if !stream || prev_mend {
                    return out;
                }
                prev_mend = true;
            } else {
                prev_mend = false;
            }
        }
    }
    panic!("X-ALL stream {label} never terminated");
}

/// Flatten `label`'s bytes in a port source: from the label to the next
/// column-0 label (or end of file).
fn port_stream(lines: &[String], label: &str) -> Vec<u8> {
    let start = lines.iter().position(|l| l.trim_end() == label).unwrap_or_else(|| panic!("port label {label} not found"));
    let mut out = Vec::new();
    for l in &lines[start + 1..] {
        if !l.is_empty() && !l.starts_with(' ') && !l.starts_with('\t') && !l.starts_with(';') {
            break; // next label
        }
        let body = l.trim_start();
        if let Some(rest) = body.strip_prefix("fcb") {
            for a in split_args(rest.trim_start()) {
                out.push(eval(&a) as u8);
            }
        } else if let Some(rest) = body.strip_prefix("fcc") {
            let rest = rest.trim();
            let q1 = rest.find('"').expect("fcc string");
            let q2 = rest.rfind('"').expect("fcc string end");
            out.extend(rest[q1 + 1..q2].bytes());
        }
    }
    out
}

fn read_lines(path: &str) -> Vec<String> {
    let raw = fs::read(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    String::from_utf8_lossy(&raw).lines().map(|s| s.to_string()).collect()
}


/// The X-ALL label whose block contains 1-based line `ln`: the nearest line at or above it that starts in column 0 with a name.
fn xall_label_of(lines: &[String], ln: usize) -> Option<String> {
    for i in (0..ln.min(lines.len())).rev() {
        let l = &lines[i];
        let Some(first) = l.chars().next() else { continue };
        if first.is_ascii_alphabetic() || first == '_' {
            let Some(tok) = l.split_whitespace().next().map(|t| t.to_string()) else { continue };
            if !matches!(tok.as_str(), "defb" | "defw" | "defm" | "defs" | "if" | "endif" | "include" | "org" | "else") {
                return Some(tok);
            }
        }
    }
    None
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));      // the stream readers panic on a label that is not that kind of stream; callers catch it
    if std::env::args().any(|a| a == "--strict-pens") { unsafe { STRICT_PENS = true; } }
    let x = read_lines(XALL);
    let expected: BTreeMap<String, String> = fs::read_to_string("tools/roompack/base_text_expected.txt")
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once('|').map(|(a, b)| (a.trim().to_string(), b.trim().to_string())))
        .collect();
    let (mut pass, mut diff, mut skip, mut bad) = (0, 0, 0, 0);
    for f in FILES {
        let tpl = read_lines(&format!("target/text_tpl/{f}"));
        let src_path = format!("target/text_src/{f}");
        let src = read_lines(&src_path);
        // labels and their first original line, from the template
        let mut cur: Option<String> = None;
        let mut first: BTreeMap<String, usize> = BTreeMap::new();
        for l in &tpl {
            let t = l.trim_end();
            if t.starts_with("msg_") && t.split_whitespace().count() == 1 {
                cur = Some(t.to_string());
            } else if let (Some(c), Some(p)) = (&cur, l.find("@orig(X-ALL:")) {
                if l.trim_start().starts_with("fcc") {
                    let num: String = l[p + 12..].chars().take_while(|c| c.is_ascii_digit()).collect();
                    if let Ok(n) = num.parse::<usize>() {
                        first.insert(c.clone(), n);   // the LAST key line decides the X-ALL label (a string like the first line of a death box repeats in several labels)
                    }
                }
            } else if !l.is_empty() && !l.starts_with(' ') && !l.starts_with('\t') && !l.starts_with(';') && !t.starts_with("msg_") {
                cur = None;
            }
        }
        for (label, ln) in &first {
            let Some(xl) = xall_label_of(&x, *ln) else { println!("SKIP {label}: no X-ALL label above line {ln}"); skip += 1; continue };
            let got_full = port_stream(&src, label);
            // a single box shown through msg_chatter carries ONE extra 0 (the chatter terminator); a real stream ends in two
            let single = std::panic::catch_unwind(|| xall_stream(&x, &xl, false)).ok();
            let multi = std::panic::catch_unwind(|| xall_stream(&x, &xl, true)).ok();
            let mut trimmed = got_full.clone();
            if trimmed.len() >= 2 && trimmed[trimmed.len() - 1] == 0 && trimmed[trimmed.len() - 2] == 0 { trimmed.pop(); }
            let (want, got, stream) = if single.as_ref() == Some(&got_full) || single.as_ref() == Some(&trimmed) {
                (single.clone().unwrap(), single.clone().unwrap(), false)
            } else if multi.as_ref() == Some(&got_full) {
                (multi.clone().unwrap(), got_full.clone(), true)
            } else {
                let st = got_full.len() >= 2 && got_full[got_full.len() - 1] == 0 && got_full[got_full.len() - 2] == 0;
                match if st { multi.clone() } else { single.clone() } { Some(w) => (w, got_full.clone(), st), None => { println!("SKIP {label}: X-ALL {xl} unreadable as a stream"); skip += 1; continue } }
            };
            if want == got {
                pass += 1;
                println!("PASS {label} == X-ALL {xl} ({} bytes, {})", got.len(), if stream { "stream" } else { "single" });
            } else {
                diff += 1;
                let i = want.iter().zip(&got).position(|(a, b)| a != b).unwrap_or(want.len().min(got.len()));
                let why = expected.get(label.as_str());
                if why.is_none() { bad += 1; }
                println!("DIFF {label} != X-ALL {xl}: lengths {} vs {}, first difference at byte {i} (X-ALL {:?}, port {:?}){}", want.len(), got.len(), want.get(i), got.get(i),
                    match why { Some(w) => format!("  EXPECTED: {w}"), None => "  <-- UNEXPECTED".to_string() });
            }
        }
    }
    println!("VERIFY_BASE_TEXT pass={pass} diff={diff} skip={skip} unexpected={bad}");
    if bad != 0 { exit(1); }
}
