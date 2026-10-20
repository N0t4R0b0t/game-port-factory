//! T0225: DTE (byte-pair) text compression for the message-VM text corpus.
//!
//! `prtmessage` (target/text_src/../message.asm) claims byte ranges 128-255
//! (cursor XY), 32-127 (literal char -- glyphs only exist for 38-90, but
//! EVERY byte 32-127 is consumed as a "char" by the dispatch, drawing
//! nothing for the rest) and 16-31 (pen, regardless of whether the pen
//! value is one any message actually uses) before falling through to the
//! seven named low opcodes (0,3,4,5,6,9,10). That leaves two genuinely free
//! ranges for DTE codes:
//!
//!   - LOW_SET: 1,2,7,8,11,12,13,14,15 (9 codes) -- values <16 that are none
//!     of the seven named opcodes; the VM currently just skips them.
//!   - HI range: 91..=127 (37 codes) -- no glyph exists there, so a message
//!     using one today is already inert/a bug. Repurposing this range needs
//!     one new range test in prtmessage's dispatch, inserted before the
//!     existing `cmpa #32/bhs pm_char` test.
//!
//! Total 46 codes. Codes are assigned in the order table entries are
//! created (greedy pairwise merge, most-frequent-pair-first, stopping once
//! the best remaining pair would not pay for its own table entry): the
//! first min(9, N) codes take LOW_SET values, in LOW_SET's fixed order; any
//! codes after that take HI values in ascending order from 91. The two
//! decoder-side lookup tables (`dte_low_index`, `dte_table`) mirror this
//! exactly -- see target/message.asm's own header for the decoder.

use std::collections::HashMap;

/// Fixed low-range codes, in the order they get assigned first. Must match
/// target/message.asm's `dte_low_index` table exactly.
pub const LOW_SET: [u8; 9] = [1, 2, 7, 8, 11, 12, 13, 14, 15];
/// First byte value of the high range (91..=127).
pub const HI_BASE: u8 = 91;
/// Last byte value of the high range (inclusive).
pub const HI_LAST: u8 = 127;
/// Total codes available (LOW_SET + HI range).
pub const MAX_CODES: usize = LOW_SET.len() + (HI_LAST - HI_BASE + 1) as usize;

/// A message-VM literal text byte must land in this range: 32-127 is the
/// VM's own "char" range, but only 38-90 draws a glyph (font_data.asm:
/// FONT_FIRST=38, FONT_LAST=90) -- so any legitimate text byte is expected
/// to be within 32..=90, comfortably clear of both DTE ranges.
pub const TEXT_MIN: u8 = 32;
pub const TEXT_MAX: u8 = 90;

pub fn is_dte_code(b: u8) -> bool {
    LOW_SET.contains(&b) || (HI_BASE..=HI_LAST).contains(&b)
}

/// One entry of the generated pair table: index i was the i-th code
/// assigned (creation order), decodes to (pair.0, pair.1). Either half may
/// itself be a further DTE code (nesting) or a literal text byte.
#[derive(Clone, Copy, Debug)]
pub struct Entry {
    pub code: u8,
    pub pair: (u8, u8),
}

pub struct Table {
    pub entries: Vec<Entry>,
}

impl Table {
    fn code_for_index(i: usize) -> u8 {
        if i < LOW_SET.len() {
            LOW_SET[i]
        } else {
            HI_BASE + (i - LOW_SET.len()) as u8
        }
    }

    pub fn code_to_index(&self, code: u8) -> Option<usize> {
        self.entries.iter().position(|e| e.code == code)
    }

    /// Decode a single byte (literal or DTE code) into its expansion.
    pub fn decode_byte(&self, b: u8, out: &mut Vec<u8>) {
        if let Some(idx) = self.code_to_index(b) {
            let (a, c) = self.entries[idx].pair;
            self.decode_byte(a, out);
            self.decode_byte(c, out);
        } else {
            out.push(b);
        }
    }

    pub fn decode(&self, bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for &b in bytes {
            self.decode_byte(b, &mut out);
        }
        out
    }

    /// Encode a literal byte string using the table's merges (applies every
    /// learned pair, in creation order -- matches how the table was built).
    pub fn encode(&self, text: &[u8]) -> Vec<u8> {
        let mut seq: Vec<u8> = text.to_vec();
        for entry in &self.entries {
            seq = merge_pair(&seq, entry.pair, entry.code);
        }
        seq
    }
}

fn merge_pair(seq: &[u8], pair: (u8, u8), code: u8) -> Vec<u8> {
    let mut out = Vec::with_capacity(seq.len());
    let mut i = 0;
    while i < seq.len() {
        if i + 1 < seq.len() && seq[i] == pair.0 && seq[i + 1] == pair.1 {
            out.push(code);
            i += 2;
        } else {
            out.push(seq[i]);
            i += 1;
        }
    }
    out
}

/// Build the greedy byte-pair table over every input string combined.
/// Stops when the best remaining pair's frequency would not net-save bytes
/// (each occurrence saves 1 byte; a table entry costs 2 -- so a pair used
/// fewer than 3 times isn't worth a code), or when MAX_CODES is reached.
pub fn build_table(strings: &[Vec<u8>]) -> Table {
    let mut seqs: Vec<Vec<u8>> = strings.to_vec();
    let mut entries = Vec::new();

    while entries.len() < MAX_CODES {
        let mut counts: HashMap<(u8, u8), u32> = HashMap::new();
        for seq in &seqs {
            for w in seq.windows(2) {
                *counts.entry((w[0], w[1])).or_insert(0) += 1;
            }
        }
        // Deterministic tie-break: HashMap iteration order is randomised
        // per-process, so ties on count alone would let the "same" corpus
        // produce a DIFFERENT (if equally-good) table across separate
        // invocations of this tool -- exactly the kind of thing that broke
        // `build` vs `selftest` agreement until this was pinned down.
        let best = counts
            .iter()
            .max_by_key(|&(&p, &c)| (c, std::cmp::Reverse(p)))
            .map(|(&p, &c)| (p, c));
        let Some((pair, count)) = best else { break };
        if count < 3 {
            break; // wouldn't pay for its own 2-byte table entry
        }
        let code = Table::code_for_index(entries.len());
        seqs = seqs.iter().map(|s| merge_pair(s, pair, code)).collect();
        entries.push(Entry { code, pair });
    }

    Table { entries }
}

/// Parse `fcc "..."` lines out of assembler source, returning (line index,
/// leading whitespace, raw ASCII bytes of the string). Every other line is
/// left completely alone by the caller.
pub fn parse_fcc_lines(src: &str) -> Vec<(usize, String, Vec<u8>)> {
    let mut out = Vec::new();
    for (i, line) in src.lines().enumerate() {
        let trimmed = line.trim_start();
        let indent_len = line.len() - trimmed.len();
        if let Some(rest) = trimmed.strip_prefix("fcc \"") {
            if let Some(end) = rest.find('"') {
                if rest[end + 1..].trim().is_empty() {
                    let indent = line[..indent_len].to_string();
                    out.push((i, indent, rest[..end].as_bytes().to_vec()));
                }
            }
        }
    }
    out
}

/// Verify every parsed string is within the safe literal range. Returns the
/// offending (line, byte) pairs; empty means clean.
pub fn check_text_range(strings: &[(usize, String, Vec<u8>)]) -> Vec<(usize, u8)> {
    let mut bad = Vec::new();
    for (line, _, bytes) in strings {
        for &b in bytes {
            if b < TEXT_MIN || b > TEXT_MAX {
                bad.push((*line, b));
            }
        }
    }
    bad
}

/// Rewrite source text into the generated form: every `fcc "..."` line
/// becomes `fcb b,b,...  ; DTE: "original text"`; every other line is
/// passed through byte-identical.
pub fn rewrite(src: &str, table: &Table) -> String {
    rewrite_from(src, table, "target/text_src")
}

/// Like `rewrite`, but names `srcdir` (relative to the port root) in the
/// GENERATED header. The table is only READ -- used for encode-only files
/// (target/text_src_tape/) that must not contribute to the codebook.
pub fn rewrite_from(src: &str, table: &Table, srcdir: &str) -> String {
    let parsed = parse_fcc_lines(src);
    let mut by_line: HashMap<usize, (&String, &Vec<u8>)> = HashMap::new();
    for (line, indent, bytes) in &parsed {
        by_line.insert(*line, (indent, bytes));
    }
    let mut out = String::new();
    out.push_str(&format!(
        "; GENERATED by tools/dte from {srcdir}/<same-name>.asm -- DO NOT EDIT.\n\
         ; fcc text strings replaced with fcb byte lists (T0225 DTE compression).\n\
         ; Edit the text_src copy and rerun tools/stage_pack.sh (which runs\n\
         ; tools/dte first) to regenerate this file.\n\n"
    ));
    for (i, line) in src.lines().enumerate() {
        if let Some((indent, bytes)) = by_line.get(&i) {
            let encoded = table.encode(bytes);
            let list: Vec<String> = encoded.iter().map(|b| b.to_string()).collect();
            let text = String::from_utf8_lossy(bytes);
            out.push_str(indent);
            out.push_str("fcb ");
            out.push_str(&list.join(","));
            out.push_str(&format!("     ; DTE: \"{text}\"\n"));
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

/// Emit target/dte_table.asm: the pair table only (the fixed LOW_SET index
/// table is hand-written in message.asm, since it never changes).
pub fn emit_table_asm(table: &Table) -> String {
    let mut out = String::new();
    out.push_str(
        "; GENERATED by tools/dte -- T0225 DTE pair table. DO NOT EDIT.\n\
         ; Index i (0-based, creation order) decodes to (pair0,pair1); either\n\
         ; half may itself be a further DTE code (nesting). Index<->code-byte\n\
         ; mapping: first 9 indices are LOW_SET codes (see message.asm's\n\
         ; dte_low_index), the rest are HI codes 91+ in order -- see\n\
         ; tools/dte/src/lib.rs Table::code_for_index.\n\n",
    );
    out.push_str(&format!("DTE_CODE_COUNT equ {}\n", table.entries.len()));
    out.push_str("dte_table\n");
    for (i, e) in table.entries.iter().enumerate() {
        let a = describe_byte(e.pair.0);
        let b = describe_byte(e.pair.1);
        out.push_str(&format!(
            "        fcb {},{}     ; [{}] code {} = {} {}\n",
            e.pair.0, e.pair.1, i, e.code, a, b
        ));
    }
    out
}

fn describe_byte(b: u8) -> String {
    if (TEXT_MIN..=TEXT_MAX).contains(&b) && b.is_ascii() {
        format!("'{}'", b as char)
    } else {
        format!("code{b}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings_from(files: &[&str]) -> Vec<Vec<u8>> {
        files
            .iter()
            .flat_map(|s| parse_fcc_lines(s))
            .map(|(_, _, b)| b)
            .collect()
    }

    #[test]
    fn round_trip_sample() {
        let src = "        fcb 3,1\nfoo     fcc \"HELLO:THERE\"\n        fcb 0\n";
        let strings = strings_from(&[src]);
        let table = build_table(&strings);
        for s in &strings {
            let enc = table.encode(s);
            let dec = table.decode(&enc);
            assert_eq!(&dec, s);
        }
    }

    #[test]
    fn rewrite_preserves_non_fcc_lines() {
        let src = "label   fcb 1,2,3\n        fcc \"HELLO\"\n        rts\n";
        let strings = strings_from(&[src]);
        let table = build_table(&strings);
        let out = rewrite(src, &table);
        assert!(out.contains("label   fcb 1,2,3"));
        assert!(out.contains("rts"));
        assert!(!out.contains("fcc \"HELLO\""));
    }

    #[test]
    fn codes_never_collide_with_text_range() {
        for &c in LOW_SET.iter() {
            assert!(!(TEXT_MIN..=TEXT_MAX).contains(&c));
        }
        assert!(HI_BASE > TEXT_MAX);
    }

    #[test]
    fn rewrite_header_unchanged_for_corpus_files() {
        let out = rewrite("        fcc \"HELLO\"\n", &build_table(&[]));
        assert!(out.starts_with(
            "; GENERATED by tools/dte from target/text_src/<same-name>.asm -- DO NOT EDIT.\n"
        ));
    }

    #[test]
    fn max_codes_is_46() {
        assert_eq!(MAX_CODES, 46);
    }
}
