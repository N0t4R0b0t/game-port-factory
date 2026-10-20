//! LZ codec shared by the packer (bin/lzpack.rs), the title-screen converter
//! (bin/mktitle.rs) and roompack's collision masks, and mirrored by
//! `lz_unpack` in target/boot_code.asm.
//!
//! Three implementations of one format drift silently, and a mis-decode on
//! the 6809 is invisible -- it just draws the wrong tiles. Keeping the two
//! host-side halves in one module removes one of the three ways that can
//! happen; harness/lzverify.lua covers the third by checking the real
//! unpacked image in the emulator.
//!
//! T0126: a ZX0-STYLE bit-level format, replacing T0085's byte-aligned LZSS
//! (4096 window, 3..18 matches, one flag byte per 8 items). Measured on this
//! game's data the LZSS packed the room blocks to only 76-81%; this packs
//! them to ~62-65%, within a few percent of exomizer and xz, for a decoder
//! of about the same size and still no decoder RAM (the output buffer is the
//! window). The format is this project's own, not zx0-compatible: it only
//! has to agree with lz_unpack.
//!
//! BITS are read MSB-first from "bit bytes"; RAW bytes (literals, an
//! offset's low byte) sit in the same stream and are read at the point they
//! are needed. The decoder fetches a new bit byte only when its buffer runs
//! dry, so the encoder reserves a bit byte at the moment it writes the first
//! bit that needs one -- the two agree on stream order by construction.
//!
//! GAMMA(v), v >= 1: interlaced Elias gamma. For each bit of v below its top
//! bit, MSB first: a 0 then that bit. Then a 1. (v=1 is a single 1 bit.)
//!
//! TOKENS. The state is "after a match" at the start.
//!
//!     after a match:     0 -> LITERALS   n = GAMMA, then n raw bytes
//!                        1 -> NEW MATCH
//!     after literals:    0 -> REPEAT     n = GAMMA, copy n from the last offset
//!                        1 -> NEW MATCH
//!     NEW MATCH:         m = GAMMA (1..256); m == 256 is END
//!                        offset = ((m-1) << 8 | raw byte) + 1   (1..65280)
//!                        n = GAMMA + 1                         (2..)
//!
//! Every match (new or repeated) is followed by the "after a match" state and
//! every literal run by "after literals" -- two literal runs in a row, or a
//! repeat right after a match, can never be the cheaper choice, so the
//! grammar spends no bits on them. Overlapping copies are intentional and
//! must run forwards a byte at a time: offset 1 is how a run is encoded.

use std::collections::HashMap;

const END_MSB: u32 = 256;
const MAX_OFFSET: usize = 65280;
const MAX_CANDIDATES: usize = 96; // match-finder chain depth per position
const MAX_LIT_RUN: usize = 256; // longest literal run the parser considers
const KEEP_STATES: usize = 8; // parser states kept per position

fn gamma_bits(v: u32) -> u32 {
    debug_assert!(v >= 1);
    2 * (31 - v.leading_zeros()) + 1
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Lit,
    Match,
}

#[derive(Clone, Copy)]
enum Tok {
    Start,
    Lit(u32),
    Rep(u32),
    New(u32, u32), // offset, length
}

struct Node {
    cost: u64,
    prev: usize,
    tok: Tok,
    last: u32,
    kind: Kind,
}

struct BitWriter {
    out: Vec<u8>,
    bit_at: usize,
    mask: u8,
}

impl BitWriter {
    fn bit(&mut self, b: bool) {
        if self.mask == 0 {
            self.out.push(0);
            self.bit_at = self.out.len() - 1;
            self.mask = 0x80;
        }
        if b {
            self.out[self.bit_at] |= self.mask;
        }
        self.mask >>= 1;
    }
    fn byte(&mut self, v: u8) {
        self.out.push(v);
    }
    fn gamma(&mut self, v: u32) {
        let top = 31 - v.leading_zeros();
        for i in (0..top).rev() {
            self.bit(false);
            self.bit((v >> i) & 1 == 1);
        }
        self.bit(true);
    }
}

pub fn pack(data: &[u8]) -> Vec<u8> {
    let n = data.len();
    // --- match finder: every earlier position with the same 2-byte prefix
    let mut chains: HashMap<(u8, u8), Vec<usize>> = HashMap::new();
    // --- parse: arena of nodes, per-position list of the best states
    let mut arena: Vec<Node> = vec![Node { cost: 0, prev: usize::MAX, tok: Tok::Start, last: 1, kind: Kind::Match }];
    let mut at: Vec<Vec<usize>> = vec![Vec::new(); n + 1];
    at[0].push(0);

    let relax = |arena: &mut Vec<Node>, at: &mut Vec<Vec<usize>>, pos: usize, node: Node| {
        let list = &mut at[pos];
        // same (last offset, kind) already there: keep the cheaper
        for &idx in list.iter() {
            let e = &arena[idx];
            if e.last == node.last && e.kind == node.kind {
                if node.cost < e.cost {
                    arena[idx] = node;
                }
                return;
            }
        }
        arena.push(node);
        list.push(arena.len() - 1);
    };

    for pos in 0..n {
        // prune this position's states to the cheapest few before expanding
        {
            let mut list = std::mem::take(&mut at[pos]);
            list.sort_by_key(|&i| arena[i].cost);
            list.truncate(KEEP_STATES);
            at[pos] = list;
        }
        let states = at[pos].clone();
        // candidate matches at pos: (offset, max length)
        let mut cands: Vec<(usize, usize)> = Vec::new();
        if pos + 1 < n {
            if let Some(list) = chains.get(&(data[pos], data[pos + 1])) {
                for &start in list.iter().rev().take(MAX_CANDIDATES) {
                    let off = pos - start;
                    if off > MAX_OFFSET {
                        break;
                    }
                    let mut l = 0;
                    while pos + l < n && data[start + l] == data[pos + l] {
                        l += 1;
                    }
                    if l >= 2 {
                        cands.push((off, l));
                    }
                }
            }
        }
        for &si in &states {
            let (cost, last, kind) = (arena[si].cost, arena[si].last, arena[si].kind);
            if kind == Kind::Match {
                for len in 1..=MAX_LIT_RUN.min(n - pos) {
                    let c = cost + 1 + gamma_bits(len as u32) as u64 + 8 * len as u64;
                    relax(&mut arena, &mut at, pos + len, Node { cost: c, prev: si, tok: Tok::Lit(len as u32), last, kind: Kind::Lit });
                }
            } else {
                let off = last as usize;
                if off <= pos {
                    let mut l = 0;
                    while pos + l < n && data[pos - off + l] == data[pos + l] {
                        l += 1;
                    }
                    for len in 1..=l {
                        let c = cost + 1 + gamma_bits(len as u32) as u64;
                        relax(&mut arena, &mut at, pos + len, Node { cost: c, prev: si, tok: Tok::Rep(len as u32), last, kind: Kind::Match });
                    }
                }
            }
            for &(off, maxl) in &cands {
                let msb = ((off - 1) >> 8) as u32 + 1;
                let base = cost + 1 + gamma_bits(msb) as u64 + 8;
                // every length is a distinct target position; long runs are
                // capped at a spread of lengths plus the maximum
                let mut lens: Vec<usize> = (2..=maxl.min(48)).collect();
                if maxl > 48 {
                    lens.push(maxl);
                }
                for len in lens {
                    let c = base + gamma_bits((len - 1) as u32) as u64;
                    relax(&mut arena, &mut at, pos + len, Node { cost: c, prev: si, tok: Tok::New(off as u32, len as u32), last: off as u32, kind: Kind::Match });
                }
            }
        }
        if pos + 1 < n {
            chains.entry((data[pos], data[pos + 1])).or_default().push(pos);
        }
    }

    // cheapest final state (END costs the same from either kind)
    let &best = at[n].iter().min_by_key(|&&i| arena[i].cost).expect("no parse");
    let mut toks = Vec::new();
    let mut i = best;
    while arena[i].prev != usize::MAX {
        toks.push(arena[i].tok);
        i = arena[i].prev;
    }
    toks.reverse();

    let mut w = BitWriter { out: Vec::new(), bit_at: 0, mask: 0 };
    let mut pos = 0usize;
    for t in toks {
        match t {
            Tok::Lit(len) => {
                w.bit(false);
                w.gamma(len);
                for k in 0..len as usize {
                    w.byte(data[pos + k]);
                }
                pos += len as usize;
            }
            Tok::Rep(len) => {
                w.bit(false);
                w.gamma(len);
                pos += len as usize;
            }
            Tok::New(off, len) => {
                w.bit(true);
                let o = off - 1;
                w.gamma((o >> 8) + 1);
                w.byte((o & 0xFF) as u8);
                w.gamma(len - 1);
                pos += len as usize;
            }
            Tok::Start => {}
        }
    }
    w.bit(true);
    w.gamma(END_MSB);
    debug_assert_eq!(pos, n);
    w.out
}

/// Decode, exactly as lz_unpack does, so the packer can prove its own output
/// before it ever reaches the 6809. A codec that is wrong in the same
/// direction on both sides round-trips happily and still corrupts the target.
pub fn unpack(p: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut u = 0usize;
    let mut bits: u8 = 0x80; // sentinel only: empty
    let mut getbit = |u: &mut usize, bits: &mut u8| -> bool {
        let carry = *bits & 0x80 != 0;
        *bits <<= 1;
        if *bits != 0 {
            return carry;
        }
        let b = p[*u];
        *u += 1;
        *bits = (b << 1) | 1;
        b & 0x80 != 0
    };
    let gamma = |u: &mut usize, bits: &mut u8, getbit: &mut dyn FnMut(&mut usize, &mut u8) -> bool| -> u32 {
        let mut v = 1u32;
        while !getbit(u, bits) {
            v = (v << 1) | getbit(u, bits) as u32;
        }
        v
    };
    let mut after_lit = false;
    let mut last = 1usize;
    loop {
        if !getbit(&mut u, &mut bits) {
            let len = gamma(&mut u, &mut bits, &mut getbit) as usize;
            if !after_lit {
                for _ in 0..len {
                    out.push(p[u]);
                    u += 1;
                }
                after_lit = true;
            } else {
                for _ in 0..len {
                    let b = out[out.len() - last];
                    out.push(b);
                }
                after_lit = false;
            }
        } else {
            let m = gamma(&mut u, &mut bits, &mut getbit);
            if m == END_MSB {
                break;
            }
            let lo = p[u] as usize;
            u += 1;
            last = (((m - 1) as usize) << 8 | lo) + 1;
            let len = gamma(&mut u, &mut bits, &mut getbit) as usize + 1;
            for _ in 0..len {
                let b = out[out.len() - last];
                out.push(b);
            }
            after_lit = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trips() {
        let mut cases: Vec<Vec<u8>> = vec![vec![], vec![7], vec![0; 1000], b"abcabcabcabcxyzabc".to_vec()];
        let mut x: u32 = 12345;
        cases.push((0..5000).map(|_| { x = x.wrapping_mul(1103515245).wrapping_add(12345); (x >> 24) as u8 & 0x0f }).collect());
        for c in cases {
            assert_eq!(unpack(&pack(&c)), c);
        }
    }
}
