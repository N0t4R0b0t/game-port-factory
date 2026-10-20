# Measure compression per-record, never whole-corpus

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-12

## Decision

Whole-corpus ratios are a fiction on 8-bit targets: the CPU cannot inflate a multi-megabyte solid stream into RAM to reach one record. Measured on Fallout 1 MSG: exomizer gave 3.23x whole-corpus but only 2.56x per-file — the usable figure was 40% worse. Always measure at the granularity the engine will actually address.

## Precondition

Target must randomly access individual records at runtime AND lacks RAM to hold the decompressed whole. Does not apply to data decompressed once into RAM at load time (levels, tilesets).

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Companion rule (added 2026-08-12)

**Filter the corpus to shippable scope before measuring.** On fallout1-c64 the MSG corpus was
measured at 6.0 MB and drove the cart-size, streaming and script-cut conclusions. It contained
English, French and Spanish; the port ships English. The real figure was 1.94 MB raw and
0.74 MB compressed, which fits the cart the earlier number had ruled out.

Measuring the right thing badly is recoverable. Measuring the wrong thing precisely is not.

## Outcome

_Fill in after the port ships: did this hold up?_
