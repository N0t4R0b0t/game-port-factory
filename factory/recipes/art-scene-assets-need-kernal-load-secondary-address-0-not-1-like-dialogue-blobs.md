# Art/scene assets need KERNAL LOAD secondary address 0, not 1 like dialogue blobs

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

T0023's per-conversation streaming always used SETLFS secondary=1 ('honour the file's own load address'), correct for a self-describing text blob loaded once per conversation. T0035's sprite loading needs secondary=0 ('load to the address I specify in X/Y') instead, because the whole point of scene-based art streaming is reusing the SAME VIC-bank buffer address across many different loaded files -- the file itself can't be trusted to carry the right address, since it's the SAME destination for every scene's sprite set, not a per-file property.

## Precondition

Any future LOAD call for an asset that reuses a fixed destination buffer (VIC-bank graphics, any double-buffered or reused RAM region) needs secondary=0 with the destination address passed in X/Y. Secondary=1 stays correct only for self-contained, one-shot blobs like a dialogue conversation where the file's own embedded address is the whole reason the format works (LOAD"NAME",8,1 straight into $C000).

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
