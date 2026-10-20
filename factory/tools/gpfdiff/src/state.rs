//! The 16-byte `gpf_state` + 5-byte `gpf_bricks` contract (recipe README) and its
//! conversion to a trace line. Shared by every platform backend.

#[cfg(test)]
use crate::trace::Line;

pub const STATE_LEN: usize = 16;
pub const BRICKS_LEN: usize = 5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawState {
    pub state: [u8; STATE_LEN],
    pub bricks: [u8; BRICKS_LEN],
}

fn u16le(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}

impl RawState {
    pub fn step(&self) -> u16 {
        u16le(&self.state, 0)
    }

    /// The classic decoder; the built-in field map must agree with it (tested in fields.rs).
    #[cfg(test)]
    pub fn to_line(&self) -> Line {
        let s = &self.state;
        let b = &self.bricks;
        let cols = [
            u16le(s, 0).to_string(),
            s[2].to_string(),
            s[3].to_string(),
            u16le(s, 4).to_string(),
            s[6].to_string(),
            s[7].to_string(),
            u16le(s, 8).to_string(),
            u16le(s, 10).to_string(),
            (u16le(s, 12) as i16).to_string(),
            (u16le(s, 14) as i16).to_string(),
            format!("{:02x}{:02x}{:02x}{:02x}{:02x}", b[0], b[1], b[2], b[3], b[4]),
        ];
        Line { cols: cols.to_vec() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_le_and_signed_fields() {
        let mut s = [0u8; 16];
        s[0] = 5; // step
        s[2] = 1; // mode
        s[3] = 3; // lives
        s[4] = 0x2c;
        s[5] = 0x01; // score 300
        s[6] = 108;
        s[7] = 7;
        s[8] = 0x00;
        s[9] = 0x78; // ball_x 30720
        s[10] = 0x00;
        s[11] = 0xa6; // 42496
        s[12] = 0x80;
        s[13] = 0xff; // -128
        s[14] = 0x80;
        s[15] = 0xfe; // -384
        let r = RawState { state: s, bricks: [0xff, 0xff, 0xff, 0xff, 0x0f] };
        assert_eq!(
            r.to_line().to_string(),
            "5 1 3 300 108 7 30720 42496 -128 -384 ffffffff0f"
        );
        assert_eq!(r.step(), 5);
    }
}
