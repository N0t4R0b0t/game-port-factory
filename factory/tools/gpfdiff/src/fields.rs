//! The field map: which numbers make up one trace line, where each is read from and how it
//! is normalised. `[state] source = "labels"` is the built-in map (the 11 Brickfall columns
//! decoded from `gpf_state` / `gpf_bricks`); `source = "map"` is whatever `[[field]]` says.
//!
//! Reading is deliberately independent of how a target is driven: a field only needs
//! "give me `len` bytes at `addr`" ([`MemRead`]), plus, for the built-in map, the 21 bytes the
//! cooperative backends already deliver ([`RawState`]). A future frame-synchronous backend
//! only has to provide the same memory read.

use crate::diff::ColRule;
use crate::manifest::{FieldDef, FieldSrc};
use crate::state::RawState;
use crate::trace::{Line, FIELDS};

/// "Read `len` bytes at `addr`": the only thing a mapped field needs from a target.
pub type MemRead<'a> = &'a mut dyn FnMut(u16, usize) -> Result<Vec<u8>, String>;

#[derive(Clone, Debug, PartialEq)]
pub enum Source {
    Addr(u16),
    Label(String),
    /// Built-in map only: byte offset into the 16-byte `gpf_state` block.
    State(usize),
    /// Built-in map only: the 5-byte `gpf_bricks` mask, printed as hex text.
    Bricks,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Field {
    pub name: String,
    pub source: Source,
    pub size: usize,
    pub big_endian: bool,
    pub signed: bool,
    pub scale: f64,
    pub offset: f64,
    pub tolerance: f64,
    pub ignore: bool,
    /// Print the bytes in memory order as hex text instead of a number (`format = "hex"`).
    pub hex: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FieldMap {
    pub fields: Vec<Field>,
}

/// Decode `bytes` (1/2/4 of them) to a number.
pub fn decode(bytes: &[u8], big_endian: bool, signed: bool) -> f64 {
    let mut v: u64 = 0;
    if big_endian {
        for b in bytes {
            v = (v << 8) | *b as u64;
        }
    } else {
        for b in bytes.iter().rev() {
            v = (v << 8) | *b as u64;
        }
    }
    let bits = bytes.len() * 8;
    if signed && bits < 64 && v & (1 << (bits - 1)) != 0 {
        (v as i64 - (1i64 << bits)) as f64
    } else {
        v as f64
    }
}

/// Canonical text of a normalised value: integers print as integers, anything else with at
/// most 6 decimals (trailing zeros trimmed), so equal values always print identically.
pub fn format_num(v: f64) -> String {
    let v = if v == 0.0 { 0.0 } else { v }; // no "-0"
    if v == v.trunc() && v.abs() < 1e15 {
        return format!("{}", v as i64);
    }
    let s = format!("{v:.6}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-0" { "0".into() } else { s.to_string() }
}

impl FieldMap {
    /// The built-in Brickfall map: exactly what `RawState::to_line` has always produced.
    pub fn builtin() -> FieldMap {
        let f = |name: &str, source: Source, size: usize, signed: bool| Field {
            name: name.into(),
            source,
            size,
            big_endian: false,
            signed,
            scale: 1.0,
            offset: 0.0,
            tolerance: 0.0,
            ignore: false,
            hex: false,
        };
        use Source::*;
        let spec: [(Source, usize, bool); 11] = [
            (State(0), 2, false),
            (State(2), 1, false),
            (State(3), 1, false),
            (State(4), 2, false),
            (State(6), 1, false),
            (State(7), 1, false),
            (State(8), 2, false),
            (State(10), 2, false),
            (State(12), 2, true),
            (State(14), 2, true),
            (Bricks, 5, false),
        ];
        FieldMap { fields: FIELDS.iter().zip(spec).map(|(n, (s, z, sg))| f(n, s, z, sg)).collect() }
    }

    pub fn from_defs(defs: &[FieldDef]) -> FieldMap {
        FieldMap {
            fields: defs
                .iter()
                .map(|d| Field {
                    name: d.name.clone(),
                    source: match &d.src {
                        FieldSrc::Addr(a) => Source::Addr(*a),
                        FieldSrc::Label(l) => Source::Label(l.clone()),
                    },
                    size: d.size,
                    big_endian: d.big_endian,
                    signed: d.signed,
                    scale: d.scale,
                    offset: d.offset,
                    tolerance: d.tolerance,
                    ignore: d.ignore,
                    hex: d.hex,
                })
                .collect(),
        }
    }

    pub fn columns(&self) -> Vec<String> {
        self.fields.iter().map(|f| f.name.clone()).collect()
    }

    /// Comparison rules (tolerance / ignore) in column order.
    pub fn rules(&self) -> Vec<ColRule> {
        self.fields.iter().map(|f| ColRule { name: f.name.clone(), tolerance: f.tolerance, ignore: f.ignore }).collect()
    }

    /// Replace every `label = ...` source with its address (`label` is the backend's symbol lookup).
    pub fn resolve(&self, label: &mut dyn FnMut(&str) -> Result<u16, String>) -> Result<FieldMap, String> {
        let mut out = self.clone();
        for f in &mut out.fields {
            if let Source::Label(l) = &f.source {
                f.source = Source::Addr(label(l).map_err(|e| format!("field `{}`: {e}", f.name))?);
            }
        }
        Ok(out)
    }

    /// One trace line. `raw` is the cooperative backends' 21-byte block (only the built-in map
    /// reads it); mapped fields go through `mem`. Normalisation (`value * scale + offset`) is applied here.
    pub fn read_line(&self, raw: &RawState, mem: MemRead) -> Result<Line, String> {
        let mut cols = Vec::with_capacity(self.fields.len());
        for f in &self.fields {
            let bytes: Vec<u8> = match &f.source {
                Source::State(o) => raw.state[*o..*o + f.size].to_vec(),
                Source::Bricks => {
                    cols.push(raw.bricks.iter().map(|b| format!("{b:02x}")).collect::<String>());
                    continue;
                }
                Source::Addr(a) => mem(*a, f.size).map_err(|e| format!("field `{}`: {e}", f.name))?,
                Source::Label(l) => return Err(format!("field `{}`: label `{l}` was not resolved", f.name)),
            };
            if bytes.len() != f.size {
                return Err(format!("field `{}`: read {} bytes, wanted {}", f.name, bytes.len(), f.size));
            }
            if f.hex {
                cols.push(bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
                continue;
            }
            cols.push(format_num(decode(&bytes, f.big_endian, f.signed) * f.scale + f.offset));
        }
        Ok(Line { cols })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_mem() -> impl FnMut(u16, usize) -> Result<Vec<u8>, String> {
        |_, _| Err("builtin map must not read memory".to_string())
    }

    #[test]
    fn builtin_map_equals_the_classic_decoder() {
        let mut s = [0u8; 16];
        for (i, b) in s.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(37).wrapping_add(11);
        }
        s[13] = 0xff; // negative velocities
        s[15] = 0xfe;
        let raw = RawState { state: s, bricks: [0xff, 0x0f, 0xa5, 0x00, 0x01] };
        let m = FieldMap::builtin();
        let l = m.read_line(&raw, &mut no_mem()).unwrap();
        assert_eq!(l, raw.to_line());
        assert_eq!(m.columns(), FIELDS.to_vec());
    }

    #[test]
    fn decode_sizes_endianness_and_sign() {
        assert_eq!(decode(&[0x34, 0x12], false, false), 0x1234 as f64);
        assert_eq!(decode(&[0x12, 0x34], true, false), 0x1234 as f64);
        assert_eq!(decode(&[0xff], false, true), -1.0);
        assert_eq!(decode(&[0xff], false, false), 255.0);
        assert_eq!(decode(&[0x00, 0x80], false, true), -32768.0);
        assert_eq!(decode(&[0xff, 0xff, 0xff, 0xff], false, false), 4294967295.0);
        assert_eq!(decode(&[0xff, 0xff, 0xff, 0xff], true, true), -1.0);
    }

    #[test]
    fn number_formatting_is_canonical() {
        assert_eq!(format_num(12.0), "12");
        assert_eq!(format_num(-0.0), "0");
        assert_eq!(format_num(3.25), "3.25");
        assert_eq!(format_num(0.1 + 0.2), "0.3");
        assert_eq!(format_num(-128.0), "-128");
        assert_eq!(format_num(1.0 / 3.0), "0.333333");
    }

    #[test]
    fn mapped_field_applies_scale_and_offset_and_reports_read_errors() {
        let raw = RawState { state: [0; 16], bricks: [0; 5] };
        let mk = |scale: f64, offset: f64| FieldMap {
            fields: vec![Field {
                name: "x".into(),
                source: Source::Addr(0x9000),
                size: 1,
                big_endian: false,
                signed: false,
                scale,
                offset,
                tolerance: 0.0,
                ignore: false,
                hex: false,
            }],
        };
        let mut rd = |a: u16, n: usize| -> Result<Vec<u8>, String> {
            assert_eq!((a, n), (0x9000, 1));
            Ok(vec![40])
        };
        assert_eq!(mk(0.25, 0.0).read_line(&raw, &mut rd).unwrap().cols, vec!["10"]);
        assert_eq!(mk(0.25, 1.5).read_line(&raw, &mut rd).unwrap().cols, vec!["11.5"]);
        let e = mk(1.0, 0.0).read_line(&raw, &mut |_, _| Err("boom".into())).unwrap_err();
        assert!(e.contains("field `x`") && e.contains("boom"), "{e}");
    }

    #[test]
    fn hex_fields_print_raw_bytes_in_memory_order() {
        let raw = RawState { state: [0; 16], bricks: [0; 5] };
        let m = FieldMap {
            fields: vec![Field {
                name: "bricks".into(),
                source: Source::Addr(0xF010),
                size: 5,
                big_endian: false,
                signed: false,
                scale: 1.0,
                offset: 0.0,
                tolerance: 0.0,
                ignore: false,
                hex: true,
            }],
        };
        let l = m.read_line(&raw, &mut |a, n| {
            assert_eq!((a, n), (0xF010, 5));
            Ok(vec![0xff, 0x0f, 0xa5, 0x00, 0x01])
        });
        assert_eq!(l.unwrap().cols, vec!["ff0fa50001"]);
    }

    #[test]
    fn labels_resolve_or_name_the_field() {
        let mut m = FieldMap::builtin();
        m.fields[0].source = Source::Label("player_x".into());
        let r = m.resolve(&mut |n| if n == "player_x" { Ok(0x1234) } else { Err("no".into()) }).unwrap();
        assert_eq!(r.fields[0].source, Source::Addr(0x1234));
        let e = m.resolve(&mut |n| Err(format!("label `{n}` missing from the labels file"))).unwrap_err();
        assert!(e.contains("field `step`") && e.contains("label `player_x` missing from"), "{e}");
    }
}
