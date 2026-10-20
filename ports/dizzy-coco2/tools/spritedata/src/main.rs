//! Decodes sprite-related original-source data files (DIZZYFRM.DAT,
//! FRAMES.DAT) — both PDS-assembler `HEX` text listings like ROOMDATA.DAT,
//! but with labeled sections and `if computer=X / endif` conditional
//! branches selecting Spectrum vs Amstrad variants of the same tables.
//!
//! Two pieces of ground truth this relies on, both read directly out of the
//! real Z80 source (research/D3-prior-art/original_source/):
//!
//! - Dizzy character sprites (`dizzytable`+`dizzydefs` in DIZZYFRM.DAT): the
//!   `prtdizzy` routine (PRTDIZZY-Z80-PDS-Neat.txt) confirms sprites are
//!   always 24px wide (3 bytes), each frame begins with a height byte, and
//!   each row is 6 bytes: 3 (mask, sprite) byte pairs, one per 8px column
//!   (mask read into C then sprite into B via `pop bc`, so mask comes first
//!   in memory). `dizzytable` holds 39 little-endian u16 offsets into
//!   `dizzydefs` (comment: "a=no of dizzy frm (0-38)").
//! - Background/scenery objects (`frmtable`+`frmdefs` in FRAMES.DAT): the
//!   header is confirmed from source (X-ALL.TXT ~line 3790-3808): `frmtable`
//!   is a u16-LE offset array (>= 0xFF00 = "no sprite" sentinel — the source
//!   only tests the high byte, see the `frmtable` sentinel-bug recipe in
//!   factory/recipes/), each `frmdefs` entry starts with a width byte then
//!   a height byte. **Pixel format now confirmed too**, from the `frame`
//!   routine (X-ALL.TXT ~line 3975 — NOT `EDITOR/PRTMESS.ASM`'s
//!   `simplesprite`, which is level-editor-only tooling code, a different
//!   and non-shipping code path that happens to read the same table):
//!   width is in "4 screen pixels" units (matching the source comment where
//!   `frmwidth` is first read), so pixel width = `width_byte * 4`; since the
//!   Spectrum screen is 1 bit/pixel, that's `width_byte / 2` bytes per row.
//!   `frame` plots each byte as a single opaque 8-pixel mono run (self-
//!   modified `and (hl)` / `xor (hl)` against the screen, exactly the ink/
//!   paper masking style used everywhere else in this codebase) — there is
//!   **no separate mask plane** the way Dizzy's own sprites have one;
//!   background objects are simple opaque bitmaps. Verified two ways:
//!   (1) self-consistency — `offset + 2 + height*(width/2)` lands at
//!   exactly 7304 (== the full `frmdefs` blob size) across all 196
//!   non-empty entries, zero overflow; (2) the competing "no division"
//!   hypothesis (bytes/row = width, i.e. a Dizzy-style separate mask plane)
//!   overflows the blob by 126 bytes on one entry — ruled out.

use clap::{Parser, Subcommand};
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// List labeled sections found in the `computer=spectrum` branch (or
    /// unconditional code) of a PDS HEX-listing file, with byte lengths.
    Sections { input: PathBuf },

    /// Decode DIZZYFRM.DAT's Spectrum dizzy-character frames to PNGs.
    DizzyFrames {
        input: PathBuf,
        #[arg(long)]
        out_dir: PathBuf,
        #[arg(long)]
        verify: bool,
    },

    /// Extract FRAMES.DAT's frmtable/frmdefs container losslessly, plus a
    /// JSON header manifest (no pixel decode — use `background-frames` for
    /// that).
    Frmtable {
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },

    /// Render FRAMES.DAT's background/scenery objects to PNGs (see module
    /// doc for the confirmed pixel format).
    BackgroundFrames {
        input: PathBuf,
        #[arg(long)]
        out_dir: PathBuf,
        #[arg(long)]
        verify: bool,
    },

    /// Emit one Dizzy character frame as 6809-asm-includable CoCo2 data:
    /// separate mask and sprite bit-planes, each 3 bytes/row (24px wide,
    /// fixed). No bit-repacking needed here (unlike background-frames) --
    /// Dizzy's source bytes are already 8px/byte MSB-first, same
    /// convention PMODE4 uses; this just de-interleaves the source's
    /// per-column (mask,sprite) pairs into two contiguous planes.
    DizzyPack {
        input: PathBuf,
        #[arg(long)]
        frame: u8,
        #[arg(long)]
        output: PathBuf,
    },

    /// Same as DizzyPack but for all 39 frames in one file: unique
    /// per-frame labels (dizzy_frameNN_h/mask/sprite) plus a flat lookup
    /// table (dizzy_frame_heights/masks/sprites, 39 entries each) so game
    /// code can select a frame at runtime by index.
    DizzyPackAll {
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
}

/// Parses a PDS HEX-listing into named sections, following `if computer=X /
/// endif` branches and keeping only lines active for `target_computer` (or
/// outside any conditional at all).
fn parse_sections(text: &str, target_computer: &str) -> BTreeMap<String, Vec<u8>> {
    let mut sections: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut current_label: Option<String> = None;
    // Stack of (computer_name, active) for nested if/endif — this format
    // isn't nested in practice, but handle it defensively.
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
        // Anything else non-blank, non-indented, non-if/endif is a label.
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

#[derive(Serialize)]
struct DizzyFrameMeta {
    frame: usize,
    offset: u16,
    height: u8,
    bytes_used: usize,
    png: String,
}

fn cmd_dizzy_frames(input: PathBuf, out_dir: PathBuf, verify: bool) {
    let text = fs::read_to_string(&input).expect("read input");
    let sections = parse_sections(&text, "spectrum");
    let table_data = sections.get("dizzytable").expect("no dizzytable section (spectrum branch)");
    let defs = sections.get("dizzydefs").expect("no dizzydefs section (spectrum branch)");

    const FRAME_COUNT: usize = 39; // "a=no of dizzy frm (0-38)"
    let offsets = read_u16_le_table(table_data, FRAME_COUNT);

    fs::create_dir_all(&out_dir).expect("mkdir out_dir");

    let mut metas = Vec::new();
    let mut max_end = 0usize;
    for (i, &off) in offsets.iter().enumerate() {
        let off = off as usize;
        let height = defs[off] as usize;
        let row_start = off + DIZZY_HEADER_LEN;
        let row_bytes = height * 6; // 3x (mask,sprite) pairs per row
        let end = row_start + row_bytes;
        assert!(end <= defs.len(), "frame {i} reads past dizzydefs end ({end} > {})", defs.len());
        max_end = max_end.max(end);

        let mut img = image::RgbaImage::new(24, height as u32);
        for row in 0..height {
            let row_off = row_start + row * 6;
            for col in 0..3 {
                let mask_byte = defs[row_off + col * 2];
                let sprite_byte = defs[row_off + col * 2 + 1];
                for bit in 0..8 {
                    let mask_bit = (mask_byte >> (7 - bit)) & 1;
                    let sprite_bit = (sprite_byte >> (7 - bit)) & 1;
                    let x = (col * 8 + bit) as u32;
                    let y = row as u32;
                    // Compositing is screen = (screen AND mask) XOR sprite,
                    // so mask=0 is the OPAQUE case (screen bits cleared,
                    // sprite substituted) and mask=1 preserves the
                    // background. This had the polarity backwards, which
                    // made every reference PNG a negative of the real
                    // sprite -- cosmetic only (the packer builds game data
                    // separately) but actively misleading when eyeballing
                    // frames, so it stayed wrong for a long time.
                    let px = if mask_bit == 0 {
                        if sprite_bit == 1 {
                            image::Rgba([255, 255, 255, 255]) // opaque white (body)
                        } else {
                            image::Rgba([0, 0, 0, 255]) // opaque black (outline/eyes)
                        }
                    } else {
                        image::Rgba([0, 0, 0, 0]) // transparent
                    };
                    img.put_pixel(x, y, px);
                }
            }
        }
        let png_name = format!("dizzy_frame_{i:02}.png");
        img.save(out_dir.join(&png_name)).expect("save png");
        metas.push(DizzyFrameMeta {
            frame: i,
            offset: off as u16,
            height: height as u8,
            bytes_used: 1 + row_bytes,
            png: png_name,
        });
    }

    let manifest = serde_json::to_string_pretty(&metas).unwrap();
    fs::write(out_dir.join("dizzy_frames.json"), &manifest).expect("write manifest");
    println!(
        "decoded {} dizzy frames -> {}  (dizzydefs blob is {} bytes, highest byte touched: {})",
        metas.len(),
        out_dir.display(),
        defs.len(),
        max_end
    );

    if verify {
        // Self-consistency: every frame's declared (offset, height) must
        // read entirely inside the dizzydefs blob — already asserted above
        // per-frame — plus report how much of the blob was actually
        // reachable from the table, as a sanity signal (frames need not be
        // contiguous/ordered, so this is informative, not a strict total).
        if max_end <= defs.len() {
            println!(
                "VERIFY OK: all {} frames read in-bounds; {} of {} dizzydefs bytes reached by table",
                metas.len(),
                max_end,
                defs.len()
            );
        } else {
            eprintln!("VERIFY FAILED: a frame read past the end of dizzydefs");
            std::process::exit(1);
        }
    }
}

#[derive(Serialize)]
struct FrmEntry {
    index: usize,
    offset: u16,
    is_empty: bool,
    width: Option<u8>,
    height: Option<u8>,
    /// Raw bytes immediately following the width/height header, up to the
    /// next entry's start offset (best-effort — entries are not guaranteed
    /// contiguous/ordered by table position, so this may include unrelated
    /// bytes for non-sequential tables; treat as a raw dump for now, not a
    /// trusted per-entry length until the plot routine confirms framing).
    header_and_following_hex: String,
}

fn cmd_frmtable(input: PathBuf, output: PathBuf) {
    let text = fs::read_to_string(&input).expect("read input");
    let sections = parse_sections(&text, "spectrum");
    let table_data = sections
        .get("frmtable")
        .expect("no frmtable section (unconditional or spectrum branch)");
    let defs = sections.get("frmdefs").expect("no frmdefs section");

    let entry_count = table_data.len() / 2;
    let offsets = read_u16_le_table(table_data, entry_count);

    let mut entries = Vec::new();
    for (i, &raw_off) in offsets.iter().enumerate() {
        // Source (X-ALL.TXT ~3796-3801) only tests the HIGH byte of the
        // offset against 255 (`ld a,d / cp 255`), not the full u16 against
        // 0xFFFF — so any offset >= 0xFF00 is a "no sprite" sentinel, not
        // just exactly 0xFFFF. Getting this wrong made ~35 valid sentinels
        // look like out-of-bounds corruption on the first pass.
        if raw_off >= 0xFF00 {
            entries.push(FrmEntry {
                index: i,
                offset: raw_off,
                is_empty: true,
                width: None,
                height: None,
                header_and_following_hex: String::new(),
            });
            continue;
        }
        let off = raw_off as usize;
        if off + 2 > defs.len() {
            eprintln!("warning: entry {i} offset {off} out of bounds ({}), skipping", defs.len());
            continue;
        }
        let width = defs[off];
        let height = defs[off + 1];
        // Dump a bounded window of raw bytes after the header for manual
        // inspection later — not claiming this is the exact per-entry
        // length (unconfirmed, see module doc).
        let dump_len = 64.min(defs.len() - off);
        let dump = &defs[off..off + dump_len];
        entries.push(FrmEntry {
            index: i,
            offset: raw_off,
            is_empty: false,
            width: Some(width),
            height: Some(height),
            header_and_following_hex: dump.iter().map(|b| format!("{:02x}", b)).collect(),
        });
    }

    #[derive(Serialize)]
    struct FrmTable {
        source_file: String,
        table_entries: usize,
        frmdefs_bytes: usize,
        entries: Vec<FrmEntry>,
    }
    let out = FrmTable {
        source_file: display_rel(&input),
        table_entries: entry_count,
        frmdefs_bytes: defs.len(),
        entries,
    };
    fs::write(&output, serde_json::to_string_pretty(&out).unwrap()).expect("write output");
    println!(
        "extracted {} frmtable entries ({} bytes of frmdefs) -> {}",
        entry_count,
        defs.len(),
        output.display()
    );
}

#[derive(Serialize)]
struct BgFrameMeta {
    index: usize,
    offset: u16,
    width_units: u8,
    pixel_width: u32,
    height: u8,
    png: String,
}

fn cmd_background_frames(input: PathBuf, out_dir: PathBuf, verify: bool) {
    let text = fs::read_to_string(&input).expect("read input");
    let sections = parse_sections(&text, "spectrum");
    let table_data = sections.get("frmtable").expect("no frmtable section");
    let defs = sections.get("frmdefs").expect("no frmdefs section");
    let entry_count = table_data.len() / 2;
    let offsets = read_u16_le_table(table_data, entry_count);

    fs::create_dir_all(&out_dir).expect("mkdir out_dir");

    let mut metas = Vec::new();
    let mut max_end = 0usize;
    for (i, &raw_off) in offsets.iter().enumerate() {
        if raw_off >= 0xFF00 {
            continue; // sentinel: no sprite in this slot
        }
        let off = raw_off as usize;
        let width_units = defs[off] & 0x7f; // bit 7 meaning unconfirmed, masked off (matches `res 7,b` in source)
        let height = defs[off + 1];
        let pixel_width = width_units as u32 * 4;
        let bytes_per_row = (width_units as usize).div_ceil(2);
        let row_start = off + 2;
        let end = row_start + bytes_per_row * height as usize;
        assert!(end <= defs.len(), "entry {i} reads past frmdefs end ({end} > {})", defs.len());
        max_end = max_end.max(end);

        let mut img = image::GrayImage::new(pixel_width, height as u32);
        for row in 0..height as usize {
            for col_byte in 0..bytes_per_row {
                let byte = defs[row_start + row * bytes_per_row + col_byte];
                for bit in 0..8 {
                    let x = (col_byte * 8 + bit) as u32;
                    if x >= pixel_width {
                        break;
                    }
                    let set = (byte >> (7 - bit)) & 1 == 1;
                    img.put_pixel(x, row as u32, image::Luma([if set { 0 } else { 255 }]));
                }
            }
        }
        let png_name = format!("bg_frame_{i:03}.png");
        img.save(out_dir.join(&png_name)).expect("save png");
        metas.push(BgFrameMeta {
            index: i,
            offset: raw_off,
            width_units,
            pixel_width,
            height,
            png: png_name,
        });
    }

    fs::write(
        out_dir.join("background_frames.json"),
        serde_json::to_string_pretty(&metas).unwrap(),
    )
    .expect("write manifest");
    println!(
        "decoded {} background-object frames -> {} (frmdefs blob is {} bytes, highest byte touched: {})",
        metas.len(),
        out_dir.display(),
        defs.len(),
        max_end
    );

    if verify {
        if max_end <= defs.len() {
            println!(
                "VERIFY OK: all {} frames read in-bounds; {} of {} frmdefs bytes reached by table",
                metas.len(),
                max_end,
                defs.len()
            );
        } else {
            eprintln!("VERIFY FAILED: an entry read past the end of frmdefs");
            std::process::exit(1);
        }
    }
}

const DIZZY_FRAME_COUNT: usize = 39;

/// Per-frame header in dizzydefs is TWO bytes: [height][unused], then
/// the row data. Confirmed three independent ways: (a) every frame's
/// offset gap in dizzytable is exactly height*6 + 2, (b) the original
/// Z80 `prtdizzy` reads the header with a single `pop bc`, which
/// consumes 2 bytes (C=height, B=the second byte, discarded), and
/// (c) decoding with this offset finally produces a recognisable
/// Dizzy -- egg body, two eyes, arms, boots -- where off-by-one gave
/// an amorphous blob (NOTES.md "the real bug: one-byte header
/// offset"). Reading row data one byte early effectively swapped
/// mask<->sprite on EVERY pixel of every frame, which is what produced
/// the long-hunted "duplicated top" artefact and the bogus
/// invert-mode pixels that two earlier "fixes" were built to paper
/// over. With the correct offset there are ZERO invert pixels across
/// all 39 frames (verified), so no such compensation is needed --
/// every pixel is cleanly transparent, opaque black, or opaque white.
const DIZZY_HEADER_LEN: usize = 2;

/// Decode one Dizzy frame's mask/sprite planes from the parsed
/// dizzytable/dizzydefs sections. Shared by DizzyPack and DizzyPackAll.
fn decode_dizzy_frame(table_data: &[u8], defs: &[u8], frame_id: u8) -> (u8, Vec<u8>, Vec<u8>) {
    let offsets = read_u16_le_table(table_data, DIZZY_FRAME_COUNT);
    let off = offsets[frame_id as usize] as usize;
    let height = defs[off];
    let row_start = off + DIZZY_HEADER_LEN;

    let mut mask_plane = Vec::with_capacity(height as usize * 3);
    let mut sprite_plane = Vec::with_capacity(height as usize * 3);
    for row in 0..height as usize {
        let row_off = row_start + row * 6;
        for col in 0..3 {
            mask_plane.push(defs[row_off + col * 2]);
            sprite_plane.push(defs[row_off + col * 2 + 1]);
        }
    }
    (height, mask_plane, sprite_plane)
}

fn cmd_dizzy_pack(input: PathBuf, frame_id: u8, output: PathBuf) {
    use std::fmt::Write as _;

    let text = fs::read_to_string(&input).expect("read input");
    let sections = parse_sections(&text, "spectrum");
    let table_data = sections.get("dizzytable").expect("no dizzytable section");
    let defs = sections.get("dizzydefs").expect("no dizzydefs section");

    let (height, mask_plane, sprite_plane) = decode_dizzy_frame(table_data, defs, frame_id);

    let mut out = String::new();
    writeln!(out, "; Auto-generated by tools/spritedata dizzy-pack -- Dizzy frame {frame_id}.").unwrap();
    writeln!(out, "; DO NOT EDIT BY HAND. 24px wide (3 bytes/row) x {height} rows.").unwrap();
    writeln!(out, "; mask/sprite compositing (matches original): screen = (screen AND mask) XOR sprite.\n").unwrap();
    writeln!(out, "dizzy_frame_h\tfcb {height}").unwrap();
    write!(out, "dizzy_frame_mask\tfcb ").unwrap();
    writeln!(out, "{}", mask_plane.iter().map(|b| format!("${:02x}", b)).collect::<Vec<_>>().join(",")).unwrap();
    write!(out, "dizzy_frame_sprite\tfcb ").unwrap();
    writeln!(out, "{}", sprite_plane.iter().map(|b| format!("${:02x}", b)).collect::<Vec<_>>().join(",")).unwrap();

    fs::write(&output, out).expect("write output");
    println!("packed dizzy frame {frame_id} ({height} rows) -> {}", output.display());
}

fn cmd_dizzy_pack_all(input: PathBuf, output: PathBuf) {
    use std::fmt::Write as _;

    let text = fs::read_to_string(&input).expect("read input");
    let sections = parse_sections(&text, "spectrum");
    let table_data = sections.get("dizzytable").expect("no dizzytable section");
    let defs = sections.get("dizzydefs").expect("no dizzydefs section");

    let mut out = String::new();
    writeln!(out, "; Auto-generated by tools/spritedata dizzy-pack-all -- all {DIZZY_FRAME_COUNT} Dizzy frames.").unwrap();
    writeln!(out, "; DO NOT EDIT BY HAND. Each frame is 24px wide (3 bytes/row), height varies.").unwrap();
    writeln!(out, "; mask/sprite compositing (matches original): screen = (screen AND mask) XOR sprite.").unwrap();
    writeln!(out, "; Dizzy is drawn feet-anchored in the original (y = bottom, top = y - height) --").unwrap();
    writeln!(out, "; game code must account for this per-frame, it is NOT baked in here.\n").unwrap();

    let mut heights = Vec::with_capacity(DIZZY_FRAME_COUNT);
    for frame_id in 0..DIZZY_FRAME_COUNT as u8 {
        let (height, mask_plane, sprite_plane) = decode_dizzy_frame(table_data, defs, frame_id);
        heights.push(height);
        writeln!(out, "dizzy_frame{frame_id:02}_mask\tfcb {}", mask_plane.iter().map(|b| format!("${:02x}", b)).collect::<Vec<_>>().join(",")).unwrap();
        writeln!(out, "dizzy_frame{frame_id:02}_sprite\tfcb {}", sprite_plane.iter().map(|b| format!("${:02x}", b)).collect::<Vec<_>>().join(",")).unwrap();
    }

    writeln!(out, "\ndizzy_frame_heights\tfcb {}", heights.iter().map(|h| h.to_string()).collect::<Vec<_>>().join(",")).unwrap();
    writeln!(out, "dizzy_frame_maskptrs\tfdb {}", (0..DIZZY_FRAME_COUNT as u8).map(|i| format!("dizzy_frame{i:02}_mask")).collect::<Vec<_>>().join(",")).unwrap();
    writeln!(out, "dizzy_frame_spriteptrs\tfdb {}", (0..DIZZY_FRAME_COUNT as u8).map(|i| format!("dizzy_frame{i:02}_sprite")).collect::<Vec<_>>().join(",")).unwrap();

    fs::write(&output, out).expect("write output");
    println!("packed all {DIZZY_FRAME_COUNT} dizzy frames -> {}", output.display());
}

/// Source path as written into the JSON: made relative to the current directory when it lies
/// under it, so no machine-specific absolute path ends up in generated files.
fn display_rel(p: &std::path::Path) -> String {
    if p.is_absolute() {
        if let Ok(cwd) = std::env::current_dir() {
            if let Ok(r) = p.strip_prefix(&cwd) {
                return r.display().to_string();
            }
        }
    }
    p.display().to_string()
}

fn main() {
    let args = Args::parse();
    match args.cmd {
        Cmd::Sections { input } => {
            let text = fs::read_to_string(&input).expect("read input");
            let sections = parse_sections(&text, "spectrum");
            for (name, bytes) in &sections {
                println!("{name}: {} bytes", bytes.len());
            }
        }
        Cmd::DizzyFrames { input, out_dir, verify } => cmd_dizzy_frames(input, out_dir, verify),
        Cmd::Frmtable { input, output } => cmd_frmtable(input, output),
        Cmd::BackgroundFrames { input, out_dir, verify } => cmd_background_frames(input, out_dir, verify),
        Cmd::DizzyPack { input, frame, output } => cmd_dizzy_pack(input, frame, output),
        Cmd::DizzyPackAll { input, output } => cmd_dizzy_pack_all(input, output),
    }
}
