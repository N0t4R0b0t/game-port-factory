# Count the matches before reading them when searching for callers

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

Before adding a build-time guard I grepped for the old build command and piped through head -10, which cut off three real callers including the user launcher tracked since the first commit. The guard then fired in the user's face. A truncated search that finds something reads as a completed search.

## Precondition

Any change that breaks an existing interface or command. Enumerate callers exhaustively -- count first, read second -- before shipping the thing that breaks them.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
