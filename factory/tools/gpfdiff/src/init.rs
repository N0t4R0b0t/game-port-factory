//! `gpfdiff init-oracle`: scaffold a black-box (keys mode) oracle for a port's ORIGINAL.
//!
//! Writes four files into the port directory, all of which parse with the real parsers (the unit tests load
//! every one of them): `harness.toml` (heavily commented, TODO markers where only the user knows the value),
//! `expectations.toml`, `scenarios/example.toml` and `NEXT-STEPS.md`. Nothing is overwritten without `--force`.
//! The templates are text files in `templates/` with `@TOKEN@` placeholders.

use crate::errors::{EXIT_ENV, EXIT_PASS};
use crate::keys;
use std::io::Write;
use std::path::PathBuf;

const HARNESS: &str = include_str!("../templates/harness.toml.tmpl");
const EXPECTATIONS: &str = include_str!("../templates/expectations.toml.tmpl");
const EXAMPLE: &str = include_str!("../templates/example.toml.tmpl");
const NEXT_STEPS: &str = include_str!("../templates/NEXT-STEPS.md.tmpl");

#[derive(Clone, Debug, Default)]
pub struct InitArgs {
    pub port: PathBuf,
    pub platform: String,
    pub image: Option<String>,
    pub force: bool,
}

/// What differs per platform.
struct Plat {
    id: &'static str,
    machine: &'static str,
    rom_var: &'static str,
    fps: u32,
    image: &'static str,
    image_kind: &'static str,
    region: &'static str,
    keys: &'static [(&'static str, &'static str)],
}

fn plat(platform: &str) -> Result<Plat, String> {
    match platform {
        "zx48" => Ok(Plat {
            id: "zx48",
            machine: "spectrum",
            rom_var: "ZX_ROMPATH",
            fps: keys::default_fps("zx48"),
            image: "original.sna",
            image_kind: "a .sna snapshot of the game (MAME loads it with -snapshot)",
            region: "0x5B00:0xFFFF",
            keys: &[("LEFT", "O"), ("RIGHT", "P"), ("UP", "Q"), ("DOWN", "A"), ("FIRE", "SPACE"), ("START", "ENTER")],
        }),
        "coco2" => Ok(Plat {
            id: "coco2",
            machine: "coco2b",
            rom_var: "COCO_ROMPATH",
            fps: keys::default_fps("coco2"),
            image: "original.bin",
            image_kind: "a DECB .bin (the loader writes its segments into RAM and jumps to the entry)",
            region: "0x0600:0x7FFF",
            keys: &[("LEFT", "LEFT"), ("RIGHT", "RIGHT"), ("UP", "UP"), ("DOWN", "DOWN"), ("FIRE", "SPACE"), ("START", "ENTER")],
        }),
        "c64" => Err("keys mode is not supported on c64 (cooperative labels mode only); see README, \"Keys mode (black-box)\": the VICE backend has no keys driver, so an original on c64 cannot be driven black-box".into()),
        other => Err(format!("unknown platform `{other}` (keys mode supports zx48 and coco2)")),
    }
}

fn fill(tmpl: &str, p: &Plat, image: &str) -> String {
    let keys: String = p.keys.iter().map(|(b, k)| format!("{b:<5} = \"{k}\"\n")).collect::<String>().trim_end().to_string();
    tmpl.replace("@PLATFORM@", p.id)
        .replace("@MACHINE@", p.machine)
        .replace("@ROMVAR@", p.rom_var)
        .replace("@VALID_NAMES@", &keys::valid_names(p.id))
        .replace("@KEYS@", &keys)
        .replace("@FPS@", &p.fps.to_string())
        .replace("@IMAGE@", image)
        .replace("@IMAGE_KIND@", p.image_kind)
        .replace("@REGION@", p.region)
}

/// The files to write: (path relative to the port dir, contents).
pub fn files(platform: &str, image: Option<&str>) -> Result<Vec<(&'static str, String)>, String> {
    let p = plat(platform)?;
    let image = image.unwrap_or(p.image);
    if image.contains('"') || image.contains('\n') {
        return Err(format!("--image `{image}`: quotes and newlines are not allowed"));
    }
    Ok(vec![
        ("harness.toml", fill(HARNESS, &p, image)),
        ("expectations.toml", fill(EXPECTATIONS, &p, image)),
        ("scenarios/example.toml", fill(EXAMPLE, &p, image)),
        ("NEXT-STEPS.md", fill(NEXT_STEPS, &p, image)),
    ])
}

pub fn run_init(a: &InitArgs, out: &mut dyn Write) -> u8 {
    let mut say = |s: &str| {
        let _ = writeln!(out, "{s}");
    };
    let fs = match files(&a.platform, a.image.as_deref()) {
        Ok(f) => f,
        Err(e) => {
            say(&format!("ERROR: {e}"));
            return EXIT_ENV;
        }
    };
    let existing: Vec<&str> = fs.iter().map(|(n, _)| *n).filter(|n| a.port.join(n).exists()).collect();
    if !existing.is_empty() && !a.force {
        say(&format!("ERROR: refusing to overwrite {} existing file{} in {}:", existing.len(), if existing.len() == 1 { "" } else { "s" }, a.port.display()));
        for n in &existing {
            say(&format!("  {n}"));
        }
        say("  next: pass --force to replace them, or scaffold into another directory; nothing was written");
        return EXIT_ENV;
    }
    for (name, text) in &fs {
        let path = a.port.join(name);
        if let Some(dir) = path.parent() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                say(&format!("ERROR: {}: {e}", dir.display()));
                return EXIT_ENV;
            }
        }
        if let Err(e) = std::fs::write(&path, text) {
            say(&format!("ERROR: {}: {e}", path.display()));
            return EXIT_ENV;
        }
        say(&format!("{} {}", if existing.contains(name) { "overwrote" } else { "wrote    " }, path.display()));
    }
    let d = a.port.display();
    say(&format!("INIT-ORACLE OK: {} black-box oracle scaffold in {d} ({} files)", a.platform, fs.len()));
    say(&format!("  next: edit the TODOs in {d}/harness.toml, then read {d}/NEXT-STEPS.md"));
    say(&format!("        gpfdiff check {d} --list      (the scaffold already parses)"));
    say(&format!("        gpfdiff watch {d} --keys \"LEFT@0ms+1s\" --no-gate      (find the state addresses)"));
    EXIT_PASS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{InputMode, Manifest, StateSource};
    use crate::scenario::Scenario;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gpfdiff_init_{}_{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn run(a: &InitArgs) -> (u8, String) {
        let mut buf: Vec<u8> = vec![];
        let c = run_init(a, &mut buf);
        (c, String::from_utf8(buf).unwrap())
    }

    /// Delete the `#> ` prefix of the example lines: they must be valid when made live.
    fn uncomment(text: &str) -> String {
        text.lines().map(|l| l.strip_prefix("#>").map(|r| r.strip_prefix(' ').unwrap_or(r)).unwrap_or(l)).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn every_generated_file_parses_with_the_real_parsers() {
        for platform in ["zx48", "coco2"] {
            let fs = files(platform, None).unwrap();
            let get = |n: &str| fs.iter().find(|(k, _)| *k == n).unwrap().1.clone();
            let m = Manifest::parse(&get("harness.toml")).unwrap_or_else(|e| panic!("{platform}: {e}"));
            assert_eq!(m.platform, platform);
            assert_eq!(m.input_mode, InputMode::Keys);
            assert_eq!(m.state_source, StateSource::Map);
            assert_eq!(m.fields.len(), 4);
            assert!(m.input_keys.iter().any(|(b, _)| b == "FIRE") && m.input_keys.iter().any(|(b, _)| b == "LEFT"));
            assert_eq!(m.time.fps, Some(keys::default_fps(platform)));
            assert!(m.boot.ready.is_none(), "the gate is a TODO, not a guess");
            assert_eq!(m.recipe.as_deref(), Some("."));
            let sc = Scenario::parse(&get("scenarios/example.toml")).unwrap();
            assert_eq!((sc.length_ms(), sc.sample_every_ms()), (3000, 100));
            assert!(sc.entries.len() >= 3);
            assert_eq!(crate::expect::parse(&get("expectations.toml")).unwrap(), vec![]);
            assert!(get("NEXT-STEPS.md").contains("gpfdiff watch") && get("NEXT-STEPS.md").contains("gpfdiff capture"));
            for (n, t) in &fs {
                for tok in ["@PLATFORM@", "@MACHINE@", "@ROMVAR@", "@VALID_NAMES@", "@KEYS@", "@FPS@", "@IMAGE@", "@IMAGE_KIND@", "@REGION@"] {
                    assert!(!t.contains(tok), "{n}: unreplaced {tok}");
                }
            }
        }
    }

    #[test]
    fn the_commented_examples_are_valid_when_made_live() {
        for platform in ["zx48", "coco2"] {
            let fs = files(platform, None).unwrap();
            let h = uncomment(&fs.iter().find(|(k, _)| *k == "harness.toml").unwrap().1);
            let m = Manifest::parse(&h).unwrap_or_else(|e| panic!("{platform}: {e}"));
            assert!(m.boot.ready.is_some() && !m.boot.ready_keys.is_empty());
            assert_eq!(m.fields.len(), 7);
            assert!(matches!(m.oracle, crate::manifest::OracleSource::Trace { .. }));
            let e = uncomment(&fs.iter().find(|(k, _)| *k == "expectations.toml").unwrap().1);
            let devs = crate::expect::parse(&e).unwrap();
            assert_eq!(devs.len(), 1);
            assert_eq!(devs[0].axis, "x");
        }
    }

    #[test]
    fn the_key_defaults_are_names_the_platform_knows() {
        for platform in ["zx48", "coco2"] {
            for (b, k) in plat(platform).unwrap().keys {
                assert!(keys::resolve_key(platform, k).is_ok(), "{platform}: {b} = {k}");
            }
        }
    }

    #[test]
    fn scaffolds_then_check_list_works_on_it() {
        let d = tmp("list");
        let (code, out) = run(&InitArgs { port: d.clone(), platform: "zx48".into(), image: Some("../target/x.sna".into()), force: false });
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("INIT-ORACLE OK") && out.contains("harness.toml") && out.contains("NEXT-STEPS.md"), "{out}");
        let m = Manifest::parse(&std::fs::read_to_string(d.join("harness.toml")).unwrap()).unwrap();
        assert_eq!(m.image, "../target/x.sna");
        let mut buf: Vec<u8> = vec![];
        let code = crate::check::run_check(&crate::check::CheckArgs { port: d.clone(), list: true, ..Default::default() }, &mut buf);
        assert_eq!(code, 0, "{}", String::from_utf8_lossy(&buf));
        assert_eq!(String::from_utf8(buf).unwrap(), "example  (150 steps)\n");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn refuses_to_overwrite_without_force_and_lists_the_files() {
        let d = tmp("force");
        let a = InitArgs { port: d.clone(), platform: "coco2".into(), image: None, force: false };
        assert_eq!(run(&a).0, 0);
        std::fs::write(d.join("harness.toml"), "mine").unwrap();
        let (code, out) = run(&a);
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("refusing to overwrite 4 existing files") && out.contains("harness.toml") && out.contains("scenarios/example.toml") && out.contains("--force"), "{out}");
        assert_eq!(std::fs::read_to_string(d.join("harness.toml")).unwrap(), "mine");
        let (code, out) = run(&InitArgs { force: true, ..a });
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("overwrote") && std::fs::read_to_string(d.join("harness.toml")).unwrap().contains("coco2b"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_partial_clash_writes_nothing() {
        let d = tmp("partial");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("NEXT-STEPS.md"), "mine").unwrap();
        let (code, out) = run(&InitArgs { port: d.clone(), platform: "zx48".into(), image: None, force: false });
        assert_eq!(code, 2, "{out}");
        assert!(out.contains("refusing to overwrite 1 existing file ") && out.contains("NEXT-STEPS.md"), "{out}");
        assert!(!d.join("harness.toml").exists() && !d.join("scenarios").exists());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn c64_and_unknown_platforms_are_exit_2_and_write_nothing() {
        let d = tmp("c64");
        let (code, out) = run(&InitArgs { port: d.clone(), platform: "c64".into(), image: None, force: false });
        assert_eq!(code, 2);
        assert!(out.contains("keys mode is not supported on c64 (cooperative labels mode only); see README"), "{out}");
        let (code, out) = run(&InitArgs { port: d.clone(), platform: "amiga".into(), image: None, force: false });
        assert_eq!(code, 2);
        assert!(out.contains("unknown platform `amiga`"), "{out}");
        assert!(!d.exists());
    }

    #[test]
    fn a_hostile_image_name_is_rejected() {
        assert!(files("zx48", Some("a\"b")).is_err());
    }
}
