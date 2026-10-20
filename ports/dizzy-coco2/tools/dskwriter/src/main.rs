//! dskwriter -- build / inspect RS-DOS .dsk images (T0241).
//!
//!   dskwriter build OUT.dsk  [--type N] [--ascii N] [--reserve BYTES] [--at GRANULE] --file NAME.EXT SRC
//!                            ... (options apply to the NEXT --file; --reserve 0 = size of SRC)
//!   dskwriter ls DSK
//!   dskwriter extract DSK NAME.EXT OUT
//!   dskwriter locate DSK NAME.EXT      -> "<track> <sector> <sectors> <bytes>" of the first sector
//!   dskwriter check DSK
use dskwriter::*;
use std::process::exit;

fn die(m: &str) -> ! {
    eprintln!("dskwriter: {m}");
    exit(2)
}

fn load(p: &str) -> Disk {
    Disk::from_image(std::fs::read(p).unwrap_or_else(|e| die(&format!("{p}: {e}")))).unwrap_or_else(|e| die(&e))
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.is_empty() {
        die("usage: dskwriter build|ls|extract|locate|check ...");
    }
    match a[0].as_str() {
        "build" => {
            let out = a.get(1).unwrap_or_else(|| die("build OUT.dsk ..."));
            let mut d = Disk::new();
            let (mut ty, mut asc, mut res, mut at) = (T_DATA, 0u8, 0usize, None::<usize>);
            let mut i = 2;
            while i < a.len() {
                let need = |i: usize| a.get(i + 1).unwrap_or_else(|| die(&format!("{} needs a value", a[i]))).clone();
                match a[i].as_str() {
                    "--type" => { ty = need(i).parse().unwrap_or_else(|_| die("bad --type")); i += 2; }
                    "--ascii" => { asc = if need(i) == "0" { 0 } else { 0xFF }; i += 2; }
                    "--reserve" => { res = need(i).parse().unwrap_or_else(|_| die("bad --reserve")); i += 2; }
                    "--at" => { at = Some(need(i).parse().unwrap_or_else(|_| die("bad --at"))); i += 2; }
                    "--file" => {
                        let name = need(i);
                        let src = a.get(i + 2).unwrap_or_else(|| die("--file NAME SRC")).clone();
                        let data = if src == "-" { vec![] } else { std::fs::read(&src).unwrap_or_else(|e| die(&format!("{src}: {e}"))) };
                        let p = d.add_file(&name, ty, asc, &data, res, at).unwrap_or_else(|e| die(&e));
                        println!("{:<12} gran={:<2} track={:<2} sector={:<2} granules={} sectors={} bytes={}",
                                 p.name, p.first_gran, p.track, p.sector, p.granules, p.sectors, p.bytes);
                        (ty, asc, res, at) = (T_DATA, 0, 0, None);
                        i += 3;
                    }
                    x => die(&format!("unknown argument {x}")),
                }
            }
            d.check().unwrap_or_else(|e| die(&e));
            std::fs::write(out, &d.img).unwrap_or_else(|e| die(&format!("{out}: {e}")));
        }
        "ls" => {
            let d = load(a.get(1).unwrap_or_else(|| die("ls DSK")));
            for e in d.entries() {
                let (g, last) = d.chain(e.first_gran as usize).unwrap_or_else(|m| die(&m));
                let (t, s) = gran_pos(g[0]);
                println!("{:<12} type={} ascii={:02x} gran={} track={} sector={} granules={} bytes={}",
                         e.full_name(), e.ftype, e.ascii, g[0], t, s, g.len(),
                         (g.len() - 1) * 9 * 256 + (last - 1) * 256 + e.last_sector_bytes as usize);
            }
        }
        "extract" => {
            let d = load(a.get(1).unwrap_or_else(|| die("extract DSK NAME OUT")));
            let b = d.read_file(a.get(2).unwrap_or_else(|| die("name"))).unwrap_or_else(|e| die(&e));
            std::fs::write(a.get(3).unwrap_or_else(|| die("out")), b).unwrap_or_else(|e| die(&e.to_string()));
        }
        "locate" => {
            let d = load(a.get(1).unwrap_or_else(|| die("locate DSK NAME")));
            let n = a.get(2).unwrap_or_else(|| die("name"));
            let e = d.entries().into_iter().find(|e| &e.full_name() == n).unwrap_or_else(|| die("not found"));
            let (g, last) = d.chain(e.first_gran as usize).unwrap_or_else(|m| die(&m));
            let (t, s) = gran_pos(g[0]);
            let secs = (g.len() - 1) * 9 + last;
            println!("{} {} {} {}", t, s, secs, (secs - 1) * 256 + e.last_sector_bytes as usize);
        }
        "check" => {
            load(a.get(1).unwrap_or_else(|| die("check DSK"))).check().unwrap_or_else(|e| die(&e));
            println!("OK");
        }
        x => die(&format!("unknown command {x}")),
    }
}
