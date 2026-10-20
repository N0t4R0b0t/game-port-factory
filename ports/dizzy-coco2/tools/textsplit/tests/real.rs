//! Verifier over the real port files. Needs extracted/game_text.json (the
//! user's own original text); skipped with a message when it is absent.
//! Run: cargo test --offline --manifest-path ports/dizzy-coco2/tools/textsplit/Cargo.toml

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use textsplit::*;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn orig() -> Option<OrigSet> {
    let j = root().join("extracted/game_text.json");
    let Ok(s) = fs::read_to_string(&j) else {
        eprintln!("SKIPPED: {} absent (supply the original text first)", j.display());
        return None;
    };
    let mut o = OrigSet::new(&load_orig(&s).unwrap()).unwrap();
    o.set_allow(&fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("allow.txt")).unwrap());
    Some(o)
}

fn asm_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    let mut v: Vec<_> = rd.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "asm")).collect();
    v.sort();
    v
}

/// fill(split(x)) == x for every legacy text_src*/ file (when present).
#[test]
fn roundtrip_legacy_sources() {
    let Some(o) = orig() else { return };
    let mut files = 0;
    for d in ["target/text_src", "target/text_src_tape"] {
        for f in asm_files(&root().join(d)) {
            let x = fs::read_to_string(&f).unwrap();
            let (tpl, rep) = split_text(&x, &o);
            assert!(rep.problems.is_empty(), "{}: {:?}", f.display(), rep.problems);
            assert_eq!(fill_text(&tpl, &o).unwrap(), x, "{}", f.display());
            files += 1;
        }
    }
    eprintln!("roundtrip: {files} legacy files byte-identical");
}

/// The shipped templates fill cleanly, re-split to themselves, and leak nothing.
#[test]
fn shipped_templates_are_clean_and_stable() {
    let Some(o) = orig() else { return };
    let mut files = 0;
    for d in ["target/text_tpl", "target/text_tpl_tape"] {
        for f in asm_files(&root().join(d)) {
            let t = fs::read_to_string(&f).unwrap();
            assert!(leaks_in_text(&t, &o).is_empty(), "{} leaks: {:?}", f.display(), leaks_in_text(&t, &o));
            let filled = fill_text(&t, &o).unwrap();
            let (again, rep) = split_text(&filled, &o);
            assert!(rep.problems.is_empty());
            assert_eq!(again, t, "{}", f.display());
            files += 1;
        }
    }
    assert!(files == 0 || files == 10, "expected 10 template files, found {files}");
}

/// A deliberately leaked original string makes check-public FAIL (exit 1);
/// a clean tree passes (exit 0).
#[test]
fn check_public_detects_a_planted_leak() {
    let Some(o) = orig() else { return };
    let j = root().join("extracted/game_text.json");
    let victim = load_orig(&fs::read_to_string(&j).unwrap())
        .unwrap()
        .into_iter()
        .find(|s| words(&s.raw).join(" ").len() >= 12  && !o.leaks_in_line(&s.raw).is_empty())
        .unwrap()
        .raw;
    let dir = std::env::temp_dir().join(format!("textsplit_leak_{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let bin = env!("CARGO_BIN_EXE_textsplit");
    let run = |dir: &Path| {
        Command::new(bin)
            .args(["check-public", "--templates"])
            .arg(dir)
            .arg("--orig-json")
            .arg(&j)
            .output()
            .unwrap()
    };
    fs::write(dir.join("ok.asm"), "        fcc \"GAME:OVER\"\n        fcb 1\n").unwrap();
    assert!(run(&dir).status.success());
    fs::write(dir.join("leak.asm"), format!("; harmless\n        fcc \"{victim}\"\n")).unwrap();
    let out = run(&dir);
    assert!(!out.status.success(), "planted leak {victim:?} was not detected");
    assert!(String::from_utf8_lossy(&out.stderr).contains("LEAK"));
    let _ = fs::remove_dir_all(&dir);
}

/// The text policy over the port's own docs, notes, harness and tools: no running message text.
/// (Directories are walked recursively; generated holders of the original text, e.g. harness/orig_text.lua, are skipped by the walker.)
#[test]
fn port_docs_and_harness_quote_no_message_text() {
    let j = root().join("extracted/game_text.json");
    if !j.exists() {
        eprintln!("SKIPPED: {} absent", j.display());
        return;
    }
    let mut c = Command::new(env!("CARGO_BIN_EXE_textsplit"));
    c.args(["check-public", "--docs", "--orig-json"]).arg(&j).arg("--allow").arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("allow.txt"));
    for p in ["NOTES.md", "SESSION-LOG.md", "tasks.toml", "docs", "harness", "tools"] {
        c.arg("--also").arg(root().join(p));
    }
    let out = c.output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}
