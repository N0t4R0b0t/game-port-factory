//! Scenario files (`scenarios/*.toml`): platform independent.
//!
//! Step clock (the original format; cooperative targets):
//! ```toml
//! steps = 300
//! sample_every = 5
//! [[input]]
//! step = 0
//! buttons = 5
//! ```
//! Buttons hold from `step` until the next entry (initially 0). Input index `i`
//! drives the simulation call that produces step `i+1`.
//!
//! Millisecond clock (oracle mode; every key may be mixed with the step ones, each in its own unit):
//! `length_ms` instead of `steps`, `sample_every_ms` instead of `sample_every`, and in an
//! `[[input]]` `at_ms` instead of `step`, an optional `duration_ms` (the buttons are released that long
//! after `at_ms`, unless another entry takes over first) and `press = ["LEFT", "A"]` (button or key
//! names; `LEFT`/`RIGHT`/`FIRE` are the bits 1/2/4 of `buttons`, any other name is a key of the target and is
//! only usable in `[input] mode = "keys"`).
//!
//! A step is `step_ms` milliseconds (default 20, the manifest's `[time] step_ms`). A scenario keeps the
//! form it was authored in and derives both views from it: the step-clock view (`steps`, `sample_every`,
//! `inputs`, what cooperative targets run) and the millisecond view ([`Scenario::length_ms`],
//! [`Scenario::sample_ms`], [`Scenario::ms_events`], what keys mode converts to frames).

use crate::manifest::{parse_string_array, strip_comment};

pub const DEFAULT_STEP_MS: u32 = 20;

/// A duration or instant in the unit the scenario was authored in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dur {
    Steps(u32),
    Ms(u32),
}

impl Dur {
    pub fn ms(self, step_ms: u32) -> u64 {
        match self {
            Dur::Steps(n) => n as u64 * step_ms as u64,
            Dur::Ms(m) => m as u64,
        }
    }
    pub fn steps(self, step_ms: u32) -> u32 {
        match self {
            Dur::Steps(n) => n,
            Dur::Ms(m) => round_div(m as u64, step_ms as u64) as u32,
        }
    }
}

/// `n / d` rounded to nearest, halves up (integer arithmetic; the one rounding rule of the time axis).
pub fn round_div(n: u64, d: u64) -> u64 {
    (2 * n + d) / (2 * d)
}

/// One authored `[[input]]` entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Input {
    pub at: Dur,
    /// Bitmask: 1 LEFT, 2 RIGHT, 4 FIRE.
    pub buttons: u8,
    /// Extra key/button names from `press` (upper case), beyond the three canonical bits.
    pub names: Vec<String>,
    pub duration_ms: Option<u32>,
}

/// The buttons held from an instant on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MsEvent {
    pub ms: u64,
    pub buttons: u8,
    pub names: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scenario {
    // ---- the step-clock view (cooperative targets)
    pub steps: u32,
    pub sample_every: u32,
    /// (step, buttons), sorted by step.
    pub inputs: Vec<(u32, u8)>,
    // ---- as authored
    pub step_ms: u32,
    pub length: Dur,
    pub every: Dur,
    pub entries: Vec<Input>,
}

const CANON: [(&str, u8); 3] = [("LEFT", 1), ("RIGHT", 2), ("FIRE", 4)];

impl Scenario {
    pub fn parse(text: &str) -> Result<Scenario, String> {
        Scenario::parse_with(text, DEFAULT_STEP_MS)
    }

    pub fn parse_with(text: &str, step_ms: u32) -> Result<Scenario, String> {
        if step_ms == 0 {
            return Err("step_ms must be at least 1".into());
        }
        let mut length: Option<Dur> = None;
        let mut every: Option<Dur> = None;
        let mut entries: Vec<Input> = vec![];
        #[derive(Default)]
        struct Cur {
            at: Option<Dur>,
            buttons: Option<u8>,
            names: Vec<String>,
            have_press: bool,
            duration_ms: Option<u32>,
        }
        let mut cur: Option<Cur> = None;

        fn flush(cur: &mut Option<Cur>, entries: &mut Vec<Input>) -> Result<(), String> {
            if let Some(c) = cur.take() {
                let at = c.at.ok_or("[[input]] missing `step` (or `at_ms`)")?;
                if c.buttons.is_none() && !c.have_press {
                    return Err("[[input]] missing `buttons` (or `press`)".into());
                }
                entries.push(Input { at, buttons: c.buttons.unwrap_or(0), names: c.names, duration_ms: c.duration_ms });
            }
            Ok(())
        }

        for (n, raw) in text.lines().enumerate() {
            let line = strip_comment(raw).trim();
            if line.is_empty() {
                continue;
            }
            let at = |e: String| format!("line {}: {e}", n + 1);
            if line == "[[input]]" {
                flush(&mut cur, &mut entries).map_err(at)?;
                cur = Some(Cur::default());
                continue;
            }
            let (k, v) = line.split_once('=').ok_or_else(|| at(format!("expected `key = value`: {raw}")))?;
            let (k, v) = (k.trim(), v.trim());
            if k == "press" && cur.is_some() {
                let c = cur.as_mut().unwrap();
                for name in parse_string_array(v).map_err(at)? {
                    let up = name.trim().to_ascii_uppercase();
                    match CANON.iter().find(|(c, _)| *c == up) {
                        Some((_, bit)) => c.buttons = Some(c.buttons.unwrap_or(0) | bit),
                        None if up.is_empty() => return Err(at("`press` has an empty name".into())),
                        None => c.names.push(up),
                    }
                }
                c.have_press = true;
                continue;
            }
            let num: u32 = v.parse().map_err(|_| at(format!("bad number `{v}`")))?;
            match (k, cur.as_mut()) {
                ("steps", None) | ("length_ms", None) => {
                    if length.is_some() {
                        return Err(at("scenario length given twice (`steps` and `length_ms` are alternatives)".into()));
                    }
                    length = Some(if k == "steps" { Dur::Steps(num) } else { Dur::Ms(num) });
                }
                ("sample_every", None) | ("sample_every_ms", None) => {
                    if every.is_some() {
                        return Err(at("sampling interval given twice (`sample_every` and `sample_every_ms` are alternatives)".into()));
                    }
                    every = Some(if k == "sample_every" { Dur::Steps(num.max(1)) } else { Dur::Ms(num.max(1)) });
                }
                ("step", Some(c)) | ("at_ms", Some(c)) => {
                    if c.at.is_some() {
                        return Err(at("[[input]] has both `step` and `at_ms`".into()));
                    }
                    c.at = Some(if k == "step" { Dur::Steps(num) } else { Dur::Ms(num) });
                }
                ("buttons", Some(c)) => {
                    if num > 7 {
                        return Err(at(format!("buttons {num} > 7")));
                    }
                    c.buttons = Some(c.buttons.unwrap_or(0) | num as u8);
                }
                ("duration_ms", Some(c)) => c.duration_ms = Some(num),
                _ => return Err(at(format!("unexpected key `{k}`"))),
            }
        }
        flush(&mut cur, &mut entries)?;
        let length = length.ok_or("scenario has no `steps` (or `length_ms`)")?;
        let every = every.unwrap_or(Dur::Steps(1));
        let mut sc = Scenario { steps: 0, sample_every: 1, inputs: vec![], step_ms, length, every, entries };
        sc.derive_step_view();
        Ok(sc)
    }

    /// The step-clock view: what a cooperative target runs.
    fn derive_step_view(&mut self) {
        self.steps = self.length.steps(self.step_ms);
        self.sample_every = self.every.steps(self.step_ms).max(1);
        let mut v: Vec<(u32, u8, u8)> = vec![]; // (step, priority, buttons); explicit entries beat a release
        for e in &self.entries {
            v.push((e.at.steps(self.step_ms), 1, e.buttons));
            if let Some(d) = e.duration_ms {
                v.push((round_div(e.at.ms(self.step_ms) + d as u64, self.step_ms as u64) as u32, 0, 0));
            }
        }
        v.sort_by_key(|x| (x.0, x.1));
        self.inputs = v.into_iter().map(|(s, _, b)| (s, b)).collect();
    }

    /// Any button beyond LEFT/RIGHT/FIRE: only keys mode can press it.
    pub fn uses_key_names(&self) -> Option<&str> {
        self.entries.iter().find_map(|e| e.names.first().map(|s| s.as_str()))
    }

    /// Buttons held while producing step `step+1`.
    pub fn buttons_at(&self, step: u32) -> u8 {
        let mut b = 0;
        for &(s, v) in &self.inputs {
            if s <= step {
                b = v;
            } else {
                break;
            }
        }
        b
    }

    pub fn sampled(&self, step: u32) -> bool {
        step % self.sample_every == 0
    }

    // ---- the millisecond view

    pub fn length_ms(&self) -> u64 {
        self.length.ms(self.step_ms)
    }

    pub fn sample_every_ms(&self) -> u64 {
        self.every.ms(self.step_ms).max(1)
    }

    /// Scheduled sample instants: 0, every, 2*every ... up to and including the length.
    pub fn sample_ms(&self) -> Vec<u64> {
        let (len, ev) = (self.length_ms(), self.sample_every_ms());
        (0..).map(|k| k * ev).take_while(|t| *t <= len).collect()
    }

    /// Button changes in time order: each entry sets the buttons from its instant on; a `duration_ms`
    /// adds a release; at the same instant an explicit entry beats a release.
    pub fn ms_events(&self) -> Vec<MsEvent> {
        let mut v: Vec<(u64, u8, MsEvent)> = vec![];
        for e in &self.entries {
            let ms = e.at.ms(self.step_ms);
            v.push((ms, 1, MsEvent { ms, buttons: e.buttons, names: e.names.clone() }));
            if let Some(d) = e.duration_ms {
                let r = ms + d as u64;
                v.push((r, 0, MsEvent { ms: r, buttons: 0, names: vec![] }));
            }
        }
        v.sort_by_key(|x| (x.0, x.1));
        v.into_iter().map(|x| x.2).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: &str = "# comment\nsteps = 300\nsample_every = 5\n\n[[input]]\nstep = 0\nbuttons = 5\n\n[[input]]\nstep = 10 # inline\nbuttons = 0\n";

    #[test]
    fn parses_header_and_inputs() {
        let s = Scenario::parse(T).unwrap();
        assert_eq!(s.steps, 300);
        assert_eq!(s.sample_every, 5);
        assert_eq!(s.inputs, vec![(0, 5), (10, 0)]);
    }

    #[test]
    fn buttons_hold_until_next_entry() {
        let s = Scenario::parse(T).unwrap();
        assert_eq!(s.buttons_at(0), 5);
        assert_eq!(s.buttons_at(9), 5);
        assert_eq!(s.buttons_at(10), 0);
        assert_eq!(s.buttons_at(299), 0);
    }

    #[test]
    fn buttons_before_first_entry_are_zero() {
        let s = Scenario::parse("steps = 3\n[[input]]\nstep = 2\nbuttons = 1\n").unwrap();
        assert_eq!(s.buttons_at(0), 0);
        assert_eq!(s.buttons_at(2), 1);
    }

    #[test]
    fn sampling() {
        let s = Scenario::parse(T).unwrap();
        assert!(s.sampled(0) && s.sampled(5) && !s.sampled(6));
    }

    #[test]
    fn unsorted_inputs_are_sorted() {
        let s = Scenario::parse("steps=9\n[[input]]\nstep=5\nbuttons=2\n[[input]]\nstep=1\nbuttons=4\n").unwrap();
        assert_eq!(s.inputs, vec![(1, 4), (5, 2)]);
    }

    #[test]
    fn rejects_garbage() {
        assert!(Scenario::parse("steps = x").is_err());
        assert!(Scenario::parse("sample_every = 2").is_err()); // no steps
        assert!(Scenario::parse("steps = 1\n[[input]]\nstep = 1\n").is_err()); // no buttons
        assert!(Scenario::parse("steps = 1\n[[input]]\nstep = 1\nbuttons = 9\n").is_err());
        assert!(Scenario::parse("steps = 1\nbogus = 3\n").is_err());
    }

    #[test]
    fn sample_every_zero_is_one() {
        let s = Scenario::parse("steps = 1\nsample_every = 0\n").unwrap();
        assert_eq!(s.sample_every, 1);
    }

    // ---- milliseconds

    #[test]
    fn rounding_is_to_nearest_halves_up() {
        assert_eq!(round_div(10, 20), 1); // 0.5 -> 1
        assert_eq!(round_div(9, 20), 0);
        assert_eq!(round_div(30, 20), 2); // 1.5 -> 2
        assert_eq!(round_div(29, 20), 1);
        assert_eq!(round_div(40, 20), 2);
    }

    #[test]
    fn step_scenarios_have_an_exact_millisecond_view() {
        let s = Scenario::parse(T).unwrap();
        assert_eq!((s.length_ms(), s.sample_every_ms()), (6000, 100));
        let ev = s.ms_events();
        assert_eq!(ev.iter().map(|e| (e.ms, e.buttons)).collect::<Vec<_>>(), vec![(0, 5), (200, 0)]);
        assert_eq!(s.sample_ms().len(), 61);
        assert_eq!(s.sample_ms()[..3], [0, 100, 200]);
        assert_eq!(*s.sample_ms().last().unwrap(), 6000);
        // another step length rescales the whole timeline
        let s = Scenario::parse_with(T, 10).unwrap();
        assert_eq!((s.length_ms(), s.steps), (3000, 300));
    }

    #[test]
    fn native_millisecond_entries() {
        let s = Scenario::parse(
            "length_ms = 1000\nsample_every_ms = 100\n[[input]]\nat_ms = 100\nbuttons = 1\nduration_ms = 300\n[[input]]\nat_ms = 600\npress = [\"fire\", \"a\"]\n",
        )
        .unwrap();
        assert_eq!((s.length_ms(), s.sample_every_ms()), (1000, 100));
        let ev = s.ms_events();
        assert_eq!(ev.len(), 3);
        assert_eq!((ev[0].ms, ev[0].buttons), (100, 1));
        assert_eq!((ev[1].ms, ev[1].buttons), (400, 0)); // released after duration_ms
        assert_eq!((ev[2].ms, ev[2].buttons, ev[2].names.clone()), (600, 4, vec!["A".to_string()]));
        assert_eq!(s.uses_key_names(), Some("A"));
        // step view at the default 20 ms/step: 50 steps, every 5, press at 5, release at 20, fire at 30
        assert_eq!((s.steps, s.sample_every), (50, 5));
        assert_eq!(s.inputs, vec![(5, 1), (20, 0), (30, 4)]);
    }

    #[test]
    fn an_explicit_entry_beats_a_release_at_the_same_instant() {
        let s = Scenario::parse("length_ms = 500\n[[input]]\nat_ms = 0\nbuttons = 1\nduration_ms = 200\n[[input]]\nat_ms = 200\nbuttons = 2\n").unwrap();
        let ev = s.ms_events();
        assert_eq!(ev.iter().map(|e| (e.ms, e.buttons)).collect::<Vec<_>>(), vec![(0, 1), (200, 0), (200, 2)]);
        assert_eq!(s.buttons_at(10), 2);
    }

    #[test]
    fn ms_and_step_forms_are_alternatives() {
        let e = Scenario::parse("steps = 5\nlength_ms = 100\n").unwrap_err();
        assert!(e.contains("given twice"), "{e}");
        let e = Scenario::parse("steps = 5\nsample_every = 1\nsample_every_ms = 5\n").unwrap_err();
        assert!(e.contains("given twice"), "{e}");
        let e = Scenario::parse("steps = 5\n[[input]]\nstep = 1\nat_ms = 5\nbuttons = 1\n").unwrap_err();
        assert!(e.contains("both `step` and `at_ms`"), "{e}");
        let e = Scenario::parse("steps = 5\n[[input]]\nat_ms = 5\n").unwrap_err();
        assert!(e.contains("missing `buttons`"), "{e}");
        assert!(Scenario::parse("length_ms = 100\n[[input]]\nbuttons = 1\n").is_err());
        // ms entries inside a step-length scenario are fine (each in its own unit)
        let s = Scenario::parse("steps = 10\n[[input]]\nat_ms = 60\nbuttons = 2\n").unwrap();
        assert_eq!(s.inputs, vec![(3, 2)]);
    }

    #[test]
    fn press_folds_canonical_names_into_the_button_mask() {
        let s = Scenario::parse("steps = 5\n[[input]]\nstep = 0\npress = [\"LEFT\", \"fire\"]\n").unwrap();
        assert_eq!(s.inputs, vec![(0, 5)]);
        assert_eq!(s.uses_key_names(), None);
    }
}
