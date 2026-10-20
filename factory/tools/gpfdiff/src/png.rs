//! Minimal PNG writer (RGB8, stored deflate, no dependencies) plus an integer
//! nearest-neighbour upscaler: screenshots stay pixel-exact, no smoothing.

/// An RGB8 image.
pub struct Image {
    pub w: usize,
    pub h: usize,
    pub rgb: Vec<u8>,
}

impl Image {
    /// Integer nearest-neighbour upscale by `k` (>= 1).
    pub fn scaled(&self, k: usize) -> Image {
        let k = k.max(1);
        let (w, h) = (self.w * k, self.h * k);
        let mut rgb = Vec::with_capacity(w * h * 3);
        for y in 0..h {
            let sy = y / k;
            for x in 0..w {
                let o = (sy * self.w + x / k) * 3;
                rgb.extend_from_slice(&self.rgb[o..o + 3]);
            }
        }
        Image { w, h, rgb }
    }

    pub fn to_png(&self) -> Vec<u8> {
        let mut raw = Vec::with_capacity((self.w * 3 + 1) * self.h);
        for y in 0..self.h {
            raw.push(0); // filter: none
            raw.extend_from_slice(&self.rgb[y * self.w * 3..(y + 1) * self.w * 3]);
        }
        let mut z = vec![0x78, 0x01];
        let mut chunks = raw.chunks(65535).peekable();
        if chunks.peek().is_none() {
            z.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
        }
        while let Some(c) = chunks.next() {
            z.push(if chunks.peek().is_none() { 1 } else { 0 });
            z.extend_from_slice(&(c.len() as u16).to_le_bytes());
            z.extend_from_slice(&(!(c.len() as u16)).to_le_bytes());
            z.extend_from_slice(c);
        }
        z.extend_from_slice(&adler32(&raw).to_be_bytes());
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        let mut ihdr = vec![];
        ihdr.extend_from_slice(&(self.w as u32).to_be_bytes());
        ihdr.extend_from_slice(&(self.h as u32).to_be_bytes());
        ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
        chunk(&mut out, b"IHDR", &ihdr);
        chunk(&mut out, b"IDAT", &z);
        chunk(&mut out, b"IEND", &[]);
        out
    }
}

fn chunk(out: &mut Vec<u8>, ty: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut c = ty.to_vec();
    c.extend_from_slice(data);
    out.extend_from_slice(&c);
    out.extend_from_slice(&crc32(&c).to_be_bytes());
}

fn crc32(d: &[u8]) -> u32 {
    let mut c = 0xffff_ffffu32;
    for &b in d {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
        }
    }
    !c
}

fn adler32(d: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &x in d {
        a = (a + x as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_and_adler_known_values() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
    }

    #[test]
    fn scale_is_nearest_neighbour_integer() {
        let im = Image { w: 2, h: 1, rgb: vec![1, 2, 3, 4, 5, 6] };
        let s = im.scaled(2);
        assert_eq!((s.w, s.h), (4, 2));
        assert_eq!(&s.rgb[0..12], &[1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6]);
        assert_eq!(s.rgb[12..24], s.rgb[0..12]);
    }

    #[test]
    fn png_has_signature_and_iend() {
        let p = Image { w: 3, h: 2, rgb: vec![9; 18] }.to_png();
        assert_eq!(&p[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        assert_eq!(&p[p.len() - 8..p.len() - 4], b"IEND");
    }
}
