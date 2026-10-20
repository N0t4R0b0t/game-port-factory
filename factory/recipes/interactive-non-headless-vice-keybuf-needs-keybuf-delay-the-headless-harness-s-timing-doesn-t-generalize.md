# Interactive (non-headless) VICE -keybuf needs -keybuf-delay; the headless harness's timing doesn't generalize

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

A VS Code task launching x64sc interactively with -keybuf (auto-typing LOAD/RUN) worked in this session's own sandbox but produced a garbled, corrupted command on the user's real machine -- a real environment-dependent timing race, not a flag mistake. Every prior use of -keybuf in this project ran under xvfb-run -a x64sc ... -warp -limitcycles N -exitscreenshot, which paces the machine by CPU cycles, not wall-clock time; a live interactive window has no such pinning, and its real-world startup timing (GTK realization, compositor, host load) varies enough that the emulator's internal keyboard-buffer injection can start before the machine is ready, dropping characters. This never surfaced before because nothing before this session had used -keybuf outside the headless, cycle-paced harness.

## Precondition

Any future interactive (non-harness, real-window) use of x64sc's -keybuf in this project should add -keybuf-delay defensively from the start (50 confirmed working) rather than assume the headless harness's timing generalizes to a live GUI session. If a -keybuf-driven interactive task is ever reported broken on a real machine, check this first before assuming a flag/syntax error.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

**Wrong. Did not hold up — the same failure recurred with `-keybuf-delay 50` in place.**
The timing-race theory was plausible and this session's own sandbox test (which passed both
with and without the delay) provided no way to distinguish "fixed" from "never broken here
to begin with." The real cause, found after the fix demonstrably failed: `.vscode/tasks.json`
embedded the whole command — including a `$'...'`-ANSI-C-quoted `-keybuf` string — as an
inline `bash -c "..."` one-liner. VS Code's `"type": "shell"` re-quotes `args` for whatever
shell it invokes on the target machine, an extra quoting layer this project's own test
never exercised the same way. That's where the string got corrupted, not in keyboard-buffer
delivery timing. Real fix: moved the command into a real script file
(`target/run-vice.sh`) and pointed the task at that path directly — see
`ports/fallout1-c64/NOTES.md`'s corrected write-up ("Interactive VICE -keybuf broke on a
real machine — the actual fix, and a wrong first guess") for the full account. Superseded by
`factory/recipes/` — no separate decision filed for the real fix; this file's own corrected
Outcome section is the record. Left in place, corrected, rather than deleted: the mistake of
trusting a plausible-but-unverified theory is itself the reusable lesson.
