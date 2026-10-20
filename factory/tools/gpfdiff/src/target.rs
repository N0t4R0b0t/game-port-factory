//! Platform-independent driving loop. A platform backend (C64/VICE today, MAME/ZX
//! later) implements [`Target`]; everything else (scenario stepping, sampling,
//! desync gating, trace comparison, repeat/determinism) is shared.

use crate::fields::FieldMap;
use crate::scenario::Scenario;
use crate::state::RawState;
use crate::trace::Trace;

/// A target that is *parked at the input point*: the instant where the program is
/// about to consume this step's buttons, i.e. `gpf_state` holds the state after the
/// previous step and is not being mutated.
pub trait Target {
    /// Start the emulator, load the program and run to the first input point.
    fn boot(&mut self) -> Result<(), String>;
    /// Read `gpf_state` + `gpf_bricks` while parked.
    fn read_state(&mut self) -> Result<RawState, String>;
    /// Supply the buttons for the pending step, verify they were really injected,
    /// resume, and run to the next input point.
    fn provide_input(&mut self, buttons: u8) -> Result<(), String>;
    /// Stop the emulator and release resources. Must be safe to call twice.
    fn shutdown(&mut self);
    /// Read raw RAM while parked (probe/diagnostics). Optional.
    fn peek(&mut self, _addr: u16, _len: usize) -> Result<Vec<u8>, String> {
        Err("this backend cannot peek memory".into())
    }
    /// Address of an assembler label from the target's symbol file (used by `[[field]] label = ...`).
    fn label(&self, _name: &str) -> Option<u16> {
        None
    }
    /// Grab the emulator's current video frame (only while parked). Optional.
    fn screenshot(&mut self) -> Result<crate::png::Image, String> {
        Err("this backend cannot take screenshots".into())
    }
}

/// Run a whole scenario and log every input point where `len` bytes at `addr` differ from
/// the previous point: `(step, bytes)`. First point is always logged.
pub fn run_probe(t: &mut dyn Target, sc: &Scenario, addr: u16, len: usize) -> Result<Vec<(u32, Vec<u8>)>, String> {
    let mut out: Vec<(u32, Vec<u8>)> = vec![];
    t.boot()?;
    for i in 0..=sc.steps {
        let v = t.peek(addr, len)?;
        if out.last().map(|l| l.1 != v).unwrap_or(true) {
            out.push((i, v));
        }
        if i == sc.steps {
            break;
        }
        t.provide_input(sc.buttons_at(i))?;
    }
    Ok(out)
}

/// Run a scenario up to input point `at` and grab a screenshot there.
pub fn run_to_shot(t: &mut dyn Target, sc: &Scenario, at: u32) -> Result<crate::png::Image, String> {
    t.boot()?;
    for i in 0..=at.min(sc.steps) {
        let st = t.read_state()?;
        if st.step() as u32 != i & 0xffff {
            return Err(format!("harness desync: at input point {i} the target reports step {}", st.step()));
        }
        if i == at {
            return t.screenshot();
        }
        t.provide_input(sc.buttons_at(i))?;
    }
    Err(format!("scenario has only {} steps, cannot shoot at {at}", sc.steps))
}

/// Run one scenario and return the sampled trace, one column per field of `map`.
///
/// At input point `i` the state holds step `i`; it is sampled when
/// `i % sample_every == 0`, then buttons for index `i` are injected. The observed
/// `step` field of the cooperative `gpf_state` block must equal `i`: any drift means the
/// harness lost sync with the program (never believe a diff after that). The desync gate
/// reads the backend's own state block, so it works whatever the field map is.
pub fn run_scenario(t: &mut dyn Target, sc: &Scenario, map: &FieldMap) -> Result<Trace, String> {
    let mut lines = vec![];
    t.boot()?;
    let map = {
        let tt: &dyn Target = &*t;
        map.resolve(&mut |n| tt.label(n).ok_or_else(|| format!("label `{n}` missing from the labels file")))?
    };
    for i in 0..=sc.steps {
        let st = t.read_state()?;
        if st.step() as u32 != i & 0xffff {
            return Err(format!(
                "harness desync: at input point {i} the target reports step {}",
                st.step()
            ));
        }
        if sc.sampled(i) {
            lines.push(map.read_line(&st, &mut |a, n| t.peek(a, n))?);
        }
        if i == sc.steps {
            break;
        }
        t.provide_input(sc.buttons_at(i))?;
    }
    Ok(Trace { columns: map.columns(), lines })
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::state::{BRICKS_LEN, STATE_LEN};

    /// A fake target that just counts steps (state[0..2] = step).
    pub struct Counter {
        pub step: u16,
        pub injected: Vec<u8>,
        pub skew: u16, // reports step+skew after the 3rd input, to test desync gating
    }

    impl Target for Counter {
        fn boot(&mut self) -> Result<(), String> {
            self.step = 0;
            Ok(())
        }
        fn read_state(&mut self) -> Result<RawState, String> {
            let mut state = [0u8; STATE_LEN];
            state[0..2].copy_from_slice(&self.step.to_le_bytes());
            state[3] = 3;
            Ok(RawState { state, bricks: [0xff; BRICKS_LEN] })
        }
        fn provide_input(&mut self, b: u8) -> Result<(), String> {
            self.injected.push(b);
            self.step += 1;
            if self.injected.len() == 3 {
                self.step += self.skew;
            }
            Ok(())
        }
        fn shutdown(&mut self) {}
    }

    #[test]
    fn samples_and_injects_per_scenario() {
        let sc = Scenario::parse("steps = 10\nsample_every = 5\n[[input]]\nstep = 2\nbuttons = 4\n").unwrap();
        let mut t = Counter { step: 0, injected: vec![], skew: 0 };
        let tr = run_scenario(&mut t, &sc, &FieldMap::builtin()).unwrap();
        assert_eq!((0..tr.len()).map(|i| tr.step_at(i).unwrap()).collect::<Vec<_>>(), vec![0, 5, 10]);
        assert_eq!(t.injected, vec![0, 0, 4, 4, 4, 4, 4, 4, 4, 4]); // 10 steps, none after the last sample
    }

    #[test]
    fn desync_is_an_error_not_a_diff() {
        let sc = Scenario::parse("steps = 10\n").unwrap();
        let mut t = Counter { step: 0, injected: vec![], skew: 1 };
        let e = run_scenario(&mut t, &sc, &FieldMap::builtin()).unwrap_err();
        assert!(e.contains("desync"), "{e}");
    }
}
