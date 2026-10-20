//! Convert the Spectrum title screen to a packed CoCo PMODE4 image, split
//! across the load-time holes below $8000 (NOTES.md T0092).
//!
//! SOURCE: a linear 6144-byte PMODE4 image from tools/title_image.py,
//! which thresholds research/D3-prior-art/info/dizzy3_title.png -- the
//! real title screen, with the Yolkfolk cast and "SPC OR FIRE TO START".
//!
//! NOT DIZ3SPEC.SCR. That is the tape LOADING screen, a different
//! picture, and shipping it as the title was T0096 -- caught by a
//! playtest, not by any check here. The title is not in the original
//! source as a bitmap at all (the other .SCR files are 8192-byte Amstrad
//! screens); the game draws it from sprites at runtime. A .SCR path is
//! still accepted -- assembler source of `HEX ...` lines decoding to a
//! 6912-byte ZX SCREEN$, de-interleaved here -- but nothing ships on it.
//!
//! COLUMN-MAJOR before packing. Measured on this exact image:
//!
//!     linear order              4345 bytes packed
//!     column-major              3788   <- 557 bytes better, what we emit
//!     XOR with previous row     4664   worse
//!     XOR with row two above    4712   worse
//!     ZX-native interleave      4375   worse
//!
//! Row XOR filters LOSE on dithered art: the dither is already the
//! high-frequency content, and XOR destroys the byte repeats LZ was
//! living on. Do not re-try them. The target de-transforms with a stride
//! loop after unpacking, which is why this costs ~30 bytes of 6809 and
//! buys 557 bytes of the scarce resource.
//!
//! WHY SPLIT: the packed image does not fit the framebuffer staging
//! windows alone (3495 free, 293 short) but fits easily in the 4796 bytes
//! of loadable-free space below $8000 once the four small gaps between
//! resident blocks are counted. The fragments are NOT decoded in place --
//! the target gathers them into one scratch buffer above the room image
//! and runs the ordinary unpacker once, so there is no format change and
//! no second decoder.
use roompack::lz::pack;
use std::env;
use std::fs;

// Holes come from the CALLER (--hole ADDR:LEN, repeatable), computed by
// tools/stage_pack.sh after the rooms are packed.
//
// They are deliberately NOT hardcoded, and deliberately exclude the low-data
// and code+data spares. Those two move when this feature's own 6809 code
// grows, which makes the build circular: the holes depend on the code size,
// the code cannot be assembled without knowing the holes. The four holes
// actually used -- framebuffer A spare, gap1, framebuffer B spare, gap2 --
// depend only on the packed room blocks and on org'd resident blocks, both
// known before the final assembly. That is 3953 bytes against 3788 needed.
// If a future room pushes that under, this exits non-zero rather than
// silently writing past a hole.

/// Decode the `HEX ...` lines of a .SCR source file.
fn read_scr(path: &str) -> Vec<u8> {
    let text = fs::read(path).expect("read .SCR");
    let text = String::from_utf8_lossy(&text);
    let mut hex = String::new();
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix("HEX ") {
            hex.push_str(rest.trim());
        }
    }
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).expect("hex digit"))
        .collect()
}

/// ZX screen layout -> linear 256x192 1bpp.
fn deinterleave(bm: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; 6144];
    for y in 0..192usize {
        let off = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2);
        out[y * 32..y * 32 + 32].copy_from_slice(&bm[off..off + 32]);
    }
    out
}

/// All 192 bytes of column 0, then column 1, ... The target undoes this
/// with a stride-32 write loop.
fn column_major(linear: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(6144);
    for c in 0..32usize {
        for r in 0..192usize {
            out.push(linear[r * 32 + c]);
        }
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: mktitle <DIZ3SPEC.SCR> <blob.asm> <table.asm> --hole ADDR:LEN ...");
        std::process::exit(2);
    }
    let holes: Vec<(u16, usize)> = args[4..]
        .chunks(2)
        .filter(|c| c[0] == "--hole")
        .map(|c| {
            let (a, l) = c[1].split_once(':').expect("--hole ADDR:LEN");
            (
                u16::from_str_radix(a.trim_start_matches("0x"), 16).expect("hole addr"),
                l.parse::<usize>().expect("hole len"),
            )
        })
        .collect();
    assert!(!holes.is_empty(), "at least one --hole ADDR:LEN is required");

    // Two accepted inputs. A raw 6144-byte file is an already-linear
    // PMODE4 image (what tools/title_image.py produces from the real
    // title-screen PNG). Anything else is treated as a .SCR assembler
    // source of HEX lines, decoding to a 6912-byte ZX SCREEN$ that still
    // needs de-interleaving. The .SCR path is kept only because the
    // loading screen is still reachable that way; the SHIPPING title
    // comes from the PNG (T0096 -- shipping the loading screen as the
    // title was the bug).
    let raw = fs::read(&args[1]).expect("read title source");
    let linear = if raw.len() == 6144 {
        raw
    } else {
        let scr = read_scr(&args[1]);
        assert_eq!(scr.len(), 6912, "expected 6912 bytes (6144 bitmap + 768 attrs)");
        deinterleave(&scr[..6144])
    };
    let cm = column_major(&linear);
    let mut packed = pack(&cm);
    // T0126: prove the title round-trips before it ships. Nothing checked
    // this before -- lzverify covers only the $8000 room image -- and the
    // T0085 LZSS path turned out to have been showing two wrong title bytes
    // (found by a before/after framebuffer diff when the codec changed).
    assert!(roompack::lz::unpack(&packed) == cm, "title pack does not round-trip");
    let title_len = packed.len();

    // TITLE_MIX3 builds: `--music BLOB` is target/title_mix3.asm assembled
    // raw -- the 3-voice mixer plus its event stream. Packed on its own and
    // appended after the title's stream, so it rides the same holes and the
    // same gather; boot finds it at TITLE_LZ_BUF+TITLE_LZ_LEN (an explicit
    // offset, NOT wherever lz_unpack stops: the unpacker reads one flags
    // byte past the end whenever the last item closes a block).
    let (music_len, music_raw) = match args[4..].chunks(2).find(|c| c[0] == "--music") {
        Some(c) => {
            let blob = fs::read(&c[1]).expect("read --music blob");
            let mp = pack(&blob);
            let n = mp.len();
            packed.extend_from_slice(&mp);
            (n, blob.len())
        }
        None => (0, 0),
    };
    // T0125: `--extra BLOB` is staging block C (tools/stage_pack.sh): room
    // data that no longer fits framebuffers A/B, raw bytes of the $8000
    // image's tail. Packed on its own and appended after the music, so it
    // rides the same holes and the same gather; new_game unpacks it from
    // TITLE_LZ_BUF+TITLE_LZ_LEN+TITLE_MUSIC_LEN (an explicit offset, as the
    // music's). Round-trip checked like the title -- nothing else verifies it.
    // T0224: `--raw-extras 1` (tape build). Blocks C and D are NOT packed into the
    // title stream / load-time holes at all: tools/stage_pack.sh delivers their raw
    // bytes as ordinary tape segments at RC_DEST / CODE_DEST (tape_stage1 writes any
    // addr >= $8000 segment through its staged copy). The blobs are still read here
    // so TITLE_EXTRA_RAW / TITLE_EXTRA2_RAW (raw sizes) are emitted, but
    // TITLE_EXTRA_LEN / TITLE_EXTRA2_LEN (packed bytes in the gathered stream) are 0,
    // nothing goes in the holes, and no title_frags gather table is written.
    let raw_extras = args[4..]
        .chunks(2)
        .any(|c| c[0] == "--raw-extras" && c.get(1).map(|v| v.as_str()) == Some("1"));
    let (extra_len, extra_raw) = match args[4..].chunks(2).find(|c| c[0] == "--extra") {
        Some(c) if raw_extras => {
            let blob = fs::read(&c[1]).expect("read --extra blob");
            (0, blob.len())
        }
        Some(c) => {
            let blob = fs::read(&c[1]).expect("read --extra blob");
            let ep = pack(&blob);
            assert!(roompack::lz::unpack(&ep) == blob, "extra block does not round-trip");
            let n = ep.len();
            packed.extend_from_slice(&ep);
            (n, blob.len())
        }
        None => (0, 0),
    };
    // T0148: `--extra2 BLOB` is staging block D (tools/stage_pack.sh): RESIDENT
    // CODE, not room data. Packed on its OWN, appended after the extra room
    // block, riding the same holes and gather. Kept as a SEPARATE stream from
    // --extra rather than concatenated: the two decode to DIFFERENT
    // destinations (RC_DEST vs CODE_DEST, opposite ends of the free span),
    // and an LZSS stream can only be decoded from its own start, so two
    // destinations need two streams. logic_low.asm's unpack_d reads it from
    // TITLE_LZ_BUF+TITLE_LZ_LEN+TITLE_MUSIC_LEN+TITLE_EXTRA_LEN. Round-trip
    // checked like the others -- nothing else verifies it.
    let (extra2_len, extra2_raw) = match args[4..].chunks(2).find(|c| c[0] == "--extra2") {
        Some(c) if raw_extras => {
            let blob = fs::read(&c[1]).expect("read --extra2 blob");
            (0, blob.len())
        }
        Some(c) => {
            let blob = fs::read(&c[1]).expect("read --extra2 blob");
            let ep = pack(&blob);
            assert!(roompack::lz::unpack(&ep) == blob, "extra2 block does not round-trip");
            let n = ep.len();
            packed.extend_from_slice(&ep);
            (n, blob.len())
        }
        None => (0, 0),
    };
    // T0231: `--resident-out PATH` -- a THIRD, always-generated output: the
    // packed title-image + music streams (title_len+music_len bytes) as ONE
    // contiguous blob, no hole-splitting, no gather table. This is what the
    // tape build's game-over title replay copies into TITLE_LZ_BUF before
    // reusing show_title's own unpack code -- see boot_code.asm's
    // show_title_resident and room36.asm's TAPE_ROOMS block. Deliberately
    // NOT block C/D (--extra/--extra2): those are boot-once (RC_DEST/
    // CODE_DEST already hold live data/code by the time a game-over can
    // happen) and must not be re-unpacked. Emitted unconditionally --
    // harmless for the -run build, which never includes the file.
    if let Some(c) = args[4..].chunks(2).find(|c| c[0] == "--resident-out") {
        let resident = &packed[..title_len + music_len];
        let mut r = String::from(
            "; Auto-generated by tools/mktitle -- DO NOT EDIT.\n\
             ; T0231: the packed title image + music streams, concatenated as\n\
             ; ONE contiguous blob (no hole-splitting) -- the tape-only\n\
             ; region's resident copy for the game-over title replay. NOT\n\
             ; block C/D (those are boot-once). See boot_code.asm's\n\
             ; show_title_resident.\n\n",
        );
        r.push_str("TITLE_RESIDENT_LZ\n");
        for chunk in resident.chunks(16) {
            let hex: Vec<String> = chunk.iter().map(|b| format!("${b:02x}")).collect();
            r.push_str(&format!("\tfcb {}\n", hex.join(",")));
        }
        r.push_str(&format!("TITLE_RESIDENT_LEN equ {}\n", resident.len()));
        fs::write(&c[1], r).expect("write resident blob asm");
    }

    // T0219: `--dedup-resident 1` (tape build only). The first
    // title_len+music_len bytes of the stream are ALREADY resident at
    // TITLE_RESIDENT_LZ (the --resident-out blob above), so boot copies
    // them from there and only block C + block D (the tail of `packed`)
    // need hole space. The stream laid out into the holes, and the
    // title_frags table, then cover just that tail; TITLE_LZ_LEN/
    // MUSIC_LEN/EXTRA_* still describe the full gathered layout.
    let dedup = args[4..]
        .chunks(2)
        .any(|c| c[0] == "--dedup-resident" && c.get(1).map(|v| v.as_str()) == Some("1"));
    let skip = if dedup { title_len + music_len } else { 0 };
    if dedup && !args[4..].chunks(2).any(|c| c[0] == "--resident-out") {
        eprintln!("--dedup-resident requires --resident-out (the resident copy must exist)");
        std::process::exit(1);
    }
    let packed_full_len = packed.len();
    let packed: Vec<u8> = packed[skip..].to_vec();

    // The gathered stream sits at TITLE_LZ_BUF with the banner and the
    // transient scratch laid out after it by room36.asm (TITLE_GATHER_LEN),
    // whose guards catch the chain running past $FF00. This is only a
    // sanity bound.
    if packed.len() > 8192 {
        eprintln!(
            "title ({title_len}) + music ({music_len}) + extra ({extra_len}) = {} packed bytes, implausibly large",
            packed.len()
        );
        std::process::exit(1);
    }

    let capacity: usize = holes.iter().map(|&(_, l)| l).sum();
    if packed.len() > capacity {
        eprintln!(
            "title is {} bytes packed but only {} bytes of load-time holes exist",
            packed.len(),
            capacity
        );
        std::process::exit(1);
    }

    let mut s = String::new();
    s.push_str(&format!(
        "; Auto-generated by tools/mktitle -- DO NOT EDIT.\n\
         ; The Spectrum title screen, de-interleaved to PMODE4, reordered\n\
         ; column-major and LZSS-packed: 6144 -> {} bytes ({}%).\n\
         ; Rationale and the transforms that LOST: mktitle.rs' own header.\n\
         ;\n\
         ; Split across the load-time holes below $8000 because it does not\n\
         ; fit the framebuffer windows alone. The target gathers the pieces\n\
         ; into one buffer before unpacking -- see title_frags.\n\n",
        packed_full_len,
        packed_full_len * 100 / 6144
    ));

    // Emit one labelled chunk per hole, in gather order.
    let mut cut = 0usize;
    let mut frags: Vec<(String, usize)> = Vec::new();
    for (i, &(lo, len)) in holes.iter().enumerate() {
        if cut >= packed.len() {
            break;
        }
        let take = len.min(packed.len() - cut);
        let label = format!("title_lz{i}");
        // T0107: org is CONDITIONAL on STAGE_GEN. title_lz.asm is
        // included UNCONDITIONALLY in both the raw measurement pass and
        // the real packed build (title_frags.asm's fdb entries need
        // these labels to exist either way). Once holes could land
        // inside low-data/code+data, a STALE title_lz.asm's real
        // addresses got assembled into the RAW pass too and polluted
        // the exact regions that pass exists to measure -- a genuine
        // circularity, not the harmless case this used to be when every
        // hole was framebuffer-only. Scratch address $c000 is always
        // free in the raw pass (it is never measured, and the packed
        // pass never uses it -- STAGE_GEN is not defined there).
        s.push_str(&format!(
            "; hole at ${:04x}: using {} of {} bytes\n             	ifdef STAGE_GEN\n             		org $c000+({i}*128)\n             	else\n             		org ${:04x}\n             	endif\n{}\n",
            lo, take, len, lo, label
        ));
        for chunk in packed[cut..cut + take].chunks(16) {
            let hex: Vec<String> = chunk.iter().map(|b| format!("${b:02x}")).collect();
            s.push_str(&format!("\tfcb {}\n", hex.join(",")));
        }
        s.push('\n');
        frags.push((label, take));
        cut += take;
    }

    // The gather table goes in a SEPARATE file: it is resident code-area
    // data, while the fragments above each carry their own `org` into a
    // hole. Mixing them would drag that last org into whatever follows
    // the include.
    let mut t = String::new();
    if raw_extras {
        assert!(frags.is_empty(), "--raw-extras: nothing may be left to gather");
        t.push_str(
            "; Auto-generated by tools/mktitle -- DO NOT EDIT.\n\
             ; T0224 (--raw-extras): blocks C/D travel as raw tape segments, so the\n\
             ; title stream has NO fragments and there is no title_frags gather table.\n",
        );
    } else {
    t = String::from(
        "; Auto-generated by tools/mktitle -- DO NOT EDIT.\n\
         ; (source, length) pairs in stream order; a zero length ends the\n\
         ; list. The target walks these to gather the split title stream\n\
         ; into one contiguous buffer before unpacking it.\n",
    );
    t.push_str("title_frags\n");
    for (label, take) in &frags {
        t.push_str(&format!("        fdb {label},{take}\n"));
    }
    t.push_str("        fdb 0,0\n");
    // T0120: FIXED SIZE. This table is assembled into the low region, and the
    // holes are measured from the raw pass -- which assembled the PREVIOUS
    // build's table. When the title needed one more hole than last time, the
    // table grew 4 bytes between the passes and the low block ran 4 bytes
    // into the hole chosen for the title (memaudit: overlapping blocks at
    // $0B85). Padding after the terminator keeps both passes the same size;
    // the gather loop stops at the first zero length and never reads it.
    const MAX_FRAGS: usize = 6;
    if frags.len() > MAX_FRAGS {
        eprintln!(
            "title needs {} holes but title_frags is fixed at {MAX_FRAGS} entries -- raise MAX_FRAGS (costs 4 bytes each in the low region)",
            frags.len()
        );
        std::process::exit(1);
    }
    for _ in frags.len()..MAX_FRAGS {
        t.push_str("        fdb 0,0                  ; padding (fixed size)\n");
    }
    }
    // T0223: `--tail-region-end ADDR` (tape build). The hole that ENDS at ADDR
    // (code+data's spare, ending at $4000) is filled front-to-back, so its
    // unused TAIL is persistent free RAM: boot only READS the fragments
    // (gather copies them to TITLE_LZ_BUF) and nothing writes the tail.
    // Emit exactly where the title's own bytes end (TAPE_LOW3_START), so the
    // region is "whatever the title does not need" with zero hand-kept
    // margin, plus where the hole begins (the resident code must end at or
    // below it; room36.asm asserts that) and where the region ends.
    let mut tail_note = String::new();
    if let Some(c) = args[4..].chunks(2).find(|c| c[0] == "--tail-region-end") {
        let end = u32::from_str_radix(c[1].trim_start_matches("0x"), 16).expect("tail-region-end addr");
        let (i, &(lo, len)) = holes
            .iter()
            .enumerate()
            .find(|(_, h)| h.0 as u32 + h.1 as u32 == end)
            .expect("--tail-region-end: no hole ends at that address");
        let label = format!("title_lz{i}");
        let take = frags.iter().find(|(l, _)| *l == label).map(|(_, n)| *n).unwrap_or(0);
        t.push_str(&format!("TAPE_LOW3_HOLE_START equ ${:04x}\n", lo));
        t.push_str(&format!("TAPE_LOW3_START equ ${:04x}\n", lo as usize + take));
        t.push_str(&format!("TAPE_LOW3_END equ ${:04x}\n", end));
        tail_note = format!(
            ", tail region ${:04x}-${:04x} = {} bytes persistent free",
            lo as usize + take,
            end,
            len - take
        );
    }
    t.push_str(&format!("TITLE_LZ_LEN equ {}\n", title_len));
    t.push_str(&format!("TITLE_MUSIC_LEN equ {}\n", music_len));
    // T0120: the UNPACKED blob size, so room36.asm can place MIX3_DP's page
    // strictly past the blob and assert it (a margin guess rounded down once).
    t.push_str(&format!("TITLE_MUSIC_RAW equ {}\n", music_raw));
    t.push_str(&format!("TITLE_EXTRA_LEN equ {}\n", extra_len));
    t.push_str(&format!("TITLE_EXTRA_RAW equ {}\n", extra_raw));
    t.push_str(&format!("TITLE_EXTRA2_LEN equ {}\n", extra2_len));
    t.push_str(&format!("TITLE_EXTRA2_RAW equ {}\n", extra2_raw));

    fs::write(&args[2], s).expect("write blob asm");
    fs::write(&args[3], t).expect("write table asm");
    println!(
        "title 6144 -> {} bytes ({}%) + music {} bytes + extra {} bytes ({} raw) + extra2 {} bytes ({} raw), split across {} holes, {} bytes of hole space spare{}",
        title_len,
        title_len * 100 / 6144,
        music_len,
        extra_len,
        extra_raw,
        extra2_len,
        extra2_raw,
        frags.len(),
        capacity - packed.len(),
        tail_note
    );
}
