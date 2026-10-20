# A gdb-remote stub that halts the target CPU on connect makes sleep-based poke-and-read verification silently test a frozen snapshot, not live execution

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Confirmed on xroar's gdb-remote stub (6809/CoCo2): querying stop-reason ('?') returns S02 (already stopped) immediately at connect, and a heartbeat counter incremented unconditionally in the game's own main loop stayed frozen across a full second of sleep with no continue sent -- proving the CPU had executed zero instructions while the debug connection was open. Every earlier test in the same session that appeared to verify live behavior via 'connect, write state, sleep, read back' was actually reading state that was either compiled into the ROM image or set once at boot, never state that changed due to continued execution after the poke -- a false positive that looked like success. The correct pattern: send a continue command to resume, and before any subsequent memory read or write, send a raw interrupt byte to re-halt, perform the access, then continue again. A single connect-read-disconnect (e.g. a one-shot screenshot capture) is unaffected by this and needs no such handling, since it only needs a snapshot of already-completed execution.

## Precondition

Verifying behavior that requires the target to keep executing WHILE the gdb/debug connection is open (a counter advancing, a state machine reacting to polled writes over time) -- not a single read-then-disconnect snapshot. Applies to any gdb-remote-protocol stub, not just xroar; check the stub's actual continue/interrupt semantics before trusting a sleep-based hold-and-poll test.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
