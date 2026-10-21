# Gate public exports on file CONTENT (binary or not), not file extensions

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

An extensionless XRoar machine snapshot of a running game slipped past an extension blocklist into a public repo; any non-text file outside docs screenshots is now an export error

## Precondition

A one-way export to a public repo with an automated scan; fails to protect against text files that embed original data, which needs the textual gates as well

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
