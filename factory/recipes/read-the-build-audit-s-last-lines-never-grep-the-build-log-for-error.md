# Read the build audit's last lines, never grep the build log for 'error'

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-07

## Decision

memaudit prints OVERLAPPING BLOCKS, not the word error. Filtering stage_pack.sh's output through grep -iE 'error' hid a 195-byte overflow of the resident code region into a staging window; the build shipped and the user hit it on the next pull. The audit is the last thing the build prints precisely so it can be read.

## Precondition

Any build whose final step is a memory/layout audit. Read its tail, or grep for the audit's own vocabulary as well.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
