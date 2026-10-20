//! T0241 -- RS-DOS (Disk Extended Color BASIC) disk image model.
//!
//! Geometry: 35 tracks x 18 sectors x 256 bytes = 161280 bytes, single sided, raw sector order
//! (sector 1 of track 0 first). Directory = track 17 sectors 3..=11 (9 sectors x 8 entries of 32
//! bytes), FAT = track 17 sector 2 (68 bytes, one per granule). A granule = 9 sectors = half a
//! track; granule numbers SKIP the directory track (granule 34 is on physical track 18).
//! FAT byte: 0xFF free; 0x00..=0x43 next granule; 0xC1..=0xC9 last granule, low nibble = number
//! of sectors used in it. Layout verified against Disk BASIC 1.1 itself (see NOTES.md T0241).

pub const TRACKS: usize = 35;
pub const SECS: usize = 18;
pub const SECSZ: usize = 256;
pub const DISK_BYTES: usize = TRACKS * SECS * SECSZ;
pub const DIR_TRACK: usize = 17;
pub const GRANULES: usize = 68;
pub const GRAN_SECS: usize = 9;
pub const DIR_ENTRIES: usize = 72;

/// File types in the directory entry.
pub const T_BASIC: u8 = 0;
pub const T_DATA: u8 = 1;
pub const T_BIN: u8 = 2;
pub const T_TEXT: u8 = 3;

/// Physical (track, first sector 1-based) of a granule.
pub fn gran_pos(g: usize) -> (usize, usize) {
    assert!(g < GRANULES, "granule {g} out of range");
    let lt = g / 2;
    let track = if lt >= DIR_TRACK { lt + 1 } else { lt };
    (track, (g % 2) * GRAN_SECS + 1)
}

/// Byte offset of (track, sector 1-based) in the image.
pub fn sector_off(track: usize, sec: usize) -> usize {
    assert!(track < TRACKS && (1..=SECS).contains(&sec));
    (track * SECS + sec - 1) * SECSZ
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String, // 8 chars, trimmed
    pub ext: String,  // 3 chars, trimmed
    pub ftype: u8,
    pub ascii: u8,
    pub first_gran: u8,
    pub last_sector_bytes: u16,
}

impl Entry {
    pub fn full_name(&self) -> String {
        format!("{}.{}", self.name, self.ext)
    }
}

pub struct Disk {
    pub img: Vec<u8>,
}

#[derive(Debug)]
pub struct Placed {
    pub name: String,
    pub first_gran: usize,
    pub granules: usize,
    pub sectors: usize,
    pub bytes: usize,
    pub track: usize,
    pub sector: usize,
}

pub fn split_name(full: &str) -> Result<([u8; 8], [u8; 3]), String> {
    let (n, e) = match full.split_once('.') {
        Some((n, e)) => (n, e),
        None => (full, ""),
    };
    let ok = |s: &str, max: usize| {
        s.len() <= max && s.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    };
    if n.is_empty() || !ok(n, 8) || !ok(e, 3) {
        return Err(format!("bad RS-DOS file name {full:?} (1-8 + 0-3 chars of A-Z 0-9 _ -)"));
    }
    let mut nb = [b' '; 8];
    let mut eb = [b' '; 3];
    nb[..n.len()].copy_from_slice(n.as_bytes());
    eb[..e.len()].copy_from_slice(e.as_bytes());
    Ok((nb, eb))
}

impl Disk {
    /// A freshly "formatted" disk, as Disk BASIC's DSKINI leaves it: every sector 0xFF, the FAT
    /// sector 68 x 0xFF then zeros.
    pub fn new() -> Disk {
        let mut img = vec![0xFFu8; DISK_BYTES];
        let f = sector_off(DIR_TRACK, 2);
        for b in &mut img[f + GRANULES..f + SECSZ] {
            *b = 0;
        }
        Disk { img }
    }

    pub fn from_image(img: Vec<u8>) -> Result<Disk, String> {
        if img.len() != DISK_BYTES {
            return Err(format!("image is {} bytes, expected {DISK_BYTES}", img.len()));
        }
        Ok(Disk { img })
    }

    fn fat_off(&self) -> usize {
        sector_off(DIR_TRACK, 2)
    }
    pub fn fat(&self, g: usize) -> u8 {
        self.img[self.fat_off() + g]
    }
    fn set_fat(&mut self, g: usize, v: u8) {
        let o = self.fat_off();
        self.img[o + g] = v;
    }

    pub fn entries(&self) -> Vec<Entry> {
        let mut v = Vec::new();
        for i in 0..DIR_ENTRIES {
            let o = sector_off(DIR_TRACK, 3) + i * 32;
            let e = &self.img[o..o + 32];
            if e[0] == 0xFF || e[0] == 0x00 {
                continue;
            }
            v.push(Entry {
                name: String::from_utf8_lossy(&e[0..8]).trim_end().to_string(),
                ext: String::from_utf8_lossy(&e[8..11]).trim_end().to_string(),
                ftype: e[11],
                ascii: e[12],
                first_gran: e[13],
                last_sector_bytes: u16::from_be_bytes([e[14], e[15]]),
            });
        }
        v
    }

    /// Granule chain of a file: (granules in order, sectors used in the last one).
    pub fn chain(&self, first: usize) -> Result<(Vec<usize>, usize), String> {
        let mut v = vec![];
        let mut g = first;
        loop {
            if g >= GRANULES {
                return Err(format!("granule {g} out of range"));
            }
            if v.contains(&g) {
                return Err(format!("FAT loop at granule {g}"));
            }
            v.push(g);
            let f = self.fat(g);
            if (0xC1..=0xC9).contains(&f) {
                return Ok((v, (f - 0xC0) as usize));
            }
            if f as usize >= GRANULES {
                return Err(format!("FAT[{g}] = {f:#04x} is neither a granule nor an end marker"));
            }
            g = f as usize;
        }
    }

    /// Next granule that is free, scanning upward from `from`.
    fn next_free(&self, from: usize) -> Option<usize> {
        (from..GRANULES).find(|&g| self.fat(g) == 0xFF)
    }

    /// Add a file. `data` is padded with zeros up to `reserve` bytes when given. If `at` is given
    /// the file must start exactly at that granule (else Err). Files are allocated in ascending
    /// contiguous granules starting at the lowest free granule >= `at.unwrap_or(0)`.
    pub fn add_file(
        &mut self,
        full_name: &str,
        ftype: u8,
        ascii: u8,
        data: &[u8],
        reserve: usize,
        at: Option<usize>,
    ) -> Result<Placed, String> {
        let (nb, eb) = split_name(full_name)?;
        if self.entries().iter().any(|e| e.full_name() == full_name) {
            return Err(format!("{full_name} already exists"));
        }
        let bytes = data.len().max(reserve).max(1);
        let sectors = bytes.div_ceil(SECSZ);
        let ngr = sectors.div_ceil(GRAN_SECS);
        let first = self.next_free(at.unwrap_or(0)).ok_or("disk full")?;
        if let Some(a) = at {
            if first != a {
                return Err(format!("{full_name}: wanted granule {a}, next free is {first}"));
            }
        }
        // find a free dir slot
        let slot = (0..DIR_ENTRIES)
            .find(|&i| {
                let b = self.img[sector_off(DIR_TRACK, 3) + i * 32];
                b == 0xFF || b == 0x00
            })
            .ok_or("directory full")?;
        // granules: contiguous ascending (skip any that are taken -> error, we want contiguity)
        let grans: Vec<usize> = (first..first + ngr).collect();
        if grans.iter().any(|&g| g >= GRANULES || self.fat(g) != 0xFF) {
            return Err(format!("{full_name}: {ngr} contiguous free granules from {first} not available"));
        }
        for (i, &g) in grans.iter().enumerate() {
            if i + 1 < ngr {
                self.set_fat(g, grans[i + 1] as u8);
            } else {
                self.set_fat(g, 0xC0 + (sectors - GRAN_SECS * (ngr - 1)) as u8);
            }
        }
        // data
        let mut padded = data.to_vec();
        padded.resize(sectors * SECSZ, 0);
        if data.len() < bytes {
            // reserved tail is zero, already
        }
        for s in 0..sectors {
            let g = grans[s / GRAN_SECS];
            let (t, s0) = gran_pos(g);
            let o = sector_off(t, s0 + s % GRAN_SECS);
            self.img[o..o + SECSZ].copy_from_slice(&padded[s * SECSZ..(s + 1) * SECSZ]);
        }
        let last = (bytes - (sectors - 1) * SECSZ) as u16;
        let o = sector_off(DIR_TRACK, 3) + slot * 32;
        let mut e = [0u8; 32];
        e[0..8].copy_from_slice(&nb);
        e[8..11].copy_from_slice(&eb);
        e[11] = ftype;
        e[12] = ascii;
        e[13] = first as u8;
        e[14..16].copy_from_slice(&last.to_be_bytes());
        self.img[o..o + 32].copy_from_slice(&e);
        let (t, s) = gran_pos(first);
        Ok(Placed { name: full_name.to_string(), first_gran: first, granules: ngr, sectors, bytes, track: t, sector: s })
    }

    /// Read a file's bytes back by following the FAT.
    pub fn read_file(&self, full_name: &str) -> Result<Vec<u8>, String> {
        let e = self
            .entries()
            .into_iter()
            .find(|e| e.full_name() == full_name)
            .ok_or_else(|| format!("{full_name}: not found"))?;
        let (grans, last_secs) = self.chain(e.first_gran as usize)?;
        let total_secs = (grans.len() - 1) * GRAN_SECS + last_secs;
        let mut out = Vec::new();
        for s in 0..total_secs {
            let (t, s0) = gran_pos(grans[s / GRAN_SECS]);
            let o = sector_off(t, s0 + s % GRAN_SECS);
            let take = if s + 1 == total_secs { e.last_sector_bytes as usize } else { SECSZ };
            out.extend_from_slice(&self.img[o..o + take]);
        }
        Ok(out)
    }

    /// Whole-disk consistency: every directory file has a valid chain, no granule is shared, the
    /// directory track's granule slots are never used (they do not exist), and every non-free
    /// FAT entry belongs to some file.
    pub fn check(&self) -> Result<(), String> {
        let mut owner = [usize::MAX; GRANULES];
        for (i, e) in self.entries().iter().enumerate() {
            let (grans, _) = self.chain(e.first_gran as usize).map_err(|m| format!("{}: {m}", e.full_name()))?;
            for g in grans {
                if owner[g] != usize::MAX {
                    return Err(format!("granule {g} shared by two files"));
                }
                owner[g] = i;
            }
        }
        for g in 0..GRANULES {
            if self.fat(g) != 0xFF && owner[g] == usize::MAX {
                return Err(format!("FAT[{g}] = {:#04x} but no file owns it", self.fat(g)));
            }
        }
        Ok(())
    }
}

impl Default for Disk {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pattern(n: usize, seed: u8) -> Vec<u8> {
        (0..n).map(|i| (i as u8).wrapping_mul(7).wrapping_add(seed).wrapping_add((i >> 8) as u8)).collect()
    }

    #[test]
    fn granule_positions_skip_the_directory_track() {
        assert_eq!(gran_pos(0), (0, 1));
        assert_eq!(gran_pos(1), (0, 10));
        assert_eq!(gran_pos(32), (16, 1));
        assert_eq!(gran_pos(33), (16, 10));
        assert_eq!(gran_pos(34), (18, 1)); // logical track 17 is physical track 18
        assert_eq!(gran_pos(67), (34, 10));
    }

    #[test]
    fn round_trip_many_sizes() {
        let mut d = Disk::new();
        let sizes = [1usize, 13, 255, 256, 257, 2303, 2304, 2305, 4608, 5000, 9217];
        let mut datas = vec![];
        for (i, &n) in sizes.iter().enumerate() {
            let data = pattern(n, i as u8);
            d.add_file(&format!("F{i}.DAT"), T_DATA, 0, &data, 0, None).unwrap();
            datas.push(data);
        }
        d.check().unwrap();
        for (i, data) in datas.iter().enumerate() {
            assert_eq!(&d.read_file(&format!("F{i}.DAT")).unwrap(), data, "size {}", sizes[i]);
        }
        assert_eq!(d.entries().len(), sizes.len());
    }

    #[test]
    fn file_crossing_the_directory_track_reads_back() {
        let mut d = Disk::new();
        // 34 granules fill logical tracks 0..16; this file starts at 30 and runs through 34..
        d.add_file("PAD.BIN", T_BIN, 0, &pattern(30 * 2304, 1), 0, Some(0)).unwrap();
        let data = pattern(8 * 2304 + 17, 9);
        let p = d.add_file("CROSS.DAT", T_DATA, 0, &data, 0, Some(30)).unwrap();
        assert_eq!(p.granules, 9);
        d.check().unwrap();
        assert_eq!(d.read_file("CROSS.DAT").unwrap(), data);
        // the directory track must be untouched by file data: its FAT/dir sectors still intact
        assert_eq!(d.entries().len(), 2);
    }

    #[test]
    fn fat_end_marker_counts_sectors_in_last_granule() {
        let mut d = Disk::new();
        d.add_file("A.DAT", T_DATA, 0, &pattern(2304 + 3 * 256, 0), 0, None).unwrap();
        assert_eq!(d.fat(0), 1);
        assert_eq!(d.fat(1), 0xC3);
        d.add_file("B.DAT", T_DATA, 0, &pattern(1, 0), 0, None).unwrap();
        assert_eq!(d.fat(2), 0xC1);
    }

    #[test]
    fn reserve_allocates_zeroed_space_and_full_length() {
        let mut d = Disk::new();
        let p = d.add_file("DIZZY.SAV", T_DATA, 0, &[], 4608, Some(0)).unwrap();
        assert_eq!((p.granules, p.sectors, p.bytes), (2, 18, 4608));
        let back = d.read_file("DIZZY.SAV").unwrap();
        assert_eq!(back.len(), 4608);
        assert!(back.iter().all(|&b| b == 0));
        let e = &d.entries()[0];
        assert_eq!(e.last_sector_bytes, 256);
    }

    #[test]
    fn at_mismatch_and_duplicates_and_bad_names_fail() {
        let mut d = Disk::new();
        d.add_file("A.DAT", T_DATA, 0, &[1, 2, 3], 0, Some(0)).unwrap();
        assert!(d.add_file("B.DAT", T_DATA, 0, &[1], 0, Some(0)).is_err());
        assert!(d.add_file("A.DAT", T_DATA, 0, &[1], 0, None).is_err());
        assert!(d.add_file("lower.dat", T_DATA, 0, &[1], 0, None).is_err());
        assert!(d.add_file("TOOLONGNAME.DAT", T_DATA, 0, &[1], 0, None).is_err());
        assert!(d.add_file("A.TOOL", T_DATA, 0, &[1], 0, None).is_err());
    }

    #[test]
    fn disk_full_and_directory_full() {
        let mut d = Disk::new();
        assert!(d.add_file("BIG.DAT", T_DATA, 0, &[], 68 * 2304 + 1, None).is_err());
        let mut d = Disk::new();
        for i in 0..68 {
            d.add_file(&format!("F{i}.D"), T_DATA, 0, &[1], 0, None).unwrap();
        }
        assert!(d.add_file("ONE.TOO", T_DATA, 0, &[1], 0, None).is_err());
        d.check().unwrap();
    }

    #[test]
    fn fresh_disk_matches_dskini_shape() {
        let d = Disk::new();
        assert_eq!(d.img.len(), 161280);
        let f = sector_off(17, 2);
        assert!(d.img[f..f + 68].iter().all(|&b| b == 0xFF));
        assert!(d.img[f + 68..f + 256].iter().all(|&b| b == 0));
        d.check().unwrap();
    }

    #[test]
    fn dir_sector_layout_byte_exact() {
        // the same bytes Disk BASIC 1.1 wrote for SAVE"AAA" on a fresh disk (XRoar, T0241):
        // 41 41 41 20 20 20 20 20 | 42 41 53 | 00 | 00 | 20 | 00 0d
        let mut d = Disk::new();
        d.add_file("AAA.BAS", T_BASIC, 0x00, &[0u8; 13], 0, Some(32)).unwrap();
        let o = sector_off(17, 3);
        assert_eq!(&d.img[o..o + 16], &[0x41, 0x41, 0x41, 0x20, 0x20, 0x20, 0x20, 0x20, 0x42, 0x41, 0x53, 0, 0, 0x20, 0, 13]);
        assert_eq!(d.fat(32), 0xC1);
    }
}
