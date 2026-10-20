# Never duplicate a generated-file parser across tools -- import it

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

start_pos.py kept its own copy of the raw-mask parser instead of importing roomview.py's. When T0106 changed the mask format, roomview.py was updated and start_pos.py silently was not -- every room fell back to its 'no mask' default, and ./play.sh 53 started seeding items onto a build that actually opened in a different room. This is the second time in this project a duplicated parser for a generated file has gone stale (roomview.py itself existed to fix the same class of mistake once already).

## Precondition

Two or more tools need to read the same generated/derived file format. Import the one canonical parser; a second implementation of the same decode logic is a drift bug waiting to happen, not a convenience.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
