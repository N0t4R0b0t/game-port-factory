//! .cas cassette image writer for the CoCo2 target, matching the block
//! format Color BASIC's ROM cassette I/O actually implements -- verified
//! against a real disassembly of source/roms/BASIC.ROM (Color BASIC 1.2,
//! "Color Basic Unravelled II" listing cross-checked byte-for-byte
//! against our own ROM dump), not assumed from folklore:
//!
//!   GETBLK ($A70B, ROM vector BLKIN at $A006) bit-scans the incoming tape
//!   signal for a byte matching $3C (the sync byte), then reads:
//!     type byte, length byte, `length` data bytes, checksum byte
//!   checksum = (type + length + sum(data bytes)) & 0xFF -- this is
//!   exactly GETBLK's own running total (ADDA BLKTYP once, then ADDA
//!   CCKSUM once per data byte), compared against the trailing byte it
//!   reads last.
//!
//!   CASON ($A77C, ROM vector CSRDON at $A004) does NOT look for $3C
//!   itself -- it locks onto the leader's alternating-bit tone (96
//!   consecutive transitions) first. The real SAVEM routine calls WRLDR
//!   (write leader) before EVERY block, header or data ($A473, $A620
//!   region), so this writer puts a fresh leader before every block too.
//!
//! Block types: 0 = namefile (header), 1 = data, 0xFF = EOF. This 3-way
//! split, and the 15-byte namefile payload layout below, are the
//! standard DECB cassette convention (not found written down inside the
//! ROM itself, which only cares about generic type/len/data/checksum);
//! confirmed empirically by CLOADM successfully loading a caswriter-built
//! image in XRoar (see tools/tapeloader_spike).

pub const LEADER_BYTE: u8 = 0x55;
pub const SYNC_BYTE: u8 = 0x3C;
pub const DEFAULT_LEADER_LEN: usize = 128;

/// The gap between CONSECUTIVE blocks of the SAME cassette "file" --
/// i.e. after the tone has already locked once and doesn't need to
/// re-lock, only GETBLK's own $3C bit-scan needs to find the next sync.
/// Measured directly from a real xroar-encoded reference
/// (/tmp/ref2.cas, `CSAVEM"REF",&H3000,&H3257,&H3000` -- a 600-byte
/// range, split into 255+255+90-byte data blocks): the namefile block
/// gets a full ~234-byte leader (a fresh CASON tone-lock), but EVERY
/// block after that -- data block 2, data block 3, EOF -- has exactly
/// 2 bytes of $55 before its sync, not a whole leader. This matches the
/// ROM disassembly (T0226): CLOADM calls CASON ONCE (LA52B), then loops
/// on GETBLK alone (LA52E) for every subsequent block in the file.
/// T0229: tape_stage1.asm does the same -- one CSRDON call for the
/// WHOLE segment stream, not per block -- and this constant is what
/// caswriter uses for every block after the first.
pub const INTER_BLOCK_GAP: usize = 2;

pub const BLOCK_NAMEFILE: u8 = 0x00;
pub const BLOCK_DATA: u8 = 0x01;
pub const BLOCK_EOF: u8 = 0xFF;

/// File type byte inside a namefile block.
pub const FILETYPE_BASIC: u8 = 0x00;
pub const FILETYPE_DATA: u8 = 0x01;
pub const FILETYPE_ML: u8 = 0x02;

/// checksum = type + len + sum(data), all mod 256 -- confirmed against a
/// REAL reference .cas (xroar's own CSAVEM"REF",&H3000,&H300F,&H3000
/// encoder, /tmp/ref.cas) byte-for-byte: its namefile block checksum is
/// $EE = 0(type) + 15(len) + 0xDF(sum of the 15-byte payload), and its
/// data block checksum is $89 = 1(type) + 16(len) + 0x78(sum of 16
/// bytes 0..15). An earlier version of this function omitted `len`,
/// which self-consistently passed this file's own round-trip tests
/// (parse_blocks used the same wrong formula) but produced a byte
/// stream neither GETBLK nor a real CoCo would accept -- see NOTES.md
/// T0227 for the diff that caught it.
pub fn checksum(block_type: u8, len: u8, data: &[u8]) -> u8 {
    let mut sum: u8 = block_type.wrapping_add(len);
    for &b in data {
        sum = sum.wrapping_add(b);
    }
    sum
}

/// Appends one full block (leader + sync + type + len + data + checksum)
/// to `out`. `data.len()` must fit in a u8 (<= 255) -- GETBLK's length
/// field is one byte, same constraint as the real ROM.
pub fn write_block(out: &mut Vec<u8>, leader_len: usize, block_type: u8, data: &[u8]) {
    assert!(data.len() <= 255, "block payload must be <= 255 bytes (BLKLEN is one byte)");
    out.extend(std::iter::repeat(LEADER_BYTE).take(leader_len));
    out.push(SYNC_BYTE);
    out.push(block_type);
    out.push(data.len() as u8);
    out.extend_from_slice(data);
    out.push(checksum(block_type, data.len() as u8, data));
}

/// Standard 15-byte DECB namefile payload: 8-char name (space padded),
/// file type, ASCII flag, gap flag, exec addr (BE), load addr (BE).
pub fn namefile_payload(
    name: &str,
    file_type: u8,
    ascii: bool,
    gaps: bool,
    exec_addr: u16,
    load_addr: u16,
) -> [u8; 15] {
    let mut out = [0x20u8; 15]; // space-pad
    let bytes = name.as_bytes();
    assert!(bytes.len() <= 8, "namefile name must be <= 8 chars");
    out[..bytes.len()].copy_from_slice(bytes);
    out[8] = file_type;
    out[9] = if ascii { 0xFF } else { 0x00 };
    out[10] = if gaps { 0xFF } else { 0x00 };
    out[11] = (exec_addr >> 8) as u8;
    out[12] = (exec_addr & 0xFF) as u8;
    out[13] = (load_addr >> 8) as u8;
    out[14] = (load_addr & 0xFF) as u8;
    out
}

/// Builds a complete "one ML file" image: namefile block, the ML payload
/// split into <= 255-byte data blocks, and an EOF block -- exactly what
/// a real CSAVEM would put on tape and CLOADM expects to read back.
pub fn write_ml_file(
    out: &mut Vec<u8>,
    leader_len: usize,
    name: &str,
    load_addr: u16,
    exec_addr: u16,
    payload: &[u8],
    max_block: usize,
) {
    assert!(max_block >= 1 && max_block <= 255);
    // Only the FIRST block (namefile) gets a full leader -- CLOADM
    // calls CASON once for the whole file, then loops on GETBLK alone
    // (see INTER_BLOCK_GAP's own doc comment). Mirroring this matters
    // for real load time: this file is what a real CLOADM reads, so it
    // must match what a real CSAVEM writes, byte-timing included.
    let header = namefile_payload(name, FILETYPE_ML, false, false, exec_addr, load_addr);
    write_block(out, leader_len, BLOCK_NAMEFILE, &header);
    for chunk in payload.chunks(max_block) {
        write_block(out, INTER_BLOCK_GAP, BLOCK_DATA, chunk);
    }
    write_block(out, INTER_BLOCK_GAP, BLOCK_EOF, &[]);
}

/// Appends RAW data blocks with no namefile framing -- what our stage-1
/// loader reads directly via its own BLKIN calls, continuing past the
/// EOF block CLOADM already consumed. No EOF block is written here: the
/// reader (our stage-1 code) knows exactly how many blocks to expect.
pub fn write_raw_blocks(out: &mut Vec<u8>, leader_len: usize, payload: &[u8], max_block: usize) {
    assert!(max_block >= 1 && max_block <= 255);
    for chunk in payload.chunks(max_block) {
        write_block(out, leader_len, BLOCK_DATA, chunk);
    }
}

/// Parses a `lwasm --decb` binary into its (addr, data) segments plus
/// the EOF block's exec address -- the same shape
/// harness/mame_load_run.lua's `load_decb` already reads, reimplemented
/// here so tools/tape_pack.sh can turn ANY such build straight into a
/// tape_stage1.asm segment stream without hand-maintained address
/// lists. Segments are returned in FILE order (not sorted) -- callers
/// that care about contiguity should sort by address themselves.
pub fn parse_decb(data: &[u8]) -> (Vec<(u16, Vec<u8>)>, u16) {
    let mut pos = 0usize;
    let mut segments = Vec::new();
    let mut exec_addr = 0u16;
    while pos < data.len() {
        let block_type = data[pos];
        if block_type == 0x00 {
            let len = (data[pos + 1] as usize) * 256 + data[pos + 2] as usize;
            let addr = (data[pos + 3] as u16) * 256 + data[pos + 4] as u16;
            let seg = data[pos + 5..pos + 5 + len].to_vec();
            segments.push((addr, seg));
            pos += 5 + len;
        } else if block_type == 0xFF {
            exec_addr = (data[pos + 3] as u16) * 256 + data[pos + 4] as u16;
            break;
        } else {
            panic!("parse_decb: unknown DECB block type ${block_type:02X} at offset {pos}");
        }
    }
    (segments, exec_addr)
}

/// Writes tape_stage1.asm's own segment-stream format: for every
/// segment, chunked into <= max_chunk (<=255, BLKLEN is one byte)
/// pieces, a 3-byte header block (addr_hi, addr_lo, len) immediately
/// followed by a `len`-byte data block at the next address along --
/// stage1 reads them in this exact lockstep, so header and data are
/// ALWAYS a pair, never merged or reordered. Ends with the sentinel
/// stage1 checks for (header addr=$FFFF) followed by a 2-byte data
/// block holding the real jump-to address.
pub fn write_segment_stream(
    out: &mut Vec<u8>,
    leader_len: usize,
    segments: &[(u16, Vec<u8>)],
    exec_addr: u16,
    max_chunk: usize,
) {
    assert!(max_chunk >= 1 && max_chunk <= 255);
    // T0229: tape_stage1.asm calls CSRDON exactly ONCE, before reading
    // the very first header -- so ONLY that first block gets a full
    // leader here; everything after (every other header, every data
    // chunk, the sentinel and its exec-addr block) gets INTER_BLOCK_GAP,
    // matching what stage1's single tone-lock can actually rely on
    // (mirrors real CSAVEM/CLOADM exactly -- see INTER_BLOCK_GAP's doc).
    let mut first = true;
    let mut gap = |out: &mut Vec<u8>, block_type: u8, data: &[u8]| {
        write_block(out, if first { leader_len } else { INTER_BLOCK_GAP }, block_type, data);
        first = false;
    };
    for (addr, data) in segments {
        let mut a = *addr;
        for chunk in data.chunks(max_chunk) {
            let header = [(a >> 8) as u8, (a & 0xFF) as u8, chunk.len() as u8];
            gap(out, BLOCK_DATA, &header);
            gap(out, BLOCK_DATA, chunk);
            a = a.wrapping_add(chunk.len() as u16);
        }
    }
    let sentinel = [0xFFu8, 0xFF, 0x02];
    gap(out, BLOCK_DATA, &sentinel);
    let exec_bytes = [(exec_addr >> 8) as u8, (exec_addr & 0xFF) as u8];
    gap(out, BLOCK_DATA, &exec_bytes);
}

/// A from-scratch reimplementation of GETBLK's parse logic (sync-scan,
/// type/len/data/checksum), used ONLY by tests to prove write_block's
/// output is exactly what the real ROM routine would accept -- this is
/// the offline verifier a cheaper tier can run without an emulator.
pub struct ParsedBlock {
    pub block_type: u8,
    pub data: Vec<u8>,
    pub checksum_ok: bool,
}

pub fn parse_blocks(bytes: &[u8]) -> Vec<ParsedBlock> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        // skip leader bytes and anything before the next sync byte
        while i < bytes.len() && bytes[i] != SYNC_BYTE {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        i += 1; // consume sync
        if i + 2 > bytes.len() {
            break;
        }
        let block_type = bytes[i];
        let len = bytes[i + 1] as usize;
        i += 2;
        if i + len + 1 > bytes.len() {
            break;
        }
        let data = bytes[i..i + len].to_vec();
        i += len;
        let cksum = bytes[i];
        i += 1;
        let checksum_ok = checksum(block_type, len as u8, &data) == cksum;
        out.push(ParsedBlock { block_type, data, checksum_ok });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_matches_getblk_accumulation() {
        // GETBLK: ADDA BLKTYP, then ADDA BLKLEN (A721: ADDA BLKTYP while
        // A holds LEN -- i.e. the running total STARTS as type+len),
        // then ADDA CCKSUM (running) per byte.
        let data = [0x01u8, 0x02, 0xFF];
        let mut manual: u8 = 5u8.wrapping_add(data.len() as u8); // type + len
        for b in data {
            manual = manual.wrapping_add(b);
        }
        assert_eq!(checksum(5, data.len() as u8, &data), manual);
    }

    #[test]
    fn checksum_matches_a_real_xroar_encoded_reference() {
        // /tmp/ref.cas, generated 2026-09-27 by:
        //   xroar -machine coco2bus -tape-write /tmp/ref.cas
        //     -type 'FOR I=0 TO 15:POKE &H3000+I,I:NEXT<CR>
        //            CSAVEM"REF",&H3000,&H300F,&H3000<CR>'
        // Namefile checksum $EE = 0(type) + 15(len) + sum(15-byte
        // payload); data-block checksum $89 = 1(type) + 16(len) +
        // sum(0..15). An earlier version of this function (type+data
        // only, no len) gave $DF and $79 -- self-consistent with this
        // file's own (also wrong) parser, but NOT what a real CoCo
        // wrote. See NOTES.md T0227.
        let namefile_payload = namefile_payload("REF", FILETYPE_ML, false, false, 0x3000, 0x3000);
        assert_eq!(checksum(BLOCK_NAMEFILE, 15, &namefile_payload), 0xEE);

        let data: Vec<u8> = (0..16u8).collect();
        assert_eq!(checksum(BLOCK_DATA, 16, &data), 0x89);
    }

    /// The sync+type+len+data+checksum bytes of EVERY block in
    /// /tmp/ref.cas (see the checksum test above for how it was made),
    /// extracted with the leader stripped off (real leader length
    /// varies per block on a genuine xroar-written tape -- ~234 $55
    /// bytes before the namefile and data blocks, only 2 before EOF --
    /// and is not part of what this test is pinning down; GETBLK only
    /// needs "enough" leader, not an exact count). This is the
    /// byte-for-byte proof caswriter's block encoding matches a REAL
    /// CoCo cassette write, not just its own (previously wrong) parser.
    const REF_NAMEFILE_BLOCK: [u8; 19] = [
        0x3C, 0x00, 0x0F, 0x52, 0x45, 0x46, 0x20, 0x20, 0x20, 0x20, 0x20, 0x02, 0x00, 0x00, 0x30,
        0x00, 0x30, 0x00, 0xEE,
    ];
    const REF_DATA_BLOCK: [u8; 20] = [
        0x3C, 0x01, 0x10, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F, 0x89,
    ];
    const REF_EOF_BLOCK: [u8; 4] = [0x3C, 0xFF, 0x00, 0xFF];

    /// Every position where a fresh block starts (a SYNC_BYTE not
    /// itself part of the preceding block's checksum/data, found by
    /// walking leader runs -- i.e. every $3C immediately preceded by
    /// at least one $55).
    fn sync_positions(cas: &[u8]) -> Vec<usize> {
        (1..cas.len())
            .filter(|&i| cas[i] == SYNC_BYTE && cas[i - 1] == LEADER_BYTE)
            .collect()
    }

    #[test]
    fn matches_a_real_xroar_encoded_reference_byte_for_byte() {
        let mut cas = Vec::new();
        write_ml_file(&mut cas, 8, "REF", 0x3000, 0x3000, &(0..16u8).collect::<Vec<u8>>(), 255);

        let syncs = sync_positions(&cas);
        assert_eq!(syncs.len(), 3, "namefile + 1 data block + EOF");

        assert_eq!(&cas[syncs[0]..syncs[0] + REF_NAMEFILE_BLOCK.len()], &REF_NAMEFILE_BLOCK);
        assert_eq!(&cas[syncs[1]..syncs[1] + REF_DATA_BLOCK.len()], &REF_DATA_BLOCK);
        assert_eq!(&cas[syncs[2]..syncs[2] + REF_EOF_BLOCK.len()], &REF_EOF_BLOCK);
    }

    #[test]
    fn namefile_payload_layout() {
        let p = namefile_payload("SPIKE1", FILETYPE_ML, false, false, 0x3010, 0x3000);
        assert_eq!(p.len(), 15);
        assert_eq!(&p[0..6], b"SPIKE1");
        assert_eq!(&p[6..8], b"  "); // space-padded to 8
        assert_eq!(p[8], FILETYPE_ML);
        assert_eq!(p[9], 0x00);
        assert_eq!(p[10], 0x00);
        assert_eq!(p[11], 0x30);
        assert_eq!(p[12], 0x10);
        assert_eq!(p[13], 0x30);
        assert_eq!(p[14], 0x00);
    }

    #[test]
    fn round_trip_ml_file_through_getblk_reimplementation() {
        let mut cas = Vec::new();
        let payload: Vec<u8> = (0..600u32).map(|i| (i % 256) as u8).collect();
        write_ml_file(&mut cas, 16, "SPIKE1", 0x3000, 0x3010, &payload, 255);

        let blocks = parse_blocks(&cas);
        // namefile + ceil(600/255)=3 data blocks + EOF
        assert_eq!(blocks.len(), 1 + 3 + 1);
        assert_eq!(blocks[0].block_type, BLOCK_NAMEFILE);
        assert!(blocks[0].checksum_ok);
        let mut recovered = Vec::new();
        for b in &blocks[1..blocks.len() - 1] {
            assert_eq!(b.block_type, BLOCK_DATA);
            assert!(b.checksum_ok);
            recovered.extend_from_slice(&b.data);
        }
        assert_eq!(recovered, payload);
        let last = blocks.last().unwrap();
        assert_eq!(last.block_type, BLOCK_EOF);
        assert_eq!(last.data.len(), 0);
        assert!(last.checksum_ok);
    }

    #[test]
    fn round_trip_raw_blocks_used_by_the_stage1_loader() {
        let mut cas = Vec::new();
        let payload: Vec<u8> = (0..8192u32).map(|i| (i % 256) as u8).collect();
        write_raw_blocks(&mut cas, 16, &payload, 200);

        let blocks = parse_blocks(&cas);
        assert_eq!(blocks.len(), 8192usize.div_ceil(200));
        let mut recovered = Vec::new();
        for b in &blocks {
            assert_eq!(b.block_type, BLOCK_DATA);
            assert!(b.checksum_ok);
            recovered.extend_from_slice(&b.data);
        }
        assert_eq!(recovered, payload);
    }

    #[test]
    fn corrupted_byte_flips_checksum_ok_to_false() {
        let mut cas = Vec::new();
        write_block(&mut cas, 8, BLOCK_DATA, &[1, 2, 3, 4]);
        // flip a data byte after the fact, simulating tape damage
        let sync_pos = cas.iter().position(|&b| b == SYNC_BYTE).unwrap();
        cas[sync_pos + 3] ^= 0xFF; // first data byte
        let blocks = parse_blocks(&cas);
        assert_eq!(blocks.len(), 1);
        assert!(!blocks[0].checksum_ok);
    }

    #[test]
    #[should_panic]
    fn block_over_255_bytes_rejected() {
        let mut cas = Vec::new();
        write_block(&mut cas, 8, BLOCK_DATA, &vec![0u8; 256]);
    }

    /// A tiny hand-built DECB image: two blocks with a gap between them
    /// (mirrors target/room36.bin's own shape -- several non-contiguous
    /// `org` regions, not one flat range) plus an EOF/exec marker.
    fn tiny_decb() -> Vec<u8> {
        let mut d = Vec::new();
        // block 1: $0100, 4 bytes
        d.extend([0x00, 0x00, 0x04, 0x01, 0x00, 0xAA, 0xBB, 0xCC, 0xDD]);
        // block 2: $0200 (gap after block 1's $0104 end), 3 bytes
        d.extend([0x00, 0x00, 0x03, 0x02, 0x00, 0x11, 0x22, 0x33]);
        // EOF, exec = $0100
        d.extend([0xFF, 0x00, 0x00, 0x01, 0x00]);
        d
    }

    #[test]
    fn parse_decb_recovers_segments_and_exec_addr() {
        let (segs, exec) = parse_decb(&tiny_decb());
        assert_eq!(segs, vec![(0x0100, vec![0xAA, 0xBB, 0xCC, 0xDD]), (0x0200, vec![0x11, 0x22, 0x33])]);
        assert_eq!(exec, 0x0100);
    }

    /// Reimplements tape_stage1.asm's own segment-stream reader (header
    /// then data, sentinel $FFFF then a 2-byte exec addr) as a test-only
    /// oracle -- proves write_segment_stream emits exactly what stage1
    /// is coded to consume, the same way parse_blocks proves write_block
    /// matches GETBLK.
    fn read_segment_stream(cas: &[u8]) -> (Vec<(u16, Vec<u8>)>, u16) {
        let blocks = parse_blocks(cas);
        assert!(blocks.iter().all(|b| b.checksum_ok));
        let mut i = 0;
        let mut segs = Vec::new();
        loop {
            let hdr = &blocks[i].data;
            let addr = (hdr[0] as u16) * 256 + hdr[1] as u16;
            let len = hdr[2] as usize;
            i += 1;
            let data = blocks[i].data.clone();
            assert_eq!(data.len(), len);
            i += 1;
            if addr == 0xFFFF {
                let exec = (data[0] as u16) * 256 + data[1] as u16;
                return (segs, exec);
            }
            segs.push((addr, data));
        }
    }

    #[test]
    fn segment_stream_round_trips_a_chunked_decb_image() {
        let (segs, exec) = parse_decb(&tiny_decb());
        let mut cas = Vec::new();
        write_segment_stream(&mut cas, 8, &segs, exec, 3); // force chunking
        let (recovered, recovered_exec) = read_segment_stream(&cas);
        // block 1 (4 bytes) splits into a 3-byte and a 1-byte chunk at
        // consecutive addresses; block 2 (3 bytes) fits in one chunk.
        assert_eq!(
            recovered,
            vec![
                (0x0100, vec![0xAA, 0xBB, 0xCC]),
                (0x0103, vec![0xDD]),
                (0x0200, vec![0x11, 0x22, 0x33]),
            ]
        );
        assert_eq!(recovered_exec, 0x0100);
    }

    /// T0229: only the FIRST block gets a full leader; every block
    /// after that (there are 6 more here: 2nd header+data, 3rd
    /// header+data, sentinel header+exec-addr) gets exactly
    /// INTER_BLOCK_GAP -- pins the real-load-time fix in place with an
    /// exact byte count, not just "it still parses".
    #[test]
    fn only_the_first_block_gets_a_full_leader() {
        let (segs, exec) = parse_decb(&tiny_decb());
        let mut cas = Vec::new();
        write_segment_stream(&mut cas, 40, &segs, exec, 3);

        // Sequential walk (like parse_blocks/GETBLK): find a sync ONLY
        // by scanning forward from where the PREVIOUS block ended, so a
        // coincidental $55,$3C byte pair inside real data/checksum
        // bytes elsewhere in the stream can't be mistaken for a block
        // boundary the way a blind whole-buffer scan could.
        let mut pos = 0usize;
        let mut gaps = Vec::new();
        loop {
            let sync_pos = pos + cas[pos..].iter().position(|&b| b == SYNC_BYTE).unwrap();
            gaps.push(sync_pos - pos); // leader length immediately before this sync
            let len = cas[sync_pos + 2] as usize;
            pos = sync_pos + 1 + 1 + 1 + len + 1; // sync+type+len+data+checksum
            if pos >= cas.len() {
                break;
            }
        }
        assert_eq!(gaps.len(), 8, "3 chunk header+data pairs (4-byte seg splits into 3+1) + sentinel header+exec-addr pair");
        assert_eq!(gaps[0], 40, "first block gets the full leader");
        for &g in &gaps[1..] {
            assert_eq!(g, INTER_BLOCK_GAP, "every block after the first should get only the short inter-block gap");
        }
    }
}
