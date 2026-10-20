//! CLI tests for the docs gate (`check-public --docs`), `export-lua` and `scrub`, on a SYNTHETIC
//! game_text.json (invented strings, line numbers placed in the real source regions). They need no
//! user data, so a cheaper tier can run them anywhere:
//!   cargo test --offline --manifest-path ports/dizzy-coco2/tools/textsplit/Cargo.toml --test docs_cli

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const JSON: &str = r#"[
 {"file":"X-ALL.TXT","line":296,"raw":"CASTLE:OF:TESTS","decoded":""},
 {"file":"X-ALL.TXT","line":437,"raw":":THE:TEST:HARBOUR:","decoded":""},
 {"file":"X-ALL.TXT","line":1100,"raw":"A:BRASS:TEST:LAMP","decoded":""},
 {"file":"X-ALL.TXT","line":700,"raw":"&GREETINGS:TRAVELLER<:I","decoded":""},
 {"file":"X-ALL.TXT","line":701,"raw":"HAVE:LOST:MY:HAT@'","decoded":""},
 {"file":"X-ALL.TXT","line":702,"raw":"WILL:YOU:FIND:IT?","decoded":""},
 {"file":"X-ALL.TXT","line":703,"raw":"THANKS@:BYE","decoded":""},
 {"file":"X-ALL.TXT","line":704,"raw":"SEE:YA:LATER","decoded":""},
 {"file":"X-ALL.TXT","line":704,"raw":"MIND:THE:GAP;S","decoded":""}
]"#;

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("textsplit_docs_{}_{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

fn run(args: &[&str], dir: &Path) -> Output {
    let j = dir.join("game_text.json");
    if !j.exists() {
        fs::write(&j, JSON).unwrap();
    }
    Command::new(env!("CARGO_BIN_EXE_textsplit")).args(args).arg("--orig-json").arg(&j).output().unwrap()
}

fn docs(dir: &Path, files: &[&Path]) -> Output {
    let mut a: Vec<String> = vec!["check-public".into(), "--docs".into()];
    for f in files {
        a.push("--also".into());
        a.push(f.display().to_string());
    }
    let a: Vec<&str> = a.iter().map(|s| s.as_str()).collect();
    run(&a, dir)
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

#[test]
fn identifiers_pass_even_three_in_a_window() {
    let d = tmp("ids");
    let f = d.join("NOTES.md");
    fs::write(&f, "Room :THE:TEST:HARBOUR: (The Test Harbour), item A BRASS TEST LAMP, title CASTLE OF TESTS.\n").unwrap();
    let o = docs(&d, &[&f]);
    assert!(o.status.success(), "{}", stderr(&o));
}

#[test]
fn dialogue_in_markdown_fails() {
    let d = tmp("md");
    let f = d.join("NOTES.md");
    fs::write(&f, "# notes\nthe NPC says \"HAVE:LOST:MY:HAT@\" first\n").unwrap();
    let o = docs(&d, &[&f]);
    assert_eq!(o.status.code(), Some(1));
    assert!(stderr(&o).contains("NOTES.md:2"), "{}", stderr(&o));
}

#[test]
fn dialogue_in_lua_fails() {
    let d = tmp("lua");
    let f = d.join("t.lua");
    fs::write(&f, "local L={\"WILL:YOU:FIND:IT?\"}\n").unwrap();
    assert_eq!(docs(&d, &[&f]).status.code(), Some(1));
}

#[test]
fn dialogue_split_across_short_rows_fails() {
    let d = tmp("rows");
    let f = d.join("t.lua");
    // none of these is long enough alone; together they are a run
    fs::write(&f, "R={{1,\"THANKS@:BYE\"},\n{2,\"SEE:YA:LATER\"},\n{3,\"MIND:THE:GAP;S\"}}\n").unwrap();
    let o = docs(&d, &[&f]);
    assert_eq!(o.status.code(), Some(1), "{}", stderr(&o));
    assert!(stderr(&o).contains("run of message strings"));
}

#[test]
fn directories_are_walked_recursively_with_an_extension_filter() {
    let d = tmp("walk");
    fs::create_dir_all(d.join("a/b/target")).unwrap();
    fs::write(d.join("a/b/deep.sh"), "echo 'HAVE:LOST:MY:HAT@'\n").unwrap();
    fs::write(d.join("a/b/target/skipped.md"), "HAVE:LOST:MY:HAT@\n").unwrap();
    fs::write(d.join("a/b/data.bin"), "HAVE:LOST:MY:HAT@\n").unwrap();
    fs::write(d.join("a/orig_text.lua"), "return {[\"X-ALL:1\"]=\"HAVE:LOST:MY:HAT@\"}\n").unwrap(); // generated fixture: never scanned by a walk
    let o = docs(&d, &[&d.join("a")]);
    assert_eq!(o.status.code(), Some(1));
    let e = stderr(&o);
    assert!(e.contains("deep.sh"), "{e}");
    assert!(!e.contains("skipped.md") && !e.contains("data.bin") && !e.contains("orig_text.lua"), "{e}");
}

#[test]
fn list_file_and_binary_files() {
    let d = tmp("list");
    let (a, b) = (d.join("a.md"), d.join("b.png"));
    fs::write(&a, "fine\n").unwrap();
    fs::write(&b, b"\0\0HAVE:LOST:MY:HAT@\0").unwrap();
    fs::write(d.join("files.lst"), format!("{}\n{}\n", a.display(), b.display())).unwrap();
    let o = run(&["check-public", "--docs", "--list", d.join("files.lst").to_str().unwrap()], &d);
    assert!(o.status.success(), "{}", stderr(&o));
}

#[test]
fn export_lua_keys_and_escaping() {
    let d = tmp("lua_out");
    let out = d.join("orig_text.lua");
    let o = run(&["export-lua", "--out", out.to_str().unwrap()], &d);
    assert!(o.status.success(), "{}", stderr(&o));
    let s = fs::read_to_string(&out).unwrap();
    assert!(s.contains("[\"X-ALL:700\"] = \"&GREETINGS:TRAVELLER<:I\","));
    assert!(s.contains("[\"X-ALL:704#1\"] = \"MIND:THE:GAP;S\","), "ordinal key for the second string on a line");
    assert!(s.trim_end().ends_with('}'));
}

#[test]
fn scrub_replaces_with_pointers_and_leaves_identifiers() {
    let d = tmp("scrub");
    let f = d.join("n.md");
    fs::write(&f, "Harbour :THE:TEST:HARBOUR: says \"WILL:YOU:FIND:IT?\" twice.\n").unwrap();
    fs::write(d.join("files.lst"), format!("{}\n", f.display())).unwrap();
    let l = d.join("files.lst");
    let o = run(&["scrub", "--list", l.to_str().unwrap()], &d);
    assert!(o.status.success());
    assert!(fs::read_to_string(&f).unwrap().contains("WILL:YOU"), "dry run must not write");
    let o = run(&["scrub", "--list", l.to_str().unwrap(), "--apply"], &d);
    assert!(o.status.success());
    let s = fs::read_to_string(&f).unwrap();
    assert_eq!(s, "Harbour :THE:TEST:HARBOUR: says \"[X-ALL.TXT line 702]?\" twice.\n");
    assert!(docs(&d, &[&f]).status.success(), "scrubbed file passes the gate");
}
