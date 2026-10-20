# A data-emission tool must place a table's label on its actual pointer entries, not on a placeholder position chosen only to guarantee the symbol exists

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

tools/roompack needed a jump/pointer table's label to exist even for a room with zero entries (the caller resolves its address at assembly time regardless of the runtime count). The fix that seemed obvious -- emit the label once, up front, before conditionally emitting the real entries -- silently aliased the label onto unrelated data (the first sprite's own header bytes) whenever the table WASN'T empty, because the real fdb pointer list was written afterward, in a different place, with no label of its own. At runtime this produced a garbage pointer that got dereferenced as a sprite header; the resulting bogus width/height values occasionally produced a loop large enough to be indistinguishable from an infinite hang within any reasonable test window, while a static single-frame capture looked completely normal. Found via a heartbeat counter proving the mainloop had stopped completing passes, not via any error at build or load time -- the assembler had no way to know the label was semantically wrong, only that it resolved to a valid address.

## Precondition

A code generator emits BOTH a data table's label and (conditionally, or in a separate code path) its real entries, especially when a 'the label must exist even in the empty case' requirement pushes the label's placement earlier than the entries it is meant to point at. Verify: does the label sit immediately before the actual pointer/entry list in every code path, not just the trivial one? A byte-for-byte diff of the generated output between the empty and non-empty cases is a cheap way to catch this before it ever reaches runtime.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
