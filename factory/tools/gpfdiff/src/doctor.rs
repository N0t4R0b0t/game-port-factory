//! `gpfdiff doctor` and the pre-flight checks shared with `run`/`check`.
//!
//! Doctor never installs anything: it reports what is present and prints the exact
//! package command per OS for what is missing. The Spectrum ROM is the user's own and is
//! never distributed, so for it the remediation is "supply your own". The same holds
//! for the CoCo's `coco2b` romset (BASIC ROMs, also your own).

use crate::report::Style;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- PATH / ROM lookup

/// Find an executable: a name is searched on PATH, anything containing `/` is taken literally.
pub fn which(prog: &str) -> Option<PathBuf> {
    if prog.contains('/') {
        let p = PathBuf::from(prog);
        return p.is_file().then_some(p);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(prog)).find(|p| p.is_file())
}

/// Directories of a MAME-style rompath (`;`-separated, as MAME itself does).
fn rompath_dirs(rompath: &str) -> Vec<String> {
    rompath.split(';').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect()
}

/// Does `dir` hold the `machine` romset (`machine.zip`, or a `machine/` folder with files)?
pub fn romset_in(dir: &Path, machine: &str) -> bool {
    if dir.join(format!("{machine}.zip")).is_file() {
        return true;
    }
    let d = dir.join(machine);
    d.is_dir() && std::fs::read_dir(d).map(|mut r| r.next().is_some()).unwrap_or(false)
}

fn expand_home(p: &str, home: Option<&Path>) -> PathBuf {
    match (p.strip_prefix("~/"), home) {
        (Some(rest), Some(h)) => h.join(rest),
        _ => PathBuf::from(p),
    }
}

/// Decide the `-rompath` handed to MAME. Precedence: explicit flag, `$ZX_ROMPATH`,
/// harness.toml, then `~/.mame/roms`. Empty strings count as unset (the Makefiles pass
/// `--rompath ""` when they found nothing). Err = the "MAME romset ... not found" message
/// naming every directory searched.
#[cfg(test)]
pub fn resolve_rompath(
    explicit: Option<&str>,
    env: Option<&str>,
    manifest: Option<&str>,
    home: Option<&Path>,
    machine: &str,
) -> Result<String, String> {
    resolve_rompath_named(explicit, env, manifest, home, machine, "ZX_ROMPATH")
}

/// The environment variable that names the ROM directory for a MAME platform (`None`: no ROM needed).
pub fn rompath_env_var(platform: &str) -> Option<&'static str> {
    match platform {
        "zx48" => Some("ZX_ROMPATH"),
        "coco2" => Some("COCO_ROMPATH"),
        _ => None,
    }
}

/// [`resolve_rompath`] with the platform's own environment variable named in the messages.
pub fn resolve_rompath_named(
    explicit: Option<&str>,
    env: Option<&str>,
    manifest: Option<&str>,
    home: Option<&Path>,
    machine: &str,
    env_name: &str,
) -> Result<String, String> {
    let nonempty = |o: Option<&str>| o.map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    let default = home.map(|h| h.join(".mame/roms").to_string_lossy().to_string());
    // The first source that is set is THE choice: an explicit path that lacks the ROM
    // is an error, not a silent fall-through to another directory (that hides typos).
    let chosen = nonempty(explicit).or_else(|| nonempty(env)).or_else(|| nonempty(manifest)).or(default);
    let Some(c) = chosen else {
        return Err(format!(
            "MAME romset `{machine}` not found (searched: nothing, since no --rompath, ${env_name}, harness.toml rompath or home dir is set); the ROM is your own and is not distributed"
        ));
    };
    let dirs = rompath_dirs(&c);
    if dirs.iter().any(|d| romset_in(&expand_home(d, home), machine)) {
        return Ok(c);
    }
    Err(format!(
        "MAME romset `{machine}` not found (searched: {}); the ROM is your own and is not distributed",
        dirs.join(", ")
    ))
}

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

// ---------------------------------------------------------------- remediation

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Arch,
    Debian,
    Macos,
}

impl Os {
    pub const ALL: [Os; 3] = [Os::Arch, Os::Debian, Os::Macos];
    pub fn label(self) -> &'static str {
        match self {
            Os::Arch => "Arch",
            Os::Debian => "Debian/Ubuntu",
            Os::Macos => "macOS",
        }
    }
}

/// The install command for `tool` on `os`, or a short note when there is no package.
/// `None` = this tool is not a package (the ROM).
pub fn remediation(tool: &str, os: Os) -> Option<String> {
    let (arch, deb, brew): (&str, &str, &str) = match tool {
        "x64sc" | "c1541" => ("sudo pacman -S vice", "sudo apt install vice", "brew install vice"),
        "acme" => ("yay -S acme", "sudo apt install acme", "brew install acme"),
        "xvfb-run" => ("sudo pacman -S xorg-server-xvfb", "sudo apt install xvfb", ""),
        "mame" => ("sudo pacman -S mame", "sudo apt install mame", "brew install mame"),
        "sjasmplus" => ("yay -S sjasmplus", "sudo apt install sjasmplus", "brew install sjasmplus"),
        "lwasm" => ("sudo pacman -S lwtools", "sudo apt install lwtools", "build lwtools from source: http://lwtools.projects.l-w.ca/"),
        "cargo" => ("sudo pacman -S rust   (or rustup)", "sudo apt install cargo   (or rustup)", "brew install rust   (or rustup)"),
        "magick" => ("sudo pacman -S imagemagick", "sudo apt install imagemagick", "brew install imagemagick"),
        _ => return None,
    };
    let s = match os {
        Os::Arch => arch,
        Os::Debian => deb,
        Os::Macos => brew,
    };
    Some(if s.is_empty() {
        "no package; pass --xvfb never (the emulator window will open on your desktop)".to_string()
    } else {
        s.to_string()
    })
}

pub const ROM_REMEDIATION: &str = "supply your own: put spectrum.zip (MAME `spectrum` romset, one file spectrum.rom) in ~/.mame/roms, or set $ZX_ROMPATH / pass --rompath";
pub const COCO_ROM_REMEDIATION: &str = "supply your own: put coco2b.zip (MAME `coco2b` romset: bas13.rom + extbas11.rom) in ~/.mame/roms, or set $COCO_ROMPATH / pass --rompath";

// ---------------------------------------------------------------- checks

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Need {
    Required,
    Optional,
}

#[derive(Clone, Debug)]
pub struct Tool {
    pub id: &'static str,
    pub exe: &'static str,
    pub need: Need,
    pub why: &'static str,
    /// Arguments that print a version (None = just report the path).
    pub version_args: Option<&'static [&'static str]>,
}

pub fn platforms(sel: &str) -> Result<Vec<&'static str>, String> {
    match sel {
        "c64" => Ok(vec!["c64"]),
        "zx48" => Ok(vec!["zx48"]),
        "coco2" => Ok(vec!["coco2"]),
        "all" => Ok(vec!["c64", "zx48", "coco2"]),
        o => Err(format!("unknown platform `{o}` for doctor (c64, zx48, coco2 or all)")),
    }
}

/// The tool list for one section (`common`, `c64`, `zx48`).
pub fn tools_for(section: &str) -> Vec<Tool> {
    use Need::*;
    match section {
        "common" => vec![
            Tool { id: "cargo", exe: "cargo", need: Required, why: "builds gpfdiff itself", version_args: Some(&["--version"]) },
            Tool { id: "magick", exe: "magick", need: Optional, why: "only for `make shots` (zx48 screenshots)", version_args: Some(&["--version"]) },
        ],
        "c64" => vec![
            Tool { id: "x64sc", exe: "x64sc", need: Required, why: "the C64 emulator (VICE)", version_args: Some(&["--version"]) },
            Tool { id: "acme", exe: "acme", need: Required, why: "assembles the C64 port", version_args: Some(&["--version"]) },
            Tool { id: "xvfb-run", exe: "xvfb-run", need: Optional, why: "keeps x64sc off your desktop (without it a window opens)", version_args: None },
            Tool { id: "c1541", exe: "c1541", need: Optional, why: "only for building .d64 disk images", version_args: None },
        ],
        "zx48" => vec![
            Tool { id: "mame", exe: "mame", need: Required, why: "the ZX Spectrum emulator", version_args: Some(&["-version"]) },
            Tool { id: "sjasmplus", exe: "sjasmplus", need: Required, why: "assembles the ZX port", version_args: Some(&[]) },
        ],
        "coco2" => vec![
            Tool { id: "mame", exe: "mame", need: Required, why: "the CoCo 2 emulator (machine coco2b)", version_args: Some(&["-version"]) },
            Tool { id: "lwasm", exe: "lwasm", need: Required, why: "assembles the CoCo port (lwtools)", version_args: Some(&["--version"]) },
        ],
        _ => vec![],
    }
}

#[derive(Clone, Debug)]
pub struct Check {
    pub section: String,
    pub name: String,
    pub need: Need,
    pub why: String,
    /// `Some(detail)` = present.
    pub found: Option<String>,
    /// Remediation lines (empty when present).
    pub fix: Vec<String>,
}

impl Check {
    pub fn tag(&self) -> &'static str {
        match (&self.found, self.need) {
            (Some(_), _) => "OK",
            (None, Need::Required) => "MISSING",
            (None, Need::Optional) => "OPTIONAL",
        }
    }
}

/// Pure core: probe tools through `finder`/`version`, so tests can fake the machine.
pub fn run_checks(
    sections: &[&str],
    finder: &dyn Fn(&str) -> Option<PathBuf>,
    version: &dyn Fn(&Tool, &Path) -> Option<String>,
    roms: &[(&str, Result<String, String>)],
) -> Vec<Check> {
    let mut out = vec![];
    for sec in sections {
        for t in tools_for(sec) {
            let found = finder(t.exe).map(|p| {
                let v = version(&t, &p);
                match v {
                    Some(v) => format!("{v} ({})", p.display()),
                    None => p.display().to_string(),
                }
            });
            let fix = if found.is_none() {
                Os::ALL.iter().filter_map(|o| remediation(t.id, *o).map(|r| format!("{:<14} {r}", o.label()))).collect()
            } else {
                vec![]
            };
            out.push(Check { section: sec.to_string(), name: t.id.to_string(), need: t.need, why: t.why.to_string(), found, fix });
        }
        if let Some((_, r)) = roms.iter().find(|(s, _)| s == sec) {
            let (name, machine, why, fix) = if *sec == "coco2" {
                ("coco2b ROM", "coco2b", "MAME `coco2b` romset (your own; never distributed)", COCO_ROM_REMEDIATION)
            } else {
                ("spectrum ROM", "spectrum", "MAME `spectrum` romset (your own; never distributed)", ROM_REMEDIATION)
            };
            out.push(Check {
                section: sec.to_string(),
                name: name.into(),
                need: Need::Required,
                why: why.into(),
                found: r.as_ref().ok().map(|p| format!("{machine} romset under {p}")),
                fix: if r.is_err() { vec![fix.to_string()] } else { vec![] },
            });
        }
    }
    out
}

pub fn any_required_missing(checks: &[Check]) -> bool {
    checks.iter().any(|c| c.found.is_none() && c.need == Need::Required)
}

pub fn render_checklist(checks: &[Check], platform_sel: &str, st: &Style) -> String {
    let mut s = format!("gpfdiff doctor (platform: {platform_sel}); checks only, installs nothing\n");
    let mut sec = "";
    for c in checks {
        if c.section != sec {
            sec = &c.section;
            s.push_str(&format!("\n[{sec}]\n"));
        }
        let tag = format!("{:<8}", c.tag());
        let tag = match c.tag() {
            "OK" => st.green(&tag),
            "MISSING" => st.red(&tag),
            _ => st.yellow(&tag),
        };
        let detail = match &c.found {
            Some(d) => d.clone(),
            None => c.why.clone(),
        };
        s.push_str(&format!("  [{tag}] {:<13} {detail}\n", c.name));
        if c.found.is_none() {
            for f in &c.fix {
                s.push_str(&format!("             fix: {f}\n"));
            }
        }
    }
    let missing: Vec<&str> = checks.iter().filter(|c| c.found.is_none() && c.need == Need::Required).map(|c| c.name.as_str()).collect();
    if missing.is_empty() {
        s.push_str("\nall required prerequisites present\n");
    } else {
        s.push_str(&format!("\nMISSING required: {}\n", missing.join(", ")));
    }
    s
}

/// Run `exe args`, capture the first non-empty output line, give up after 5 s.
pub fn probe_version(exe: &Path, args: &[&str]) -> Option<String> {
    let mut c = Command::new(exe)
        .args(args)
        .env_remove("DISPLAY")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        match c.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = c.kill();
                let _ = c.wait();
                return None;
            }
        }
    }
    let o = c.wait_with_output().ok()?;
    let text = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    let mut line: String = line.chars().take(60).collect();
    if line.is_empty() {
        line = "?".into();
    }
    Some(line)
}

/// Entry point for `gpfdiff doctor`. Returns (report text, any required missing).
pub fn doctor(platform_sel: &str, rompath: Option<&str>, st: &Style) -> Result<(String, bool), String> {
    let plats = platforms(platform_sel)?;
    let mut sections: Vec<&str> = vec!["common"];
    sections.extend(plats.iter().copied());
    let home = home_dir();
    let mut roms: Vec<(&str, Result<String, String>)> = vec![];
    for (plat, machine) in [("zx48", "spectrum"), ("coco2", crate::coco::DEFAULT_MACHINE)] {
        if plats.contains(&plat) {
            let var = rompath_env_var(plat).unwrap_or("ZX_ROMPATH");
            let env = std::env::var(var).ok();
            roms.push((plat, resolve_rompath_named(rompath, env.as_deref(), None, home.as_deref(), machine, var)));
        }
    }
    let finder = |e: &str| which(e);
    let version = |t: &Tool, p: &Path| t.version_args.and_then(|a| probe_version(p, a));
    let checks = run_checks(&sections, &finder, &version, &roms);
    Ok((render_checklist(&checks, platform_sel, st), any_required_missing(&checks)))
}

// ---------------------------------------------------------------- pre-flight

/// What `run`/`check` verify before spawning anything. Err = an environment error with
/// a message `errors::classify` understands.
pub fn preflight_exe(platform: &str, x64sc: &str, mame: &str) -> Result<(), String> {
    let (exe, what) = if matches!(platform, "zx48" | "coco2") { (mame, "MAME") } else { (x64sc, "x64sc") };
    if which(exe).is_none() {
        return Err(format!("cannot start `{exe}` ({what}): not found on PATH"));
    }
    Ok(())
}

pub fn preflight_files(platform: &str, image: &Path, labels: &Path, required: &[String]) -> Result<(), String> {
    if !image.is_file() {
        return Err(format!("{}: no such file (image not built?)", image.display()));
    }
    let text = std::fs::read_to_string(labels).map_err(|e| format!("{}: {e} (symbol file not built?)", labels.display()))?;
    let have = match platform {
        "zx48" => crate::mame::parse_labels(&text),
        "coco2" => crate::coco::parse_labels(&text),
        _ => crate::c64::parse_labels(&text),
    };
    for l in required {
        if !have.contains_key(l.as_str()) {
            return Err(format!("label `{l}` missing from {}", labels.display()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gpfdiff_doctor_{}_{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn remediation_per_os() {
        assert_eq!(remediation("mame", Os::Arch).unwrap(), "sudo pacman -S mame");
        assert_eq!(remediation("mame", Os::Debian).unwrap(), "sudo apt install mame");
        assert_eq!(remediation("mame", Os::Macos).unwrap(), "brew install mame");
        assert_eq!(remediation("x64sc", Os::Debian).unwrap(), "sudo apt install vice");
        assert_eq!(remediation("sjasmplus", Os::Arch).unwrap(), "yay -S sjasmplus");
        assert!(remediation("xvfb-run", Os::Macos).unwrap().contains("--xvfb never"));
        assert!(remediation("spectrum ROM", Os::Arch).is_none());
    }

    #[test]
    fn missing_required_fails_missing_optional_does_not() {
        let none = |_: &str| None;
        let nov = |_: &Tool, _: &Path| None;
        let c = run_checks(&["common", "c64"], &none, &nov, &[]);
        assert!(any_required_missing(&c));
        let tag = |n: &str| c.iter().find(|c| c.name == n).unwrap().tag();
        assert_eq!(tag("cargo"), "MISSING");
        assert_eq!(tag("magick"), "OPTIONAL");
        assert_eq!(tag("xvfb-run"), "OPTIONAL");
        assert_eq!(tag("c1541"), "OPTIONAL");
        let x = c.iter().find(|c| c.name == "x64sc").unwrap();
        assert_eq!(x.fix.len(), 3);
        assert!(x.fix[0].starts_with("Arch") && x.fix[0].contains("pacman -S vice"));

        // only optional tools absent -> fine
        let all_but_optional = |e: &str| (!matches!(e, "magick" | "xvfb-run" | "c1541")).then(|| PathBuf::from(format!("/usr/bin/{e}")));
        let c = run_checks(&["common", "c64"], &all_but_optional, &nov, &[]);
        assert!(!any_required_missing(&c));
    }

    #[test]
    fn rom_is_required_for_zx48_and_remediation_is_supply_your_own() {
        let all = |e: &str| Some(PathBuf::from(format!("/usr/bin/{e}")));
        let nov = |_: &Tool, _: &Path| Some("v1".to_string());
        let c = run_checks(&["zx48"], &all, &nov, &[("zx48", Err("nope".into()))]);
        let r = c.iter().find(|c| c.name == "spectrum ROM").unwrap();
        assert_eq!(r.tag(), "MISSING");
        assert!(r.fix[0].contains("supply your own") && r.fix[0].contains("ZX_ROMPATH"));
        assert!(any_required_missing(&c));
        let c = run_checks(&["zx48"], &all, &nov, &[("zx48", Ok("/x".into()))]);
        assert!(!any_required_missing(&c));
        // c64 sections never mention the ROM
        assert!(run_checks(&["c64"], &all, &nov, &[("zx48", Err("x".into()))]).iter().all(|c| c.name != "spectrum ROM"));
    }

    #[test]
    fn coco2_needs_lwasm_mame_and_its_own_rom() {
        let none = |_: &str| None;
        let nov = |_: &Tool, _: &Path| None;
        let c = run_checks(&["coco2"], &none, &nov, &[("coco2", Err("nope".into()))]);
        let names: Vec<&str> = c.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["mame", "lwasm", "coco2b ROM"]);
        let l = c.iter().find(|c| c.name == "lwasm").unwrap();
        assert!(l.fix[0].contains("pacman -S lwtools") && l.fix[1].contains("apt install lwtools"), "{:?}", l.fix);
        let r = c.iter().find(|c| c.name == "coco2b ROM").unwrap();
        assert_eq!(r.tag(), "MISSING");
        assert!(r.fix[0].contains("supply your own") && r.fix[0].contains("COCO_ROMPATH") && r.fix[0].contains("coco2b"), "{:?}", r.fix);
        assert!(!r.fix[0].contains("ZX_ROMPATH"));
        // present everywhere -> nothing required missing; a zx48 section is not asked about the coco ROM
        let all = |e: &str| Some(PathBuf::from(format!("/usr/bin/{e}")));
        let c = run_checks(&["coco2"], &all, &nov, &[("coco2", Ok("/r".into()))]);
        assert!(!any_required_missing(&c));
        assert!(run_checks(&["zx48"], &all, &nov, &[("coco2", Err("x".into()))]).iter().all(|c| c.name != "coco2b ROM"));
    }

    #[test]
    fn coco_rompath_error_names_its_own_env_var() {
        let empty = tmp("coco_empty");
        let e = resolve_rompath_named(None, None, None, Some(&empty), "coco2b", "COCO_ROMPATH").unwrap_err();
        assert!(e.contains("romset `coco2b` not found"), "{e}");
        let e = resolve_rompath_named(None, None, None, None, "coco2b", "COCO_ROMPATH").unwrap_err();
        assert!(e.contains("$COCO_ROMPATH") && !e.contains("ZX_ROMPATH"), "{e}");
        // a folder-style romset (how ~/.mame/roms/coco2b is laid out here) counts
        let home = tmp("coco_home");
        std::fs::create_dir_all(home.join(".mame/roms/coco2b")).unwrap();
        std::fs::write(home.join(".mame/roms/coco2b/bas13.rom"), b"r").unwrap();
        assert!(resolve_rompath_named(None, None, None, Some(&home), "coco2b", "COCO_ROMPATH").unwrap().ends_with(".mame/roms"));
        assert_eq!(rompath_env_var("coco2"), Some("COCO_ROMPATH"));
        assert_eq!(rompath_env_var("c64"), None);
    }

    #[test]
    fn coco2_preflight_reads_lwasm_maps() {
        use crate::errors::{classify, Kind};
        let d = tmp("pfcoco");
        std::fs::write(d.join("a.bin"), b"x").unwrap();
        std::fs::write(d.join("a.map"), "Symbol: gpf_state (a.bin) = 1000\n").unwrap();
        assert!(preflight_files("coco2", &d.join("a.bin"), &d.join("a.map"), &["gpf_state".into()]).is_ok());
        let e = preflight_files("coco2", &d.join("a.bin"), &d.join("a.map"), &["gpf_input_ret".into()]).unwrap_err();
        assert_eq!(classify(&e), Kind::MissingLabel, "{e}");
        let e = preflight_exe("coco2", "x64sc", "/nonexistent/mame").unwrap_err();
        assert_eq!(classify(&e), Kind::EmulatorMissing, "{e}");
        assert!(e.contains("MAME"), "{e}");
    }

    #[test]
    fn checklist_renders_tags_and_fix_lines() {
        let none = |_: &str| None;
        let nov = |_: &Tool, _: &Path| None;
        let c = run_checks(&["common", "zx48"], &none, &nov, &[("zx48", Err("x".into()))]);
        let s = render_checklist(&c, "zx48", &Style { color: false });
        assert!(s.contains("[MISSING ] mame"), "{s}");
        assert!(s.contains("[OPTIONAL] magick"), "{s}");
        assert!(s.contains("fix: Debian/Ubuntu  sudo apt install mame"), "{s}");
        assert!(s.contains("MISSING required: cargo, mame, sjasmplus, spectrum ROM"), "{s}");
        assert!(!s.contains('\x1b'));
    }

    #[test]
    fn platform_selection() {
        assert_eq!(platforms("all").unwrap(), vec!["c64", "zx48", "coco2"]);
        assert_eq!(platforms("coco2").unwrap(), vec!["coco2"]);
        assert!(platforms("amiga").is_err());
    }

    #[test]
    fn rompath_precedence_and_search() {
        let home = tmp("home");
        let a = tmp("a");
        let b = tmp("b");
        std::fs::write(b.join("spectrum.zip"), b"z").unwrap();
        let (a_s, b_s) = (a.to_string_lossy().to_string(), b.to_string_lossy().to_string());
        // explicit wins and is returned verbatim
        assert_eq!(resolve_rompath(Some(&b_s), Some(&a_s), None, Some(&home), "spectrum").unwrap(), b_s);
        // empty explicit (Makefile passes "") falls to env
        assert_eq!(resolve_rompath(Some(""), Some(&b_s), None, Some(&home), "spectrum").unwrap(), b_s);
        // an explicit path WITHOUT the rom is an error, not a silent fallthrough
        let e = resolve_rompath(Some(&a_s), Some(&b_s), None, Some(&home), "spectrum").unwrap_err();
        assert!(e.contains("romset `spectrum` not found") && e.contains(&a_s), "{e}");
        // multi-dir rompath: any dir having it is enough
        let multi = format!("{a_s};{b_s}");
        assert_eq!(resolve_rompath(Some(&multi), None, None, None, "spectrum").unwrap(), multi);
        // manifest, then ~/.mame/roms
        assert_eq!(resolve_rompath(None, None, Some(&b_s), Some(&home), "spectrum").unwrap(), b_s);
        std::fs::create_dir_all(home.join(".mame/roms")).unwrap();
        std::fs::write(home.join(".mame/roms/spectrum.zip"), b"z").unwrap();
        assert!(resolve_rompath(None, None, None, Some(&home), "spectrum").unwrap().ends_with(".mame/roms"));
        // folder-style romset
        std::fs::create_dir_all(a.join("spectrum")).unwrap();
        std::fs::write(a.join("spectrum/spectrum.rom"), b"r").unwrap();
        assert!(romset_in(&a, "spectrum"));
        // nothing at all
        let e = resolve_rompath(None, None, None, Some(&tmp("empty")), "spectrum").unwrap_err();
        assert!(e.contains("not found") && e.contains("not distributed"), "{e}");
    }

    #[test]
    fn preflight_messages_classify_correctly() {
        use crate::errors::{classify, Kind};
        let e = preflight_exe("zx48", "x64sc", "/nonexistent/mame").unwrap_err();
        assert_eq!(classify(&e), Kind::EmulatorMissing, "{e}");
        let d = tmp("pf");
        let e = preflight_files("c64", &d.join("a.prg"), &d.join("a.vs"), &[]).unwrap_err();
        assert_eq!(classify(&e), Kind::MissingFile, "{e}");
        std::fs::write(d.join("a.prg"), b"x").unwrap();
        std::fs::write(d.join("a.vs"), "al C:c000 .gpf_state\n").unwrap();
        assert!(preflight_files("c64", &d.join("a.prg"), &d.join("a.vs"), &["gpf_state".into()]).is_ok());
        let e = preflight_files("c64", &d.join("a.prg"), &d.join("a.vs"), &["gpf_bricks".into()]).unwrap_err();
        assert_eq!(classify(&e), Kind::MissingLabel, "{e}");
    }
}
