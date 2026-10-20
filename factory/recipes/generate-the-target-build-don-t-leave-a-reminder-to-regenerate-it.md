# Generate the target build, don't leave a reminder to regenerate it

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

The two-pass packed build reads raw bytes back out, so regenerating art without repacking leaves blobs describing the previous art -- and that build still assembles, still loads and silently draws the old rooms. A printed reminder does not survive a session with no memory of the last one. regen_art.sh execs stage_pack.sh instead.

## Precondition

A build step consumes the output of an earlier build step and the stale-input failure is silent rather than an error.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
