# A task's verify command must be run once at creation time, not just written plausibly

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Hit the identical bug twice in this project: T0014/T0019's verify was 'cargo test -p readability' and T0029's was 'cargo test -p datx' -- both look reasonable (crate name matches the binary) but both fail immediately, because these tools are standalone Cargo projects (no workspace Cargo.toml), so -p never resolves regardless of directory. A verify command that has never actually been run is a guess wearing a verifier's clothes -- exactly the 'confident wrong output' failure the cost model warns about, just applied to task metadata instead of model output.

## Precondition

Whenever writing or updating a task's --verify command (gpf task add, or hand-editing tasks.toml), actually run it once before trusting it -- 'cd <tool-dir> && cargo test' works everywhere in this repo since nothing here uses a Cargo workspace; a bare '-p <crate>' does not, regardless of how plausible it looks.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
