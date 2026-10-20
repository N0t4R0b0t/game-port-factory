//! `harness.toml`: the per-port declaration `gpfdiff check <port-dir>` runs from.
//!
//! A deliberately tiny TOML subset (no serde in the dependency tree): top-level
//! `key = value` lines, the tables `[emulator]`, `[state]`, `[oracle]` and any number of
//! `[[field]]` entries; values are `"strings"`, integers (decimal, `0x..`, `$..`), floats,
//! `true`/`false` or `["string", "arrays"]`. Unknown keys are errors (typo protection).
//! Relative paths are relative to the directory holding the manifest.

use std::path::{Path, PathBuf};

pub const DEFAULT_REQUIRED_LABELS: [&str; 3] = ["gpf_state", "gpf_bricks", "gpf_input_ret"];

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Emulator {
    pub x64sc: Option<String>,
    pub xvfb: Option<String>,
    pub mame: Option<String>,
    pub machine: Option<String>,
    pub rompath: Option<String>,
}

/// Where a `[[field]]` is read from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FieldSrc {
    Addr(u16),
    Label(String),
}

/// One `[[field]]` entry (`[state] source = "map"`).
#[derive(Clone, Debug, PartialEq)]
pub struct FieldDef {
    pub name: String,
    pub src: FieldSrc,
    pub size: usize,
    pub big_endian: bool,
    pub signed: bool,
    pub scale: f64,
    pub offset: f64,
    pub tolerance: f64,
    pub ignore: bool,
    /// `format = "hex"`: the bytes in memory order as lower-case hex text (e.g. a brick bitmap), compared as text.
    pub hex: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StateSource {
    /// The built-in 11 Brickfall columns from `gpf_state` / `gpf_bricks`.
    Labels,
    /// `[[field]]` entries.
    Map,
}

/// Where the expected trace of `check` comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OracleSource {
    /// `<recipe>/golden/NAME.trace` (default).
    Recipe,
    /// `<dir>/NAME.trace`: traces recorded with `gpfdiff capture`.
    Trace { dir: String },
    /// Run another port's own harness on the same scenario and diff the two.
    Live { port: String, manifest: Option<String> },
}

/// How the program is driven: parked at `gpf_input_ret` (cooperative, the default) or by injected keys on a frame clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputMode {
    Breakpoint,
    Keys,
}

/// The condition of a `[boot] ready` gate on the value read at `addr`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cond {
    Eq(i64),
    Ne(i64),
    In(i64, i64),
}

/// `[boot] ready = { addr = 0x5C00, size = 1, endian = "le", eq | ne | in = [lo, hi] }`: the observed state that says
/// the program really started. The timeline begins at the first frame where it holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Gate {
    pub addr: u16,
    pub size: usize,
    pub big_endian: bool,
    pub cond: Cond,
}

impl Gate {
    /// Does the observed (unsigned) value satisfy the gate?
    pub fn holds(&self, v: u64) -> bool {
        let v = v as i64;
        match self.cond {
            Cond::Eq(a) => v == a,
            Cond::Ne(a) => v != a,
            Cond::In(lo, hi) => v >= lo && v <= hi,
        }
    }

    pub fn describe(&self) -> String {
        let c = match self.cond {
            Cond::Eq(a) => format!("== {a}"),
            Cond::Ne(a) => format!("!= {a}"),
            Cond::In(lo, hi) => format!("in [{lo}, {hi}]"),
        };
        format!("{} byte{} at ${:04X} {c}", self.size, if self.size == 1 { "" } else { "s" }, self.addr)
    }
}

pub const DEFAULT_BOOT_TIMEOUT_MS: u64 = 20000;

/// `[boot]` (keys mode).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Boot {
    pub ready: Option<Gate>,
    /// `NAME@50ms[+100ms]`: keys tapped (from the start of the boot clock) until the gate holds, e.g. to dismiss a title screen.
    pub ready_keys: Vec<String>,
    pub timeout_ms: u64,
}

/// `[time]`: the frame rate used to convert milliseconds to frames, the length of a scenario step, and the
/// fixed number of frames the program takes to see a key that was applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimeCfg {
    pub fps: Option<u32>,
    pub step_ms: u32,
    pub input_latency_frames: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Manifest {
    pub platform: String,
    pub image: String,
    /// Symbol file. Required in breakpoint mode; optional in keys mode (only `[[field]] label = ...` needs it).
    pub labels: Option<String>,
    /// Scenario/golden directory. Optional only so a discovery-only manifest (`watch`) can omit it.
    pub recipe: Option<String>,
    pub input_mode: InputMode,
    /// `[input.keys]`: button name -> emulator key name (upper case).
    pub input_keys: Vec<(String, String)>,
    pub boot: Boot,
    pub time: TimeCfg,
    pub repeat: Option<u32>,
    pub timeout: Option<u64>,
    pub required_labels: Vec<String>,
    pub emulator: Emulator,
    pub state_source: StateSource,
    pub fields: Vec<FieldDef>,
    pub oracle: OracleSource,
    /// `expectations = "path"`; default `expectations.toml` next to the manifest (optional file).
    pub expectations: Option<String>,
}

/// Remove a `#` comment, ignoring `#` inside a quoted string.
pub(crate) fn strip_comment(line: &str) -> &str {
    let mut in_str = false;
    let mut esc = false;
    for (i, c) in line.char_indices() {
        match c {
            '\\' if in_str => esc = !esc,
            '"' if !esc => in_str = !in_str,
            '#' if !in_str => return &line[..i],
            _ => esc = false,
        }
    }
    line
}

pub(crate) fn parse_string(v: &str) -> Result<String, String> {
    let v = v.trim();
    let inner = v
        .strip_prefix('"')
        .and_then(|r| r.strip_suffix('"'))
        .ok_or_else(|| format!("expected a \"quoted string\", got `{v}`"))?;
    let mut out = String::new();
    let mut it = inner.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                other => return Err(format!("unsupported escape `\\{}`", other.unwrap_or(' '))),
            }
        } else {
            out.push(c);
        }
    }
    Ok(out)
}

pub(crate) fn parse_string_array(v: &str) -> Result<Vec<String>, String> {
    let v = v.trim();
    let inner = v
        .strip_prefix('[')
        .and_then(|r| r.strip_suffix(']'))
        .ok_or_else(|| format!("expected [\"a\", \"b\"], got `{v}`"))?;
    let mut out = vec![];
    for part in inner.split(',') {
        let p = part.trim();
        if !p.is_empty() {
            out.push(parse_string(p)?);
        }
    }
    Ok(out)
}

fn parse_int(v: &str) -> Result<i64, String> {
    let t = v.trim();
    let (neg, t) = match t.strip_prefix('-') {
        Some(r) => (true, r),
        None => (false, t),
    };
    let r = if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")).or_else(|| t.strip_prefix('$')) {
        i64::from_str_radix(h, 16)
    } else {
        t.parse::<i64>()
    };
    r.map(|n| if neg { -n } else { n }).map_err(|_| format!("expected an integer (decimal, 0x.. or $..), got `{v}`"))
}

fn parse_float(v: &str) -> Result<f64, String> {
    v.trim().parse::<f64>().ok().filter(|f| f.is_finite()).ok_or_else(|| format!("expected a number, got `{v}`"))
}

fn parse_bool(v: &str) -> Result<bool, String> {
    match v.trim() {
        "true" => Ok(true),
        "false" => Ok(false),
        o => Err(format!("expected true or false, got `{o}`")),
    }
}

/// A `[[field]]` being read.
#[derive(Default)]
struct FieldB {
    line: usize,
    name: Option<String>,
    addr: Option<u16>,
    label: Option<String>,
    size: Option<usize>,
    big_endian: bool,
    signed: bool,
    scale: Option<f64>,
    offset: f64,
    tolerance: f64,
    ignore: bool,
    hex: bool,
}

impl FieldB {
    fn finish(self) -> Result<FieldDef, String> {
        let at = |e: String| format!("line {}: [[field]] {e}", self.line);
        let name = self.name.clone().ok_or_else(|| at("is missing `name`".into()))?;
        let src = match (self.addr, self.label.clone()) {
            (Some(a), None) => FieldSrc::Addr(a),
            (None, Some(l)) => FieldSrc::Label(l),
            _ => return Err(at(format!("`{name}` needs exactly one of `addr` or `label`"))),
        };
        let size = self.size.unwrap_or(1);
        if self.hex {
            if !(1..=32).contains(&size) {
                return Err(at(format!("`{name}`: a hex field needs size 1..=32, got {size}")));
            }
            if self.scale.is_some() || self.offset != 0.0 || self.signed || self.tolerance != 0.0 || self.big_endian {
                return Err(at(format!("`{name}`: format = \"hex\" prints raw bytes; scale, offset, signed, endian and tolerance do not apply")));
            }
        } else if !matches!(size, 1 | 2 | 4) {
            return Err(at(format!("`{name}`: size must be 1, 2 or 4, got {size} (or use format = \"hex\")")));
        }
        let scale = self.scale.unwrap_or(1.0);
        if scale == 0.0 {
            return Err(at(format!("`{name}`: scale 0 would make every value 0")));
        }
        if self.tolerance < 0.0 {
            return Err(at(format!("`{name}`: tolerance must be >= 0")));
        }
        Ok(FieldDef { name, src, size, big_endian: self.big_endian, signed: self.signed, scale, offset: self.offset, tolerance: self.tolerance, ignore: self.ignore, hex: self.hex })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Sect {
    Top,
    Emulator,
    State,
    Oracle,
    Field,
    Input,
    InputKeys,
    Time,
    Boot,
}

/// Split `a = 1, in = [2, 3]` at the commas outside brackets/quotes.
fn split_top(s: &str) -> Vec<String> {
    let (mut out, mut cur, mut depth, mut in_str) = (vec![], String::new(), 0i32, false);
    for c in s.chars() {
        match c {
            '"' => {
                in_str = !in_str;
                cur.push(c)
            }
            '[' if !in_str => {
                depth += 1;
                cur.push(c)
            }
            ']' if !in_str => {
                depth -= 1;
                cur.push(c)
            }
            ',' if !in_str && depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}

/// `ready = { addr = 0xF046, size = 1, endian = "le", in = [1, 254] }`
fn parse_gate(v: &str) -> Result<Gate, String> {
    let inner = v
        .trim()
        .strip_prefix('{')
        .and_then(|r| r.strip_suffix('}'))
        .ok_or_else(|| format!("[boot] ready must be an inline table `{{ addr = 0x.., eq = N }}`, got `{v}`"))?;
    let (mut addr, mut size, mut big, mut cond): (Option<u16>, usize, bool, Option<Cond>) = (None, 1, false, None);
    for part in split_top(inner) {
        let (k, val) = part.split_once('=').ok_or_else(|| format!("[boot] ready: expected `key = value`, got `{}`", part.trim()))?;
        let (k, val) = (k.trim(), val.trim());
        let set_cond = |cond: &mut Option<Cond>, c: Cond| -> Result<(), String> {
            if cond.is_some() {
                return Err("[boot] ready takes exactly one of eq, ne, in".into());
            }
            *cond = Some(c);
            Ok(())
        };
        match k {
            "addr" => addr = Some(u16::try_from(parse_int(val)?).map_err(|_| format!("[boot] ready: addr {val} is outside 0..=0xffff"))?),
            "size" => {
                size = parse_int(val)? as usize;
                if !matches!(size, 1 | 2 | 4) {
                    return Err(format!("[boot] ready: size must be 1, 2 or 4, got {size}"));
                }
            }
            "endian" => {
                big = match parse_string(val)?.as_str() {
                    "le" => false,
                    "be" => true,
                    o => return Err(format!("[boot] ready: endian must be \"le\" or \"be\", got `{o}`")),
                }
            }
            "eq" => set_cond(&mut cond, Cond::Eq(parse_int(val)?))?,
            "ne" => set_cond(&mut cond, Cond::Ne(parse_int(val)?))?,
            "in" => {
                let inner = val
                    .strip_prefix('[')
                    .and_then(|r| r.strip_suffix(']'))
                    .ok_or_else(|| format!("[boot] ready: `in` must be [lo, hi], got `{val}`"))?;
                let nums: Vec<i64> = inner.split(',').map(parse_int).collect::<Result<_, _>>()?;
                if nums.len() != 2 || nums[0] > nums[1] {
                    return Err(format!("[boot] ready: `in` must be [lo, hi] with lo <= hi, got `{val}`"));
                }
                set_cond(&mut cond, Cond::In(nums[0], nums[1]))?
            }
            o => return Err(format!("[boot] ready: unknown key `{o}` (addr, size, endian, eq, ne, in)")),
        }
    }
    Ok(Gate {
        addr: addr.ok_or("[boot] ready needs `addr`")?,
        size,
        big_endian: big,
        cond: cond.ok_or("[boot] ready needs one of eq, ne, in")?,
    })
}

impl Manifest {
    pub fn parse(text: &str) -> Result<Manifest, String> {
        let mut platform = None;
        let mut image = None;
        let mut labels = None;
        let mut recipe = None;
        let mut repeat = None;
        let mut timeout = None;
        let mut required_labels = None;
        let mut expectations = None;
        let mut emu = Emulator::default();
        let mut state_source: Option<StateSource> = None;
        let mut fields: Vec<FieldDef> = vec![];
        let mut cur_field: Option<FieldB> = None;
        let (mut o_source, mut o_dir, mut o_port, mut o_manifest): (Option<String>, Option<String>, Option<String>, Option<String>) = (None, None, None, None);
        let mut input_mode: Option<InputMode> = None;
        let mut input_keys: Vec<(String, String)> = vec![];
        let (mut boot_image, mut boot_ready, mut boot_keys, mut boot_timeout): (Option<String>, Option<Gate>, Vec<String>, Option<u64>) = (None, None, vec![], None);
        let mut saw_boot = false;
        let mut time = TimeCfg { fps: None, step_ms: crate::scenario::DEFAULT_STEP_MS, input_latency_frames: 0 };
        let mut sect = Sect::Top;
        for (n, raw) in text.lines().enumerate() {
            let at = |e: String| format!("line {}: {e}", n + 1);
            let line = strip_comment(raw).trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with('[') && !line.contains('=') {
                if let Some(f) = cur_field.take() {
                    fields.push(f.finish()?);
                }
                match line {
                    "[emulator]" => sect = Sect::Emulator,
                    "[state]" => sect = Sect::State,
                    "[oracle]" => sect = Sect::Oracle,
                    "[input]" => sect = Sect::Input,
                    "[input.keys]" => sect = Sect::InputKeys,
                    "[time]" => sect = Sect::Time,
                    "[boot]" => {
                        sect = Sect::Boot;
                        saw_boot = true;
                    }
                    "[[field]]" => {
                        sect = Sect::Field;
                        cur_field = Some(FieldB { line: n + 1, ..FieldB::default() });
                    }
                    other => {
                        return Err(at(format!(
                            "unknown table `{other}` (only [emulator], [state], [oracle], [input], [input.keys], [time], [boot], [[field]] exist)"
                        )))
                    }
                }
                continue;
            }
            let (k, v) = line.split_once('=').ok_or_else(|| at(format!("expected `key = value`: {raw}")))?;
            let (k, v) = (k.trim(), v.trim());
            match sect {
                Sect::Emulator => {
                    let slot = match k {
                        "x64sc" => &mut emu.x64sc,
                        "xvfb" => &mut emu.xvfb,
                        "mame" => &mut emu.mame,
                        "machine" => &mut emu.machine,
                        "rompath" => &mut emu.rompath,
                        _ => return Err(at(format!("unknown key `{k}` in [emulator] (x64sc, xvfb, mame, machine, rompath)"))),
                    };
                    *slot = Some(parse_string(v).map_err(at)?);
                }
                Sect::State => match k {
                    "source" => {
                        state_source = Some(match parse_string(v).map_err(at)?.as_str() {
                            "labels" => StateSource::Labels,
                            "map" => StateSource::Map,
                            o => return Err(at(format!("[state] source must be \"labels\" or \"map\", got `{o}`"))),
                        })
                    }
                    _ => return Err(at(format!("unknown key `{k}` in [state] (source)"))),
                },
                Sect::Input => match k {
                    "mode" => {
                        input_mode = Some(match parse_string(v).map_err(at)?.as_str() {
                            "breakpoint" => InputMode::Breakpoint,
                            "keys" => InputMode::Keys,
                            o => return Err(at(format!("[input] mode must be \"breakpoint\" or \"keys\", got `{o}`"))),
                        })
                    }
                    _ => return Err(at(format!("unknown key `{k}` in [input] (mode; button names go in [input.keys])"))),
                },
                Sect::InputKeys => {
                    let name = k.trim_matches('"').to_ascii_uppercase();
                    if name.is_empty() || name.contains(char::is_whitespace) {
                        return Err(at(format!("invalid button name `{k}` in [input.keys]")));
                    }
                    if input_keys.iter().any(|(b, _)| *b == name) {
                        return Err(at(format!("duplicate button `{name}` in [input.keys]")));
                    }
                    input_keys.push((name, parse_string(v).map_err(at)?.trim().to_ascii_uppercase()));
                }
                Sect::Time => match k {
                    "fps" => {
                        let f = v.parse::<u32>().ok().filter(|f| (1..=1000).contains(f));
                        time.fps = Some(f.ok_or_else(|| at(format!("[time] fps must be an integer 1..=1000, got `{v}`")))?)
                    }
                    "step_ms" => {
                        time.step_ms = v.parse::<u32>().ok().filter(|s| *s >= 1).ok_or_else(|| at(format!("[time] step_ms must be a positive integer (ms), got `{v}`")))?
                    }
                    "input_latency_frames" => {
                        time.input_latency_frames =
                            v.parse::<u32>().map_err(|_| at(format!("[time] input_latency_frames must be a non-negative integer, got `{v}`")))?
                    }
                    _ => return Err(at(format!("unknown key `{k}` in [time] (fps, step_ms, input_latency_frames)"))),
                },
                Sect::Boot => match k {
                    "image" => boot_image = Some(parse_string(v).map_err(at)?),
                    "ready" => boot_ready = Some(parse_gate(v).map_err(at)?),
                    "ready_keys" => boot_keys = parse_string_array(v).map_err(at)?,
                    "timeout_ms" => boot_timeout = Some(v.parse::<u64>().map_err(|_| at(format!("[boot] timeout_ms must be milliseconds (integer), got `{v}`")))?),
                    _ => return Err(at(format!("unknown key `{k}` in [boot] (image, ready, ready_keys, timeout_ms)"))),
                },
                Sect::Oracle => match k {
                    "source" => o_source = Some(parse_string(v).map_err(at)?),
                    "dir" => o_dir = Some(parse_string(v).map_err(at)?),
                    "port" => o_port = Some(parse_string(v).map_err(at)?),
                    "manifest" => o_manifest = Some(parse_string(v).map_err(at)?),
                    _ => return Err(at(format!("unknown key `{k}` in [oracle] (source, dir, port, manifest)"))),
                },
                Sect::Field => {
                    let f = cur_field.as_mut().expect("in a [[field]]");
                    match k {
                        "name" => f.name = Some(parse_string(v).map_err(at)?),
                        "label" => f.label = Some(parse_string(v).map_err(at)?),
                        "addr" => {
                            let a = parse_int(v).map_err(at)?;
                            f.addr = Some(u16::try_from(a).map_err(|_| at(format!("addr {a} is outside 0..=0xffff")))?);
                        }
                        "size" => f.size = Some(parse_int(v).map_err(at)? as usize),
                        "endian" => {
                            f.big_endian = match parse_string(v).map_err(at)?.as_str() {
                                "le" => false,
                                "be" => true,
                                o => return Err(at(format!("endian must be \"le\" or \"be\", got `{o}`"))),
                            }
                        }
                        "format" => {
                            f.hex = match parse_string(v).map_err(at)?.as_str() {
                                "hex" => true,
                                "number" => false,
                                o => return Err(at(format!("format must be \"number\" or \"hex\", got `{o}`"))),
                            }
                        }
                        "signed" => f.signed = parse_bool(v).map_err(at)?,
                        "scale" => f.scale = Some(parse_float(v).map_err(at)?),
                        "offset" => f.offset = parse_float(v).map_err(at)?,
                        "tolerance" => f.tolerance = parse_float(v).map_err(at)?,
                        "ignore" => f.ignore = parse_bool(v).map_err(at)?,
                        _ => return Err(at(format!("unknown key `{k}` in [[field]] (name, addr, label, size, endian, format, signed, scale, offset, tolerance, ignore)"))),
                    }
                }
                Sect::Top => match k {
                    "platform" => platform = Some(parse_string(v).map_err(at)?),
                    "image" => image = Some(parse_string(v).map_err(at)?),
                    "labels" => labels = Some(parse_string(v).map_err(at)?),
                    "recipe" => recipe = Some(parse_string(v).map_err(at)?),
                    "expectations" => expectations = Some(parse_string(v).map_err(at)?),
                    "repeat" => repeat = Some(v.parse::<u32>().map_err(|_| at(format!("repeat must be a positive integer, got `{v}`")))?),
                    "timeout" => timeout = Some(v.parse::<u64>().map_err(|_| at(format!("timeout must be seconds (integer), got `{v}`")))?),
                    "required_labels" => required_labels = Some(parse_string_array(v).map_err(at)?),
                    _ => {
                        return Err(at(format!(
                            "unknown key `{k}` (platform, image, labels, recipe, repeat, timeout, required_labels, expectations, [emulator], [state], [oracle], [input], [input.keys], [time], [boot], [[field]])"
                        )))
                    }
                },
            }
        }
        if let Some(f) = cur_field.take() {
            fields.push(f.finish()?);
        }
        let need = |o: Option<String>, k: &str| o.ok_or_else(|| format!("missing required key `{k}`"));
        let platform = need(platform, "platform")?;
        if !matches!(platform.as_str(), "c64" | "zx48" | "coco2") {
            return Err(format!("unknown platform `{platform}` (supported: c64, zx48, coco2)"));
        }
        if repeat == Some(0) {
            return Err("repeat must be at least 1".into());
        }
        let input_mode = input_mode.unwrap_or(InputMode::Breakpoint);
        let keys_mode = input_mode == InputMode::Keys;
        if !keys_mode {
            if saw_boot {
                return Err("[boot] needs `[input] mode = \"keys\"` (breakpoint mode boots to `gpf_input_ret` by itself)".into());
            }
            if !input_keys.is_empty() {
                return Err("[input.keys] needs `[input] mode = \"keys\"`".into());
            }
            if time.fps.is_some() || time.input_latency_frames != 0 {
                return Err("[time] fps / input_latency_frames need `[input] mode = \"keys\"` (only step_ms applies to a cooperative target)".into());
            }
        } else if platform == "c64" {
            return Err("`[input] mode = \"keys\"` is not supported for platform c64 yet (the VICE backend only has the breakpoint mode; use zx48 or coco2)".into());
        }
        let state_source = state_source.unwrap_or(StateSource::Labels);
        match (state_source, fields.is_empty()) {
            (StateSource::Labels, false) => return Err("[[field]] entries need `[state] source = \"map\"` (the default source is the built-in `labels` map)".into()),
            (StateSource::Map, true) => return Err("`[state] source = \"map\"` needs at least one [[field]]".into()),
            _ => {}
        }
        if keys_mode && state_source != StateSource::Map {
            return Err("`[input] mode = \"keys\"` needs `[state] source = \"map\"` with [[field]] entries (there is no gpf_state to read from an original)".into());
        }
        for (i, f) in fields.iter().enumerate() {
            if fields[..i].iter().any(|g| g.name == f.name) {
                return Err(format!("duplicate [[field]] name `{}`", f.name));
            }
        }
        // key names must exist on the platform: a typo is a config error listing the valid names
        let keymap_err = |what: String, name: &str| crate::keys::resolve_key(&platform, name).map(|_| ()).map_err(|e| format!("invalid {what}: {e}"));
        for (b, k) in &input_keys {
            keymap_err(format!("[input.keys] {b} = \"{k}\""), k)?;
        }
        for rk in &boot_keys {
            for p in crate::keys::parse_key_script(rk).map_err(|e| format!("invalid [boot] ready_keys: {e}"))? {
                if !input_keys.iter().any(|(b, _)| *b == p.name) {
                    keymap_err(format!("[boot] ready_keys `{rk}`"), &p.name)?;
                }
            }
        }
        let image = match (image, boot_image) {
            (Some(a), Some(b)) if a != b => return Err("`image` is given twice (top level and in [boot]) with different values; keep one".into()),
            (a, b) => need(b.or(a), "image")?,
        };
        if !keys_mode {
            if labels.is_none() {
                return Err("missing required key `labels`".into());
            }
            if recipe.is_none() {
                return Err("missing required key `recipe`".into());
            }
        }
        let oracle = match o_source.as_deref().unwrap_or("recipe") {
            "recipe" => {
                if o_dir.is_some() || o_port.is_some() || o_manifest.is_some() {
                    return Err("[oracle] source = \"recipe\" takes no dir/port/manifest".into());
                }
                OracleSource::Recipe
            }
            "trace" => {
                if o_port.is_some() || o_manifest.is_some() {
                    return Err("[oracle] source = \"trace\" takes `dir`, not port/manifest".into());
                }
                OracleSource::Trace { dir: o_dir.ok_or("[oracle] source = \"trace\" needs `dir = \"path\"`")? }
            }
            "live" => {
                if o_dir.is_some() {
                    return Err("[oracle] source = \"live\" takes `port`, not dir".into());
                }
                OracleSource::Live { port: o_port.ok_or("[oracle] source = \"live\" needs `port = \"path/to/port\"`")?, manifest: o_manifest }
            }
            o => return Err(format!("[oracle] source must be \"recipe\", \"trace\" or \"live\", got `{o}`")),
        };
        Ok(Manifest {
            platform,
            image,
            labels,
            recipe,
            input_mode,
            input_keys,
            boot: Boot { ready: boot_ready, ready_keys: boot_keys, timeout_ms: boot_timeout.unwrap_or(DEFAULT_BOOT_TIMEOUT_MS) },
            time,
            repeat,
            timeout,
            required_labels: required_labels.unwrap_or_else(|| {
                if keys_mode {
                    vec![]
                } else {
                    DEFAULT_REQUIRED_LABELS.iter().map(|s| s.to_string()).collect()
                }
            }),
            emulator: emu,
            state_source,
            fields,
            oracle,
            expectations,
        })
    }

    /// Load `<port_dir>/harness.toml` (or the file itself if a file path is given).
    /// Returns the manifest and the directory its relative paths hang off.
    pub fn load(port: &Path) -> Result<(Manifest, PathBuf), String> {
        let (file, dir) = if port.is_file() {
            (port.to_path_buf(), port.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from(".")))
        } else {
            (port.join("harness.toml"), port.to_path_buf())
        };
        let text = std::fs::read_to_string(&file).map_err(|e| {
            format!(
                "{}: {e} (a port needs a harness.toml; see factory/tools/gpfdiff/README.md, \"harness.toml reference\")",
                file.display()
            )
        })?;
        let m = Manifest::parse(&text).map_err(|e| format!("invalid {}: {e}", file.display()))?;
        Ok((m, dir))
    }
}

/// Resolve a manifest-relative path (absolute paths pass through).
pub fn resolve(dir: &Path, p: &str) -> PathBuf {
    let pb = Path::new(p);
    if pb.is_absolute() {
        pb.to_path_buf()
    } else {
        dir.join(pb)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: &str = r#"
# comment
platform = "c64"          # inline
image    = "target/brickfall.prg"
labels   = "target/brickfall.vs"
recipe   = "../../games/brickfall/recipe"
"#;

    #[test]
    fn minimal_manifest_gets_defaults() {
        let m = Manifest::parse(OK).unwrap();
        assert_eq!(m.platform, "c64");
        assert_eq!(m.image, "target/brickfall.prg");
        assert_eq!(m.repeat, None);
        assert_eq!(m.required_labels, vec!["gpf_state", "gpf_bricks", "gpf_input_ret"]);
        assert_eq!(m.emulator, Emulator::default());
    }

    #[test]
    fn full_manifest() {
        let t = format!(
            "{OK}repeat = 3\ntimeout = 90\nrequired_labels = [\"a\", \"b\"]\n[emulator]\nmame = \"/opt/mame\"\nrompath = \"~/roms # not a comment\"\n"
        );
        let m = Manifest::parse(&t).unwrap();
        assert_eq!((m.repeat, m.timeout), (Some(3), Some(90)));
        assert_eq!(m.required_labels, vec!["a", "b"]);
        assert_eq!(m.emulator.mame.as_deref(), Some("/opt/mame"));
        assert_eq!(m.emulator.rompath.as_deref(), Some("~/roms # not a comment"));
    }

    #[test]
    fn errors_name_the_line_and_the_problem() {
        let e = Manifest::parse(&format!("{OK}bogus = 1\n")).unwrap_err();
        assert!(e.contains("unknown key `bogus`") && e.contains("line "), "{e}");
        let e = Manifest::parse("platform = \"c64\"\n").unwrap_err();
        assert!(e.contains("missing required key `image`"), "{e}");
        let e = Manifest::parse(&OK.replace("c64", "amiga")).unwrap_err();
        assert!(e.contains("unknown platform `amiga`"), "{e}");
        let e = Manifest::parse(&format!("{OK}repeat = 0\n")).unwrap_err();
        assert!(e.contains("at least 1"), "{e}");
        let e = Manifest::parse(&format!("{OK}[emulator]\nx = \"y\"\n")).unwrap_err();
        assert!(e.contains("unknown key `x` in [emulator]"), "{e}");
        let e = Manifest::parse(&format!("{OK}[wat]\n")).unwrap_err();
        assert!(e.contains("unknown table"), "{e}");
        let e = Manifest::parse(&OK.replace("\"target/brickfall.prg\"", "target/brickfall.prg")).unwrap_err();
        assert!(e.contains("quoted string"), "{e}");
    }

    #[test]
    fn coco2_manifest_with_emulator_keys() {
        let t = "platform = \"coco2\"\nimage = \"target/brickfall.bin\"\nlabels = \"target/brickfall.map\"\nrecipe = \"r\"\n[emulator]\nmame = \"mame\"\nmachine = \"coco2b\"\nrompath = \"/my/roms\"\n";
        let m = Manifest::parse(t).unwrap();
        assert_eq!(m.platform, "coco2");
        assert_eq!(m.emulator.machine.as_deref(), Some("coco2b"));
        assert_eq!(m.emulator.rompath.as_deref(), Some("/my/roms"));
        assert_eq!(m.required_labels, vec!["gpf_state", "gpf_bricks", "gpf_input_ret"]);
        // the unsupported-platform message lists coco2
        let e = Manifest::parse(&t.replace("coco2\"", "dragon\"")).unwrap_err();
        assert!(e.contains("unknown platform `dragon`") && e.contains("coco2"), "{e}");
    }

    #[test]
    fn relative_paths_hang_off_the_manifest_dir() {
        assert_eq!(resolve(Path::new("/p"), "target/x"), PathBuf::from("/p/target/x"));
        assert_eq!(resolve(Path::new("/p"), "/abs/x"), PathBuf::from("/abs/x"));
    }

    #[test]
    fn missing_manifest_points_at_the_docs() {
        let e = Manifest::load(Path::new("/definitely/not/here")).unwrap_err();
        assert!(e.contains("harness.toml") && e.contains("README.md"), "{e}");
    }

    #[test]
    fn defaults_are_the_cooperative_labels_map_and_recipe_oracle() {
        let m = Manifest::parse(OK).unwrap();
        assert_eq!(m.state_source, StateSource::Labels);
        assert!(m.fields.is_empty());
        assert_eq!(m.oracle, OracleSource::Recipe);
        assert_eq!(m.expectations, None);
    }

    #[test]
    fn field_map_parses_every_attribute() {
        let t = format!(
            "{OK}expectations = \"exp.toml\"\n[state]\nsource = \"map\"\n[[field]]\nname = \"x\"\naddr = 0x5C00\nsize = 2\nendian = \"be\"\nsigned = true\nscale = 0.25\noffset = -1.5\ntolerance = 1\n[[field]]\nname = \"room\" # c\nlabel = \"cur_room\"\nignore = true\n[[field]]\nname = \"s\"\naddr = $10\n"
        );
        let m = Manifest::parse(&t).unwrap();
        assert_eq!(m.state_source, StateSource::Map);
        assert_eq!(m.expectations.as_deref(), Some("exp.toml"));
        assert_eq!(m.fields.len(), 3);
        let x = &m.fields[0];
        assert_eq!((x.src.clone(), x.size, x.big_endian, x.signed), (FieldSrc::Addr(0x5c00), 2, true, true));
        assert_eq!((x.scale, x.offset, x.tolerance, x.ignore), (0.25, -1.5, 1.0, false));
        let r = &m.fields[1];
        assert_eq!((r.src.clone(), r.size, r.scale, r.ignore), (FieldSrc::Label("cur_room".into()), 1, 1.0, true));
        assert_eq!(m.fields[2].src, FieldSrc::Addr(16));
    }

    #[test]
    fn field_map_errors() {
        let map = format!("{OK}[state]\nsource = \"map\"\n");
        let e = Manifest::parse(&map).unwrap_err();
        assert!(e.contains("needs at least one [[field]]"), "{e}");
        let e = Manifest::parse(&format!("{OK}[[field]]\nname = \"a\"\naddr = 1\n")).unwrap_err();
        assert!(e.contains("source = \"map\""), "{e}");
        let bad = |f: &str, want: &str| {
            let e = Manifest::parse(&format!("{map}[[field]]\n{f}\n")).unwrap_err();
            assert!(e.contains(want), "{f}: {e}");
        };
        bad("addr = 1", "missing `name`");
        bad("name = \"a\"", "exactly one of `addr` or `label`");
        bad("name = \"a\"\naddr = 1\nlabel = \"l\"", "exactly one of");
        bad("name = \"a\"\naddr = 1\nsize = 3", "size must be 1, 2 or 4");
        bad("name = \"a\"\naddr = 70000", "outside 0..=0xffff");
        bad("name = \"a\"\naddr = 1\nendian = \"mid\"", "endian must be");
        bad("name = \"a\"\naddr = 1\nscale = 0", "scale 0");
        bad("name = \"a\"\naddr = 1\ntolerance = -1", "tolerance must be >= 0");
        bad("name = \"a\"\naddr = 1\nsigned = yes", "true or false");
        bad("name = \"a\"\naddr = 1\nbogus = 1", "unknown key `bogus` in [[field]]");
        let e = Manifest::parse(&format!("{map}[[field]]\nname = \"a\"\naddr = 1\n[[field]]\nname = \"a\"\naddr = 2\n")).unwrap_err();
        assert!(e.contains("duplicate [[field]] name `a`"), "{e}");
        let e = Manifest::parse(&format!("{OK}[state]\nsource = \"x\"\n")).unwrap_err();
        assert!(e.contains("\"labels\" or \"map\""), "{e}");
    }

    #[test]
    fn oracle_block() {
        let m = Manifest::parse(&format!("{OK}[oracle]\nsource = \"trace\"\ndir = \"captured/zx\"\n")).unwrap();
        assert_eq!(m.oracle, OracleSource::Trace { dir: "captured/zx".into() });
        let m = Manifest::parse(&format!("{OK}[oracle]\nsource = \"live\"\nport = \"ports/p\"\nmanifest = \"h2.toml\"\n")).unwrap();
        assert_eq!(m.oracle, OracleSource::Live { port: "ports/p".into(), manifest: Some("h2.toml".into()) });
        let m = Manifest::parse(&format!("{OK}[oracle]\nsource = \"recipe\"\n")).unwrap();
        assert_eq!(m.oracle, OracleSource::Recipe);
        for (body, want) in [
            ("source = \"trace\"", "needs `dir"),
            ("source = \"live\"", "needs `port"),
            ("source = \"live\"\ndir = \"x\"", "takes `port`"),
            ("source = \"trace\"\ndir = \"x\"\nport = \"p\"", "takes `dir`"),
            ("source = \"recipe\"\ndir = \"x\"", "takes no dir"),
            ("source = \"model\"", "must be"),
            ("bogus = 1", "unknown key `bogus` in [oracle]"),
        ] {
            let e = Manifest::parse(&format!("{OK}[oracle]\n{body}\n")).unwrap_err();
            assert!(e.contains(want), "{body}: {e}");
        }
    }

    // ---- keys mode ----

    const KEYS: &str = "platform = \"zx48\"\nrecipe = \"r\"\n[input]\nmode = \"keys\"\n[boot]\nimage = \"x.sna\"\n[state]\nsource = \"map\"\n[[field]]\nname = \"x\"\naddr = 0x9000\n";

    #[test]
    fn keys_mode_manifest_needs_no_labels_and_defaults_are_sane() {
        let m = Manifest::parse(KEYS).unwrap();
        assert_eq!((m.input_mode, m.image.as_str(), m.labels.clone(), m.required_labels.len()), (InputMode::Keys, "x.sna", None, 0));
        assert_eq!(m.boot, Boot { ready: None, ready_keys: vec![], timeout_ms: DEFAULT_BOOT_TIMEOUT_MS });
        assert_eq!(m.time, TimeCfg { fps: None, step_ms: 20, input_latency_frames: 0 });
        // cooperative default is unchanged
        let c = Manifest::parse(OK).unwrap();
        assert_eq!((c.input_mode, c.labels.as_deref(), c.recipe.as_deref()), (InputMode::Breakpoint, Some("target/brickfall.vs"), Some("../../games/brickfall/recipe")));
    }

    #[test]
    fn input_keys_time_and_boot_parse() {
        let t = format!(
            "{KEYS}[input.keys]\nLEFT = \"z\"\nfire = \"SPACE\"\n[time]\nfps = 60\nstep_ms = 16\ninput_latency_frames = 2\n"
        )
        .replace("[boot]\nimage = \"x.sna\"\n", "[boot]\nimage = \"x.sna\"\nready = { addr = 0x5C78, size = 2, endian = \"be\", in = [1, 254] }\nready_keys = [\"SPACE@50ms\", \"FIRE@2s+300ms\"]\ntimeout_ms = 5000\n");
        let m = Manifest::parse(&t).unwrap();
        assert_eq!(m.input_keys, vec![("LEFT".to_string(), "Z".to_string()), ("FIRE".to_string(), "SPACE".to_string())]);
        assert_eq!(m.time, TimeCfg { fps: Some(60), step_ms: 16, input_latency_frames: 2 });
        assert_eq!(m.boot.ready, Some(Gate { addr: 0x5C78, size: 2, big_endian: true, cond: Cond::In(1, 254) }));
        assert_eq!((m.boot.ready_keys.len(), m.boot.timeout_ms), (2, 5000));
        // image at the top level works too; both with different values do not
        let top = KEYS.replace("[boot]\nimage = \"x.sna\"\n", "[boot]\n").replace("recipe = \"r\"\n", "recipe = \"r\"\nimage = \"x.sna\"\n");
        assert_eq!(Manifest::parse(&top).unwrap().image, "x.sna");
        let e = Manifest::parse(&KEYS.replace("recipe = \"r\"\n", "recipe = \"r\"\nimage = \"y.sna\"\n")).unwrap_err();
        assert!(e.contains("given twice"), "{e}");
    }

    #[test]
    fn gate_forms_and_evaluation() {
        let g = |s: &str| parse_gate(s);
        assert_eq!(g("{ addr = 0x10, eq = 3 }").unwrap(), Gate { addr: 16, size: 1, big_endian: false, cond: Cond::Eq(3) });
        assert_eq!(g("{addr=$10,ne=0}").unwrap().cond, Cond::Ne(0));
        let r = g("{ addr = 16, in = [2, 5] }").unwrap();
        assert!(!r.holds(1) && r.holds(2) && r.holds(5) && !r.holds(6));
        let e = g("{ addr = 1, eq = 1 }").unwrap();
        assert!(e.holds(1) && !e.holds(2));
        let n = g("{ addr = 1, ne = 255 }").unwrap();
        assert!(n.holds(0) && !n.holds(255));
        assert_eq!(r.describe(), "1 byte at $0010 in [2, 5]");
        for (bad, want) in [
            ("{ eq = 1 }", "needs `addr`"),
            ("{ addr = 1 }", "one of eq, ne, in"),
            ("{ addr = 1, eq = 1, ne = 2 }", "exactly one"),
            ("{ addr = 1, in = [5, 2] }", "lo <= hi"),
            ("{ addr = 1, in = 5 }", "[lo, hi]"),
            ("{ addr = 1, size = 3, eq = 1 }", "size must be"),
            ("{ addr = 70000, eq = 1 }", "outside"),
            ("{ addr = 1, bogus = 1 }", "unknown key `bogus`"),
            ("addr = 1", "inline table"),
        ] {
            let e = g(bad).unwrap_err();
            assert!(e.contains(want), "{bad}: {e}");
        }
    }

    #[test]
    fn keys_mode_errors() {
        let bad = |t: String, want: &str| {
            let e = Manifest::parse(&t).unwrap_err();
            assert!(e.contains(want), "{want}: {e}");
        };
        bad(KEYS.replace("zx48", "c64"), "not supported for platform c64");
        bad(KEYS.replace("source = \"map\"", "source = \"labels\"").replace("[[field]]\nname = \"x\"\naddr = 0x9000\n", ""), "needs `[state] source = \"map\"`");
        bad(format!("{OK}[boot]\nimage = \"x\"\n"), "[boot] needs `[input] mode = \"keys\"`");
        bad(format!("{OK}[input.keys]\nLEFT = \"Z\"\n"), "[input.keys] needs");
        bad(format!("{OK}[time]\nfps = 60\n"), "[time] fps");
        bad(format!("{KEYS}[input.keys]\nLEFT = \"CURSOR\"\n"), "unknown key name `CURSOR` for platform zx48; valid names: A-Z, 0-9");
        bad(format!("{KEYS}[input.keys]\nLEFT = \"Z\"\nleft = \"X\"\n"), "duplicate button `LEFT`");
        bad(KEYS.replace("[boot]\n", "[boot]\nready_keys = [\"NOPE@1ms\"]\n"), "ready_keys");
        bad(KEYS.replace("[boot]\n", "[boot]\nready_keys = [\"SPACE\"]\n"), "NAME@TIME");
        bad(format!("{KEYS}[time]\nfps = 0\n"), "fps must be");
        bad(format!("{KEYS}[time]\nstep_ms = 0\n"), "step_ms must be");
        bad(format!("{KEYS}[time]\ninput_latency_frames = -1\n"), "input_latency_frames");
        bad(KEYS.replace("mode = \"keys\"", "mode = \"warp\""), "mode must be");
    }
}
