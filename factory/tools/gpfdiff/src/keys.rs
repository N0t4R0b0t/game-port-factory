//! Keys mode (`[input] mode = "keys"`): the pure logic. No emulator is involved here.
//!
//! The program under test is NOT parked and NOT modified. It runs on the emulator's own frame clock;
//! a Lua `frame_done` hook (`lua/gpf_keys.lua`) presses emulated keys and reads RAM at frames this module
//! computed from a millisecond timeline. This module owns:
//!
//! * the **time axis**: milliseconds -> frames per machine, with ONE rounding rule
//!   (nearest frame, halves up: `frame = (ms * fps + 500) / 1000`, integer arithmetic);
//! * **key names**: the names a manifest may use, per platform, and the text that finds the matching
//!   MAME input field (the proven mechanism of `keys_smoke.lua`: `ports[...]:fields[...]:set_value`);
//! * the **plan**: everything the Lua side needs, as a small line file (`Plan::to_text`);
//! * turning samples back into a trace through the field map.
//!
//! Frame semantics (derived empirically on Brickfall ZX, see README "Keys mode"): the timeline starts at the
//! hook where the ready gate first holds, that hook is frame 0. At the hook of frame `t` the harness FIRST reads the
//! samples scheduled for `t`, THEN applies the key state for `t`; the program's next frame (`t+1`) sees that
//! state. That is exactly the cooperative contract: the state at input point `i` is read, then `buttons_at(i)` drives
//! the step that produces `i+1`.

use crate::fields::FieldMap;
use crate::manifest::{Cond, Gate};
use crate::scenario::{round_div, Scenario};
use crate::trace::{Line, Trace};
use std::collections::HashMap;

/// A tap lasts this long unless `+HOLD` says otherwise (`ready_keys` and `watch --keys`).
pub const DEFAULT_HOLD_MS: u64 = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimeAxis {
    pub fps: u32,
    pub step_ms: u32,
}

/// Nominal frame rate per machine (`[time] fps` overrides): ZX 50, CoCo (NTSC) 60, C64 (PAL) 50.
pub fn default_fps(platform: &str) -> u32 {
    if platform == "coco2" {
        60
    } else {
        50
    }
}

/// Milliseconds to the nearest frame, halves up: `(ms*fps + 500) / 1000`.
pub fn ms_to_frame(ms: u64, fps: u32) -> u32 {
    ((ms * fps as u64 + 500) / 1000) as u32
}

/// A frame back to milliseconds (nearest).
pub fn frame_to_ms(frame: u32, fps: u32) -> u64 {
    round_div(frame as u64 * 1000, fps as u64)
}

// ---------------------------------------------------------------- key names

const ZX_SPECIAL: [(&str, &str); 4] = [("SPACE", "SPACE"), ("ENTER", "ENTER"), ("CAPSSHIFT", "CAPS SHIFT"), ("SYMSHIFT", "SYMBOL SHIFT")];
const COCO_SPECIAL: [(&str, &str); 15] = [
    ("SPACE", "SPACE"),
    ("ENTER", "ENTER"),
    ("CLEAR", "CLEAR"),
    ("BREAK", "BREAK"),
    ("SHIFT", "SHIFT"),
    ("LEFT", "LEFT"),
    ("RIGHT", "RIGHT"),
    ("UP", "UP"),
    ("DOWN", "DOWN"),
    ("COLON", ":"),
    ("SEMICOLON", ";"),
    ("COMMA", ","),
    ("MINUS", "-"),
    ("PERIOD", "."),
    ("SLASH", "/"),
];

/// The key names a manifest may use on `platform`, for error messages.
pub fn valid_names(platform: &str) -> String {
    match platform {
        "zx48" => "A-Z, 0-9, SPACE, ENTER, CAPSSHIFT, SYMSHIFT".into(),
        "coco2" => "A-Z, 0-9, SPACE, ENTER, CLEAR, BREAK, SHIFT, LEFT, RIGHT, UP, DOWN, COLON (:), SEMICOLON (;), COMMA (,), MINUS (-), PERIOD (.), SLASH (/), AT (@)".into(),
        _ => "(none: keys mode does not support this platform)".into(),
    }
}

/// The text that identifies the key's MAME input field: the whole field name, or its first word, matched
/// case-insensitively (`z` matches the ZX field `z    Z    :  LN ...`, `LEFT` the CoCo field `LEFT`).
pub fn resolve_key(platform: &str, name: &str) -> Result<String, String> {
    let up = name.trim().to_ascii_uppercase();
    let single = up.len() == 1 && up.chars().all(|c| c.is_ascii_alphanumeric());
    let found = match platform {
        "zx48" => {
            if single {
                Some(up.to_ascii_lowercase())
            } else {
                ZX_SPECIAL.iter().find(|(n, _)| *n == up).map(|(_, t)| t.to_string())
            }
        }
        "coco2" => {
            if single {
                Some(up.to_ascii_lowercase())
            } else if up == "AT" || up == "@" {
                Some("@".into())
            } else if matches!(up.as_str(), ":" | ";" | "," | "-" | "." | "/") {
                Some(up.clone())
            } else {
                COCO_SPECIAL.iter().find(|(n, _)| *n == up).map(|(_, t)| t.to_string())
            }
        }
        other => return Err(format!("keys mode does not support platform {other}")),
    };
    found.ok_or_else(|| format!("unknown key name `{}` for platform {platform}; valid names: {}", name.trim(), valid_names(platform)))
}

// ---------------------------------------------------------------- key scripts

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPress {
    /// Button name or key name, upper case.
    pub name: String,
    pub at_ms: u64,
    pub hold_ms: u64,
}

/// `500ms`, `1s`, `0.25s` or a bare number of milliseconds.
pub fn parse_time_ms(t: &str) -> Result<u64, String> {
    let t = t.trim();
    let bad = || format!("bad time `{t}` (use e.g. 500ms or 1.5s)");
    if let Some(s) = t.strip_suffix("ms") {
        return s.trim().parse::<u64>().map_err(|_| bad());
    }
    if let Some(s) = t.strip_suffix('s') {
        let f: f64 = s.trim().parse().map_err(|_| bad())?;
        if !(f.is_finite() && f >= 0.0) {
            return Err(bad());
        }
        return Ok((f * 1000.0).round() as u64);
    }
    t.parse::<u64>().map_err(|_| bad())
}

/// `RIGHT@500ms,FIRE@1000ms+250ms`: tap each key at a time for a hold (default 100 ms).
pub fn parse_key_script(s: &str) -> Result<Vec<KeyPress>, String> {
    let mut out = vec![];
    for tok in s.split(',').map(str::trim).filter(|t| !t.is_empty()) {
        let (name, rest) = tok.rsplit_once('@').ok_or_else(|| format!("`{tok}`: expected NAME@TIME[+HOLD], e.g. LEFT@500ms+1s"))?;
        if name.trim().is_empty() {
            return Err(format!("`{tok}`: missing key name before `@`"));
        }
        let (at, hold) = match rest.split_once('+') {
            Some((a, h)) => (parse_time_ms(a).map_err(|e| format!("`{tok}`: {e}"))?, parse_time_ms(h).map_err(|e| format!("`{tok}`: {e}"))?),
            None => (parse_time_ms(rest).map_err(|e| format!("`{tok}`: {e}"))?, DEFAULT_HOLD_MS),
        };
        out.push(KeyPress { name: name.trim().to_ascii_uppercase(), at_ms: at, hold_ms: hold });
    }
    Ok(out)
}

// ---------------------------------------------------------------- configuration and plan

/// Everything keys mode needs from a manifest, resolved.
#[derive(Clone, Debug)]
pub struct KeysCfg {
    pub platform: String,
    pub time: TimeAxis,
    pub latency: u32,
    /// Button name -> emulator key name (both upper case).
    pub keymap: Vec<(String, String)>,
    pub gate: Option<Gate>,
    pub ready_keys: Vec<String>,
    pub timeout_ms: u64,
    pub labels: HashMap<String, u16>,
}

impl KeysCfg {
    /// A button name, or else a raw key name of the platform, to the key name that is pressed.
    pub fn key_for(&self, button: &str) -> Result<String, String> {
        let up = button.to_ascii_uppercase();
        if let Some((_, k)) = self.keymap.iter().find(|(b, _)| *b == up) {
            return Ok(k.clone());
        }
        resolve_key(&self.platform, &up).map(|_| up.clone()).map_err(|e| {
            if matches!(up.as_str(), "LEFT" | "RIGHT" | "FIRE") {
                format!("button {up} has no key: add `{up} = \"<key>\"` to [input.keys] ({e})")
            } else {
                e
            }
        })
    }
}

/// What the Lua side runs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub platform: String,
    /// (key name, text that finds its MAME field), every key the plan presses.
    pub keymap: Vec<(String, String)>,
    /// (addr, len) read at every sample, concatenated in this order.
    pub regions: Vec<(u16, usize)>,
    pub samples: Vec<u32>,
    /// (frame, keys held from that frame's hook on).
    pub events: Vec<(u32, Vec<String>)>,
    /// (from, to, key): held at boot frames [from, to) while the gate is not yet satisfied.
    pub ready_keys: Vec<(u32, u32, String)>,
    pub gate: Option<Gate>,
    pub gate_timeout_frames: u32,
    /// Last timeline frame (the run ends after its hook).
    pub end: u32,
    /// watch: report every change inside this inclusive range instead of sampling.
    pub watch: Option<(u16, u16)>,
}

impl Plan {
    pub fn to_text(&self) -> String {
        let mut s = format!("P {}\n", self.platform);
        for (n, t) in &self.keymap {
            s.push_str(&format!("K {n} {t}\n"));
        }
        for (a, l) in &self.regions {
            s.push_str(&format!("R {a} {l}\n"));
        }
        for f in &self.samples {
            s.push_str(&format!("S {f}\n"));
        }
        for (f, keys) in &self.events {
            s.push_str(&format!("E {f} {}\n", if keys.is_empty() { "-".to_string() } else { keys.join(" ") }));
        }
        for (a, b, k) in &self.ready_keys {
            s.push_str(&format!("RK {a} {b} {k}\n"));
        }
        if let Some(g) = &self.gate {
            let (op, a, b) = match g.cond {
                Cond::Eq(a) => ("eq", a, 0),
                Cond::Ne(a) => ("ne", a, 0),
                Cond::In(a, b) => ("in", a, b),
            };
            s.push_str(&format!("G {} {} {} {op} {a} {b}\n", g.addr, g.size, if g.big_endian { "be" } else { "le" }));
        }
        s.push_str(&format!("GT {}\nEND {}\n", self.gate_timeout_frames, self.end));
        if let Some((a, b)) = self.watch {
            s.push_str(&format!("W {a} {b}\n"));
        }
        s
    }

    pub fn sample_bytes(&self) -> usize {
        self.regions.iter().map(|r| r.1).sum()
    }
}

/// Key state changes (frame, keys down) from presses (taps). A press ends no earlier than one frame after it
/// starts. `latency` frames are subtracted from every frame (see README: the program sees a key `latency` frames
/// after it was applied).
pub fn presses_to_events(presses: &[(String, u64, u64)], fps: u32, latency: u32) -> Result<Vec<(u32, Vec<String>)>, String> {
    let spans: Vec<(String, u32, u32)> = presses
        .iter()
        .map(|(k, at, hold)| {
            let a = ms_to_frame(*at, fps);
            (k.clone(), a, ms_to_frame(at + hold, fps).max(a + 1))
        })
        .collect();
    state_events(&spans, latency)
}

fn state_events(spans: &[(String, u32, u32)], latency: u32) -> Result<Vec<(u32, Vec<String>)>, String> {
    let mut bounds: Vec<u32> = spans.iter().flat_map(|s| [s.1, s.2]).collect();
    bounds.sort_unstable();
    bounds.dedup();
    let mut out = vec![];
    for f in bounds {
        let mut down: Vec<String> = vec![];
        for (k, a, b) in spans {
            if *a <= f && f < *b && !down.contains(k) {
                down.push(k.clone());
            }
        }
        down.sort();
        let at = f.checked_sub(latency).ok_or_else(|| {
            format!("a key change at frame {f} is earlier than input_latency_frames = {latency}: it would have to be applied before the timeline starts")
        })?;
        out.push((at, down));
    }
    Ok(out)
}

/// The key state per frame a step/ms scenario asks for.
pub fn scenario_events(sc: &Scenario, cfg: &KeysCfg) -> Result<Vec<(u32, Vec<String>)>, String> {
    let mut out: Vec<(u32, Vec<String>)> = vec![];
    for e in sc.ms_events() {
        let mut keys: Vec<String> = vec![];
        for (bit, name) in [(1u8, "LEFT"), (2, "RIGHT"), (4, "FIRE")] {
            if e.buttons & bit != 0 {
                keys.push(cfg.key_for(name)?);
            }
        }
        for n in &e.names {
            keys.push(cfg.key_for(n)?);
        }
        keys.sort();
        keys.dedup();
        let f = ms_to_frame(e.ms, cfg.time.fps);
        let at = f.checked_sub(cfg.latency).ok_or_else(|| {
            format!("invalid scenario: an input at {} ms (frame {f}) is earlier than input_latency_frames = {}", e.ms, cfg.latency)
        })?;
        match out.last_mut() {
            Some(last) if last.0 == at => last.1 = keys, // the later entry wins
            _ => out.push((at, keys)),
        }
    }
    Ok(out)
}

/// Sample frames of a scenario. Two samples on one frame would make the trace lie about its length.
pub fn scenario_samples(sc: &Scenario, fps: u32) -> Result<Vec<u32>, String> {
    let mut out: Vec<u32> = vec![];
    let mut prev_ms = 0;
    for ms in sc.sample_ms() {
        let f = ms_to_frame(ms, fps);
        if out.last() == Some(&f) {
            return Err(format!(
                "invalid scenario: the samples at {prev_ms} ms and {ms} ms both land on frame {f} at {fps} fps; sample_every is shorter than a frame"
            ));
        }
        out.push(f);
        prev_ms = ms;
    }
    Ok(out)
}

fn ready_key_spans(cfg: &KeysCfg) -> Result<Vec<(u32, u32, String)>, String> {
    let mut v = vec![];
    for rk in &cfg.ready_keys {
        for p in parse_key_script(rk)? {
            let from = ms_to_frame(p.at_ms, cfg.time.fps).max(1);
            let to = ms_to_frame(p.at_ms + p.hold_ms, cfg.time.fps).max(from + 1);
            v.push((from, to, cfg.key_for(&p.name)?));
        }
    }
    Ok(v)
}

fn keymap_for(cfg: &KeysCfg, events: &[(u32, Vec<String>)], ready: &[(u32, u32, String)]) -> Result<Vec<(String, String)>, String> {
    let mut names: Vec<String> = events.iter().flat_map(|e| e.1.iter().cloned()).chain(ready.iter().map(|r| r.2.clone())).collect();
    names.sort();
    names.dedup();
    names.into_iter().map(|n| resolve_key(&cfg.platform, &n).map(|t| (n, t))).collect()
}

fn base_plan(cfg: &KeysCfg) -> Plan {
    Plan {
        platform: cfg.platform.clone(),
        gate: cfg.gate,
        gate_timeout_frames: ms_to_frame(cfg.timeout_ms, cfg.time.fps).max(1),
        ..Plan::default()
    }
}

/// The plan for one scenario: `regions` are the byte ranges of the field map, in field order.
pub fn scenario_plan(cfg: &KeysCfg, sc: &Scenario, regions: Vec<(u16, usize)>) -> Result<Plan, String> {
    let mut p = base_plan(cfg);
    p.samples = scenario_samples(sc, cfg.time.fps)?;
    p.events = scenario_events(sc, cfg)?;
    p.ready_keys = ready_key_spans(cfg)?;
    p.keymap = keymap_for(cfg, &p.events, &p.ready_keys)?;
    p.regions = regions;
    p.end = ms_to_frame(sc.length_ms(), cfg.time.fps).max(p.samples.last().copied().unwrap_or(0));
    Ok(p)
}

/// The plan of `gpfdiff watch`: scripted taps, a region to observe, a number of frames.
pub fn watch_plan(cfg: &KeysCfg, presses: &[KeyPress], region: (u16, u16), frames: u32) -> Result<Plan, String> {
    let mut p = base_plan(cfg);
    let named: Vec<(String, u64, u64)> = presses.iter().map(|k| Ok((cfg.key_for(&k.name)?, k.at_ms, k.hold_ms))).collect::<Result<_, String>>()?;
    p.events = presses_to_events(&named, cfg.time.fps, cfg.latency)?;
    p.ready_keys = ready_key_spans(cfg)?;
    p.keymap = keymap_for(cfg, &p.events, &p.ready_keys)?;
    p.watch = Some(region);
    p.end = frames;
    Ok(p)
}

/// Decode what the Lua side read at the samples (`bytes` per sample, regions concatenated) into a trace.
pub fn samples_to_trace(map: &FieldMap, regions: &[(u16, usize)], samples: &[Vec<u8>]) -> Result<Trace, String> {
    let raw = crate::state::RawState { state: [0; crate::state::STATE_LEN], bricks: [0; crate::state::BRICKS_LEN] };
    let mut lines: Vec<Line> = vec![];
    for (i, s) in samples.iter().enumerate() {
        let mut next = 0usize;
        let mut off = 0usize;
        let line = map.read_line(&raw, &mut |a, n| {
            let (ra, rl) = *regions.get(next).ok_or("internal: more reads than regions")?;
            if (ra, rl) != (a, n) {
                return Err(format!("internal: field read ${a:04x}+{n} does not match region ${ra:04x}+{rl}"));
            }
            next += 1;
            let b = s.get(off..off + n).ok_or_else(|| format!("sample #{i} is too short"))?.to_vec();
            off += n;
            Ok(b)
        })?;
        lines.push(line);
    }
    Ok(Trace { columns: map.columns(), lines })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(platform: &str, fps: u32, latency: u32) -> KeysCfg {
        KeysCfg {
            platform: platform.into(),
            time: TimeAxis { fps, step_ms: 20 },
            latency,
            keymap: vec![("LEFT".into(), "Z".into()), ("RIGHT".into(), "X".into()), ("FIRE".into(), "SPACE".into())],
            gate: None,
            ready_keys: vec![],
            timeout_ms: 1000,
            labels: HashMap::new(),
        }
    }

    #[test]
    fn ms_to_frame_rounds_to_nearest_halves_up() {
        // 50 Hz: a step of 20 ms is exactly one frame
        assert_eq!((0..5).map(|n| ms_to_frame(n * 20, 50)).collect::<Vec<_>>(), vec![0, 1, 2, 3, 4]);
        assert_eq!(ms_to_frame(10, 50), 1); // 0.5 -> 1
        assert_eq!(ms_to_frame(9, 50), 0);
        assert_eq!(ms_to_frame(29, 50), 1);
        assert_eq!(ms_to_frame(30, 50), 2);
        // 60 Hz: 20 ms = 1.2 frames
        assert_eq!((0..6).map(|n| ms_to_frame(n * 20, 60)).collect::<Vec<_>>(), vec![0, 1, 2, 4, 5, 6]);
        assert_eq!(ms_to_frame(500, 60), 30);
        assert_eq!(ms_to_frame(1000, 50), 50);
        assert_eq!(frame_to_ms(30, 60), 500);
        assert_eq!(frame_to_ms(1, 60), 17);
        assert_eq!(frame_to_ms(7, 50), 140);
    }

    #[test]
    fn default_fps_per_machine() {
        assert_eq!((default_fps("zx48"), default_fps("coco2"), default_fps("c64")), (50, 60, 50));
    }

    #[test]
    fn key_names_resolve_per_platform_and_list_the_valid_ones() {
        assert_eq!(resolve_key("zx48", "z").unwrap(), "z");
        assert_eq!(resolve_key("zx48", "Space").unwrap(), "SPACE");
        assert_eq!(resolve_key("zx48", "0").unwrap(), "0");
        assert_eq!(resolve_key("zx48", "capsshift").unwrap(), "CAPS SHIFT");
        assert_eq!(resolve_key("coco2", "LEFT").unwrap(), "LEFT");
        assert_eq!(resolve_key("coco2", "x").unwrap(), "x");
        assert_eq!(resolve_key("coco2", "comma").unwrap(), ",");
        assert_eq!(resolve_key("coco2", "@").unwrap(), "@");
        let e = resolve_key("zx48", "LEFT").unwrap_err(); // the Spectrum has no cursor keys
        assert!(e.contains("unknown key name `LEFT`") && e.contains("valid names: A-Z, 0-9, SPACE, ENTER"), "{e}");
        assert!(resolve_key("zx48", "AA").is_err() && resolve_key("coco2", "FOO").unwrap_err().contains("CLEAR"));
        assert!(resolve_key("c64", "A").unwrap_err().contains("does not support platform c64"));
    }

    #[test]
    fn key_scripts_parse_times_and_holds() {
        let k = parse_key_script("RIGHT@500ms, fire@1s+250ms,A@0").unwrap();
        assert_eq!(
            k,
            vec![
                KeyPress { name: "RIGHT".into(), at_ms: 500, hold_ms: 100 },
                KeyPress { name: "FIRE".into(), at_ms: 1000, hold_ms: 250 },
                KeyPress { name: "A".into(), at_ms: 0, hold_ms: 100 },
            ]
        );
        assert_eq!(parse_key_script("").unwrap(), vec![]);
        assert_eq!(parse_key_script("LEFT@0.25s+1s").unwrap()[0], KeyPress { name: "LEFT".into(), at_ms: 250, hold_ms: 1000 });
        assert_eq!(parse_key_script("@@100ms").unwrap()[0].name, "@");
        for bad in ["LEFT", "LEFT@", "@100ms", "LEFT@x", "LEFT@10ms+", "LEFT@-5ms"] {
            assert!(parse_key_script(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn taps_become_state_changes_and_latency_shifts_them_earlier() {
        let p = vec![("Z".to_string(), 100u64, 200u64), ("SPACE".to_string(), 200, 20)];
        // 50 Hz: Z down frames [5, 15), SPACE [10, 11)
        assert_eq!(
            presses_to_events(&p, 50, 0).unwrap(),
            vec![(5, vec!["Z".to_string()]), (10, vec!["SPACE".to_string(), "Z".to_string()]), (11, vec!["Z".to_string()]), (15, vec![])]
        );
        assert_eq!(presses_to_events(&p, 50, 2).unwrap()[0].0, 3);
        let e = presses_to_events(&p, 50, 6).unwrap_err();
        assert!(e.contains("earlier than input_latency_frames = 6"), "{e}");
        // a hold shorter than a frame still lasts one frame
        assert_eq!(presses_to_events(&[("A".into(), 0, 1)], 50, 0).unwrap(), vec![(0, vec!["A".to_string()]), (1, vec![])]);
    }

    #[test]
    fn a_step_scenario_maps_one_to_one_at_50hz_and_by_rounding_at_60hz() {
        let sc = Scenario::parse("steps = 10\nsample_every = 5\n[[input]]\nstep = 0\nbuttons = 5\n[[input]]\nstep = 3\nbuttons = 0\n").unwrap();
        let c50 = cfg("zx48", 50, 0);
        assert_eq!(scenario_samples(&sc, 50).unwrap(), vec![0, 5, 10]);
        assert_eq!(scenario_events(&sc, &c50).unwrap(), vec![(0, vec!["SPACE".to_string(), "Z".to_string()]), (3, vec![])]);
        let c60 = cfg("coco2", 60, 0);
        assert_eq!(scenario_samples(&sc, 60).unwrap(), vec![0, 6, 12]);
        assert_eq!(scenario_events(&sc, &c60).unwrap()[1].0, 4); // 60 ms * 60 / 1000 = 3.6 -> 4
        // latency 1 applies every change one frame earlier; the first one cannot be
        let e = scenario_events(&sc, &cfg("zx48", 50, 1)).unwrap_err();
        assert!(e.contains("earlier than input_latency_frames = 1"), "{e}");
        let sc2 = Scenario::parse("steps = 10\n[[input]]\nstep = 2\nbuttons = 2\n").unwrap();
        assert_eq!(scenario_events(&sc2, &cfg("zx48", 50, 1)).unwrap(), vec![(1, vec!["X".to_string()])]);
    }

    #[test]
    fn samples_closer_than_a_frame_are_rejected() {
        let sc = Scenario::parse("length_ms = 100\nsample_every_ms = 5\n").unwrap();
        let e = scenario_samples(&sc, 50).unwrap_err();
        assert!(e.contains("shorter than a frame"), "{e}");
        let sc = Scenario::parse("length_ms = 100\nsample_every_ms = 20\n").unwrap();
        assert_eq!(scenario_samples(&sc, 50).unwrap(), vec![0, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn unmapped_buttons_and_unknown_names_are_errors_naming_the_fix() {
        let mut c = cfg("zx48", 50, 0);
        c.keymap.retain(|(b, _)| b != "FIRE");
        let sc = Scenario::parse("steps = 3\n[[input]]\nstep = 0\nbuttons = 4\n").unwrap();
        let e = scenario_events(&sc, &c).unwrap_err();
        assert!(e.contains("button FIRE has no key") && e.contains("[input.keys]"), "{e}");
        // an extra named key falls back to the platform's own key name
        let sc = Scenario::parse("steps = 3\n[[input]]\nstep = 0\npress = [\"q\"]\n").unwrap();
        assert_eq!(scenario_events(&sc, &c).unwrap(), vec![(0, vec!["Q".to_string()])]);
        let sc = Scenario::parse("steps = 3\n[[input]]\nstep = 0\npress = [\"nosuch\"]\n").unwrap();
        assert!(scenario_events(&sc, &c).unwrap_err().contains("unknown key name"));
    }

    #[test]
    fn plan_text_is_what_the_lua_side_reads() {
        let mut c = cfg("zx48", 50, 0);
        c.gate = Some(Gate { addr: 0xF046, size: 1, big_endian: false, cond: Cond::In(1, 254) });
        c.ready_keys = vec!["SPACE@50ms".into()];
        let sc = Scenario::parse("steps = 4\nsample_every = 2\n[[input]]\nstep = 1\nbuttons = 1\n").unwrap();
        let p = scenario_plan(&c, &sc, vec![(0xF000, 2), (0xF006, 1)]).unwrap();
        assert_eq!(
            p.to_text(),
            "P zx48\nK SPACE SPACE\nK Z z\nR 61440 2\nR 61446 1\nS 0\nS 2\nS 4\nE 1 Z\nRK 3 8 SPACE\nG 61510 1 le in 1 254\nGT 50\nEND 4\n"
        );
        assert_eq!(p.sample_bytes(), 3);
        // ne / eq gates and a watch region
        c.gate = Some(Gate { addr: 0x5C00, size: 2, big_endian: true, cond: Cond::Ne(0) });
        let w = watch_plan(&c, &parse_key_script("LEFT@0ms+1s").unwrap(), (0xF000, 0xF0FF), 60).unwrap();
        assert_eq!(w.to_text(), "P zx48\nK SPACE SPACE\nK Z z\nE 0 Z\nE 50 -\nRK 3 8 SPACE\nG 23552 2 be ne 0 0\nGT 50\nEND 60\nW 61440 61695\n");
    }

    #[test]
    fn samples_decode_through_the_field_map_in_region_order() {
        use crate::fields::{Field, Source};
        let f = |name: &str, a: u16, size: usize, hex: bool| Field {
            name: name.into(),
            source: Source::Addr(a),
            size,
            big_endian: false,
            signed: false,
            scale: 1.0,
            offset: 0.0,
            tolerance: 0.0,
            ignore: false,
            hex,
        };
        let map = FieldMap { fields: vec![f("step", 0xF000, 2, false), f("bricks", 0xF010, 3, true)] };
        let regions = vec![(0xF000, 2), (0xF010, 3)];
        let t = samples_to_trace(&map, &regions, &[vec![5, 1, 0xff, 0x0f, 0x00], vec![6, 0, 1, 2, 3]]).unwrap();
        assert_eq!(t.columns, vec!["step", "bricks"]);
        assert_eq!(t.lines.iter().map(|l| l.to_string()).collect::<Vec<_>>(), vec!["261 ff0f00", "6 010203"]);
        assert!(samples_to_trace(&map, &regions, &[vec![5, 1]]).unwrap_err().contains("too short"));
    }
}
