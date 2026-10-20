//! Decodes the original Fantasy World Dizzy ROOMDATA.DAT (a PDS-assembler
//! `HEX` text listing, not raw binary) into a neutral JSON intermediate, and
//! verifies the decode is lossless by re-encoding and comparing byte-for-byte
//! against the original.
//!
//! Format (confirmed against research/D3-prior-art/info/rooms and by direct
//! byte inspection — see ports/dizzy-coco2/NOTES.md):
//!   - 102 little-endian u16 offsets (204 bytes), each pointing into the
//!     room-data blob that immediately follows.
//!   - A room's data runs from its offset up to the next room's offset; an
//!     empty room shares its offset with the following room.
//!   - The final (102nd) offset equals the total room-data length and acts
//!     as an end sentinel, so there are 101 real room slots (indices 0-100).

use clap::Parser;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Path to the original ROOMDATA.DAT (HEX-text PDS listing)
    #[arg(long)]
    input: PathBuf,

    /// Where to write the decoded JSON intermediate
    #[arg(long)]
    output: PathBuf,

    /// Also cross-reference room names from this info/rooms doc, if given
    #[arg(long)]
    names: Option<PathBuf>,

    /// Re-encode the JSON back to raw bytes and diff against the original
    #[arg(long)]
    verify: bool,
}

/// One sprite placement, decoded per the `roomsetup`/`thinglp` routine in
/// X-ALL.TXT (~line 5436 onward — the comment there literally documents this
/// exact packed format): `frame_no` indexes tools/spritedata's `frmtable`
/// (T0009). `same_colour_as_previous` is bit 7 of the x byte; when clear, a
/// 4th attribute byte follows (not yet decoded here — see NOTES.md, the
/// colour/attribute bit-packing (`%01000111` mask, reverse bit, plot-type
/// nibble) is confirmed in source but not yet worth a field until something
/// needs it).
///
/// `x` is stored in the SAME "4 screen pixels per unit" convention as
/// `frmwidth` (T0009/T0012), with a fixed +32 origin offset — confirmed by
/// reading `frame`'s actual blit-position code (`frmxcoord - 32`, then
/// `srl a`) and by rendering: the raw byte values (`x`) alone produced an
/// incoherent, screen-width-starved mockup, while `pixel_x = (x - 32) * 4`
/// produced a complete, obviously-correct room scene (T0014, NOTES.md has
/// the full story). `y` needs no such transform — used directly as a
/// screen row-table index in `frame`. `pixel_x` is what a renderer should
/// actually use; `x` is kept as the raw byte for round-trip fidelity.
#[derive(Serialize, Deserialize)]
struct Placement {
    frame: u8,
    x: u8,
    pixel_x: i32,
    y: u8,
    same_colour_as_previous: bool,
    attribute_byte: Option<u8>,
}

#[derive(Serialize, Deserialize)]
struct Room {
    index: usize,
    start_offset: u16,
    end_offset: u16,
    length: u16,
    is_empty: bool,
    name: Option<String>,
    /// Decoded per Placement's doc comment. Verified to consume every
    /// room's bytes exactly (52/52 non-empty rooms, zero overrun/underrun)
    /// — see NOTES.md T0011 section.
    things: Vec<Placement>,
    data_hex: String,
}

/// Decodes a room's raw byte blob into its placement list. Returns None if
/// the format doesn't cleanly consume the whole blob (would indicate this
/// room doesn't match the confirmed format — hasn't happened across all 52
/// non-empty rooms in this game, but a decode should never silently lie).
fn decode_things(data: &[u8]) -> Option<Vec<Placement>> {
    let mut things = Vec::new();
    let mut i = 0;
    while i < data.len() {
        if i + 3 > data.len() {
            return None;
        }
        let frame = data[i];
        let xbyte = data[i + 1];
        let y = data[i + 2];
        let same_colour = xbyte & 0x80 != 0;
        i += 3;
        let attribute_byte = if same_colour {
            None
        } else {
            if i >= data.len() {
                return None;
            }
            let b = data[i];
            i += 1;
            Some(b)
        };
        let x = xbyte & 0x7f;
        things.push(Placement {
            frame,
            x,
            pixel_x: (x as i32 - 32) * 4,
            y,
            same_colour_as_previous: same_colour,
            attribute_byte,
        });
    }
    Some(things)
}

#[derive(Serialize, Deserialize)]
struct RoomTable {
    source_file: String,
    total_bytes: usize,
    offset_table_bytes: usize,
    rooms: Vec<Room>,
}

/// Undo the PDS assembler's `HEX` text-listing format: strip the leading
/// `HEX` token off each non-blank line and concatenate the remaining hex
/// digits, in file order, into one continuous byte stream.
fn decode_hex_listing(text: &str) -> Vec<u8> {
    let mut hexdigits = String::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("HEX") {
            hexdigits.push_str(rest.trim());
        }
    }
    hex::decode(&hexdigits)
}

/// Re-encode raw bytes back into the same `HEX` text-listing format lwasm's
/// PDS dialect expects: uppercase hex, wrapped to the same line width the
/// original file used (16 bytes / 32 hex chars per `HEX` line, tab-indented).
fn encode_hex_listing(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(16) {
        out.push_str("\tHEX ");
        for b in chunk {
            out.push_str(&format!("{:02X}", b));
        }
        out.push('\n');
    }
    out
}

mod hex {
    pub fn decode(s: &str) -> Vec<u8> {
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
}

/// Best-effort parse of info/rooms's free-form "<index> <name>" listing.
/// Room names use `:` as the display space character and `;` as an
/// apostrophe (CoCo/Spectrum text encodings both avoided raw spaces/quotes
/// in fixed-width room-title strings) — left as-is here since this is just
/// a cross-reference aid, not something re-encoded back to the original.
fn parse_room_names(text: &str) -> std::collections::HashMap<usize, String> {
    let mut names = std::collections::HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some((num, name)) = line.split_once(' ') {
            if let Ok(idx) = num.parse::<usize>() {
                names.insert(idx, name.trim().to_string());
            }
        }
    }
    names
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

    let text = fs::read_to_string(&args.input).expect("read input");
    let data = decode_hex_listing(&text);

    const OFFSET_TABLE_ENTRIES: usize = 102;
    const OFFSET_TABLE_BYTES: usize = OFFSET_TABLE_ENTRIES * 2;

    let mut offsets = Vec::with_capacity(OFFSET_TABLE_ENTRIES);
    for i in 0..OFFSET_TABLE_ENTRIES {
        let lo = data[i * 2] as u16;
        let hi = data[i * 2 + 1] as u16;
        offsets.push(lo | (hi << 8));
    }

    let names = args
        .names
        .map(|p| parse_room_names(&fs::read_to_string(p).expect("read names")))
        .unwrap_or_default();

    let mut rooms = Vec::new();
    // offsets[0..100] are real room slots; offsets[101] is the end sentinel.
    for i in 0..OFFSET_TABLE_ENTRIES - 1 {
        let start = offsets[i];
        let end = offsets[i + 1];
        let start_abs = OFFSET_TABLE_BYTES + start as usize;
        let end_abs = OFFSET_TABLE_BYTES + end as usize;
        let slice = &data[start_abs..end_abs];
        rooms.push(Room {
            index: i,
            start_offset: start,
            end_offset: end,
            length: end - start,
            is_empty: start == end,
            name: names.get(&i).cloned(),
            things: decode_things(slice).unwrap_or_else(|| {
                if start != end {
                    eprintln!("warning: room {i} ({} bytes) did not decode to a clean placement list", end - start);
                }
                Vec::new()
            }),
            data_hex: slice.iter().map(|b| format!("{:02x}", b)).collect(),
        });
    }

    let table = RoomTable {
        source_file: display_rel(&args.input),
        total_bytes: data.len(),
        offset_table_bytes: OFFSET_TABLE_BYTES,
        rooms,
    };

    let json = serde_json::to_string_pretty(&table).expect("serialize");
    fs::write(&args.output, &json).expect("write output");
    println!(
        "decoded {} bytes, {} room slots -> {}",
        data.len(),
        table.rooms.len(),
        args.output.display()
    );

    if args.verify {
        // Reconstruct the full byte stream: offset table + concatenated room
        // data (relying on rooms being contiguous and in order, which they
        // are per the format), then re-encode to HEX-listing text and diff
        // against the original file byte-for-byte.
        let mut rebuilt = Vec::with_capacity(data.len());
        for off in &offsets {
            rebuilt.push((*off & 0xff) as u8);
            rebuilt.push((*off >> 8) as u8);
        }
        for room in &table.rooms {
            for i in (0..room.data_hex.len()).step_by(2) {
                let byte = u8::from_str_radix(&room.data_hex[i..i + 2], 16).unwrap();
                rebuilt.push(byte);
            }
        }

        if rebuilt == data {
            println!("VERIFY OK: reconstructed {} bytes match original exactly", rebuilt.len());
        } else {
            eprintln!(
                "VERIFY FAILED: reconstructed {} bytes, original {} bytes",
                rebuilt.len(),
                data.len()
            );
            std::process::exit(1);
        }

        // Also confirm the HEX-listing re-encoding round-trips at the text
        // level (same bytes, not necessarily byte-identical text formatting,
        // e.g. line wrap position) by decoding it again.
        let reencoded_text = encode_hex_listing(&rebuilt);
        let redecoded = decode_hex_listing(&reencoded_text);
        if redecoded == data {
            println!("VERIFY OK: HEX-listing re-encode/decode round-trip matches");
        } else {
            eprintln!("VERIFY FAILED: HEX-listing re-encode/decode round-trip mismatch");
            std::process::exit(1);
        }
    }
}
