//! textsplit: see README.md.

use clap::{Parser, Subcommand};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use textsplit::*;

#[derive(Parser)]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// text_src dir -> template dir (originals replaced by keys)
    Split {
        #[arg(long)]
        src: PathBuf,
        #[arg(long)]
        orig_json: PathBuf,
        #[arg(long)]
        out: PathBuf,
        /// strings allowed in comment/code prose (see README)
        #[arg(long)]
        allow: Option<PathBuf>,
    },
    /// template dir + original text -> text_src dir
    Fill {
        #[arg(long)]
        templates: PathBuf,
        #[arg(long)]
        orig_json: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// fail if original text occurs in the templates (all strings) or, with --docs, in tracked files
    /// (message strings only; identifiers may be named)
    CheckPublic {
        /// template directory (asm); optional with --docs
        #[arg(long)]
        templates: Option<PathBuf>,
        /// original text; needed to know what to look for
        #[arg(long)]
        orig_json: PathBuf,
        /// extra files or directories to scan too (directories are walked recursively)
        #[arg(long = "also")]
        also: Vec<PathBuf>,
        /// file holding paths to scan, one per line
        #[arg(long)]
        list: Option<PathBuf>,
        #[arg(long)]
        allow: Option<PathBuf>,
        /// docs mode: scan --also/--list files for running message text (see tools/textsplit/README.md)
        #[arg(long)]
        docs: bool,
        /// source-region categories (default: the built-in categories.txt)
        #[arg(long)]
        categories: Option<PathBuf>,
        /// docs mode: also list message strings too short to fail the gate on their own
        #[arg(long)]
        show_weak: bool,
    },
    /// write the original strings as a Lua table keyed `X-ALL:<line>[#n]` (generated test fixture)
    ExportLua {
        #[arg(long)]
        orig_json: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// replace message strings found in tracked files by pointers (dry run unless --apply)
    Scrub {
        #[arg(long)]
        orig_json: PathBuf,
        #[arg(long)]
        list: PathBuf,
        #[arg(long)]
        allow: Option<PathBuf>,
        #[arg(long)]
        categories: Option<PathBuf>,
        #[arg(long)]
        apply: bool,
    },
    /// in-memory fill(split(x)) == x for every file in DIR
    Roundtrip {
        #[arg(long)]
        src: PathBuf,
        #[arg(long)]
        orig_json: PathBuf,
        #[arg(long)]
        allow: Option<PathBuf>,
        /// byte test only: do not fail on leak findings (for the unscrubbed legacy files)
        #[arg(long)]
        no_leak_check: bool,
    },
}

fn load(p: &Path, allow: &Option<PathBuf>) -> Result<OrigSet, String> {
    load_with(p, allow, &None)
}

fn load_with(p: &Path, allow: &Option<PathBuf>, cats: &Option<PathBuf>) -> Result<OrigSet, String> {
    let s = fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
    let mut list = load_orig(&s)?;
    let rules = match cats {
        Some(c) => Rules::parse(&fs::read_to_string(c).map_err(|e| format!("{}: {e}", c.display()))?)?,
        None => Rules::parse(DEFAULT_RULES)?,
    };
    rules.apply(&mut list);
    let mut o = OrigSet::new(&list)?;
    if let Some(a) = allow {
        o.set_allow(&fs::read_to_string(a).map_err(|e| format!("{}: {e}", a.display()))?);
    }
    Ok(o)
}

fn files_in(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "asm"))
        .collect();
    v.sort();
    Ok(v)
}

const DOC_EXT: &[&str] = &["md", "lua", "py", "rs", "toml", "sh", "json", "asm", "txt", "inc", "cfg", "yml", "yaml", "s", "c", "h"];
/// Directories never walked: build output, VCS, and the generated holders of the user's own text.
const SKIP_DIRS: &[&str] = &["target", ".git", "node_modules", "text_src", "text_src_tape", "extracted"];
/// Generated files that ARE the original text (never scanned when found by a directory walk).
const SKIP_FILES: &[&str] = &["orig_text.lua", "game_text.json"];

/// A file as given, or every text file below a directory.
fn walk(p: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    if p.is_dir() {
        let mut v: Vec<PathBuf> = fs::read_dir(p).map_err(|e| format!("{}: {e}", p.display()))?.filter_map(|e| e.ok().map(|e| e.path())).collect();
        v.sort();
        for c in v {
            let n = c.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if c.is_dir() && !SKIP_DIRS.contains(&n.as_str()) {
                walk(&c, out)?;
            } else if c.is_file() && !SKIP_FILES.contains(&n.as_str()) && c.extension().is_some_and(|x| DOC_EXT.iter().any(|e| x == *e)) {
                out.push(c);
            }
        }
    } else {
        out.push(p.to_path_buf());
    }
    Ok(())
}

fn list_paths(list: &Option<PathBuf>, also: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let mut v = Vec::new();
    if let Some(l) = list {
        for line in fs::read_to_string(l).map_err(|e| format!("{}: {e}", l.display()))?.lines() {
            if !line.trim().is_empty() {
                walk(Path::new(line), &mut v)?;
            }
        }
    }
    for p in also {
        walk(p, &mut v)?;
    }
    Ok(v)
}

/// UTF-8 text of a file, or None for a binary file.
fn read_text(p: &Path) -> Result<Option<String>, String> {
    let b = fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
    Ok(if b.contains(&0) { None } else { Some(String::from_utf8_lossy(&b).into_owned()) })
}

fn pointer(k: &Key) -> String {
    let src = if k.tag == "X-ALL" { "X-ALL.TXT".to_string() } else { k.tag.clone() };
    if k.nth == 0 { format!("[{src} line {}]", k.line) } else { format!("[{src} line {} #{}]", k.line, k.nth) }
}

fn lua_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn name(p: &Path) -> String {
    p.file_name().unwrap().to_string_lossy().into_owned()
}

/// Returns (split, per-file) after verifying; templates by file name.
fn split_all(src: &Path, orig: &OrigSet, leak_check: bool) -> Result<(Vec<(String, String, String)>, usize, usize), String> {
    let mut res = Vec::new();
    let mut bad = false;
    let (mut keyed, mut port) = (0, 0);
    for f in files_in(src)? {
        let text = fs::read_to_string(&f).map_err(|e| format!("{}: {e}", f.display()))?;
        let (tpl, rep) = split_text(&text, orig);
        for (l, t, why) in &rep.problems {
            eprintln!("UNMATCHED {}:{l}: {t:?}: {why}", name(&f));
            bad = true;
        }
        for (l, t) in &rep.port_only {
            println!("port-only {}:{l}: {t:?}", name(&f));
        }
        for (l, h) in leaks_in_text(&tpl, orig).into_iter().filter(|_| leak_check) {
            eprintln!("LEAK in template of {}:{l}: original string {h:?} would be published", name(&f));
            bad = true;
        }
        keyed += rep.keyed;
        port += rep.port_only.len();
        if fill_text(&tpl, orig).map_err(|e| e.join("; "))? != text {
            eprintln!("ROUNDTRIP {} does not reproduce", name(&f));
            bad = true;
        }
        res.push((name(&f), text, tpl));
    }
    if bad { Err("split failed (see above); nothing written".into()) } else { Ok((res, keyed, port)) }
}

fn run(a: Args) -> Result<(), String> {
    match a.cmd {
        Cmd::Split { src, orig_json, out, allow } => {
            let o = load(&orig_json, &allow)?;
            let (files, keyed, port) = split_all(&src, &o, true)?;
            fs::create_dir_all(&out).map_err(|e| e.to_string())?;
            for (n, _, tpl) in &files {
                fs::write(out.join(n), tpl).map_err(|e| e.to_string())?;
            }
            println!("split: {} files, {keyed} keyed, {port} port-only", files.len());
        }
        Cmd::Fill { templates, orig_json, out } => {
            let o = load(&orig_json, &None)?;
            fs::create_dir_all(&out).map_err(|e| e.to_string())?;
            let mut n = 0;
            let mut bad = false;
            for f in files_in(&templates)? {
                let t = fs::read_to_string(&f).map_err(|e| e.to_string())?;
                match fill_text(&t, &o) {
                    Ok(s) => {
                        fs::write(out.join(name(&f)), s).map_err(|e| e.to_string())?;
                        n += 1;
                    }
                    Err(es) => {
                        bad = true;
                        for e in es {
                            eprintln!("{}: {e}", name(&f));
                        }
                    }
                }
            }
            if bad {
                return Err("fill failed".into());
            }
            println!("fill: {n} files");
        }
        Cmd::CheckPublic { templates, orig_json, also, list, allow, docs, categories, show_weak } => {
            let o = load_with(&orig_json, &allow, &categories)?;
            if docs {
                let paths = list_paths(&list, &also)?;
                let (mut n, mut hits) = (0, 0);
                for p in &paths {
                    let Some(t) = read_text(p)? else { continue };
                    n += 1;
                    if show_weak {
                        let flagged: Vec<usize> = doc_findings(&t, &o).iter().map(|f| f.hit.start).collect();
                        for h in message_hits(&t, &o).iter().filter(|h| !flagged.contains(&h.start)) {
                            eprintln!("weak {}:{}: short message string, key {}", p.display(), h.line, pointer(&h.key));
                        }
                    }
                    for f in doc_findings(&t, &o) {
                        let why = if f.kind == FindKind::Message { "message string" } else { "run of message strings" };
                        eprintln!("DOC LEAK {}:{}: {why}, key {}", p.display(), f.hit.line, pointer(&f.hit.key));
                        hits += 1;
                    }
                }
                if hits > 0 {
                    return Err(format!("check-public --docs FAILED: {hits} message string(s) quoted in {n} files (identifiers are allowed; message text is not)"));
                }
                println!("check-public --docs OK: {n} files, no running message text (identifiers allowed)");
                return Ok(());
            }
            let templates = templates.ok_or("check-public needs --templates (or --docs)")?;
            let mut paths = files_in(&templates)?;
            paths.extend(list_paths(&list, &also)?);
            let mut hits = 0;
            for p in &paths {
                let t = fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
                for (l, h) in leaks_in_text(&String::from_utf8_lossy(&t), &o) {
                    eprintln!("LEAK {}:{l}: {h:?}", p.display());
                    hits += 1;
                }
            }
            if hits > 0 {
                return Err(format!("check-public FAILED: {hits} leaked original string(s)"));
            }
            println!("check-public OK: {} files, no original string >= {MIN_LEAK_LEN} chars", paths.len());
        }
        Cmd::ExportLua { orig_json, out } => {
            let o = load(&orig_json, &None)?;
            let mut s = String::from(
                "-- GENERATED by `textsplit export-lua` from YOUR game_text.json. Gitignored: this is the original game's text.\n\
                 -- Keys are X-ALL:<line>[#n] (1-based source line, ordinal when a line holds several strings).\n\
                 return {\n",
            );
            let mut n = 0;
            for (tag, line, nth, raw) in o.entries() {
                let k = if nth == 0 { format!("{tag}:{line}") } else { format!("{tag}:{line}#{nth}") };
                s.push_str(&format!("  [{}] = {},\n", lua_str(&k), lua_str(raw)));
                n += 1;
            }
            s.push_str("}\n");
            fs::write(&out, s).map_err(|e| format!("{}: {e}", out.display()))?;
            println!("export-lua: {n} strings -> {}", out.display());
        }
        Cmd::Scrub { orig_json, list, allow, categories, apply } => {
            let o = load_with(&orig_json, &allow, &categories)?;
            let (mut files, mut total) = (0, 0);
            for p in list_paths(&Some(list), &[])? {
                let Some(t) = read_text(&p)? else { continue };
                let fs_ = doc_findings(&t, &o);
                if fs_.is_empty() {
                    continue;
                }
                let mut out = String::new();
                let mut at = 0;
                for f in &fs_ {
                    let (mut a, mut b) = (f.hit.start, f.hit.end);
                    let by = t.as_bytes();
                    if a > 0 && b < by.len() && by[a - 1] == by[b] && matches!(by[b], b'"' | b'\'' | b'`') {
                        a -= 1;
                        b += 1;
                    }
                    if a < at {
                        continue;
                    }
                    out.push_str(&t[at..a]);
                    out.push_str(&pointer(&f.hit.key));
                    at = b;
                }
                out.push_str(&t[at..]);
                println!("{}: {} replacement(s)", p.display(), fs_.len());
                files += 1;
                total += fs_.len();
                if apply {
                    fs::write(&p, out).map_err(|e| format!("{}: {e}", p.display()))?;
                }
            }
            println!("scrub{}: {total} replacement(s) in {files} file(s)", if apply { "" } else { " (dry run; --apply to write)" });
        }
        Cmd::Roundtrip { src, orig_json, allow, no_leak_check } => {
            let o = load(&orig_json, &allow)?;
            let (files, keyed, port) = split_all(&src, &o, !no_leak_check)?;
            println!("roundtrip OK: {} files, {keyed} keyed + {port} port-only strings, byte-identical", files.len());
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("textsplit: {e}");
            ExitCode::FAILURE
        }
    }
}
