# Critter/item art is found via packed FID -> .lst index lookup, not a direct filename

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

proto.rs's .pro parser had always read a critter/item's fid field (Header::fid) but never propagated it past read_header -- there was no way to find which .FRM sprite belongs to a given recipe entry. Decoded the packed FID format from vault13 (bits: direction(3)/kind(4)/anim(8)/sub_anim(4)/idx(12)) and confirmed against real data: Cave Rat's fid 0x1000018 decodes to kind=Critter idx=24, which resolves against the real art/critters/critters.lst to basename 'masrat', and art/critters/masrataa.frm genuinely exists and decodes to real rat art. The idx is a direct line number into the matching .lst file (art/critters/critters.lst for critters), not an encoded filename -- the .lst is required to go from fid to basename.

## Precondition

Any future need to find a critter or item's sprite file from recipe data (games/fallout1/recipe/{items,critters}.json) should use the fid field plus tools/datx/src/fid.rs::decode + lst_basename against the matching archive's .lst file (art/critters/critters.lst for critters; other entity kinds -- item, scenery, wall, tile -- use their own .lst under a different art/ subdirectory per EntityKind::dir(), not yet needed or verified by this project). A resolved basename is not a specific frame file -- a critter has many .frm variants (direction x animation x weapon), picking the right one for a given use (world sprite, combat pose, etc.) is a separate judgement call.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
