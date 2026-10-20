//! Packages one room's scenery for the CoCo2 target: reads the original
//! FRAMES.DAT (Spectrum bit-packed source sprites, decoded per
//! tools/spritedata's confirmed format) and rooms.json (T0008/T0014's
//! decoded placement list, including the confirmed `pixel_x` transform),
//! and emits a 6809-assembler-includable data file.
//!
//! Deliberately does NOT replicate the Spectrum's own bit-packing on the
//! target -- this is a reimplement, not a source-port (see NOTES.md
//! Strategy section), so sprite data is re-packed into CoCo2-native
//! 8-pixels-per-byte, MSB-first bitmaps (matching PMODE4's own format).
//! This keeps the on-target blit routine simple: source and destination
//! share the same bit-packing, only the horizontal *position* (not the
//! source format) needs sub-byte handling.

use clap::Parser;
use roompack::lz;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

fn parse_glyph_override(s: &str) -> Result<(u8, [u8; 8]), String> {
    let (code, bytes) = s
        .split_once(':')
        .ok_or_else(|| format!("expected CODE:b0,...,b7, got {s:?}"))?;
    let code: u8 = code.parse().map_err(|e| format!("bad glyph code: {e}"))?;
    let parts: Vec<&str> = bytes.split(',').collect();
    if parts.len() != 8 {
        return Err(format!("expected exactly 8 bytes, got {}", parts.len()));
    }
    let mut out = [0u8; 8];
    for (i, p) in parts.iter().enumerate() {
        let p = p.trim().strip_prefix("0x").unwrap_or(p.trim());
        out[i] = u8::from_str_radix(p, 16).map_err(|e| format!("bad byte {p:?}: {e}"))?;
    }
    Ok((code, out))
}

#[derive(Parser)]
struct Args {
    /// Path to the original FRAMES.DAT (HEX-text PDS listing)
    #[arg(long)]
    frames: PathBuf,

    /// Path to rooms.json (from tools/roomdata)
    #[arg(long)]
    rooms: PathBuf,

    /// Room index to pack
    #[arg(long)]
    room: usize,

    /// Comma-separated frame ids to despeckle (see despeckle_row) --
    /// e.g. tiles directly under a sprite that shows visible detail
    /// leakage through mask "preserve" holes. Off by default: applying
    /// this room-wide once made NTSC fringing worse, not better (see
    /// NOTES.md) -- scope it narrowly to specific frames only.
    #[arg(long, value_delimiter = ',')]
    despeckle_frames: Vec<u8>,

    /// T0220: comma-separated frame ids to reduce to DRAWN STRUCTURE only --
    /// every pixel not in a horizontal or vertical run of at least
    /// --structure-run is dropped (structure_mask, the same test regularize
    /// uses, but standalone rather than as a step of --shade).
    ///
    /// This exists because the Spectrum artists used 50% checkerboard fill to
    /// suggest a flat mid-tone that their COLOUR ATTRIBUTE then tinted. On a
    /// 1bpp screen that fill is just a checkerboard, it swamps the linework
    /// underneath, and its isolated pixels become NTSC artifact-colour
    /// speckle. Playtest: "the pictures on the wall are illegible, I cannot
    /// tell what is on them at all" (room 52's picture, frame 160).
    ///
    /// PER-FRAME on purpose, never global: regen_art.sh's own header records
    /// that every global transform here was reverted once T0028 fixed the
    /// video mode, because verbatim beat every processed version on the troll
    /// (frame 96). Do not add a solid-placement frame to this list -- the
    /// collision mask is rasterised FROM that ink (derive_room_cmask), so
    /// thinning it can put holes in floors.
    #[arg(long, value_delimiter = ',')]
    structure_frames: Vec<u8>,

    /// Enable attribute-byte -> ordered-dither tonal shading (T0025).
    /// Off by default so the flat-white rendering stays reproducible for
    /// before/after comparison.
    #[arg(long)]
    shade: bool,

    /// Duty cycle the DARKEST source colour gets in the regularized fill
    /// (brightest always reaches 1.0). Lower = more tonal separation but
    /// sparser interiors. 0.35 is the tuned default -- see NOTES.md T0025.
    #[arg(long, default_value_t = 0.35)]
    dither_floor: f32,

    /// Minimum run length (horizontal or vertical) for a pixel to count as
    /// DRAWN STRUCTURE rather than dither noise, and so be preserved
    /// verbatim. 3 keeps outlines and mortar lines while letting the
    /// artists' 50% texture fill be replaced.
    #[arg(long, default_value_t = 3)]
    structure_run: usize,

    #[arg(long)]
    output: PathBuf,

    /// Path to a shared sprite-bitmap file, deduplicated ACROSS rooms in
    /// one regen_art.sh run. Plain (unshaded, unmirrored -- the only kind
    /// this project's verbatim pipeline ever produces) room-placement
    /// sprites are genuinely IDENTICAL bytes regardless of which room
    /// uses them (frame 134's wall tile is the same bitmap in room 35, 36
    /// and 52), but before this flag every room emitted its own private
    /// copy under a room-prefixed label (r36_spr_134 vs r35_spr_134),
    /// wasting real bytes in a build that is already within a few hundred
    /// bytes of its hard memory ceiling (NOTES.md T0035). With this flag,
    /// a frame is emitted ONCE under a global label (spr_134, no room
    /// prefix) into this shared file the first time any room needs it;
    /// later rooms in the same run just reference that existing label.
    /// The file is regenerated whole each run (read, extend, rewrite),
    /// same as every other output here -- never hand-edited. Run rooms
    /// in the SAME order every time (regen_art.sh does) so the shared
    /// file's contents are deterministic.
    #[arg(long)]
    shared_sprites: Option<PathBuf>,

    /// Once --shared-sprites' primary file's EXISTING content reaches this
    /// many bytes, new frames go to --shared-sprites-overflow instead.
    /// Exists because this build has two separate small unused RAM blocks
    /// to place shared data in (NOTES.md T0035/T0033 memory audit), not
    /// one big one -- the primary file has to stop well short of filling
    /// its own block, or a later room's frame would tip the WHOLE shared
    /// file past that block's boundary into the live framebuffer or ROM.
    /// Approximate (compares against the file's raw text length, not its
    /// exact compiled byte count) -- keep it conservative and verify
    /// headroom in both blocks after any regen (see regen_art.sh).
    #[arg(long)]
    shared_sprites_budget: Option<usize>,

    /// Second shared-sprite file, used once --shared-sprites-budget is
    /// exceeded. See --shared-sprites-budget.
    #[arg(long)]
    shared_sprites_overflow: Option<PathBuf>,

    /// T0121: with --shared-sprites (and --shared-sprites-overflow), only
    /// REFERENCE frames those files already hold; emit every other frame
    /// locally under the room prefix and never write to the shared files.
    /// For rooms that must not grow the shared pool -- its overflow half
    /// lives in the nearly-full r9800 block, which is why rooms 67/83/84/85/
    /// 86/100 were generated fully self-contained, duplicating ~2KB of tiles
    /// the pool already had. Run these rooms AFTER every pool-feeding room.
    #[arg(long)]
    shared_sprites_reuse_only: bool,

    /// T0167: global, per-BUILD frame index table (index -> sprite header
    /// address), shared across every roompack invocation in one
    /// regen_art.sh run -- read/extend/rewrite, exactly the same
    /// incremental pattern --shared-sprites already uses. There are under
    /// 256 distinct sprite labels used by room_placements across the whole
    /// game, so a 1-byte index here replaces the 2-byte `fdb` pointer each
    /// placement used to carry, shrinking a placement record from 4 bytes
    /// to 3 (room36.asm's derive_room_cmask and rd_sortplaces resolve the
    /// index back to a real pointer; rd_placelp, the PER-FRAME draw path,
    /// never sees an index at all -- rd_sortplaces resolves once, at room
    /// load, into the same 4-byte RAM record the draw path always used).
    /// Indexes EVERY label used by a static room_placements entry, shared
    /// or room-private -- it is keyed on the exact label (as label_for()
    /// returns it), not on the raw frame id, so two rooms that privately
    /// emit the same raw frame under different labels get two separate
    /// table entries; this only costs a spare index, never correctness.
    #[arg(long)]
    frame_table: Option<PathBuf>,

    /// T0235: LZ-pack this room's own per-room data (placements + flames +
    /// water, the exact concatenation load_room's SOURCE-order table plus
    /// the two animated-tile tables would otherwise ship raw) with the
    /// same codec as the title screen (tools/roompack/src/lz.rs, mirrored
    /// by lz_unpack in target/boot_code.asm). Emits ONE `room_packed` blob
    /// instead of the three raw tables, and changes the room_desc record:
    /// room_placements_ptr points at the packed blob and
    /// room_placements_end is emitted as the sentinel 0 (never a valid ROM
    /// address) so load_room (gated `if TAPE_ROOMS`) knows to unpack this
    /// room into ROOM_UNPACK_BUF before deriving its mask, instead of
    /// reading room_placements_ptr/end as a raw ROM table directly. Also
    /// emits an assemble-time guard against ROOM_UNPACK_BUF_LEN (defined
    /// in room36.asm, must already be in scope) so a room whose raw data
    /// grows past the shared unpack buffer fails to assemble instead of
    /// silently corrupting the next room's data at runtime.
    ///
    /// TAPE_ROOMS build only -- the -run build's load_room has no matching
    /// unpack branch, so a room built with this flag would read garbage
    /// there. Never combine with the -run build's own regen_art.sh calls.
    #[arg(long, default_value_t = false)]
    pack_room_data: bool,

    /// T0121: emit the animated flame and water tiles ONCE, under global
    /// labels (flame_table / water_table), into this file, and have each room
    /// alias its own table onto them. They were byte-identical in every room
    /// that had them -- 12 copies of the flames, 3 of the water. The first
    /// room that needs a set writes it; later rooms verify theirs is
    /// identical and fail loudly if not. Delete the file before a regen run.
    #[arg(long)]
    shared_anim: Option<PathBuf>,

    /// Also emit the text font (T0025). The glyphs are just ordinary
    /// frames -- glyph index == ASCII code, verified by rendering frames
    /// 65-90 and getting exactly A-Z -- so they decode through the same
    /// path as scenery and draw through the same `blit` routine. Never
    /// shaded: text stays solid.
    #[arg(long)]
    font_output: Option<PathBuf>,

    /// Replace one font glyph's 8 bytes with a hand-drawn bitmap instead of
    /// the extracted Spectrum ROM character. Format: "CODE:b0,b1,...,b7",
    /// bytes as 0x-prefixed hex, one row each, MSB-first (same convention
    /// as every other packed sprite here). Repeatable.
    ///
    /// Exists for T0077's status-bar icon: this port draws every glyph in
    /// FONT_FIRST..FONT_LAST from the ORIGINAL Spectrum font whether or
    /// not any message text ever uses that code (see font_output's own
    /// header comment -- glyph index IS the ASCII code, verbatim, no
    /// per-glyph opt-out). A custom icon glyph therefore has to occupy a
    /// code THIS GAME NEVER PRINTS in real dialogue (checked against every
    /// string in gap_messages.asm/actors.json -- J/M/Q/X/Z are unused),
    /// substituted here rather than hand-edited into the generated
    /// font_data.asm, which regen_art.sh would overwrite on the next run.
    #[arg(long, value_parser = parse_glyph_override)]
    glyph_override: Vec<(u8, [u8; 8])>,

    /// actors.json from tools/actordata. When given, emits the live actor
    /// table (T0027) and the sprites those actors need.
    #[arg(long)]
    actors: Option<PathBuf>,

    /// Rooms whose actor sprites should be emitted. Actors live in ONE
    /// global table (as the original's movingdata does, so a picked-up
    /// item stays gone when you leave and come back), but only the rooms
    /// actually built need their sprite art in the binary.
    #[arg(long, value_delimiter = ',')]
    actor_rooms: Vec<usize>,

    #[arg(long)]
    actor_output: Option<PathBuf>,

    /// T0234: suffix appended to the actor table's own global symbols
    /// (ACTOR_STRIDE/ACTOR_COUNT/actor_init/ACTOR_SPR_N/actor_spr_tab)
    /// when this invocation emits a SECOND, independent actor table that
    /// must coexist with the main one already assembled earlier in the
    /// same build (the tape-only region's own actor_data_tape.asm,
    /// alongside the -run build's actor_data.asm -- same coupling class
    /// as frame_table_data_tape.asm, T0233-fix). Also skips re-emitting
    /// ROU_* (routine id) equs, which the main table already defines and
    /// which this table's routine ids are the SAME values for (the
    /// dense id space is shared, only the table+its RAM differ). Empty/
    /// absent (the default) reproduces today's actor_data.asm output
    /// byte-for-byte -- this flag exists ONLY for a second call.
    #[arg(long)]
    actor_suffix: Option<String>,

    /// T0234: skip emitting the coin table (COIN_STRIDE/COIN_COUNT/
    /// coin_init) for this --actors call. Coins are not an actor (see
    /// CoinRec's own doc comment) and are out of scope for a SECOND actor
    /// table this round -- without this, a tape-region actor call whose
    /// rooms also have coins would emit a second, colliding coin_init.
    #[arg(long, default_value_t = false)]
    actor_no_coins: bool,

    /// T0236: suffix appended to the coin table's own global symbols
    /// (COIN_STRIDE/COIN_COUNT/coin_init) for a SECOND, independent coin
    /// table (the tape-only region's own, alongside the -run build's
    /// resident coin_init) -- same coupling class as --actor-suffix.
    /// Implies the coin sprite (aspr_0_*) is NOT re-emitted: it's assumed
    /// already defined by the base table this call is layered on top of
    /// (coin_init always has at least one entry there, T0057).
    #[arg(long)]
    coin_suffix: Option<String>,

    /// T0236: emit ONLY the coin table (honouring --coin-suffix and
    /// --actor-rooms as the room filter) -- no ACTOR_STRIDE/COUNT/
    /// actor_init/ROU_*/sprites/actor_spr_tab at all. For a call whose
    /// only job is a second coin table over rooms whose actors (if any)
    /// already exist in some earlier, already-assembled actor table --
    /// re-emitting them here under a new suffix would be dead, wasted
    /// data since nothing will ever dispatch through this table's own
    /// actor_init.
    #[arg(long, default_value_t = false)]
    coins_only: bool,

    /// T0234: routine NAMES (matching ROUTINES) to drop from this
    /// --actors call entirely, room filter notwithstanding. Exists for
    /// actors whose routine id is ALSO special-cased in draw_actors'
    /// dispatch (ROU_LIFT -> draw_lift, which reads per-room bounds from
    /// ul_bounds/logic_low.asm) -- including one of these as a plain
    /// inert table entry would still run that special-cased draw path
    /// against a room ul_bounds has no entry for, not fall back to
    /// ordinary static rendering the way an un-special-cased routine
    /// (dragon/log/hawk/etc, still genuinely inert) safely does.
    #[arg(long, value_delimiter = ',')]
    actor_exclude_routines: Vec<String>,

    /// T0234: an already-generated actor_data.asm (or actor_data_tape.
    /// asm) file whose `aspr_<frame>_w` labels this call must NOT
    /// redefine -- still referenced from actor_spr_tab (the frame,
    /// pointer pair is still emitted), just not re-emitted as a second,
    /// colliding copy of the same sprite bytes. Exists because a tape
    /// actor can share a frame with one the -run build already drew
    /// (room 40's second dragon, frame 109, same as room 54's) --
    /// without this, roompack has no way to know that frame's art is
    /// already assembled elsewhere in the same final image.
    #[arg(long)]
    actor_reuse_sprites: Option<PathBuf>,

    /// T0234: also emit a PRISTINE, never-mutated copy of this table
    /// under `actor_init{suffix}_template`, byte-identical to
    /// `actor_init{suffix}` at assembly time. For a table that lives
    /// directly in mutable RAM with no separate ROM master (the tape
    /// region's own actor_init_tape, T0230's "delivered raw, no
    /// relocation" design -- see room36.asm's own comment) this is
    /// what a game-over -> new-game reset restores FROM, the same role
    /// actor_init (ROM, LZ-packed) already plays for the -run build's
    /// own actor_ram.
    #[arg(long, default_value_t = false)]
    actor_template: bool,

    /// Actor frame ids that need a horizontally-mirrored variant too
    /// (T0030 follow-up: the rat has no left/right sprite pair of its
    /// own in FRAMES.DAT, unlike Dizzy, so a real playtest found it
    /// never visibly turned around while patrolling). Emitted ONLY for
    /// the frames listed here, not every actor -- memory is tight
    /// below the framebuffer (see NOTES.md), and most actors don't
    /// need it.
    #[arg(long, value_delimiter = ',')]
    mirror_frames: Vec<u8>,

    /// Extra actor sprite frames to emit even though no actor slot names
    /// them (T0058). Animated actors switch frames at RUNTIME -- the
    /// crocodile's slot says 123, but its routine flips to 124 for the
    /// open mouth -- and the slot table alone cannot know that.
    #[arg(long, value_delimiter = ',')]
    extra_actor_frames: Vec<u8>,

    /// T0228: frames whose sprite is emitted (aspr_N_w/_h/_bpr/data) but NOT listed in
    /// actor_spr_tab -- code that names the label directly (the heart demo's hearts, room
    /// 3's Dizzy figure) never scans the table, so a 3-byte entry each is dead weight.
    #[arg(long, value_delimiter = ',')]
    no_tab_frames: Vec<u8>,

    /// Morphological-closing iterations applied to ACTOR sprites before
    /// tonal shading (see close_gaps' own doc comment for why). 0 = off
    /// (default -- opt in per the project's own established pattern for
    /// anything that trades fidelity for looks). Does not touch room
    /// placements/walls -- those are a genuinely different problem
    /// (evenly-distributed 50% dither, not scattered detail loss) with
    /// its own already-tuned fix (--dither-floor).
    #[arg(long, default_value_t = 0)]
    close_actor_sprites: usize,

    /// Replace filled/dithered shading with solid outline art: derive each
    /// shape's true silhouette (closing scattered raw dither first, same as
    /// --close-actor-sprites) and keep only its 1px boundary ring, leaving
    /// the interior empty. Sidesteps NTSC artifact-colour and dither-density
    /// problems entirely -- it's just solid ink on solid background, no
    /// pattern to misrender. Applies to both room placements and actor
    /// sprites; overrides --shade's fill behaviour (tone still selects which
    /// placements get outlined vs left solid via structure, but no longer
    /// selects a dither duty cycle).
    #[arg(long, default_value_t = false)]
    outline: bool,

    /// NTSC artifact colour: keep ink only on EVEN screen columns, which a
    /// composite CoCo2 renders as solid orange/red instead of white (see
    /// NOTES.md T0033-note for the measured palette). Applies to the
    /// animated flame tiles. Costs half the horizontal resolution IN THOSE
    /// TILES ONLY, which is free for a solid-filled blob like a flame and
    /// would be ruinous on 1px detail.
    #[arg(long, default_value_t = false)]
    colour_flames_orange: bool,

    /// As --colour-flames-orange but ODD columns, which render blue.
    /// Applies to the animated water tiles.
    #[arg(long, default_value_t = false)]
    colour_water_blue: bool,

    /// Actor frames to render in artifact ORANGE (even columns). Intended
    /// for solid-filled pickups (the apple, the loaf) -- see
    /// --colour-flames-orange for the resolution cost, which is only
    /// acceptable on shapes that are mostly solid fill.
    #[arg(long, value_delimiter = ',')]
    colour_actor_orange: Vec<u8>,

    /// Actor frames to render in artifact BLUE (odd columns), e.g. the jug
    /// of water.
    #[arg(long, value_delimiter = ',')]
    colour_actor_blue: Vec<u8>,
}

/// movingrous jump-table order (T0013). The `routine` field in
/// actors.json is a symbolic label; the target needs a small dense id to
/// dispatch on, and this IS that table's order, so ids match the
/// original's own type numbering.
const ROUTINES: [&str; 20] = [
    "portcullis", "portswitch", "pickupable", "armorog", "dragon",
    "crocodile", "log", "hawk", "machines", "lift",
    "dozyfloat", "rat", "troll", "dagger", "door",
    "crowbar", "miner", "daisy", "switch1", "daisy1",
];

#[derive(Deserialize)]
struct ActorsFile {
    actors: Vec<ActorRec>,
    #[serde(default)]
    coins: Vec<CoinRec>,
}

/// A `cointable` entry (T0057). Not an actor: coins have no behaviour
/// routine, no per-frame update and no RAM slot of their own in the
/// original -- the table IS the state, with bit 7 of the room byte
/// meaning "already collected".
#[derive(Deserialize)]
struct CoinRec {
    room: i64,
    pixel_x: i64,
    y: i64,
}

/// T0199: actors whose INITIAL room must come from `orig_room`, not
/// `room`. The original resets every actor from its orig_* fields right
/// after the title screen (`resetmoving` -> `reseteach`), so an actor
/// with `orig_room = 255` is NOT in the world at game start -- it is
/// materialised later by whatever event gives it to you. `ropehere` is
/// the case that matters: `denziltalking` carries `defw ropehere+room`
/// and `talkingtopeople1` pokes the CURRENT room into it, so Denzil
/// hands the rope over. We had the rope sitting in room 68 from the
/// start, takeable without ever talking to him.
///
/// This is a LIST, not a blanket switch, because ten other actors also
/// have orig_room=255 and their triggers are NOT implemented yet
/// (shopkeeperhere x2, beanhere, carpethere x2, crowbarhere,
/// daisy1here and two unlabelled items; sleepingpotionhere joined the list
/// with T0218 -- dozytalking's `defw sleepingpotionhere+room`). Emitting
/// orig_room for those would remove them from the world with no way to
/// get them back -- worse than having them early. Add a label here when
/// its trigger lands. See NOTES.md T0199.
const ORIG_ROOM_LABELS: &[&str] = &[
    "ropehere", "sleepingpotionhere",
    // T0223: the shopkeeper (both halves) is not in the world until
    // `shopkeeperrou` appears him; the bean until `shoptalk` pokes it.
    "shopkeeperhere", "shopkeeperhere1", "beanhere",
    // T0227: room 94's carpets appear when the rug is thrown (proxrugrou).
    "carpethere", "carpethere1",
    // T0228: daisy1here (room 73) is not in the world until `daisyrou` (room 94)
    // moves her there after the meeting (X-ALL.TXT 3510-3512).
    "daisy1here",
    // T0229: the crowbar is not in the world until Doug's `dougtalking` pokes
    // `crowbarhere+room` (X-ALL.TXT 796; tape_talk in tape_code.asm does it).
    "crowbarhere",
];

/// T0223: actor labels kept even when their routine is in
/// --actor-exclude-routines. `shopkeeperhere1` is the shopkeeper's
/// mirrored second half and its routine id is `crowbar` (the original's
/// plain "do nothing" `rethere`), which the tape table excludes wholesale
/// for room 41's rock and room 94's carpets. T0226: `rockhere` (room 41,
/// frame 146, a static blocker the pickaxe removes) is kept too; the
/// carpets stay excluded.
///
/// T0227: the two carpets (`carpethere`/`carpethere1`, room 94, frame 210) are
/// kept as well -- proxrugrou puts them in the world over the two daggers.
///
/// T0228: Daisy in her prison (`daisyhere`, routine `daisy`, room 94) is kept too: `daisyrou`
/// is her meeting trigger. She sits between the lift (`daisylifthere`) and `switch1`, as in the source.
const KEEP_DESPITE_EXCLUDE: &[&str] = &["shopkeeperhere1", "rockhere", "carpethere", "carpethere1", "daisyhere"];

/// T0203: actors moved from the original's position because the CoCo2
/// cannot reproduce what made them readable on a Spectrum. The original
/// separates overlapping objects by COLOUR; PMODE4 has none, so an item
/// drawn in front of furniture of similar density simply vanishes into
/// it.
///
/// `ropehere` sat at (176,160) with **116 inked pixels** of chair
/// directly behind it -- the busiest 16x16 window on that floor -- and a
/// playtest could not find it: "it blends itself into the chair it sits
/// in front of, so it's hard to spot". (32,160) is the clearest
/// supported spot to its left: 19 inked pixels behind, on the same
/// floor, clear of the table (which starts at x=48).
///
/// Deviations from the source's own data, so each one needs a reason
/// like that written next to it.
const ACTOR_POS_OVERRIDE: &[(&str, i64, i64)] = &[("ropehere", 32, 160)];

/// T0204: actor SLOTS whose starting position must come from the
/// `orig_x`/`orig_y` reset fields rather than the live `movex`/`movey`.
/// `resetmoving` copies orig_* -> live for every actor right after the
/// title screen, so orig IS the game-start state -- the live fields are
/// wherever that actor happened to be when the snapshot was taken.
///
/// Slot 46 is room 69's `dagger`: live (184,136), **orig (32,112)**. The
/// blade row a playtest reported as harmless is drawn by four frame-169
/// PLACEMENTS at x=16..55, y=112 -- and this actor is supposed to sit in
/// it at (32,112), which is what makes it lethal. We had it parked at
/// (184,136) at the bottom of a shaft two-thirds of the room away, so
/// walking through the blades did nothing. Confirmed against the real
/// game: walking right from (8,127) kills at x=12 there and not here.
///
/// A LIST, not a blanket switch: four other built-room actors also
/// differ, and three of them this port has deliberately tuned --
/// `porthere` (the portcullis starts CLOSED at 136, T0115, where orig
/// says 96), `rathere` (orig x=256 is off-screen) and room 71's lift.
/// Verify one before adding it.
/// T0223: slot 10 is `beanhere` (live (68,160), orig (62,144)): the bean
/// appears where `resetmoving` puts it, not where the snapshot left it.
const ORIG_POS_SLOTS: &[i64] = &[46, 10];

#[derive(Deserialize)]
struct ActorRec {
    #[serde(default)]
    slot: i64,
    room: i64,
    #[serde(default)]
    orig_room: i64,
    #[serde(default)]
    orig_x: i64,
    #[serde(default)]
    orig_y: i64,
    routine: String,
    x: i64,
    /// Real screen pixel x -- see tools/actordata's own doc comment on
    /// this field for the (x-32)*4 derivation. Use THIS for placement,
    /// not `x`, which is the original's compact on-disk encoding.
    pixel_x: i64,
    y: i64,
    frame: i64,
    colour: i64,
    label: Option<String>,
}

/// Printable glyph block. Frames below this are scenery sprites, not
/// glyphs (32-37 are 6x28-ish objects), and 91+ drop to 8x6.
const FONT_FIRST: u8 = 38;
const FONT_LAST: u8 = 90;

/// The torch-flame frame. `updateflames`/`printflame` (X-ALL.TXT 2238)
/// animate it from a 16-step counter: bit 0 alternates the colour
/// between attribute 70 (yellow, bright) and 66 (red, bright), bit 1
/// mirrors the sprite horizontally. Flames are pulled OUT of the static
/// placement list and emitted as their own animated list, exactly as the
/// original keeps `flamelist` separate from room scenery.
const FLAME_FRAME: u8 = 115;
const FLAME_ATTR_A: u8 = 70; // yellow bright
const FLAME_ATTR_B: u8 = 66; // red bright

/// Water (T0032 follow-up). `addtowater`/`updatewater` (X-ALL.TXT
/// ~2097/2183): placements use frame 91 as a trigger to register into
/// `waterlist`, but the actual animation cycles frames 92-95 (a
/// 4-step counter, `and %11` then `+92`) -- water genuinely ripples,
/// it isn't a colour-flip like the flame. It's also a real hazard in
/// the original (drowns on contact); this port didn't have any water
/// at all until a real playtest flagged room 35's pool as missing.
const WATER_TRIGGER_FRAME: u8 = 91;
const WATER_ANIM_FIRST: u8 = 92;
/// Lower than the room default: the flame's two tones need to be far
/// apart to read as a flicker, and a small sprite tolerates it.
const FLAME_DITHER_FLOOR: f32 = 0.30;

fn mirror_grid(g: &Grid) -> Grid {
    g.iter().map(|row| row.iter().rev().copied().collect()).collect()
}

/// close_gaps: morphological closing (dilate then erode, 4-connected
/// plus-shaped element), `iterations` times each. Confirmed by decoding
/// the RAW source bytes directly (no processing at all) that some actor
/// sprites -- the troll specifically -- are drawn as genuinely scattered
/// ink at native 1-bit resolution: on the real Spectrum this reads fine
/// because a single colour ATTRIBUTE binds every dot into one solid
/// green shape, but PMODE4 has no equivalent per-cell colour plane, so
/// the same bits read as noise with nothing to bind them. Real playtest:
/// "the troll for example is barely perceptible".
///
/// This is a real, disclosed trade: closing merges nearby scattered ink
/// and fills small gaps, trading exact fidelity to the original pixel
/// pattern for a shape that reads as one coherent creature instead of
/// static. It cannot invent detail that was only ever encoded as "colour
/// here", and a big enough gap between clusters still won't close --
/// this helps sprites whose real problem is scattered dot-noise, not
/// sprites that are missing large connected regions.
///
/// Dilate then erode by the SAME iteration count keeps the silhouette's
/// overall size roughly stable (dilate grows it, erode shrinks back by
/// the same margin) while a hole dilate fully closed STAYS closed --
/// erode can only remove ink touching an OFF neighbour, and a filled
/// hole's pixels no longer touch one after the dilate pass.
///
/// Pads with `iterations` OFF cells on every side before processing and
/// crops back after, so the sprite's own true outer boundary doesn't
/// erode away just because "off the edge of the bitmap" would otherwise
/// look like an OFF neighbour.
fn dilate_once(bits: &Grid) -> Grid {
    let (h, w) = (bits.len(), bits[0].len());
    (0..h)
        .map(|y| {
            (0..w)
                .map(|x| {
                    if bits[y][x] != 0 {
                        return 1;
                    }
                    let ns: [(i32, i32); 4] = [(0, -1), (0, 1), (-1, 0), (1, 0)];
                    for (dx, dy) in ns {
                        let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                        if nx >= 0 && ny >= 0 && (nx as usize) < w && (ny as usize) < h
                            && bits[ny as usize][nx as usize] != 0
                        {
                            return 1;
                        }
                    }
                    0
                })
                .collect()
        })
        .collect()
}

fn erode_once(bits: &Grid) -> Grid {
    let (h, w) = (bits.len(), bits[0].len());
    (0..h)
        .map(|y| {
            (0..w)
                .map(|x| {
                    if bits[y][x] == 0 {
                        return 0;
                    }
                    let ns: [(i32, i32); 4] = [(0, -1), (0, 1), (-1, 0), (1, 0)];
                    for (dx, dy) in ns {
                        let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                        if nx < 0 || ny < 0 || (nx as usize) >= w || (ny as usize) >= h
                            || bits[ny as usize][nx as usize] == 0
                        {
                            return 0;
                        }
                    }
                    1
                })
                .collect()
        })
        .collect()
}

fn close_gaps(bits: &Grid, iterations: usize) -> Grid {
    if iterations == 0 {
        return bits.clone();
    }
    let (h, w) = (bits.len(), bits[0].len());
    let pad = iterations;
    let (ph, pw) = (h + pad * 2, w + pad * 2);
    let mut padded = vec![vec![0u8; pw]; ph];
    for y in 0..h {
        for x in 0..w {
            padded[y + pad][x + pad] = bits[y][x];
        }
    }
    for _ in 0..iterations {
        padded = dilate_once(&padded);
    }
    for _ in 0..iterations {
        padded = erode_once(&padded);
    }
    (0..h)
        .map(|y| (0..w).map(|x| padded[y + pad][x + pad]).collect())
        .collect()
}

/// Plain Bayer thinning: drop ink the threshold rejects.
///
/// NOTES.md records thinning as a DEAD END -- and it is, for the room
/// masonry, where the source art is already a 50% checkerboard covering
/// most of the screen and removing more of it reads as damage. A torch
/// flame is the opposite case and thinning is right for it: a small,
/// isolated, mostly-solid bright object against black, where dropping
/// pixels reads as "dimmer" exactly as intended. Structure-preserving
/// `regularize` is useless here for the same reason it is good on walls
/// -- a thin flame is almost ALL structure runs, so it preserves nearly
/// every pixel and the two tone variants come out 2% apart, an invisible
/// flicker. Measured, not assumed.
fn thin(grid: &Grid, threshold: u8, y_phase: usize) -> Grid {
    if threshold >= 16 {
        return grid.clone();
    }
    grid.iter()
        .enumerate()
        .map(|(r, row)| {
            row.iter()
                .enumerate()
                .map(|(c, &v)| {
                    if v != 0 && BAYER4[(y_phase + r) % 4][c % 4] < threshold { 1 } else { 0 }
                })
                .collect()
        })
        .collect()
}

// --- attribute byte -> tone (T0025) ---------------------------------
//
// The Spectrum attribute byte we already parse for collision (bit 6 =
// solidity, T0022) also carries the ink colour the original intended.
// Room 36 is 45 placements of non-bright red masonry plus a handful of
// bright torch/decoration accents -- a dim red dungeon lit by bright
// flames. Rendering both at full white (what this port did before
// T0025) throws that away and is exactly why the scene reads as one
// flat noisy field with no figure/ground separation.
//
// PMODE4 has no colour to give back, so map the ink's LUMINANCE to a
// dither duty cycle instead: dark inks keep fewer pixels and read as
// dimmer texture, bright inks stay solid. Spectrum ink bit layout is
// b0=blue, b1=red, b2=green; non-bright is ~80% intensity.
fn ink_luminance(attr: u8) -> f32 {
    let ink = attr & 7;
    let bright = (attr >> 6) & 1;
    let b = (ink & 1) as f32;
    let r = ((ink >> 1) & 1) as f32;
    let g = ((ink >> 2) & 1) as f32;
    let l = 0.299 * r + 0.587 * g + 0.114 * b;
    l * if bright == 1 { 1.0 } else { 0.8 }
}

// Standard 4x4 Bayer matrix, values 0-15. Period 4 in both axes matters:
// every pixel_x is a multiple of 4 (the confirmed placement granularity),
// so the horizontal phase is always 0 and only the vertical phase can
// vary -- which is what keeps the sprite-variant count down. An 8x8
// matrix would double the variants by introducing two x-phases, and was
// rejected on those grounds as well as on looks.
const BAYER4: [[u8; 4]; 4] = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
];

/// Luminance -> 0-16 Bayer threshold. 16 means "fully solid".
fn tone_threshold(attr: u8, dither_floor: f32) -> u8 {
    let duty = dither_floor + ink_luminance(attr) * (1.0 - dither_floor);
    (duty * 16.0).round().clamp(0.0, 16.0) as u8
}

type Grid = Vec<Vec<u8>>;

/// Fill enclosed dither holes: flood from the border through OFF pixels.
/// Anything OFF the flood never reaches is an interior gap in the artists'
/// texture, not real transparency -- that distinction is what lets the
/// refill stay inside the shape the original drew.
fn silhouette(bits: &Grid) -> Grid {
    let (h, w) = (bits.len(), bits[0].len());
    let mut outside = vec![vec![false; w]; h];
    let mut stack: Vec<(usize, usize)> = Vec::new();
    for x in 0..w {
        for y in [0, h - 1] {
            if bits[y][x] == 0 {
                stack.push((x, y));
            }
        }
    }
    for y in 0..h {
        for x in [0, w - 1] {
            if bits[y][x] == 0 {
                stack.push((x, y));
            }
        }
    }
    while let Some((x, y)) = stack.pop() {
        if bits[y][x] != 0 || outside[y][x] {
            continue;
        }
        outside[y][x] = true;
        if x + 1 < w { stack.push((x + 1, y)); }
        if x > 0 { stack.push((x - 1, y)); }
        if y + 1 < h { stack.push((x, y + 1)); }
        if y > 0 { stack.push((x, y - 1)); }
    }
    (0..h)
        .map(|y| (0..w).map(|x| u8::from(bits[y][x] != 0 || !outside[y][x])).collect())
        .collect()
}

/// Mark pixels belonging to a horizontal OR vertical run of >= minrun set
/// pixels. These are drawn structure -- outlines, mortar, the torch shaft --
/// and are preserved verbatim so regularizing the fill can't erode shapes.
fn structure_mask(bits: &Grid, minrun: usize) -> Grid {
    let (h, w) = (bits.len(), bits[0].len());
    let mut keep = vec![vec![0u8; w]; h];
    for y in 0..h {
        let mut x = 0;
        while x < w {
            if bits[y][x] != 0 {
                let s = x;
                while x < w && bits[y][x] != 0 { x += 1; }
                if x - s >= minrun {
                    for i in s..x { keep[y][i] = 1; }
                }
            } else { x += 1; }
        }
    }
    for x in 0..w {
        let mut y = 0;
        while y < h {
            if bits[y][x] != 0 {
                let s = y;
                while y < h && bits[y][x] != 0 { y += 1; }
                if y - s >= minrun {
                    for i in s..y { keep[i][x] = 1; }
                }
            } else { y += 1; }
        }
    }
    keep
}

/// T0025's actual transform: preserve drawn structure, and replace the
/// artists' 50% noise fill with a clean ordered pattern whose duty cycle
/// encodes the original ink's luminance. `y_phase` is the tile's screen-
/// space vertical alignment -- the Bayer field is indexed in SCREEN
/// coordinates so neighbouring tiles form one continuous pattern instead
/// of showing a seam at every placement boundary.
fn regularize(bits: &Grid, threshold: u8, y_phase: usize, minrun: usize) -> Grid {
    if threshold >= 16 {
        return bits.clone();
    }
    let sil = silhouette(bits);
    let keep = structure_mask(bits, minrun);
    bits.iter()
        .enumerate()
        .map(|(r, row)| {
            row.iter()
                .enumerate()
                .map(|(c, &v)| {
                    if keep[r][c] == 1 && v != 0 {
                        1
                    } else if sil[r][c] == 1 {
                        u8::from(BAYER4[(y_phase + r) % 4][c % 4] < threshold)
                    } else {
                        0
                    }
                })
                .collect()
        })
        .collect()
}

/// Solid outline: true filled silhouette minus its own 1px erosion, so only
/// the boundary ring survives and the interior is left empty (background).
/// `close_iters` closes scattered raw dither into a solid region first --
/// without it, silhouette()'s flood fill sees the artists' noise texture as
/// genuine holes reaching the border and the "shape" never closes.
fn outline_only(bits: &Grid, close_iters: usize) -> Grid {
    let closed = close_gaps(bits, close_iters.max(1));
    let sil = silhouette(&closed);
    let eroded = erode_once(&sil);
    sil.iter()
        .zip(eroded.iter())
        .map(|(sr, er)| sr.iter().zip(er.iter()).map(|(&s, &e)| u8::from(s != 0 && e == 0)).collect())
        .collect()
}

/// NTSC artifact colour: drop ink from every other SCREEN column so the
/// composite encoder resolves the area to a solid hue instead of white.
/// `even_columns` true -> orange/red, false -> blue (measured, NOTES.md
/// T0033-note). Screen alignment is safe to do sprite-locally because every
/// placement's pixel_x is a multiple of 4 (asserted elsewhere), so a
/// sprite's column 0 is always an even screen column.
///
/// This HALVES horizontal detail in whatever it touches. Only ever point it
/// at areas that are already solid fill -- on 1px linework it does not make
/// a coloured line, it makes a dotted one.
fn artifact_mask(bits: &Grid, even_columns: bool) -> Grid {
    bits.iter()
        .map(|row| {
            row.iter()
                .enumerate()
                .map(|(c, &v)| if (c % 2 == 0) == even_columns { v } else { 0 })
                .collect()
        })
        .collect()
}

fn unpack(packed: &[u8], w: usize, h: usize, bpr: usize) -> Grid {
    (0..h)
        .map(|r| (0..w).map(|c| (packed[r * bpr + c / 8] >> (7 - (c % 8))) & 1).collect())
        .collect()
}

fn repack(grid: &Grid, w: usize, h: usize, bpr: usize) -> Vec<u8> {
    let mut out = vec![0u8; bpr * h];
    for r in 0..h {
        for c in 0..w {
            if grid[r][c] != 0 {
                out[r * bpr + c / 8] |= 1 << (7 - (c % 8));
            }
        }
    }
    out
}

// --- FRAMES.DAT parsing (same PDS HEX-listing format as tools/spritedata) ---

fn parse_sections(text: &str, target_computer: &str) -> BTreeMap<String, Vec<u8>> {
    let mut sections: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut current_label: Option<String> = None;
    let mut cond_stack: Vec<bool> = Vec::new();
    let active = |stack: &[bool]| stack.iter().all(|b| *b);

    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("if computer=") {
            cond_stack.push(rest.trim() == target_computer);
            continue;
        }
        if line == "endif" {
            cond_stack.pop();
            continue;
        }
        if !active(&cond_stack) {
            continue;
        }
        if let Some(rest) = raw_line.strip_prefix('\t').and_then(|l| l.strip_prefix("HEX")) {
            let bytes = hex_decode(rest.trim());
            if let Some(label) = &current_label {
                sections.entry(label.clone()).or_default().extend(bytes);
            }
            continue;
        }
        if !raw_line.starts_with(char::is_whitespace) {
            current_label = Some(line.to_string());
        }
    }
    sections
}

fn hex_decode(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i + 1 < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16).expect("bad hex digit");
        let lo = (bytes[i + 1] as char).to_digit(16).expect("bad hex digit");
        out.push(((hi << 4) | lo) as u8);
        i += 2;
    }
    out
}

fn read_u16_le_table(data: &[u8], count: usize) -> Vec<u16> {
    (0..count)
        .map(|i| data[i * 2] as u16 | ((data[i * 2 + 1] as u16) << 8))
        .collect()
}

// --- rooms.json ---

#[derive(Deserialize)]
struct Placement {
    frame: u8,
    pixel_x: i32,
    y: u8,
    /// The room stream only carries a colour byte when it CHANGES; a
    /// placement with this set inherits the previous one's colour.
    same_colour_as_previous: bool,
    /// Game colour byte, layout documented in X-ALL.TXT ~line 1544:
    /// `7=rev 6=dull 5=atplot 4=plot 3..0=colour`. Bit 6 ("dull") is
    /// what the original's collision check keys on -- see SOLID_DULL_BIT.
    attribute_byte: Option<u8>,
}

/// Bit 6 of a placement's colour byte is "dull", and the original's
/// `checkattri` treats a set bit 6 as NOT collidable (`bit 6,a / ret nz`
/// returns without signalling a hit). So: **bit 6 clear = solid**.
/// Verified against room 36's actual data -- wall/floor brickwork
/// (attr=2) has it clear, while torches and decorative items
/// (attr=66/70/71) have it set, which matches what you can and can't
/// stand on in the real game.
const SOLID_DULL_BIT: u8 = 0x40;

/// Collision mask geometry: one bit per 4x4 pixel block over the whole
/// 256x192 screen. 4px matches the game's own movement/placement
/// granularity (NOTES.md "Correction #2"), so it loses nothing that
/// matters while costing only 384 bytes -- vs 6144 for a full 1bpp
/// bitmap, which would not fit alongside the two framebuffers.
// T0163 (Change 1, runtime half): the y-band placement index (T0064) is
// no longer built here. roompack now emits room_placements in SOURCE
// order (the collision-mask derivation's pass 1 needs LAST-WRITER-WINS
// in that exact order -- see the comment above room_placements below),
// and load_room builds the y-sorted copy + 16px band index into RAM
// itself, once per room change. See room36.asm's PLACE_BAND (still 16,
// 12 bands over 192 rows) and rd_sortplaces.

// T0166: CMASK_COLS/ROWS/STRIDE/LEN (64x48 4px-cell grid, 384 bytes) were
// this file's own constants for the collision-mask rasteriser that used
// to run here; removed with it (see the comment above room_placements).
// The grid itself is still real -- room36.asm's own CM_STRIDE/CMASK_BYTES
// define it now, on the runtime side, for derive_room_cmask.

#[derive(Deserialize)]
struct Room {
    index: usize,
    name: Option<String>,
    things: Vec<Placement>,
}

#[derive(Deserialize)]
struct RoomTable {
    rooms: Vec<Room>,
}

/// Despeckle filter: merges an isolated single pixel (differs from both
/// horizontal neighbors, which match each other) into its surrounding
/// run. Horizontal only. NOT applied room-wide by default -- doing that
/// once made NTSC artifact-color fringing worse, not better (turning
/// fine dot-dither into coarser bands apparently moved the pattern's
/// dominant frequency closer to the color subcarrier instead of away
/// from it; see NOTES.md). Kept as an opt-in, per-frame tool for
/// specific tiles that need it (e.g. a floor tile directly under a
/// sprite whose mask "preserve" holes are leaking visible detail
/// through it) -- not a general fix.
fn despeckle_row(bits: &mut [u8]) {
    if bits.len() < 3 {
        return;
    }
    let mut i = 1;
    while i < bits.len() - 1 {
        if bits[i] != bits[i - 1] && bits[i - 1] == bits[i + 1] {
            bits[i] = bits[i - 1];
        }
        i += 1;
    }
}

/// Decodes one frmtable-indexed sprite (source bit format, confirmed in
/// tools/spritedata: header [width_units, height], width_units&0x7f * 4 =
/// real pixel width, ceil(width_units/2) source bytes/row, no mask plane),
/// optionally despeckles each row (see despeckle_row), then re-packs to
/// CoCo2-native 8px/byte MSB-first rows.
fn decode_and_repack(defs: &[u8], offset: usize, despeckle: bool) -> (u32, u8, Vec<u8>) {
    let width_units = (defs[offset] & 0x7f) as u32;
    let height = defs[offset + 1];
    let pixel_width = width_units * 4;
    let src_bytes_per_row = (width_units as usize).div_ceil(2);
    let src_row_start = offset + 2;

    let dst_bytes_per_row = (pixel_width as usize).div_ceil(8);
    let mut packed = vec![0u8; dst_bytes_per_row * height as usize];

    let mut row_bits = vec![0u8; pixel_width as usize];
    for row in 0..height as usize {
        for px in 0..pixel_width as usize {
            let src_byte = defs[src_row_start + row * src_bytes_per_row + px / 8];
            row_bits[px] = (src_byte >> (7 - (px % 8))) & 1;
        }
        if despeckle {
            despeckle_row(&mut row_bits);
        }
        for px in 0..pixel_width as usize {
            if row_bits[px] == 1 {
                let dst_idx = row * dst_bytes_per_row + px / 8;
                packed[dst_idx] |= 1 << (7 - (px % 8));
            }
        }
    }
    (pixel_width, height, packed)
}

/// T0121: write `body` into the --shared-anim file as a named section the
/// first time; on later calls, insist the room's copy is identical (a room
/// needing a DIFFERENT flame or water tile must not silently get the shared
/// one).
fn shared_anim_section(path: &PathBuf, key: &str, body: &str) {
    let begin = format!("; >>> {key}\n");
    let end = format!("; <<< {key}\n");
    let existing = fs::read_to_string(path).unwrap_or_default();
    if let Some(start) = existing.find(&begin) {
        let rest = &existing[start + begin.len()..];
        let stop = rest.find(&end).expect("unterminated --shared-anim section");
        if &rest[..stop] != body {
            eprintln!("--shared-anim: this room's {key} tiles differ from the shared copy in {}", path.display());
            std::process::exit(1);
        }
        return;
    }
    let mut combined = existing;
    if combined.is_empty() {
        combined.push_str("; Auto-generated by tools/roompack --shared-anim -- DO NOT EDIT BY HAND.\n\
                           ; ONE copy of the animated flame and water tiles for every room\n\
                           ; (T0121): they were byte-identical in every room that had them.\n\n");
    }
    combined.push_str(&begin);
    combined.push_str(body);
    combined.push_str(&end);
    fs::write(path, combined).expect("write --shared-anim file");
}

fn main() {
    let args = Args::parse();

    let frames_text = fs::read_to_string(&args.frames).expect("read frames");
    let sections = parse_sections(&frames_text, "spectrum");
    let table_data = sections.get("frmtable").expect("no frmtable section");
    let defs = sections.get("frmdefs").expect("no frmdefs section");
    let entry_count = table_data.len() / 2;
    let offsets = read_u16_le_table(table_data, entry_count);

    let room_table: RoomTable =
        serde_json::from_str(&fs::read_to_string(&args.rooms).expect("read rooms.json")).unwrap();
    let room = room_table
        .rooms
        .into_iter()
        .find(|r| r.index == args.room)
        .expect("room not found");

    // Resolve each placement's effective colour byte once (the room format
    // only stores a new one when it changes; bit 7 of x_byte means "reuse
    // the previous placement's colour" -- see NOTES.md T0011). Both the
    // collision mask (T0022, bit 6) and the tonal shading (T0025, ink
    // bits) read this same resolved value.
    let effective_attr: Vec<u8> = {
        let mut inherited: u8 = 0;
        room.things
            .iter()
            .map(|t| {
                if !t.same_colour_as_previous {
                    if let Some(a) = t.attribute_byte {
                        inherited = a;
                    }
                }
                inherited
            })
            .collect()
    };

    // A shaded sprite depends on more than its frame id: the tone comes
    // from the placement's colour, and the Bayer field is indexed in
    // SCREEN space, so a tile's vertical phase (y mod 4) shifts the
    // pattern too. Dedupe on all three. (Horizontal phase is always 0 --
    // every pixel_x is a multiple of 4, the confirmed placement
    // granularity, so x mod 4 can't vary.) With --shade off, threshold is
    // forced to 16 and phase to 0, collapsing this back to one variant
    // per frame exactly as before T0025.
    // ...and on whether the placement is MIRRORED. Bit 7 of the colour
    // byte is the original's `frmreverse` (X-ALL.TXT `thinglp` ~5553:
    // `ld a,(ix+0) / rlca / and 1 / ld (frmreverse),a`), and `frame`
    // consumes it by walking the sprite's bytes right-to-left instead of
    // left-to-right (~4072/4103) -- i.e. a plain horizontal flip of the
    // drawn sprite, nothing to do with colour.
    //
    // This port ignored that bit entirely until T0045-T0048, which is
    // FOUR separate playtest complaints with one cause: room 52's
    // right-hand stair railings "facing the wrong side, they should be
    // mirroring the left", its painting, its top-right sword, and its
    // left-hand railing. 18 of room 52's 91 placements have the bit set
    // (room 36 has 2, rooms 2/35/53 none), which is exactly the set of
    // things that looked wrong. It rides through `same_colour_as_previous`
    // runs like every other attribute bit, which `effective_attr` above
    // already handles.
    let variant_key: Vec<(u8, u8, usize, bool)> = room
        .things
        .iter()
        .zip(&effective_attr)
        .map(|(t, &attr)| {
            let mirrored = attr & 0x80 != 0;
            if args.shade {
                (t.frame, tone_threshold(attr, args.dither_floor), t.y as usize % 4, mirrored)
            } else {
                (t.frame, 16, 0, mirrored)
            }
        })
        .collect();

    // The runtime does the mirroring now (blit_mirror / blit_mkrev, proven
    // byte-identical against the old per-copy sprites -- see NOTES.md).
    // So the deduped sprite set below is built with mirrored forced to
    // false: a frame and its mirrored placement now share ONE stored
    // bitmap, never two. `variant_key` above still carries the real
    // per-placement mirrored bit -- the placement writer below needs it
    // to set the flag bit in pixel_x -- it's just no longer part of what
    // picks or names a *sprite*.
    let mut variants: Vec<(u8, u8, usize, bool)> =
        variant_key.iter().map(|&(frame, thr, phase, _mirrored)| (frame, thr, phase, false)).collect();
    variants.sort_unstable();
    variants.dedup();

    // No `_m` suffix any more: mirrored and unmirrored placements of the
    // same frame/threshold/phase now name the SAME sprite. `_mirrored` is
    // ignored on purpose -- kept in the tuple only so this closure can
    // still be called with either a `variants` entry (always false) or a
    // `variant_key` entry (may be true, from `label_for` below) and name
    // them identically.
    let vname = |&(frame, thr, phase, _mirrored): &(u8, u8, usize, bool)| -> String {
        if thr >= 16 && phase == 0 {
            format!("spr_{frame}")
        } else {
            format!("spr_{frame}_t{thr}_p{phase}")
        }
    };

    // --- shared sprite cache (T0035 follow-up) --------------------------
    // A plain (thr=16, phase=0 -- the only kind --shade off ever produces)
    // room-placement sprite is byte-identical no matter which room asked
    // for it: frame 134's wall tile doesn't change based on where it's
    // placed. Before this, every room emitted its own private copy under
    // a room-prefixed label, which was pure waste in a build already
    // within a few hundred bytes of its hard ceiling (NOTES.md T0035).
    // Frames already present in the shared file (from an earlier room in
    // this same regen_art.sh run) are referenced by their existing global
    // label instead of re-emitted; newly-seen ones are emitted once under
    // a global label and appended. Parsed by hand (no regex dependency),
    // matching this file's own frmdefs/frmtable parsing style.
    // Keyed on the full label base ("spr_134", "spr_192_m", ...), not on
    // the frame id alone: a frame and its mirrored variant are two
    // different bitmaps that must both be able to live in the shared
    // file (T0045-T0048).
    let mut shared_known: std::collections::HashSet<String> = Default::default();
    let load_shared_labels = |path: &PathBuf, known: &mut std::collections::HashSet<String>| -> String {
        let Ok(existing) = fs::read_to_string(path) else { return String::new() };
        for line in existing.lines() {
            // The label is only the FIRST whitespace-delimited token --
            // matching against the whole line (which also has the
            // `\tfcb ...` payload) silently never matched, so every
            // room thought it was first and each wrote its own copy
            // of every frame. Caught by lwasm's own duplicate-symbol
            // error, not by roompack quietly producing a wrong file.
            let Some(label) = line.split_whitespace().next() else { continue };
            if label.starts_with("spr_") {
                if let Some(base) = label.strip_suffix("_w") {
                    known.insert(base.to_string());
                }
            }
        }
        existing
    };
    let shared_existing = args
        .shared_sprites
        .as_ref()
        .map(|p| load_shared_labels(p, &mut shared_known))
        .unwrap_or_default();
    let overflow_existing = args
        .shared_sprites_overflow
        .as_ref()
        .map(|p| load_shared_labels(p, &mut shared_known))
        .unwrap_or_default();
    // Running size estimate (raw text length, not compiled bytes -- see
    // --shared-sprites-budget's own doc comment) used to decide, PER NEW
    // FRAME, whether the primary file still has budget or this frame
    // should go to the overflow file instead.
    let mut primary_len = shared_existing.len();
    let shareable = |v: &(u8, u8, usize, bool)| -> bool {
        let &(_frame, thr, phase, _mirrored) = v;
        args.shared_sprites.is_some()
            && thr >= 16
            && phase == 0
            // T0121: reuse-only rooms share a frame only if the pool has it
            && (!args.shared_sprites_reuse_only || shared_known.contains(&vname(v)))
    };
    // Per-variant final label, INCLUDING any room prefix -- the single
    // source of truth every reference below must use.
    let label_for = |v: &(u8, u8, usize, bool)| -> String {
        if shareable(v) {
            vname(v) // global: no room prefix
        } else {
            format!("r{}_{}", room.index, vname(v))
        }
    };

    let mut out = String::new();
    writeln!(out, "; Auto-generated by tools/roompack -- room {} ({}).", room.index, room.name.as_deref().unwrap_or("?")).unwrap();
    writeln!(out, "; DO NOT EDIT BY HAND -- regenerate from rooms.json/FRAMES.DAT instead.").unwrap();
    writeln!(out, "; CoCo2-native bitmaps: 8px/byte, MSB-first, no mask plane.\n").unwrap();
    if args.shared_sprites.is_some() {
        writeln!(out, "; Plain room-placement sprites for this room live in the SHARED").unwrap();
        writeln!(out, "; sprite file (see --shared-sprites), not here -- deduplicated").unwrap();
        writeln!(out, "; across every room in this regen_art.sh run.\n").unwrap();
    }

    // Label prefix keyed by room index -- lets multiple rooms' data files
    // be `include`d into the same assembly without colliding sprite/table
    // symbol names (two rooms can both use frame 130, and both need their
    // own room_placements/room_cmask). Not needed while only one room ever
    // existed per binary; became necessary for T0023 (multi-room + edge
    // transitions, NOTES.md). Still applies to shaded/mirrored variants,
    // which are NOT deduplicated above (rare -- this project's verbatim
    // pipeline never produces them; the capability is kept for a future
    // target that needs --shade).
    let rp = format!("r{}_", room.index);

    let mut new_shared = String::new();
    let mut new_overflow = String::new();
    let mut shaded_away = 0usize;
    let mut total_ink = 0usize;
    for v in &variants {
        let (frame_id, thr, phase, _mirrored) = *v;
        if shareable(v) && shared_known.contains(&vname(v)) {
            continue; // already emitted by an earlier room this run
        }
        let raw_off = offsets[frame_id as usize];
        assert!(raw_off < 0xFF00, "frame {frame_id} is a sentinel (no sprite)");
        let despeckle = args.despeckle_frames.contains(&frame_id);
        let (pixel_width, height, mut packed) =
            decode_and_repack(defs, raw_off as usize, despeckle);
        let bytes_per_row = (pixel_width as usize).div_ceil(8);

        let (w, h) = (pixel_width as usize, height as usize);
        let before = unpack(&packed, w, h, bytes_per_row);
        let ink_before: usize = before.iter().flatten().map(|&v| v as usize).sum();
        total_ink += ink_before;
        if args.outline {
            let after = outline_only(&before, 1);
            let ink_after: usize = after.iter().flatten().map(|&v| v as usize).sum();
            shaded_away += ink_before.abs_diff(ink_after);
            packed = repack(&after, w, h, bytes_per_row);
        } else if thr < 16 {
            let after = regularize(&before, thr, phase, args.structure_run);
            let ink_after: usize = after.iter().flatten().map(|&v| v as usize).sum();
            shaded_away += ink_before.abs_diff(ink_after);
            packed = repack(&after, w, h, bytes_per_row);
        }

        // T0220: structure-only reduction, applied LAST so it composes with
        // --outline/--shade above rather than discarding them. Reads back from
        // `packed` for that reason, not from `before`.
        if args.structure_frames.contains(&frame_id) {
            let cur = unpack(&packed, w, h, bytes_per_row);
            let after = structure_mask(&cur, args.structure_run);
            let ink_after: usize = after.iter().flatten().map(|&v| v as usize).sum();
            shaded_away += ink_before.abs_diff(ink_after);
            packed = repack(&after, w, h, bytes_per_row);
        }

        // No flip here any more: mirroring moved to the runtime (`blit`'s
        // blit_mirror flag, X-ALL.TXT-proven byte-identical). The stored
        // bitmap is always the unmirrored one; the placement writer below
        // sets the flag bit in pixel_x instead of this code producing a
        // second, mirrored copy of the bitmap.

        let use_overflow = shareable(v)
            && args.shared_sprites_overflow.is_some()
            && args
                .shared_sprites_budget
                .is_some_and(|budget| primary_len >= budget);
        let dest = if !shareable(v) {
            &mut out
        } else if use_overflow {
            &mut new_overflow
        } else {
            &mut new_shared
        };
        let n = label_for(v);
        let before_len = dest.len();
        writeln!(dest, "{n}_w\tfcb {pixel_width}").unwrap();
        writeln!(dest, "{n}_h\tfcb {height}").unwrap();
        writeln!(dest, "{n}_bpr\tfcb {bytes_per_row}").unwrap();
        write!(dest, "{n}\t\tfcb ").unwrap();
        let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
        writeln!(dest, "{}", hex.join(",")).unwrap();
        writeln!(dest).unwrap();
        if shareable(v) && !use_overflow {
            primary_len += dest.len() - before_len;
        }
    }

    let write_shared = |path: &PathBuf, existing: String, new_content: &str, header: &str| {
        if new_content.is_empty() {
            return;
        }
        let mut combined = existing;
        if combined.is_empty() {
            combined.push_str(header);
        }
        combined.push_str(new_content);
        fs::write(path, combined).expect("write shared sprites");
    };
    if let Some(path) = &args.shared_sprites {
        write_shared(
            path,
            shared_existing,
            &new_shared,
            "; Auto-generated by tools/roompack --shared-sprites.\n\
             ; DO NOT EDIT BY HAND -- regenerated whole on every regen_art.sh run.\n\
             ; Plain (unshaded) room-placement sprites, one copy shared across\n\
             ; every room that uses them (NOTES.md T0035 follow-up).\n\n",
        );
    }
    if let Some(path) = &args.shared_sprites_overflow {
        write_shared(
            path,
            overflow_existing,
            &new_overflow,
            "; Auto-generated by tools/roompack --shared-sprites-overflow.\n\
             ; DO NOT EDIT BY HAND -- regenerated whole on every regen_art.sh run.\n\
             ; Overflow from --shared-sprites once its budget filled -- see\n\
             ; --shared-sprites-budget's own doc comment (NOTES.md T0033/T0035\n\
             ; memory audit: two separate small unused RAM blocks, not one).\n\n",
        );
    }

    // --- T0167: global per-build frame index table -----------------------
    // Same incremental read/extend/rewrite pattern as --shared-sprites
    // above, keyed on the label placements actually reference (label_for's
    // result), in FIRST-SEEN order across the whole regen_art.sh run --
    // that order IS the index. Existing entries are parsed back by
    // position (Nth `fdb` line = index N), never re-numbered, so a label
    // already indexed by an earlier room keeps the same index forever
    // within one run.
    let mut frame_index: std::collections::HashMap<String, u8> = Default::default();
    let frame_table_existing = args
        .frame_table
        .as_ref()
        .map(|p| fs::read_to_string(p).unwrap_or_default())
        .unwrap_or_default();
    for line in frame_table_existing.lines() {
        let Some(rest) = line.trim_start().strip_prefix("fdb ") else { continue };
        let label = rest.split_whitespace().next().unwrap_or("");
        let Some(base) = label.strip_suffix("_w") else { continue };
        let idx = frame_index.len();
        assert!(idx < 256, "frame table already has 256 entries -- index no longer fits a byte");
        frame_index.insert(base.to_string(), idx as u8);
    }
    let mut new_frame_table = String::new();
    let mut frame_idx_for = |label: &str, index: &mut std::collections::HashMap<String, u8>| -> u8 {
        if let Some(&i) = index.get(label) {
            return i;
        }
        let i = index.len();
        assert!(i < 256, "T0167 frame table overflowed 256 entries (byte index) -- {label} is #{i}");
        writeln!(new_frame_table, "\tfdb {label}_w\t\t; {i}").unwrap();
        index.insert(label.to_string(), i as u8);
        i as u8
    };

    // Flames are animated separately (T0026), so they must NOT also be in
    // the static placement list -- otherwise the unchanging static copy
    // would sit underneath every animated frame and, with OR
    // compositing, the flame would never appear to move.
    // pixel_x is stored as a single fcb byte (0-255), but a handful of
    // rooms place things with x < 32 in the ORIGINAL's own coordinate
    // space -- the (x-32)*4 transform (see room36.asm's WALK_STEP
    // comment) sends those negative, which cannot be encoded at all,
    // not just clamped. First hit on room 51 (MOAT AND PORTCULLIS,
    // T0036): 4 placements (frames 178/179/180/210, all pixel_x
    // -4..-16) sit off the left edge of the room's visible area --
    // this port's `blit` has no support for partially-off-screen
    // sprites (only x>=0 is handled), so rather than crash or silently
    // wrap/misplace them, they're skipped, loudly, rather than
    // guessed at with a clamped position that could be actively wrong
    // for whatever these are (the room name suggests a portcullis
    // mechanism, not ordinary background scenery -- worth a real look
    // if this room ever gets hazard behaviour wired up, not something
    // to paper over here).
    let mut skipped_offscreen = 0usize;
    // T0163 (Change 1, runtime half): also carries each placement's own
    // effective attribute byte along, zipped in the SAME room.things
    // order as variant_key -- the decorative bit (SOLID_DULL_BIT) has to
    // ride into the emitted placement (bit 1 of pixel_x, see below) and
    // this is the one place that still has it to hand.
    let static_places: Vec<_> = room
        .things
        .iter()
        .zip(&variant_key)
        .zip(&effective_attr)
        .filter(|((t, _), _)| t.frame != FLAME_FRAME && t.frame != WATER_TRIGGER_FRAME)
        .filter(|((t, _), _)| {
            let ok = (0..256).contains(&t.pixel_x);
            if !ok {
                eprintln!(
                    "warning: room {} frame {} pixel_x {} is off the left edge (off-screen at spawn) -- skipped, not clamped",
                    room.index, t.frame, t.pixel_x
                );
                skipped_offscreen += 1;
            }
            ok
        })
        .collect();
    let flames: Vec<_> = room.things.iter().filter(|t| t.frame == FLAME_FRAME).collect();
    let water: Vec<_> =
        room.things.iter().filter(|t| t.frame == WATER_TRIGGER_FRAME).collect();
    if skipped_offscreen > 0 {
        eprintln!("room {}: skipped {} off-screen placement(s)", room.index, skipped_offscreen);
    }

    // --- placements, SOURCE order (T0163 / Change 1, runtime half) -----
    // Used to be emitted SORTED BY Y here, with a compile-time 16px-band
    // start index (T0064), so redraw_placements_dmg could skip straight
    // to the placements near the damage rect instead of scanning all of
    // them (63 in room 36, ~160 cycles each on the reject path, 11ms of a
    // 67ms frame at 1x CPU).
    //
    // The collision-mask derivation NOTES.md "Change 1" wants at room
    // load needs the OPPOSITE order: its pass 1 paints an 8x8-cell
    // "decorative" bitmap with LAST-WRITER-WINS, which only gives the
    // right answer walked in SOURCE order (proved offline by
    // tools/derive_cmask.py -- y-sorted breaks 6 of 27 rooms). Ink
    // drawing itself is order-independent (`blit` composites with OR),
    // so this order change cannot affect what gets drawn.
    //
    // The y-sorted copy + band index the draw path still wants is now
    // built AT ROOM LOAD, by load_room, from this SOURCE-order table --
    // see room36.asm's load_room / rd_sortplaces. This table (and
    // room_place_count) is the one thing both that sort and the mask
    // derivation read.
    // T0235: when --pack-room-data is set, every raw byte below (this
    // table's 3-byte records, then the flame/water 2-byte coordinate
    // tables further down) is collected here INSTEAD OF written straight
    // to `out` -- the labels/bytes get emitted once, packed, at the very
    // end (see "per-room LZ pack" below), and load_room unpacks them back
    // into this exact byte order at room-load time. Any change to the
    // record shapes below must also update lz_unpack's caller
    // (room36.asm load_room) and the offsets it derives from the room's
    // own place/flame/water counts.
    // T0235-fix: the raw tables are ALWAYS written (never conditionally
    // suppressed here any more) -- room 77's own case (94 raw -> 98
    // packed, LZ's per-token overhead losing outright on a tiny room)
    // showed a room can pack WORSE, and that has to keep shipping raw.
    // mark_* below record this text's exact span in `out` so it can be
    // cut back out (String::replace_range) once the packed size is known,
    // rather than deciding before either size exists.
    let mut packed_raw: Vec<u8> = Vec::new();
    writeln!(out, "{rp}room_place_count\tfcb {}", static_places.len()).unwrap();
    let mark_place_start = out.len();
    writeln!(out, "{rp}room_placements").unwrap();
    for &((t, key), attr) in &static_places {
        assert!((0..256).contains(&t.pixel_x), "pixel_x {} out of byte range", t.pixel_x);
        // Point at the _w header label, not the bitmap-data label -- blit
        // reads a 3-byte (width,height,bpr) header before the bitmap
        // bytes, and _w/_h/_bpr/data are laid out in exactly that order.
        //
        // pixel_x is always a multiple of 4 (room36.asm's WALK_STEP
        // comment), so its bottom two bits are free. Bit 0 is T0142's
        // blit_mirror flag (rd_placelp: `andb #1 / stb blit_mirror`).
        // Bit 1 is now T0163's DECORATIVE flag (SOLID_DULL_BIT on this
        // placement's own effective attribute) -- load_room's mask
        // derivation masks it off exactly like the mirror bit, never
        // uses it as part of a coordinate.
        let (_, _, _, mirrored) = *key;
        assert!(t.pixel_x % 4 == 0, "pixel_x {} isn't a multiple of 4 -- can't OR in mirror+decorative bits", t.pixel_x);
        let dull = attr & SOLID_DULL_BIT != 0;
        let mut px = t.pixel_x;
        if mirrored {
            px |= 1;
        }
        if dull {
            px |= 2;
        }
        // T0167: index into the global frame table, not a 2-byte pointer --
        // shrinks a placement record from 4 bytes to 3. The index is
        // resolved back to a real pointer at room-load time only
        // (derive_room_cmask, rd_sortplaces); the per-frame draw path
        // (rd_placelp) still reads a resolved 4-byte record out of RAM, so
        // this costs nothing extra per frame -- see room36.asm.
        let idx = frame_idx_for(&label_for(key), &mut frame_index);
        if args.pack_room_data {
            // No range assert on y (unlike pixel_x, filtered above): the
            // raw `fcb` path never had one either -- lwasm wraps a
            // negative literal the same way `as u8` truncates here.
            packed_raw.push(idx);
            packed_raw.push(px as u8);
            packed_raw.push(t.y as u8);
        }
        writeln!(out, "\tfcb {}\n\tfcb {},{}", idx, px, t.y).unwrap();
    }
    writeln!(out, "{rp}room_placements_end").unwrap();
    let mark_place_end = out.len();

    if let Some(path) = &args.frame_table {
        if !new_frame_table.is_empty() {
            let mut combined = frame_table_existing.clone();
            if combined.is_empty() {
                combined.push_str(
                    "; Auto-generated by tools/roompack --frame-table (T0167).\n\
                     ; DO NOT EDIT BY HAND -- regenerated whole on every regen_art.sh run.\n\
                     ; Global room_placements frame index table: index -> sprite header\n\
                     ; address. Every room_placements entry stores a 1-byte index into\n\
                     ; this table instead of a 2-byte pointer. Resolved back to a real\n\
                     ; pointer at room-load time only (room36.asm: derive_room_cmask,\n\
                     ; rd_sortplaces) -- the per-frame draw path never reads this table.\n\n\
                     frame_table\n",
                );
            }
            combined.push_str(&new_frame_table);
            fs::write(path, combined).expect("write frame table");
        }
    }

    // --- animated torch flames (T0026) -------------------------------
    writeln!(out, "\n; Torch flames: animated, not static scenery. The counter's").unwrap();
    writeln!(out, "; bit 0 picks the tone variant (the original alternates colour").unwrap();
    writeln!(out, "; 70/yellow and 66/red, which becomes a brightness flicker on a").unwrap();
    writeln!(out, "; 1-bit target) and bit 1 picks the mirrored variant.").unwrap();
    writeln!(out, "{rp}room_flame_count\tfcb {}", flames.len()).unwrap();
    let mark_flame_start = out.len();
    writeln!(out, "{rp}room_flames").unwrap();
    for t in &flames {
        // No range assert here (unlike placements above): the raw `fcb`
        // path never had one either -- lwasm two's-complement-wraps a
        // negative literal into a byte, and at least one room's flame/
        // water coordinate relies on exactly that (see room 45 below).
        // `as u8` on an i64 truncates the same way.
        if args.pack_room_data {
            packed_raw.push(t.pixel_x as u8);
            packed_raw.push(t.y as u8);
        }
        writeln!(out, "\tfcb {},{}", t.pixel_x, t.y).unwrap();
    }
    let mark_flame_end = out.len();
    if !flames.is_empty() {
        let raw_off = offsets[FLAME_FRAME as usize] as usize;
        let (fw, fh, fpacked) = decode_and_repack(defs, raw_off, false);
        let fbpr = (fw as usize).div_ceil(8);
        let base = unpack(&fpacked, fw as usize, fh as usize, fbpr);
        // Every OTHER room's flames share one y, so one phase covered
        // them cleanly -- room 2 (the "fireout" overlay, T0032 follow-
        // up) is the first with a genuine multi-flame cluster at
        // different heights (a fire pit, not evenly spaced torches).
        // Rather than multiply variant count by emitting a full
        // per-phase set (4 tones x 2 phases x 2 mirror = 16 sprites for
        // 4 tiny tiles), just use phase 0 for all of them here -- a
        // real, deliberate simplification: the Bayer dither may not
        // align perfectly to the screen grid for the off-phase tiles,
        // a barely-visible cost on a cluster this small and busy.
        let phase = 0usize;
        let _ = flames[0].y; // (documents that we deliberately ignore per-tile y here)
        // T0121: with --shared-anim the tiles go to the shared file under
        // global labels (fp = ""), and this room only aliases its table.
        let fp = if args.shared_anim.is_some() { String::new() } else { rp.clone() };
        let mut fo = String::new();
        writeln!(fo, "{fp}flame_w\tfcb {fw}").unwrap();
        writeln!(fo, "{fp}flame_h\tfcb {fh}").unwrap();
        for (i, attr) in [FLAME_ATTR_A, FLAME_ATTR_B].iter().enumerate() {
            // Flames use `thin`, not `regularize` -- see the comment on
            // `thin` for why the usual dead-end warning doesn't apply to a
            // small isolated sprite. Floor is deliberately lower than the
            // room default so the bright/dim alternation actually reads.
            let thr = if args.shade { tone_threshold(*attr, FLAME_DITHER_FLOOR) } else { 16 };
            let shaded = thin(&base, thr, phase);
            // Mask AFTER mirroring, never before: mirroring an even-width
            // sprite maps column c -> w-1-c and therefore FLIPS column
            // parity, so a pre-mirror even-column mask comes out odd on the
            // mirrored copy -- i.e. the flipped torches would render blue
            // while the others rendered orange. (Caught by
            // tools/verify_verbatim.py, which reports the hue it detects.)
            for (m, grid) in [shaded.clone(), mirror_grid(&shaded)].iter().enumerate() {
                let grid = &if args.colour_flames_orange {
                    artifact_mask(grid, true)
                } else {
                    grid.clone()
                };
                let idx = i + m * 2; // 0=A,1=B,2=A mirrored,3=B mirrored
                let packed = repack(grid, fw as usize, fh as usize, fbpr);
                writeln!(fo, "{fp}flame_{idx}_w\tfcb {fw}").unwrap();
                writeln!(fo, "{fp}flame_{idx}_h\tfcb {fh}").unwrap();
                writeln!(fo, "{fp}flame_{idx}_bpr\tfcb {fbpr}").unwrap();
                let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
                writeln!(fo, "{fp}flame_{idx}\t\tfcb {}", hex.join(",")).unwrap();
            }
        }
        writeln!(fo, "{fp}flame_table").unwrap();
        for idx in 0..4 {
            writeln!(fo, "\tfdb {fp}flame_{idx}_w").unwrap();
        }
        match &args.shared_anim {
            // No `{rp}flame_table equ flame_table` alias: rooms 35/36 are
            // assembled in the low region while their aliases' VALUES land
            // in the staged image, so stage_pack exported them a second time
            // (multiply defined). The descriptor names the global directly.
            Some(path) => shared_anim_section(path, "flames", &fo),
            None => out.push_str(&fo),
        }
    }

    // --- animated water (T0032 follow-up) -----------------------------
    writeln!(out, "\n; Water: animated, not static scenery -- a real hazard too").unwrap();
    writeln!(out, "; (drowns on contact). 4-frame ripple cycle, no colour variant.").unwrap();
    writeln!(out, "{rp}room_water_count\tfcb {}", water.len()).unwrap();
    let mark_water_start = out.len();
    writeln!(out, "{rp}room_water").unwrap();
    for t in &water {
        // See the flames loop above: no range assert, same wraparound.
        if args.pack_room_data {
            packed_raw.push(t.pixel_x as u8);
            packed_raw.push(t.y as u8);
        }
        writeln!(out, "\tfcb {},{}", t.pixel_x, t.y).unwrap();
    }
    let mark_water_end = out.len();
    // water_table must exist even for a room with none -- load_room
    // always takes its address (a room's water count is a runtime
    // value, but the table pointer is resolved at assembly time). Its
    // label goes on the actual fdb pointer list below, NOT here before
    // the sprite data -- an earlier version put it here, which left it
    // aliased onto water_0's own header bytes instead of the real
    // pointer table (the fdb entries render after all 4 sprites'
    // data), producing a garbage sprite pointer at runtime: load_room
    // would resolve room_water_tab_ptr to that address, and drawing
    // would then read whatever height/bpr happened to sit in the
    // sprite bitmap bytes there, occasionally large enough to make
    // clear_and_blit's per-row loop run for a very long time -- looked
    // exactly like an infinite loop/hang, found via a heartbeat
    // counter that simply never advanced past the water draw call.
    if water.is_empty() {
        writeln!(out, "{rp}water_table").unwrap();
    }
    if !water.is_empty() {
        // Resolve the tile's own colour the same way collision does:
        // inherited attribute at this placement's position in the list.
        let mut inherited: u8 = 0;
        let mut water_attr: u8 = 0;
        for t in &room.things {
            if !t.same_colour_as_previous {
                if let Some(a) = t.attribute_byte {
                    inherited = a;
                }
            }
            if t.frame == WATER_TRIGGER_FRAME {
                water_attr = inherited;
                break;
            }
        }
        // T0233-fix: rooms whose water/lava tiles DON'T all share one
        // y%4 phase used to panic here unconditionally. draw_water
        // (room36.asm) already draws every water tile in a room from
        // ONE shared bitmap set with ONE shared counter -- "the
        // original gives each water TILE its own independent counter
        // ... this port shares one counter room-wide, a synchronized
        // ripple instead of a staggered one" (draw_water's own
        // comment) -- so there is no per-tile selection at runtime to
        // feed even if this emitted one variant per phase. Matches
        // the FLAMES code just above, which goes further and hardcodes
        // phase=0 unconditionally ("we deliberately ignore per-tile y
        // here"): pick the phase that covers the MOST tiles (mode, not
        // a hardcoded constant) so the single shared bitmap set is
        // dither-aligned for the majority of the room's water, and
        // accept the same already-documented approximation for
        // whichever minority sits at a different phase -- a real
        // per-tile fix would need draw_water's own dispatch changed to
        // pick a table per tile, which risks regressing every
        // already-working water room and is not attempted here.
        let mut phase_counts = [0usize; 4];
        for t in &water {
            phase_counts[t.y as usize % 4] += 1;
        }
        let phase = (0..4).max_by_key(|&p| phase_counts[p]).unwrap();
        let wp = if args.shared_anim.is_some() { String::new() } else { rp.clone() };
        let mut wo = String::new();
        for i in 0..4u8 {
            let frame = WATER_ANIM_FIRST + i;
            let raw_off = offsets[frame as usize] as usize;
            let (fw, fh, fpacked) = decode_and_repack(defs, raw_off, false);
            let fbpr = (fw as usize).div_ceil(8);
            let base = unpack(&fpacked, fw as usize, fh as usize, fbpr);
            let thr = if args.shade { tone_threshold(water_attr, FLAME_DITHER_FLOOR) } else { 16 };
            let shaded = thin(&base, thr, phase);
            let shaded = if args.colour_water_blue {
                artifact_mask(&shaded, false)
            } else {
                shaded
            };
            let packed = repack(&shaded, fw as usize, fh as usize, fbpr);
            writeln!(wo, "{wp}water_{i}_w\tfcb {fw}").unwrap();
            writeln!(wo, "{wp}water_{i}_h\tfcb {fh}").unwrap();
            writeln!(wo, "{wp}water_{i}_bpr\tfcb {fbpr}").unwrap();
            let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
            writeln!(wo, "{wp}water_{i}\t\tfcb {}", hex.join(",")).unwrap();
        }
        writeln!(wo, "{wp}water_table").unwrap();
        for i in 0..4u8 {
            writeln!(wo, "\tfdb {wp}water_{i}_w").unwrap();
        }
        match &args.shared_anim {
            Some(path) => shared_anim_section(path, "water", &wo),
            None => out.push_str(&wo),
        }
    }

    // --- T0235: per-room LZ pack (TAPE_ROOMS only) --------------------
    // packed_raw is exactly [placements(3B each)][flames(2B each)]
    // [water(2B each)], the SAME byte layout room_placements/room_flames/
    // room_water would have shipped raw, in that order. load_room
    // (room36.asm, gated `if TAPE_ROOMS`) unpacks this blob into
    // ROOM_UNPACK_BUF and slices it back into the three pieces using
    // room_place_count/room_flame_count/room_water_count, already copied
    // from this same descriptor -- so this order is a contract with
    // load_room, not just this file.
    //
    // T0235-fix: pack, THEN decide. A tiny room's LZ overhead can beat its
    // own raw size (room 77: 94 raw -> 98 packed) -- the raw tables above
    // were always written, so losing here just means leaving them alone
    // and never emitting a packed blob or touching the descriptor's
    // pointer fields below. Winning here means cutting the three raw
    // spans back OUT of `out` (String::replace_range, water/flames/places
    // -- LAST mark first, so earlier marks stay valid) and emitting the
    // packed blob instead.
    let raw_len = packed_raw.len();
    let mut effective_pack = false;
    if args.pack_room_data {
        let packed = lz::pack(&packed_raw);
        if packed.len() < raw_len {
            effective_pack = true;
            out.replace_range(mark_water_start..mark_water_end, "");
            out.replace_range(mark_flame_start..mark_flame_end, "");
            out.replace_range(mark_place_start..mark_place_end, "");
            writeln!(
                out,
                "\n; T0235: per-room LZ pack -- {} raw -> {} packed bytes ({}%).",
                raw_len,
                packed.len(),
                if raw_len > 0 { packed.len() * 100 / raw_len } else { 0 }
            )
            .unwrap();
            writeln!(out, "{rp}room_packed").unwrap();
            let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
            for chunk in hex.chunks(16) {
                writeln!(out, "\tfcb {}", chunk.join(",")).unwrap();
            }
            writeln!(out, "{rp}ROOM_RAW_LEN equ {}", raw_len).unwrap();
            writeln!(out, "\tifgt {rp}ROOM_RAW_LEN-ROOM_UNPACK_BUF_LEN").unwrap();
            writeln!(
                out,
                "\terror \"room {} raw data ({} bytes) exceeds ROOM_UNPACK_BUF -- raise ROOM_UNPACK_BUF_LEN\"",
                room.index, raw_len
            )
            .unwrap();
            writeln!(out, "\tendif").unwrap();
        } else {
            eprintln!(
                "room {}: --pack-room-data declined ({} raw -> {} packed, not smaller) -- shipping raw",
                room.index, raw_len, packed.len()
            );
        }
    }

    // --- room descriptor (T0067) -------------------------------------
    // Everything load_room needs for this room, in ONE record laid out
    // in exactly the order of the `room_*` variables it copies into, so
    // load_room is a table scan plus a 19-byte block copy instead of
    // eleven hand-written stores per room repeated per room. Adding a
    // room is then adding its data file and one `fdb` to the table.
    writeln!(out, "\n; load_room descriptor: room, then the fields it copies.").unwrap();
    writeln!(out, "{rp}room_desc").unwrap();
    writeln!(out, "\tfcb {}\t\t; room number", room.index).unwrap();
    writeln!(out, "\tfcb {}\t\t; placement count", static_places.len()).unwrap();
    if effective_pack {
        // T0235: room_placements_end shipped as the sentinel 0 (never a
        // valid ROM address) -- load_room (if TAPE_ROOMS) tests this
        // field BEFORE trusting room_placements_ptr as a raw table: 0
        // means "room_placements_ptr actually points at room_packed;
        // unpack it into ROOM_UNPACK_BUF and recompute every pointer
        // field below from the counts this same block already copied."
        writeln!(out, "\tfdb {rp}room_packed\t\t; T0235: packed blob -- load_room unpacks (sentinel end below)").unwrap();
        writeln!(out, "\tfdb 0\t\t; T0235: sentinel -- \"packed, not raw\" (see load_room)").unwrap();
        writeln!(out, "\tfdb {rp}room_packed\t\t; dummy -- overwritten by load_room").unwrap();
    } else {
        writeln!(out, "\tfdb {rp}room_placements\t\t; SOURCE order (T0163) -- load_room reads this, then repoints it").unwrap();
        writeln!(out, "\tfdb {rp}room_placements_end").unwrap();
        // T0163: no shipped band index any more -- load_room builds the
        // y-sorted copy and its band index into RAM from room_placements
        // above, and repoints this field itself before the room is drawn.
        // The value shipped here is never read as a band index; it only
        // has to be a resolvable address so the block copy in load_room
        // has something harmless to load.
        writeln!(out, "\tfdb {rp}room_placements\t\t; dummy -- overwritten by load_room (T0163)").unwrap();
    }
    // T0166 (Change 1, delivery half): no shipped collision mask any
    // more -- load_room derives it straight into CUR_ROOM_CMASK from
    // room_placements above (derive_room_cmask), so this record has one
    // fewer field than it used to. See NOTES.md "Decision: remove the
    // stored masks NOW".
    // A room with no flames (or no water) has no such table emitted at
    // all, so the descriptor carries a null rather than a dangling
    // label. The count is what the drawing code actually gates on.
    writeln!(out, "\tfcb {}\t\t; flame count", flames.len()).unwrap();
    if effective_pack {
        // T0235: dummy -- load_room recomputes this into ROOM_UNPACK_BUF
        // once it sees the sentinel above; never read raw.
        writeln!(out, "\tfdb 0\t\t; T0235: dummy, overwritten by load_room").unwrap();
        if flames.is_empty() {
            writeln!(out, "\tfdb 0\t\t; no flames in this room").unwrap();
        } else if args.shared_anim.is_some() {
            writeln!(out, "\tfdb flame_table\t\t; T0121: shared_anim_data.asm").unwrap();
        } else {
            writeln!(out, "\tfdb {rp}flame_table").unwrap();
        }
    } else if flames.is_empty() {
        writeln!(out, "\tfdb 0\n\tfdb 0\t\t; no flames in this room").unwrap();
    } else {
        writeln!(out, "\tfdb {rp}room_flames").unwrap();
        if args.shared_anim.is_some() {
            writeln!(out, "\tfdb flame_table\t\t; T0121: shared_anim_data.asm").unwrap();
        } else {
            writeln!(out, "\tfdb {rp}flame_table").unwrap();
        }
    }
    writeln!(out, "\tfcb {}\t\t; water count", water.len()).unwrap();
    if effective_pack {
        writeln!(out, "\tfdb 0\t\t; T0235: dummy, overwritten by load_room").unwrap();
        if water.is_empty() {
            writeln!(out, "\tfdb 0\t\t; no water in this room").unwrap();
        } else if args.shared_anim.is_some() {
            writeln!(out, "\tfdb water_table\t\t; T0121: shared_anim_data.asm").unwrap();
        } else {
            writeln!(out, "\tfdb {rp}water_table").unwrap();
        }
    } else if water.is_empty() {
        writeln!(out, "\tfdb 0\n\tfdb 0\t\t; no water in this room").unwrap();
    } else {
        writeln!(out, "\tfdb {rp}room_water").unwrap();
        if args.shared_anim.is_some() {
            writeln!(out, "\tfdb water_table\t\t; T0121: shared_anim_data.asm").unwrap();
        } else {
            writeln!(out, "\tfdb {rp}water_table").unwrap();
        }
    }

    // --- collision mask: REMOVED (T0166, Change 1 delivery half) -----
    // Used to rasterise every SOLID placement's real sprite pixels into
    // a 4x4-block grid here and ship it LZSS-packed per room (~63 packed
    // bytes/room, ~1700 across all 27 built rooms). load_room now derives
    // the exact same mask AT ROOM LOAD from room_placements
    // (derive_room_cmask, room36.asm) -- proved byte-identical offline by
    // tools/derive_cmask.py (its `derive()` is this exact algorithm,
    // still the spec) and online by harness/cmaskverify.lua. See NOTES.md
    // "Change 1 PROVED OFFLINE" / "Change 1 runtime" / "Decision: remove
    // the stored masks NOW" for the full history, including the
    // negative-pixel_x landmine (rooms 51/84) that derivation from
    // room_placements alone cannot recover -- room36.asm patches those
    // few cells back in after deriving.
    //
    // solid_count is kept here only as a diagnostic for the summary
    // printout below; nothing is emitted from it any more.
    let solid_count = effective_attr.iter().filter(|&&a| a & SOLID_DULL_BIT == 0).count();

    // --- font (T0025) -------------------------------------------------
    if let Some(font_path) = &args.font_output {
        let mut f = String::new();
        writeln!(f, "; Auto-generated by tools/roompack --font-output.").unwrap();
        writeln!(f, "; Text glyphs are ordinary frmtable frames: GLYPH INDEX == ASCII").unwrap();
        writeln!(f, "; CODE (verified -- frames 65-90 render as exactly A-Z). They are").unwrap();
        writeln!(f, "; emitted with the same 3-byte (w,h,bpr) header scenery uses, so").unwrap();
        writeln!(f, "; the existing `blit` routine draws them with no special case.").unwrap();
        writeln!(f, ";").unwrap();
        writeln!(f, "; NOTE the original's punctuation convention (resolves T0010's open").unwrap();
        writeln!(f, "; question): ':'=space  ';'=apostrophe  '<'=comma  '='=hyphen").unwrap();
        writeln!(f, "; '>'=period  '?'=question  '@'=exclamation. So the room name").unwrap();
        writeln!(f, "; \"THE:CASTLE;S:DUNGEON\" really is \"THE CASTLE'S DUNGEON\".\n").unwrap();
        writeln!(f, "FONT_FIRST\tequ {FONT_FIRST}").unwrap();
        writeln!(f, "FONT_LAST\tequ {FONT_LAST}\n").unwrap();

        for code in FONT_FIRST..=FONT_LAST {
            let override_bytes = args
                .glyph_override
                .iter()
                .find(|(c, _)| *c == code)
                .map(|(_, b)| *b);
            let (pw, gh, bpr, packed): (u32, u8, usize, Vec<u8>) =
                if let Some(bytes) = override_bytes {
                    (8, 8, 1, bytes.to_vec())
                } else {
                    let raw_off = offsets[code as usize];
                    assert!(raw_off < 0xFF00, "glyph {code} is a sentinel (no sprite)");
                    let (pw, gh, packed) = decode_and_repack(defs, raw_off as usize, false);
                    let bpr = (pw as usize).div_ceil(8);
                    assert_eq!(pw, 8, "glyph {code} is {pw}px wide, expected 8");
                    assert_eq!(gh, 8, "glyph {code} is {gh}px tall, expected 8");
                    (pw, gh, bpr, packed)
                };
            writeln!(f, "glyph_{code}_w\tfcb {pw}").unwrap();
            writeln!(f, "glyph_{code}_h\tfcb {gh}").unwrap();
            writeln!(f, "glyph_{code}_bpr\tfcb {bpr}").unwrap();
            let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
            if override_bytes.is_some() {
                writeln!(f, "; T0077: hand-drawn icon, not the extracted Spectrum glyph -- see --glyph-override's own doc comment.").unwrap();
            }
            writeln!(f, "glyph_{code}\t\tfcb {}\n", hex.join(",")).unwrap();
        }

        writeln!(f, "; Indexed by (ascii - FONT_FIRST) * 2.").unwrap();
        writeln!(f, "font_table").unwrap();
        for code in FONT_FIRST..=FONT_LAST {
            writeln!(f, "\tfdb glyph_{code}_w").unwrap();
        }
        fs::write(font_path, f).expect("write font");
        println!(
            "emitted font glyphs {FONT_FIRST}-{FONT_LAST} ({} chars, 8x8) -> {}",
            FONT_LAST - FONT_FIRST + 1,
            font_path.display()
        );
    }

    // --- actors (T0027) ----------------------------------------------
    if let (Some(actors_path), Some(actor_out)) = (&args.actors, &args.actor_output) {
        let af: ActorsFile =
            serde_json::from_str(&fs::read_to_string(actors_path).expect("read actors.json")).unwrap();
        // T0234: frames whose aspr_<frame>_w/h/bpr/data already exist in
        // some OTHER already-assembled actor file (actor_reuse_sprites) --
        // skip re-emitting those below (a duplicate `aspr_109_w` etc is a
        // multiply-defined-symbol error, not a silent problem, but still
        // has to be avoided to assemble at all), while still pointing
        // this table's own actor_spr_tab entry at the existing label.
        let reused_sprites: std::collections::HashSet<u8> = match &args.actor_reuse_sprites {
            Some(p) => {
                let txt = fs::read_to_string(p).expect("read actor_reuse_sprites file");
                txt.lines()
                    .filter(|l| l.contains("_w\tfcb"))
                    .filter_map(|l| l.strip_prefix("aspr_"))
                    .filter_map(|l| l.split("_w\tfcb").next())
                    .filter(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()))
                    .filter_map(|s| s.parse::<u8>().ok())
                    .collect()
            }
            None => std::collections::HashSet::new(),
        };
        let mut a = String::new();
        let mut live_len = 0usize;
        let mut want_len = 0usize;
        if args.coins_only {
            writeln!(a, "; Auto-generated by tools/roompack --actors --coins-only.").unwrap();
            writeln!(a, "; T0236: coin table ONLY -- no actor_init at all, see").unwrap();
            writeln!(a, "; --coins-only's own doc comment.\n").unwrap();
        }
        if !args.coins_only {
        writeln!(a, "; Auto-generated by tools/roompack --actors.").unwrap();
        writeln!(a, "; The LIVE actor table: every interactive object in the game.").unwrap();
        writeln!(a, "; 8 bytes/slot, copied to RAM at startup so it can be mutated").unwrap();
        writeln!(a, "; (a picked-up item sets its room to 255 and stays gone).").unwrap();
        writeln!(a, "; Fields: room, routine id, x, y, frame, v1, v2, colour.").unwrap();
        writeln!(a, "; Routine ids follow the original movingrous jump-table order.\n").unwrap();
        // Only the rooms this build actually contains. The full 72-slot
        // table costs 576 bytes of load image plus 576 of RAM, and the
        // program has to fit below the framebuffer at $4000 -- see the
        // memory-budget note in NOTES.md. Actors for unbuilt rooms can
        // never be seen or picked up, so they are dead weight.
        let live: Vec<&ActorRec> = af.actors.iter()
            .filter(|x| args.actor_rooms.contains(&(x.room as usize)))
            .filter(|x| !args.actor_exclude_routines.iter().any(|r| r == &x.routine)
                || x.label.as_deref().map_or(false, |l| KEEP_DESPITE_EXCLUDE.contains(&l)))
            .collect();
        live_len = live.len();
        let asuf = args.actor_suffix.clone().unwrap_or_default();
        writeln!(a, "ACTOR_STRIDE{asuf}\tequ 8").unwrap();
        writeln!(a, "ACTOR_COUNT{asuf}\tequ {}", live.len()).unwrap();
        if args.actor_suffix.is_none() {
            for (i, r) in ROUTINES.iter().enumerate() {
                writeln!(a, "ROU_{}\tequ {i}", r.to_uppercase()).unwrap();
            }
        }
        let mut init_lines: Vec<String> = Vec::new();
        for act in &live {
            let rid = ROUTINES.iter().position(|r| *r == act.routine).unwrap_or(255);
            let note = act.label.clone().unwrap_or_default();
            // T0199: see ORIG_ROOM_LABELS. The FILTER above still uses
            // `room`, so the slot is still emitted for this build -- only
            // its starting room changes, to 255 (= not in the world).
            let mut start_room = if ORIG_ROOM_LABELS.contains(&note.as_str()) {
                act.orig_room
            } else {
                act.room
            };
            // T0204: the reset fields are the game-start state; see
            // ORIG_POS_SLOTS. orig_x is in the source's 4px units, the
            // same (x-32)*4 transform pixel_x already carries.
            let (bx, by) = if ORIG_POS_SLOTS.contains(&act.slot) {
                ((act.orig_x - 32) * 4, act.orig_y)
            } else {
                (act.pixel_x, act.y)
            };
            // T0203: see ACTOR_POS_OVERRIDE.
            let (ax, ay) = ACTOR_POS_OVERRIDE
                .iter()
                .find(|(l, _, _)| *l == note.as_str())
                .map(|(_, x, y)| (*x, *y))
                .unwrap_or((bx, by));
            // T0239: SUFFIXED (tape) tables only -- an actor spawned beyond
            // the right edge (pixel_x > 255, e.g. room 41's miner at raw
            // x=96 -> 256, hidden off-screen until minerrou places it at
            // raw 90) cannot be represented in a byte; clamping it to 255
            // would draw a sliver. Emit it as "not in the world" (room
            // 255); its routine puts it in the room when it triggers. The
            // -run table (no suffix) is untouched.
            if args.actor_suffix.is_some() && ax > 255 {
                start_room = 255;
            }
            init_lines.push(format!(
                "\tfcb {},{},{},{},{},0,0,{}\t; {}{}",
                start_room.clamp(0, 255), if rid == 255 { 255 } else { rid },
                ax.clamp(0, 255), ay.clamp(0, 255), act.frame.clamp(0, 255),
                act.colour.clamp(0, 255), act.routine,
                if note.is_empty() { String::new() } else { format!(" ({note})") }
            ));
        }
        writeln!(a, "\nactor_init{asuf}").unwrap();
        for l in &init_lines {
            writeln!(a, "{l}").unwrap();
        }
        if args.actor_template {
            writeln!(a, "\n; T0234: pristine copy, restored on new_game/game-over --").unwrap();
            writeln!(a, "; see actor_template's own doc comment.").unwrap();
            writeln!(a, "actor_init{asuf}_template").unwrap();
            for l in &init_lines {
                writeln!(a, "{l}").unwrap();
            }
        }

        // Sprites for the actors in the rooms we actually built.
        let mut want: Vec<(u8, u8)> = af.actors.iter()
            .filter(|x| args.actor_rooms.contains(&(x.room as usize)))
            .filter(|x| !args.actor_exclude_routines.iter().any(|r| r == &x.routine)
                || x.label.as_deref().map_or(false, |l| KEEP_DESPITE_EXCLUDE.contains(&l)))
            .map(|x| (x.frame as u8, x.colour as u8))
            .collect();
        for f in &args.extra_actor_frames {
            want.push((*f, 0));
        }
        want.sort_unstable();
        if args.shade {
            want.dedup();
        } else {
            // Colour never reaches the packed output when --shade is off
            // (thr is unconditionally 16 below, and colour otherwise only
            // gates the orange/blue artifact masks, which key on frame not
            // colour) -- so two actors that share a frame at different
            // colour bytes produce byte-identical sprites, and deduping by
            // the full (frame, colour) pair let both through, emitting the
            // same aspr_<frame> label twice (T0075: room 52's and room 55's
            // railingmess share frame 192 at colours 71 and 66; the second
            // one failed to assemble as a duplicate symbol).
            want.dedup_by_key(|t| t.0);
        }
        writeln!(a, "\n; Actor sprites, shaded by each actor's own colour byte.").unwrap();
        for (frame, colour) in &want {
            if reused_sprites.contains(frame) {
                // T0234: art for this frame already exists elsewhere in
                // the final image (see actor_reuse_sprites' own doc
                // comment) -- actor_spr_tab below still gets an entry
                // pointing at aspr_{frame}_w, just not a second copy of
                // the bytes it points to.
                continue;
            }
            let raw_off = offsets[*frame as usize] as usize;
            let (pw, ph, packed) = decode_and_repack(defs, raw_off, false);
            let bpr = (pw as usize).div_ceil(8);
            let grid = unpack(&packed, pw as usize, ph as usize, bpr);
            let grid = close_gaps(&grid, args.close_actor_sprites);
            // Structure-preserving regularize, same as room placements --
            // NOT `thin`. Actors range from small solid glyphs (the apple)
            // to large detailed humanoid sprites (the troll, 32x40), and
            // naive Bayer thinning destroys detail on the latter exactly
            // as it did on wall masonry (the recorded dead end). `thin`
            // stays reserved for the flame, which really is a small
            // isolated case.
            let thr = if args.shade { tone_threshold(*colour, args.dither_floor) } else { 16 };
            let out_grid = if args.outline {
                outline_only(&grid, args.close_actor_sprites)
            } else {
                regularize(&grid, thr, 0, args.structure_run)
            };
            // Artifact colour, applied BEFORE the mirror below so the
            // mirrored copy is masked from the already-masked grid -- the
            // mirror flips column parity on an even-width sprite, so the
            // mirrored variant is re-masked from scratch rather than
            // inheriting a flipped mask (same trap as the flames).
            let out_grid = if args.colour_actor_orange.contains(frame) {
                artifact_mask(&out_grid, true)
            } else if args.colour_actor_blue.contains(frame) {
                artifact_mask(&out_grid, false)
            } else {
                out_grid
            };
            let packed2 = repack(&out_grid, pw as usize, ph as usize, bpr);
            writeln!(a, "aspr_{frame}_w\tfcb {pw}").unwrap();
            writeln!(a, "aspr_{frame}_h\tfcb {ph}").unwrap();
            writeln!(a, "aspr_{frame}_bpr\tfcb {bpr}").unwrap();
            let hex: Vec<String> = packed2.iter().map(|b| format!("${:02x}", b)).collect();
            writeln!(a, "aspr_{frame}\t\tfcb {}", hex.join(",")).unwrap();

            if args.mirror_frames.contains(frame) {
                let mirrored = mirror_grid(&out_grid);
                let mirrored = if args.colour_actor_orange.contains(frame) {
                    artifact_mask(&mirrored, true)
                } else if args.colour_actor_blue.contains(frame) {
                    artifact_mask(&mirrored, false)
                } else {
                    mirrored
                };
                let packed3 = repack(&mirrored, pw as usize, ph as usize, bpr);
                writeln!(a, "aspr_{frame}_mirror_w\tfcb {pw}").unwrap();
                writeln!(a, "aspr_{frame}_mirror_h\tfcb {ph}").unwrap();
                writeln!(a, "aspr_{frame}_mirror_bpr\tfcb {bpr}").unwrap();
                let hex3: Vec<String> = packed3.iter().map(|b| format!("${:02x}", b)).collect();
                writeln!(a, "aspr_{frame}_mirror\t\tfcb {}", hex3.join(",")).unwrap();
            }
        }
        // Frame -> sprite header. A dense (frame, ptr) list with a linear
        // scan, NOT a 256-entry table indexed by frame: only a handful of
        // frames have art, and 512 bytes of mostly-zero table is exactly
        // the kind of waste that pushed this build into the framebuffer.
        want_len = want.len();
        let tabbed: Vec<&(u8, u8)> = want.iter().filter(|t| !args.no_tab_frames.contains(&t.0)).collect();
        writeln!(a, "\n; (frame, sprite header) pairs -- linear scan, terminated by 0").unwrap();
        writeln!(a, "ACTOR_SPR_N{asuf}\tequ {}", tabbed.len()).unwrap();
        writeln!(a, "actor_spr_tab{asuf}").unwrap();
        for (frame, _) in tabbed {
            writeln!(a, "\tfcb {frame}\n\tfdb aspr_{frame}_w").unwrap();
        }
        writeln!(a, "\tfcb 0\t; terminator").unwrap();
        } // !args.coins_only

        // --- coins (T0057) --------------------------------------------
        // Deliberately NOT routed through actor_spr_tab: the coin is
        // frame 0, and that table is a linear scan terminated by a zero
        // frame byte, so a frame-0 entry would truncate it. Coin drawing
        // reads aspr_0_w directly instead.
        //
        // T0234: actor_no_coins skips this whole section for a SECOND
        // actor-table call (the tape region's own) -- coins are out of
        // scope this round (see CoinRec's own doc comment, "not an
        // actor") and COIN_STRIDE/COIN_COUNT/coin_init would otherwise
        // collide with the main table's own, already assembled earlier.
        let live_coins: Vec<&CoinRec> = if args.actor_no_coins {
            Vec::new()
        } else {
            af.coins.iter()
                .filter(|c| args.actor_rooms.contains(&(c.room as usize)))
                .collect()
        };
        let csuf = args.coin_suffix.clone().unwrap_or_default();
        if !args.actor_no_coins {
            // T0236: --coin-suffix's own doc comment -- a SECOND coin
            // table is layered on a build that already has the coin
            // sprite from the FIRST (base) table, so re-emitting aspr_0
            // here would be a duplicate-symbol error.
            if !live_coins.is_empty() && args.coin_suffix.is_none() {
                let raw_off = offsets[0] as usize;
                let (pw, ph, packed) = decode_and_repack(defs, raw_off, false);
                let bpr = (pw as usize).div_ceil(8);
                writeln!(a, "\n; The coin, frame 0 -- verbatim (16x16).").unwrap();
                writeln!(a, "aspr_0_w\tfcb {pw}").unwrap();
                writeln!(a, "aspr_0_h\tfcb {ph}").unwrap();
                writeln!(a, "aspr_0_bpr\tfcb {bpr}").unwrap();
                let hex: Vec<String> = packed.iter().map(|b| format!("${:02x}", b)).collect();
                writeln!(a, "aspr_0\t\tfcb {}", hex.join(",")).unwrap();
            }
            writeln!(a, "\n; Coins: room, x, y. Bit 7 of the room byte is the").unwrap();
            writeln!(a, "; collected flag, exactly as the original's cointable.").unwrap();
            writeln!(a, "COIN_STRIDE{csuf}\tequ 3").unwrap();
            writeln!(a, "COIN_COUNT{csuf}\tequ {}", live_coins.len()).unwrap();
            writeln!(a, "coin_init{csuf}").unwrap();
            for c in &live_coins {
                writeln!(a, "\tfcb {},{},{}", c.room.clamp(0, 255),
                         c.pixel_x.clamp(0, 255), c.y.clamp(0, 255)).unwrap();
            }
            if args.actor_template {
                // T0236: same reasoning as actor_init{suf}_template above --
                // this region has no ROM master to restore a collected
                // coin's bit-7 flag from, so a pristine second copy is it.
                writeln!(a, "\n; T0236: pristine copy, restored on new_game/game-over.").unwrap();
                writeln!(a, "coin_init{csuf}_template").unwrap();
                for c in &live_coins {
                    writeln!(a, "\tfcb {},{},{}", c.room.clamp(0, 255),
                             c.pixel_x.clamp(0, 255), c.y.clamp(0, 255)).unwrap();
                }
            }
        }

        fs::write(actor_out, a).expect("write actors");
        println!("emitted {} actor slots, {} actor sprites, {} coins -> {}",
                 live_len, want_len, live_coins.len(), actor_out.display());
    }

    fs::write(&args.output, out).expect("write output");
    let shading = if args.shade {
        format!(
            ", regularized: {shaded_away}/{total_ink} ink px changed ({:.0}%, floor {:.2}, run {})",
            100.0 * shaded_away as f32 / total_ink.max(1) as f32,
            args.dither_floor,
            args.structure_run
        )
    } else {
        String::new()
    };
    println!(
        "packed {} sprite variants, {} placements ({solid_count} solid){shading} -> {}",
        variants.len(),
        room.things.len(),
        args.output.display()
    );
}
