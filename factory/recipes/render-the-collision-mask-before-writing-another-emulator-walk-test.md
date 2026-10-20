# Render the collision mask before writing another emulator walk test

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

Two bugs in one session were chased with scripted emulator walks that never reached the geometry in question -- one wrong answer about whether a border could fit, and a physics fix shipped unverified because the test walk missed a staircase entirely. Both collapsed immediately once the room's collision mask was rendered as one screen of ASCII (4x4 cells, solid/empty), and the derived 'walkable top edges' list answered 'can the player stand here' directly. A blind walk test can only prove presence, never absence: it says nothing when it fails to reach the thing. Rendering the data says what is actually there in seconds, and cross-referencing it against engine constants (a transition threshold, a play-window edge) turns a per-room hunt into one table for the whole build.

## Precondition

Target has a tile/block collision mask or equivalent per-room geometry in a form the build already emits. Prefer reading the GENERATED data over the upstream extraction, so what you inspect is what the target actually collides against, past any clipping or drops the converter applied.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
