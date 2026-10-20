# T0018: fully SD2IEC-based build — no cartridge, no EasyFlash, no Kung Fu Flash purchase

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

User's explicit call after VICE-based development proved out (vertical slice, streaming, art pipeline, engine fingerprint all verified working). All storage is now floppy/SD2IEC (FAT-access, no disk images needed per the 2026-08-12 finding) -- no cart-resident code or art. This reverses the 'cart+disk hybrid' framing locked at T0021/T0027 and the RAM budget claim in games/fallout1/NOTES.md that engine code 'costs zero RAM because it executes from cart ROM' -- that assumption is now false, code lives in the C64's 64KB RAM like everything else. It also resolves the TFC3+/data-cart cartridge-port conflict noted in ports/fallout1-c64/NOTES.md's hardware section for free: with no data cart competing for the port, the user's existing TFC3+ can be used as a dev tool (fastloader, freezer, machine-code monitor) with no Kung Fu Flash purchase needed to resolve the conflict.

## Precondition

Any future design or budget claim that assumes cart-resident code, cart-resident art, or an EasyFlash-class ~1MB read-only library is now WRONG and must be re-derived under floppy/SD2IEC-only storage. The RAM budget (previously '~20-22KB comfortable, because code is in cart') needs redoing: code now competes with data for the 64KB address space. Art asset loading now needs the same per-scene streaming design T0023 proved for text, not a cart->RAM bank copy.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
