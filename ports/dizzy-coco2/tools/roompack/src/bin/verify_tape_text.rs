//! T0223: prove the tape build's hand-transcribed message streams are
//! TOKEN-FOR-TOKEN what research/D3-prior-art/original_source/X-ALL.TXT has.
//!
//! The no-content-cuts rule is a checkable property: each stream in
//! target/text_src_tape/*.asm (the PLAIN-text sources tools/dte encodes) is
//! flattened to bytes (fcb expressions of `16+n`/`128+n`/numbers, fcc strings)
//! and compared with the same stream flattened out of X-ALL.TXT's `defb`
//! lines (mpen+n -> 16+n, mxy+n -> 128+n, drawbox -> 9, mend -> 0, quoted text
//! as its characters). `defw` lines (a talk stream's leading poke address) are
//! not part of the stream: the port does that poke in code.
//!
//! A message is "single" (ends at its first mend) or a "stream" (ends at the
//! first mend that directly follows another mend, the chatter terminator).
//!
//! Usage (from the port root): verify_tape_text
//! Exit 0 = every listed stream is identical; non-zero names the first
//! differing byte. Encoding correctness (DTE) is `dte selftest`'s job.
use std::fs;
use std::process::exit;

const XALL: &str = "research/D3-prior-art/original_source/X-ALL.TXT";

/// (X-ALL label, stream?, port file, port label)
const CHECKS: &[(&str, bool, &str, &str)] = &[
    ("dozytalking", true, "target/text_src_tape/msg_data_tape_low.asm", "msg_dozytalking"),
    ("thanksforthecowmess", true, "target/text_src_tape/msg_data_tape_low.asm", "msg_shoptalk"),
    ("throwwateronbeanmess", false, "target/text_src_tape/msg_data_tape_low.asm", "msg_waterbean"),
    ("shopkeeperappearsmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_shopappears"),
    ("givingjunkmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_givingjunk"),
    ("stopgivingjunkmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_stopjunk"),
    ("plantbeanmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_plantbean"),
    // T0226
    ("usedoorknockermess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_usedoorknocker"),
    ("fillbucketmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_fillbucket"),
    ("usepickaxemess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_usepickaxe"),
    // T0227
    ("userugmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_userug"),
    ("holdingholemess", false, "target/text_src_tape/msg_data_tape_low4.asm", "msg_holdinghole"),
    ("fullbucketmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_name_fullbucket"),
    ("doorknockermess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_name_knocker"),
    ("rugmess", false, "target/text_src_tape/msg_data_tape_low3.asm", "msg_name_rug"),
    // T0228: Daisy's meeting in room 94 (daisyrou X:3492)
    ("gottodaisymess", false, "target/text_src_tape/msg_data_tape_low4.asm", "msg_gottodaisy"),
    ("daisyrunsmess", false, "target/text_src_tape/msg_data_tape_low4.asm", "msg_daisyruns"),
    // T0229: Dylan and Doug (X:674-694, X:796-834)
    ("dylantalking", true, "target/text_src_tape/msg_data_tape_low4.asm", "msg_dylantalking"),
    ("trancemess", false, "target/text_src_tape/msg_data_tape_low4.asm", "msg_trance"),
    ("dougtalking", true, "target/text_src_tape/msg_data_tape.asm", "msg_dougtalking"),
    ("goonmysonmess", false, "target/text_src_tape/msg_data_tape.asm", "msg_goonmyson"),
    // T0230: whiskey, manure, names
    ("dropwhiskeymess", false, "target/text_src_tape/msg_data_tape.asm", "msg_dropwhiskey"),
    ("pickupmanuremess", false, "target/text_src_tape/msg_data_tape.asm", "msg_pickupmanure"),
    ("emptybottlemess", false, "target/text_src_tape/msg_data_tape.asm", "msg_name_emptybottle"),
    ("goldeneggmess", false, "target/text_src_tape/msg_data_tape.asm", "msg_name_egg"),
    ("sleeppotionmess", false, "target/text_src_tape/msg_data_tape.asm", "msg_name_potion"),
    ("crowbarmess", false, "target/text_src_tape/msg_data_tape.asm", "msg_name_crowbar"),
    ("windowmess", false, "target/text_src_tape/msg_data_tape.asm", "msg_name_window"),
];

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

/// One `+`-sum of terms: numbers and the X-ALL symbols.
fn eval(term: &str) -> u32 {
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

fn main() {
    let x = read_lines(XALL);
    let mut bad = 0;
    for &(xl, stream, file, pl) in CHECKS {
        let want = xall_stream(&x, xl, stream);
        let mut got = port_stream(&read_lines(file), pl);
        // T0229: a single box that the port shows through msg_chatter (a talk's repeat
        // message) carries ONE extra 0 after its mend, the chatter terminator.
        if !stream && got.len() == want.len() + 1 && got.last() == Some(&0) {
            got.pop();
        }
        if want == got {
            println!("PASS {pl} == X-ALL {xl} ({} bytes, {})", got.len(), if stream { "stream" } else { "single" });
        } else {
            bad += 1;
            let i = want.iter().zip(&got).position(|(a, b)| a != b).unwrap_or(want.len().min(got.len()));
            println!(
                "FAIL {pl} != X-ALL {xl}: lengths {} vs {}, first difference at byte {i} (X-ALL {:?}, port {:?})",
                want.len(),
                got.len(),
                want.get(i),
                got.get(i)
            );
        }
    }
    // T0226: the 19 tape-only rooms' banner streams == extracted/rooms.json `name`
    // (room byte, mxy+12, 24, the 20-char name, mend), and the table lists exactly them.
    const BANNER_ROOMS: [u32; 19] = [74, 75, 63, 91, 92, 45, 48, 49, 94, 89, 41, 73, 88, 93, 40, 46, 31, 47, 77];
    let rooms: serde_json::Value =
        serde_json::from_str(&fs::read_to_string("extracted/rooms.json").expect("rooms.json")).expect("rooms.json parse");
    let low4 = read_lines("target/text_src_tape/msg_data_tape_low4.asm");
    for n in BANNER_ROOMS {
        let name = rooms["rooms"].as_array().unwrap().iter()
            .find(|r| r["index"].as_u64() == Some(n as u64)).and_then(|r| r["name"].as_str())
            .unwrap_or_else(|| panic!("room {n} has no name in rooms.json"));
        let mut want = vec![n as u8, 128 + 12, 24];
        want.extend(name.bytes());
        want.push(0);
        let got = port_stream(&low4, &format!("msgname_{n}"));
        if want == got && name.len() == 20 {
            println!("PASS banner msgname_{n} == rooms.json name {name:?}");
        } else {
            bad += 1;
            println!("FAIL banner msgname_{n}: want {want:?} got {got:?}");
        }
    }
    let tab_entries: Vec<String> = low4.iter()
        .filter_map(|l| l.trim().strip_prefix("fdb ").map(|r| r.trim().to_string())).collect();
    let mut want_tab: Vec<String> = BANNER_ROOMS.iter().map(|n| format!("msgname_{n}")).collect();
    want_tab.push("0".to_string());
    if tab_entries == want_tab {
        println!("PASS banner table lists exactly the 19 tape-only rooms, 0-terminated");
    } else {
        bad += 1;
        println!("FAIL banner table: {tab_entries:?}");
    }
    println!("VERIFY_TAPE_TEXT {}", if bad == 0 { "PASS" } else { "FAIL" });
    if bad != 0 {
        exit(1);
    }
}
