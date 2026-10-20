//! Tandy CoCo 2 (6809) pieces of the MAME backend: the pure logic only.
//!
//! The transport (spawn MAME, the Lua driver, the `GPF S/ACK` protocol) is shared with the
//! ZX Spectrum backend in `mame.rs`; what differs for the CoCo is how the program gets in
//! and what the symbol file looks like:
//!
//! * The image is a DECB `.bin` (lwasm `--format=decb`). MAME's `coco2b` has no loader we can
//!   use headlessly, so the Lua script writes the segments into RAM itself (the approach proven in
//!   ports/dizzy-coco2/harness/coco_playtest.lua). DECB parsing stays here, in Rust, where it is
//!   unit-tested: [`parse_decb`] -> [`Decb::load_list`] is the tiny line format the Lua script reads.
//! * Symbols come from lwasm `--map=FILE`: `Symbol: gpf_state (brickfall.bin) = 1000`.
//! * The buttons are injected into the 6809 `A` register at `gpf_input_ret` (the `RTS` of
//!   `read_input`), exactly as on the Z80 backend.

use std::collections::HashMap;

/// MAME machine used when none is configured: the Color Computer 2 ("B" ROM set: bas13 + extbas11).
pub const DEFAULT_MACHINE: &str = "coco2b";
/// First address a stock DECB loader cannot write (BASIC ROM is mapped; see factory/platforms/coco2.toml [load]).
pub const ROM_MAP_START: u16 = 0x8000;

/// Parse an lwasm `--map` file: lines `Symbol: NAME (FILE) = HEX`.
pub fn parse_labels(text: &str) -> HashMap<String, u16> {
    let mut m = HashMap::new();
    for l in text.lines() {
        let Some(rest) = l.trim().strip_prefix("Symbol:") else { continue };
        let Some((lhs, val)) = rest.rsplit_once('=') else { continue };
        let name = lhs.split_whitespace().next();
        let (Some(name), Ok(v)) = (name, u32::from_str_radix(val.trim(), 16)) else { continue };
        if v <= 0xffff {
            m.insert(name.to_string(), v as u16);
        }
    }
    m
}

/// A parsed DECB machine-language file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decb {
    pub segments: Vec<(u16, Vec<u8>)>,
    pub exec: u16,
}

/// DECB layout: `00 LL LL AA AA <LL bytes>` data blocks, then `FF 00 00 EE EE` (exec address).
pub fn parse_decb(b: &[u8]) -> Result<Decb, String> {
    let mut pos = 0;
    let mut segments = vec![];
    loop {
        let Some(&t) = b.get(pos) else { return Err("DECB: ended without an exec (FF) record".into()) };
        let Some(h) = b.get(pos + 1..pos + 5) else { return Err(format!("DECB: truncated record header at offset {pos}")) };
        let len = u16::from_be_bytes([h[0], h[1]]) as usize;
        let addr = u16::from_be_bytes([h[2], h[3]]);
        match t {
            0x00 => {
                let data = b
                    .get(pos + 5..pos + 5 + len)
                    .ok_or_else(|| format!("DECB: segment at ${addr:04X} claims {len} bytes, file is shorter"))?;
                if (addr as usize) + len > 0x10000 {
                    return Err(format!("DECB: segment at ${addr:04X} (+{len}) runs past $FFFF"));
                }
                if (addr as usize) + len > ROM_MAP_START as usize {
                    return Err(format!(
                        "DECB: segment ${addr:04X}..${:04X} reaches $8000+: the BASIC ROM is mapped there at load time and the stock loader's writes are dropped (keep the image below $8000)",
                        addr as usize + len
                    ));
                }
                if len > 0 {
                    segments.push((addr, data.to_vec()));
                }
                pos += 5 + len;
            }
            0xFF => {
                if segments.is_empty() {
                    return Err("DECB: no data segments".into());
                }
                return Ok(Decb { segments, exec: addr });
            }
            other => return Err(format!("DECB: unknown record type ${other:02X} at offset {pos}")),
        }
    }
}

impl Decb {
    /// The line format `lua/gpf_mame.lua` reads (decimal addresses): `S <addr> <hex>` per segment, `X <exec>`.
    pub fn load_list(&self) -> String {
        let mut s = String::new();
        for (a, d) in &self.segments {
            s.push_str(&format!("S {a} "));
            for b in d {
                s.push_str(&format!("{b:02x}"));
            }
            s.push('\n');
        }
        s.push_str(&format!("X {}\n", self.exec));
        s
    }

    /// Is `addr` inside a loaded segment? (the entry point and `gpf_input_ret` must be.)
    pub fn covers(&self, addr: u16) -> bool {
        self.segments.iter().any(|(a, d)| addr >= *a && (addr as usize) < *a as usize + d.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_lwasm_map() {
        let m = parse_labels(
            "Symbol: gpf_state (brickfall.bin) = 1000\nSymbol: gpf_input_ret (brickfall.bin) = 408F\n\
             Symbol: weird (a b.bin) = 123456\nSymbol: bad (x) = zz\nSection: code\nnoise\n  Symbol: start (f) = 4000\n",
        );
        assert_eq!(m["gpf_state"], 0x1000);
        assert_eq!(m["gpf_input_ret"], 0x408f);
        assert_eq!(m["start"], 0x4000);
        assert_eq!(m.len(), 3); // out-of-range, non-hex and unrelated lines are dropped
    }

    fn decb(segs: &[(u16, &[u8])], exec: u16) -> Vec<u8> {
        let mut v = vec![];
        for (a, d) in segs {
            v.push(0);
            v.extend((d.len() as u16).to_be_bytes());
            v.extend(a.to_be_bytes());
            v.extend(*d);
        }
        v.extend([0xff, 0, 0]);
        v.extend(exec.to_be_bytes());
        v
    }

    #[test]
    fn decb_roundtrip_and_load_list() {
        let d = parse_decb(&decb(&[(0x4000, &[0x12, 0xab]), (0x4100, &[0xff])], 0x4000)).unwrap();
        assert_eq!(d.exec, 0x4000);
        assert_eq!(d.segments, vec![(0x4000, vec![0x12, 0xab]), (0x4100, vec![0xff])]);
        assert_eq!(d.load_list(), "S 16384 12ab\nS 16640 ff\nX 16384\n");
        assert!(d.covers(0x4001) && d.covers(0x4100) && !d.covers(0x4002) && !d.covers(0x3fff));
    }

    #[test]
    fn decb_errors_are_specific() {
        assert!(parse_decb(&[]).unwrap_err().contains("exec"));
        assert!(parse_decb(&[0, 0, 5]).unwrap_err().contains("truncated"));
        let mut short = decb(&[(0x4000, &[1, 2, 3])], 0x4000);
        short.drain(7..);
        assert!(parse_decb(&short).unwrap_err().contains("shorter"), "{:?}", parse_decb(&short));
        assert!(parse_decb(&decb(&[(0x7ffe, &[1, 2, 3])], 0x7ffe)).unwrap_err().contains("$8000+"));
        assert!(parse_decb(&[0x42, 0, 0, 0, 0]).unwrap_err().contains("unknown record"));
        assert!(parse_decb(&[0xff, 0, 0, 0x40, 0]).unwrap_err().contains("no data segments"));
    }

    /// The real build's image: needs `make -C ports/brickfall-coco2/target all`; skipped when absent.
    #[test]
    fn real_brickfall_image_if_built() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../ports/brickfall-coco2/target");
        let (Ok(bin), Ok(map)) = (std::fs::read(dir.join("brickfall.bin")), std::fs::read_to_string(dir.join("brickfall.map"))) else {
            return;
        };
        let d = parse_decb(&bin).unwrap();
        let l = parse_labels(&map);
        assert_eq!(d.exec, l["start"]);
        assert!(d.covers(l["gpf_input_ret"]));
    }
}
