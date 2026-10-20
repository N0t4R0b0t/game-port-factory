//! `gpfdiff watch <port-dir>`: the address-discovery tool for an original that exports nothing.
//! Boot the program (through `[boot]` and its ready gate if the manifest has them), tap the scripted keys,
//! and print every RAM change in a region by frame: press a key, see which bytes move.
//!
//! The raw material is "byte X changed from a to b in frame F". Printed as is it would be unreadable (a
//! frame counter alone is one line per frame), so [`condense`] does two things, both lossless about
//! WHICH addresses moved and WHEN:
//!
//! * adjacent bytes that changed in the same frame are one **group** (a 16-bit counter, a position);
//! * the same group changing in (nearly) consecutive frames is one **burst**: first frame..last frame, the value
//!   before the first change and after the last, and how many frames it changed in.

use crate::check::{self, Overrides};
use crate::errors;
use crate::keys::{self, frame_to_ms};
use crate::keysrun::{self, Change};
use crate::manifest::InputMode;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::PathBuf;

/// A burst continues across at most one quiet frame (a 50 Hz simulation on a 60 Hz frame clock skips one in six).
pub const MAX_GAP: u32 = 2;
/// Lines printed before the rest is summarised (narrow `--region` instead).
pub const DEFAULT_MAX_LINES: usize = 200;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Burst {
    pub first: u32,
    pub last: u32,
    pub addr: u16,
    pub old: Vec<u8>,
    pub new: Vec<u8>,
    /// Number of frames the group changed in.
    pub frames: u32,
}

/// Group adjacent bytes within a frame, then merge repeats of the same group into bursts. Sorted by
/// (first frame, address).
pub fn condense(changes: &[Change], max_gap: u32) -> Vec<Burst> {
    // per frame: addr -> (old, new)
    let mut by_frame: BTreeMap<u32, BTreeMap<u16, (u8, u8)>> = BTreeMap::new();
    for c in changes {
        by_frame.entry(c.frame).or_default().insert(c.addr, (c.old, c.new));
    }
    let mut done: Vec<Burst> = vec![];
    let mut open: Vec<Burst> = vec![]; // keyed by (addr, len)
    for (frame, bytes) in &by_frame {
        // adjacent addresses -> groups
        let mut groups: Vec<(u16, Vec<u8>, Vec<u8>)> = vec![];
        for (a, (o, n)) in bytes {
            match groups.last_mut() {
                Some((ga, go, gn)) if *ga as usize + go.len() == *a as usize => {
                    go.push(*o);
                    gn.push(*n);
                }
                _ => groups.push((*a, vec![*o], vec![*n])),
            }
        }
        // close bursts that have been quiet too long
        let (still, ended): (Vec<Burst>, Vec<Burst>) = open.drain(..).partition(|b| frame - b.last <= max_gap);
        done.extend(ended);
        open = still;
        for (a, o, n) in groups {
            match open.iter_mut().find(|b| b.addr == a && b.old.len() == o.len()) {
                Some(b) => {
                    b.last = *frame;
                    b.new = n;
                    b.frames += 1;
                }
                None => open.push(Burst { first: *frame, last: *frame, addr: a, old: o, new: n, frames: 1 }),
            }
        }
    }
    done.extend(open);
    done.sort_by_key(|b| (b.first, b.addr));
    done
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect::<Vec<_>>().join(" ")
}

/// One printable line per burst: `frame ms addr old -> new`.
pub fn render_burst(b: &Burst, fps: u32) -> String {
    let (f, ms) = if b.first == b.last {
        (b.first.to_string(), format!("{}", frame_to_ms(b.first, fps)))
    } else {
        (format!("{}..{}", b.first, b.last), format!("{}..{}", frame_to_ms(b.first, fps), frame_to_ms(b.last, fps)))
    };
    let addr = if b.old.len() == 1 { format!("0x{:04X}", b.addr) } else { format!("0x{:04X}..0x{:04X}", b.addr, b.addr as usize + b.old.len() - 1) };
    let dec = if b.old.len() == 1 { format!("  ({} -> {})", b.old[0], b.new[0]) } else { String::new() };
    let note = if b.frames > 1 { format!("  x{} frames", b.frames) } else { String::new() };
    format!("{f:>9} {ms:>11}  {addr:<13}  {} -> {}{dec}{note}", hex(&b.old), hex(&b.new))
}

pub fn render(changes: &[Change], bulk: &[(u32, u32)], fps: u32, max_lines: usize) -> Vec<String> {
    let bursts = condense(changes, MAX_GAP);
    let mut out = vec![format!("{:>9} {:>11}  {:<13}  {}", "frame", "ms", "addr", "old -> new")];
    for b in bursts.iter().take(max_lines) {
        out.push(render_burst(b, fps));
    }
    if bursts.len() > max_lines {
        out.push(format!("... {} more lines not shown (narrow --region, or raise --max-lines)", bursts.len() - max_lines));
    }
    // bulk frames (too many changed bytes to list): consecutive ones are one line
    let mut i = 0;
    while i < bulk.len() {
        let mut j = i;
        while j + 1 < bulk.len() && bulk[j + 1].0 <= bulk[j].0 + 1 {
            j += 1;
        }
        let total: u32 = bulk[i..=j].iter().map(|b| b.1).sum();
        let (a, b) = (bulk[i].0, bulk[j].0);
        out.push(format!(
            "{:>9} {:>11}  bulk: more than 512 bytes changed per frame ({} in all), not listed; the region contains noise (screen?), narrow it",
            if a == b { a.to_string() } else { format!("{a}..{b}") },
            if a == b { frame_to_ms(a, fps).to_string() } else { format!("{}..{}", frame_to_ms(a, fps), frame_to_ms(b, fps)) },
            total
        ));
        i = j + 1;
    }
    let addrs: std::collections::BTreeSet<u16> = changes.iter().map(|c| c.addr).collect();
    let frames: std::collections::BTreeSet<u32> = changes.iter().map(|c| c.frame).collect();
    out.push(format!("{} byte changes at {} addresses in {} frames; {} lines", changes.len(), addrs.len(), frames.len(), bursts.len().min(max_lines)));
    out
}

// ---------------------------------------------------------------- the command

#[derive(Clone, Debug, Default)]
pub struct WatchArgs {
    pub port: PathBuf,
    pub manifest: Option<String>,
    /// `a:b` (inclusive). Default: the platform's RAM without the video buffer.
    pub region: Option<String>,
    pub keys: Option<String>,
    pub frames: Option<u32>,
    pub no_gate: bool,
    pub max_lines: Option<usize>,
    pub ov: Overrides,
}

fn parse_addr(s: &str) -> Result<u16, String> {
    let t = s.trim();
    let v = if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")).or_else(|| t.strip_prefix('$')) {
        u32::from_str_radix(h, 16)
    } else {
        t.parse::<u32>()
    };
    v.ok().filter(|v| *v <= 0xffff).map(|v| v as u16).ok_or_else(|| format!("invalid address `{s}` (use 0x1234, $1234 or decimal, 0..=0xffff)"))
}

pub fn parse_region(s: &str) -> Result<(u16, u16), String> {
    let (a, b) = s.split_once(':').ok_or_else(|| format!("invalid --region `{s}`: expected START:END, e.g. 0xF000:0xF0FF"))?;
    let (a, b) = (parse_addr(a).map_err(|e| format!("invalid --region: {e}"))?, parse_addr(b).map_err(|e| format!("invalid --region: {e}"))?);
    if a > b {
        return Err(format!("invalid --region `{s}`: START is after END"));
    }
    Ok((a, b))
}

/// The region watched when none is given: RAM without the video buffer (ZX screen $4000-$5AFF, CoCo text/PMODE below $0600).
pub fn default_region(platform: &str) -> (u16, u16) {
    if platform == "coco2" {
        (0x0600, 0x7FFF)
    } else {
        (0x5B00, 0xFFFF)
    }
}

pub fn run_watch(a: &WatchArgs, out: &mut dyn Write) -> u8 {
    let mut say = |s: &str| {
        let _ = writeln!(out, "{s}");
        let _ = out.flush();
    };
    let platform_of = |p: &str| p.to_string();
    let fail = |say: &mut dyn FnMut(&str), platform: &str, e: String| {
        say(&format!("ERROR: {}", errors::render(&e, platform, a.ov.debug)));
        errors::EXIT_ENV
    };
    let (m, dir) = match check::load_manifest(&a.port, a.manifest.as_deref()) {
        Ok(v) => v,
        Err(e) => return fail(&mut say, "", e),
    };
    let platform = platform_of(&m.platform);
    if m.input_mode != InputMode::Keys {
        return fail(
            &mut say,
            &platform,
            "invalid harness.toml: watch needs `[input] mode = \"keys\"` (it runs the program free, it cannot watch a parked cooperative target); use --manifest to name a keys-mode manifest".into(),
        );
    }
    let mut spec = match check::build_target(&m, &dir, &a.ov, 1) {
        Ok(s) => s,
        Err(e) => return fail(&mut say, &platform, e),
    };
    let mut kc = spec.keys.take().expect("keys mode has a keys config");
    if a.no_gate {
        kc.gate = None;
        kc.ready_keys.clear();
    }
    let region = match a.region.as_deref().map(parse_region).unwrap_or_else(|| Ok(default_region(&platform))) {
        Ok(r) => r,
        Err(e) => return fail(&mut say, &platform, e),
    };
    let presses = match keys::parse_key_script(a.keys.as_deref().unwrap_or("")).map_err(|e| format!("invalid --keys: {e}")) {
        Ok(p) => p,
        Err(e) => return fail(&mut say, &platform, e),
    };
    let frames = a.frames.unwrap_or(100);
    let plan = match keys::watch_plan(&kc, &presses, region, frames) {
        Ok(p) => p,
        Err(e) => return fail(&mut say, &platform, e),
    };
    let fps = kc.time.fps;
    let gate = match (&kc.gate, a.no_gate) {
        (Some(g), _) => format!("gate: {}", g.describe()),
        (None, true) => "gate: ignored (--no-gate), frame 0 = the first frame".into(),
        (None, false) => "no [boot] ready: frame 0 = the first frame".into(),
    };
    say(&format!(
        "gpfdiff watch {} ({platform}, region 0x{:04X}..0x{:04X}, {frames} frames = {} ms at {fps} fps; {gate})",
        a.port.display(),
        region.0,
        region.1,
        frame_to_ms(frames, fps)
    ));
    if !presses.is_empty() {
        say(&format!("keys: {}", a.keys.as_deref().unwrap_or("")));
    }
    let cfg = keysrun::mame_cfg(&platform, &spec.image, &spec.opts);
    let o = match keysrun::run(&cfg, &plan, kc.timeout_ms, fps) {
        Ok(o) => o,
        Err(e) => return fail(&mut say, &platform, e),
    };
    say(&format!("timeline starts at boot frame {} (the gate saw value {})", o.ready.0, o.ready.1));
    for l in render(&o.changes, &o.bulk, fps, a.max_lines.unwrap_or(DEFAULT_MAX_LINES)) {
        say(&l);
    }
    errors::EXIT_PASS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(frame: u32, addr: u16, old: u8, new: u8) -> Change {
        Change { frame, addr, old, new }
    }

    #[test]
    fn adjacent_bytes_in_one_frame_are_one_group() {
        let b = condense(&[c(3, 0xF000, 0, 1), c(3, 0xF001, 0, 2), c(3, 0xF010, 5, 6)], 2);
        assert_eq!(b.len(), 2);
        assert_eq!((b[0].addr, b[0].old.clone(), b[0].new.clone()), (0xF000, vec![0, 0], vec![1, 2]));
        assert_eq!((b[1].addr, b[1].old.len()), (0xF010, 1));
    }

    #[test]
    fn a_counter_changing_every_frame_is_one_burst() {
        let ch: Vec<Change> = (1..=20).map(|f| c(f, 0xF000, (f - 1) as u8, f as u8)).collect();
        let b = condense(&ch, 2);
        assert_eq!(b, vec![Burst { first: 1, last: 20, addr: 0xF000, old: vec![0], new: vec![20], frames: 20 }]);
    }

    #[test]
    fn a_quiet_gap_longer_than_max_gap_splits_the_burst() {
        // frames 1,2,3 then 6,7: the gap 3 -> 6 is 3 frames > 2
        let ch = [c(1, 9, 0, 1), c(2, 9, 1, 2), c(3, 9, 2, 3), c(6, 9, 3, 4), c(7, 9, 4, 5)];
        let b = condense(&ch, 2);
        assert_eq!(b.len(), 2);
        assert_eq!((b[0].first, b[0].last, b[0].frames, b[0].new.clone()), (1, 3, 3, vec![3]));
        assert_eq!((b[1].first, b[1].last, b[1].old.clone()), (6, 7, vec![3]));
        // one quiet frame (a 50 Hz sim on a 60 Hz clock) does not split
        let b = condense(&[c(1, 9, 0, 1), c(3, 9, 1, 2)], 2);
        assert_eq!(b.len(), 1);
    }

    #[test]
    fn different_groups_do_not_merge() {
        let b = condense(&[c(1, 0x10, 0, 1), c(2, 0x20, 0, 1), c(2, 0x10, 1, 2)], 2);
        assert_eq!(b.iter().map(|x| (x.addr, x.first, x.last)).collect::<Vec<_>>(), vec![(0x10, 1, 2), (0x20, 2, 2)]);
        // a group whose width changes (lo byte only, then lo+hi) is a different group
        let b = condense(&[c(1, 0x10, 0, 1), c(2, 0x10, 1, 2), c(2, 0x11, 0, 1)], 2);
        assert_eq!(b.len(), 2);
    }

    #[test]
    fn lines_show_frame_ms_addr_and_the_change() {
        let l = render_burst(&Burst { first: 7, last: 7, addr: 0xF006, old: vec![0x70], new: vec![0x6c], frames: 1 }, 50);
        assert!(l.contains("7") && l.contains("140") && l.contains("0xF006") && l.contains("70 -> 6c") && l.contains("(112 -> 108)"), "{l}");
        let l = render_burst(&Burst { first: 7, last: 9, addr: 0xF006, old: vec![0x70], new: vec![0x64], frames: 3 }, 50);
        assert!(l.contains("7..9") && l.contains("140..180") && l.contains("x3 frames"), "{l}");
        let l = render_burst(&Burst { first: 1, last: 1, addr: 0xF000, old: vec![0, 0], new: vec![1, 0], frames: 1 }, 50);
        assert!(l.contains("0xF000..0xF001") && l.contains("00 00 -> 01 00"), "{l}");
    }

    #[test]
    fn render_caps_lines_and_summarises_bulk_and_totals() {
        let ch: Vec<Change> = (0..10).map(|i| c(1, 0x100 + 2 * i, 0, 1)).collect();
        let out = render(&ch, &[(4, 600), (5, 700), (9, 800)], 50, 3);
        assert_eq!(out.len(), 1 + 3 + 1 + 2 + 1, "{out:#?}");
        assert!(out[4].contains("7 more lines not shown"), "{out:#?}");
        assert!(out[5].contains("4..5") && out[5].contains("1300 in all"), "{out:#?}");
        assert!(out[6].contains("bulk") && out[6].trim_start().starts_with("9"), "{out:#?}");
        assert!(out.last().unwrap().contains("10 byte changes at 10 addresses in 1 frames"), "{out:#?}");
    }

    #[test]
    fn regions_parse_hex_dollar_and_decimal() {
        assert_eq!(parse_region("0xF000:0xF0FF").unwrap(), (0xF000, 0xF0FF));
        assert_eq!(parse_region("$10:$20").unwrap(), (0x10, 0x20));
        assert_eq!(parse_region("100:200").unwrap(), (100, 200));
        for bad in ["F000", "0xF000:", "0x10000:0x10001", "5:1", "a:b"] {
            assert!(parse_region(bad).is_err(), "{bad}");
        }
        assert_eq!(default_region("zx48"), (0x5B00, 0xFFFF));
        assert_eq!(default_region("coco2"), (0x0600, 0x7FFF));
    }
}
