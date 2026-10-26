//! roomcmp -- compares two room traces recorded by harness/roomcmp_rec.lua: the ZX Spectrum ORIGINAL and the CoCo PORT, both started from
//! the first entry into the same room and left alone (no keys).  See tools/roomcmp/README.md.
//!
//! Exit codes (gpfdiff's convention): 0 = nothing unexpected differs, 1 = the game differs (an unexpected DIVERGE, or a stale
//! expectation), 2 = the environment is wrong (a trace is missing/garbled, the two traces are for different rooms, too few samples).
use std::collections::BTreeMap;
mod visits;
use std::fmt::Write as _;
use std::process::exit;

/// entry-sync jitter allowance, in actor ticks (see Verdict::Sync): the ZX state is saved at the first Dizzy update after enterroom, the CoCo's
/// at the first pass after load_room; the actors' own first run lands 0..2 ticks apart.
const SYNC_JITTER: i32 = 2;

pub const ROU: [&str; 20] = [
    "portcullis", "portswitch", "pickupable", "armorog", "dragon", "crocodile", "log", "hawk", "machines", "lift", "dozyfloat", "rat",
    "troll", "dagger", "door", "crowbar", "miner", "daisy", "switch1", "daisy1",
];

#[derive(Default, Clone)]
struct Tick {
    n: i32,
    kv: BTreeMap<String, i32>,
    recs: BTreeMap<String, Vec<u8>>,
    flames: Vec<[i32; 3]>,
    water: Vec<[i32; 3]>,
    v: BTreeMap<String, i32>,
}

#[derive(Default)]
struct Trace {
    machine: String,
    room: i32,
    want_ticks: i32,
    inits: BTreeMap<String, [i32; 5]>, // port only: room,x,y,frame,rou of the pristine record
    ticks: BTreeMap<i32, Tick>,
    boxes: Vec<(i32, i32)>,
}

fn die(code: i32, msg: &str) -> ! {
    eprintln!("roomcmp: {msg}");
    exit(code)
}

fn hexbytes(s: &str) -> Vec<u8> {
    (0..s.len() / 2).filter_map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()).collect()
}

fn parse_triples(rest: &str) -> Vec<[i32; 3]> {
    rest.split_whitespace()
        .filter_map(|t| {
            let p: Vec<i32> = t.split(',').filter_map(|x| x.parse().ok()).collect();
            if p.len() == 3 { Some([p[0], p[1], p[2]]) } else { None }
        })
        .collect()
}

fn load(path: &str) -> Trace {
    let txt = std::fs::read_to_string(path).unwrap_or_else(|e| die(2, &format!("cannot read {path}: {e}")));
    let mut t = Trace::default();
    let mut cur: Option<Tick> = None;
    let kvs = |s: &str| -> BTreeMap<String, i32> {
        let mut m = BTreeMap::new();
        for w in s.split_whitespace() {
            if let Some((k, v)) = w.split_once('=') {
                if let Ok(x) = i32::from_str_radix(v, 10) {
                    m.insert(k.to_string(), x);
                }
            }
        }
        m
    };
    for line in txt.lines() {
        let (tag, rest) = line.split_once(' ').unwrap_or((line, ""));
        match tag {
            "H" => {
                for w in rest.split_whitespace() {
                    if let Some(v) = w.strip_prefix("machine=") { t.machine = v.to_string(); }
                    if let Some(v) = w.strip_prefix("room=") { t.room = v.parse().unwrap_or(-1); }
                    if let Some(v) = w.strip_prefix("ticks=") { t.want_ticks = v.parse().unwrap_or(0); }
                }
            }
            "I" => {
                let (id, vals) = rest.split_once(' ').unwrap_or((rest, ""));
                let p: Vec<i32> = vals.split(',').filter_map(|x| x.parse().ok()).collect();
                if p.len() == 5 { t.inits.insert(id.to_string(), [p[0], p[1], p[2], p[3], p[4]]); }
            }
            "T" => {
                if let Some(c) = cur.take() { t.ticks.insert(c.n, c); }
                let (n, r) = rest.split_once(' ').unwrap_or((rest, ""));
                cur = Some(Tick { n: n.parse().unwrap_or(0), kv: kvs(r), ..Default::default() });
            }
            "A" => {
                if let Some(c) = cur.as_mut() {
                    let (id, h) = rest.split_once(' ').unwrap_or((rest, ""));
                    c.recs.insert(id.to_string(), hexbytes(h));
                }
            }
            "F" => if let Some(c) = cur.as_mut() { c.flames = parse_triples(rest.split_once(' ').map(|x| x.1).unwrap_or("")); },
            "W" => if let Some(c) = cur.as_mut() { c.water = parse_triples(rest.split_once(' ').map(|x| x.1).unwrap_or("")); },
            "V" => if let Some(c) = cur.as_mut() {
                for w in rest.split_whitespace() {
                    if let Some((k, v)) = w.split_once('=') {
                        if let Ok(x) = i32::from_str_radix(v, 16) { c.v.insert(k.to_string(), x); }
                    }
                }
            },
            "B" => {
                let p: Vec<i32> = rest.split_whitespace().filter_map(|x| x.parse().ok()).collect();
                if p.len() == 2 { t.boxes.push((p[0], p[1])); }
            }
            "X" => die(2, &format!("{path}: recorder reported: {rest}")),
            _ => {}
        }
    }
    if let Some(c) = cur.take() { t.ticks.insert(c.n, c); }
    if t.machine.is_empty() { die(2, &format!("{path}: no H header")); }
    t
}

// ---------------------------------------------------------------- expectations
pub struct Expect { pub room: i32, pub entity: String, pub channel: String, pub verdict: String, pub mode: String, pub reason: String, pub used: std::cell::Cell<bool> }

pub fn load_expect(path: &str) -> Vec<Expect> {
    let Ok(txt) = std::fs::read_to_string(path) else { return vec![] };
    let mut out = vec![];
    let mut cur: Option<BTreeMap<String, String>> = None;
    let mut flush = |c: Option<BTreeMap<String, String>>, out: &mut Vec<Expect>| {
        if let Some(m) = c {
            let g = |k: &str| m.get(k).cloned().unwrap_or_default();
            if g("reason").is_empty() { die(2, &format!("{path}: an [[expect]] without a reason (room={})", g("room"))); }
            out.push(Expect { room: g("room").parse().unwrap_or(-1), entity: g("entity"), channel: g("channel"), verdict: g("verdict"), mode: g("mode"), reason: g("reason"), used: Default::default() });
        }
    };
    for l in txt.lines() {
        let l = l.trim();
        if l == "[[expect]]" { let p = cur.take(); flush(p, &mut out); cur = Some(BTreeMap::new()); }
        else if let (Some(c), Some((k, v))) = (cur.as_mut(), l.split_once('=')) {
            c.insert(k.trim().to_string(), v.trim().trim_matches('"').to_string());
        }
    }
    flush(cur.take(), &mut out);
    out
}

// ---------------------------------------------------------------- sequences
type Seq = BTreeMap<i32, i32>;

#[derive(Clone, Debug)]
enum Verdict {
    Match,
    Phase { lo: i32, hi: i32 },
    /// a phase offset of at most SYNC_JITTER ticks: the two entry-sync points differ by about that much (a harness property), not the game
    Sync { lo: i32, hi: i32 },
    Diverge { first: i32, z: i32, p: i32, best_d: i32, best_bad: usize, overlap: usize },
    Sparse,
}

/// compares zx(n) with port(n + d) over the ticks both have
fn score(z: &Seq, p: &Seq, d: i32, tol: i32) -> (usize, usize, Option<(i32, i32, i32)>) {
    let (mut bad, mut n, mut first) = (0usize, 0usize, None);
    for (&k, &zv) in z {
        if let Some(&pv) = p.get(&(k + d)) {
            n += 1;
            if (zv - pv).abs() > tol {
                bad += 1;
                if first.is_none() { first = Some((k, zv, pv)); }
            }
        }
    }
    (bad, n, first)
}

fn judge(z: &Seq, p: &Seq, tol: i32, maxd: i32) -> Verdict {
    let (bad0, n0, first0) = score(z, p, 0, tol);
    if n0 < 20 { return Verdict::Sparse; }
    if bad0 == 0 { return Verdict::Match; }
    let mut best = (bad0, 0i32, n0);
    let mut zero: Vec<i32> = vec![];
    for d in 1..=maxd {
        for s in [d, -d] {
            let (b, n, _) = score(z, p, s, tol);
            if n >= 20 && b == 0 { zero.push(s); }
            if n >= 20 && (b * best.2 < best.0 * n || (b * best.2 == best.0 * n && s.abs() < best.1.abs())) { best = (b, s, n); }
        }
    }
    if best.0 == 0 {
        // every shift that fits exactly (a sparsely sampled step signal fits several neighbours): report the range around the smallest
        let lo = *zero.iter().filter(|s| (**s - best.1).abs() <= 3).min().unwrap_or(&best.1);
        let hi = *zero.iter().filter(|s| (**s - best.1).abs() <= 3).max().unwrap_or(&best.1);
        return if hi >= -SYNC_JITTER && lo <= SYNC_JITTER { Verdict::Sync { lo, hi } } else { Verdict::Phase { lo, hi } };
    }
    let (k, zv, pv) = first0.unwrap();
    Verdict::Diverge { first: k, z: zv, p: pv, best_d: best.1, best_bad: best.0, overlap: best.2 }
}

pub fn zx_px(x: u8) -> i32 {
    // the original's x is in 4-px units from 32; 255 = parked/eaten, anything outside the screen is kept as a far-off marker
    if (32..128).contains(&x) { (x as i32 - 32) * 4 } else { 1000 + x as i32 }
}
pub fn port_px(x: u8) -> i32 { x as i32 }

struct Pair { z: String, p: String, rou: usize }

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("visits") { visits::main(&args[2..]); return; }
    let (mut zxp, mut cop, mut exp, mut verbose, mut strict_phase) = (None, None, None, false, false);
    let mut show: Option<String> = None;
    let (mut sfrom, mut sto) = (0i32, 100000i32);
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--zx" => { zxp = args.get(i + 1).cloned(); i += 1; }
            "--coco" => { cop = args.get(i + 1).cloned(); i += 1; }
            "--expect" => { exp = args.get(i + 1).cloned(); i += 1; }
            "-v" | "--verbose" => verbose = true,
            "--strict-phase" => strict_phase = true,
            "--show" => { show = args.get(i + 1).cloned(); i += 1; }
            "--from" => { sfrom = args.get(i + 1).and_then(|x| x.parse().ok()).unwrap_or(0); i += 1; }
            "--to" => { sto = args.get(i + 1).and_then(|x| x.parse().ok()).unwrap_or(100000); i += 1; }
            "-h" | "--help" => {
                println!("roomcmp --zx ZX.trace --coco COCO.trace [--expect expectations.toml] [-v] [--strict-phase]\nexit 0 match/expected, 1 game differs, 2 environment");
                return;
            }
            o => die(2, &format!("unknown argument {o}")),
        }
        i += 1;
    }
    let zx = load(&zxp.unwrap_or_else(|| die(2, "--zx missing")));
    let co = load(&cop.unwrap_or_else(|| die(2, "--coco missing")));
    if zx.machine != "zx" || co.machine != "coco" { die(2, "--zx/--coco traces are for the wrong machines"); }
    if zx.room != co.room { die(2, &format!("traces are for different rooms: zx {} coco {}", zx.room, co.room)); }
    if let Some(id) = show {
        // --show z44/b32 : one row per ZX tick, the ZX record (as x(px) y frame col v1) and the paired port slot's
        let (zid, pid) = match id.split_once('/') { Some((a, b)) => (a.to_string(), b.to_string()), None => (id.clone(), String::new()) };
        println!("{:>5} | {:<28} | {:>5} {:<28}", "tick", format!("zx {zid} x y fr col v1 room"), "ptick", format!("port {pid} x y fr col v1 room"));
        let fz = |t: &Tick| t.recs.get(&zid).filter(|b| b.len() >= 16).map(|b| format!("{:>5} {:>3} {:>3} {:>3} {:>3}  r{}", zx_px(b[2]), b[3], b[4], b[11], b[10], b[0])).unwrap_or_default();
        let fp = |t: &Tick| t.recs.get(&pid).filter(|b| b.len() >= 8).map(|b| format!("{:>5} {:>3} {:>3} {:>3} {:>3}  r{}", b[2], b[3], b[4], b[7], b[5], b[0])).unwrap_or_default();
        let ptk: Vec<&Tick> = co.ticks.values().collect();
        for (n, t) in &zx.ticks {
            if *n < sfrom || *n > sto { continue; }
            let pt = ptk.iter().find(|q| q.n == *n);
            println!("{:>5} | {:<28} | {:>5} {}", n, fz(t), pt.map(|q| q.n.to_string()).unwrap_or("-".into()), pt.map(|q| fp(q)).unwrap_or_default());
        }
        return;
    }
    let expects: Vec<Expect> = exp.map(|p| load_expect(&p)).unwrap_or_default().into_iter().filter(|e| e.mode != "visits").collect();
    let room = zx.room;
    let mut out = String::new();
    let mut unexpected = 0usize;
    let mut env_bad = false;
    if zx.ticks.len() < 50 || co.ticks.len() < 50 { env_bad = true; let _ = writeln!(out, "ENV  too few samples (zx {}, coco {})", zx.ticks.len(), co.ticks.len()); }
    let maxd = 120;

    // ---- entity pairing: ZX z<idx> <-> port b<nn>/t<nn> by (routine, original room, x, frame)
    let first_z: BTreeMap<String, &Vec<u8>> = {
        let mut m = BTreeMap::new();
        for t in zx.ticks.values() { for (id, b) in &t.recs { m.entry(id.clone()).or_insert(b); } }
        m
    };
    let mut taken: Vec<String> = vec![];
    let mut pairs: Vec<Pair> = vec![];
    let mut unmatched_z: Vec<String> = vec![];
    for (zid, b) in &first_z {
        if b.len() < 16 { continue; }
        let (rou, orm, orx, ofr, y0) = (b[1] as usize, b[12] as i32, zx_px(b[13]), b[15] as i32, b[3] as i32);
        let cands = |strict: u8| -> Vec<&String> {
            co.inits.iter().filter(|(pid, v)| {
                !taken.contains(pid) && v[4] as usize == rou && (v[0] == orm && match strict {
                    0 => v[1] == orx && v[3] == ofr,
                    1 => v[1] == orx,
                    _ => v[3] == ofr || v[2] == y0,
                } || (strict == 2 && v[0] == 255 && v[3] == ofr))   // an actor the port parks in room 255 until a trigger (the miner)
            }).map(|(k, _)| k).collect()
        };
        let mut pick = None;
        for s in 0..3u8 { let c = cands(s); if c.len() == 1 || (!c.is_empty() && s == 0) { pick = Some(c[0].clone()); break; } }
        match pick { Some(p) => { taken.push(p.clone()); pairs.push(Pair { z: zid.clone(), p, rou }); } None => unmatched_z.push(zid.clone()) }
    }
    let unmatched_p: Vec<String> = {
        let mut seen: Vec<String> = vec![];
        for t in co.ticks.values() { for id in t.recs.keys() { if !taken.contains(id) && !seen.contains(id) { seen.push(id.clone()); } } }
        seen
    };

    let _ = writeln!(out, "ROOM {room}: zx ticks {} (n {}..{}), coco samples {} (ticks {}..{}); boxes zx {} coco {}", zx.ticks.len(),
        zx.ticks.keys().next().unwrap_or(&0), zx.ticks.keys().last().unwrap_or(&0), co.ticks.len(), co.ticks.keys().next().unwrap_or(&0),
        co.ticks.keys().last().unwrap_or(&0), zx.boxes.len(), co.boxes.len());

    let mut report = |name: &str, ent: &str, ch: &str, v: &Verdict, info: bool, out: &mut String, unexpected: &mut usize| {
        let ex = expects.iter().find(|e| e.room == room && (e.entity == ent || e.entity == "*") && e.channel == ch);
        let vname = match v { Verdict::Match => "match", Verdict::Phase { .. } => "phase", Verdict::Sync { .. } => "match", Verdict::Diverge { .. } => "diverge", Verdict::Sparse => "sparse" };
        let desc = match v {
            Verdict::Match => "MATCH".to_string(),
            Verdict::Sparse => "SPARSE (too few common ticks)".to_string(),
            Verdict::Phase { lo, hi } => if lo == hi { format!("PHASE port lags {lo:+} ticks") } else { format!("PHASE port lags {lo:+}..{hi:+} ticks") },
            Verdict::Sync { lo, hi } => format!("match (entry-sync offset {lo:+}..{hi:+} ticks)"),
            Verdict::Diverge { first, z, p, best_d, best_bad, overlap } =>
                format!("DIVERGE first at tick {first}: zx={z} port={p}  (best shift {best_d:+}: {best_bad}/{overlap} still differ)"),
        };
        let mut tag = String::new();
        if let Some(e) = ex {
            e.used.set(true);
            if e.verdict == vname { tag = format!("  EXPECTED: {}", e.reason); }
            else if vname == "match" { tag = format!("  STALE-EXPECTATION({}): {}", e.verdict, e.reason); *unexpected += 1; }
            else { tag = format!("  UNEXPECTED (expected {}): {}", e.verdict, e.reason); *unexpected += 1; }
        } else if matches!(v, Verdict::Diverge { .. }) && !info { *unexpected += 1; tag = "  <-- UNEXPECTED".into(); }
        else if matches!(v, Verdict::Phase { .. }) && strict_phase && !info { *unexpected += 1; tag = "  <-- UNEXPECTED (strict-phase)".into(); }
        if verbose || !matches!(v, Verdict::Match | Verdict::Sync { .. }) || !tag.is_empty() {
            let _ = writeln!(out, "  {name:<22} {ch:<9} {desc}{tag}{}", if info { "  [info]" } else { "" });
        }
    };

    // ---- per entity channels
    for pr in &pairs {
        let name = format!("{}({}/{}) {}", ROU.get(pr.rou).unwrap_or(&"?"), pr.z, pr.p, "");
        let name = name.trim().to_string();
        let mut chans: Vec<(&str, bool, Seq, Seq)> = vec![];
        let mk = |f: &dyn Fn(&Vec<u8>) -> i32, t: &Trace, id: &str| -> Seq {
            t.ticks.iter().filter_map(|(n, tk)| tk.recs.get(id).filter(|b| !b.is_empty()).map(|b| (*n, f(b)))).collect()
        };
        chans.push(("room", false, mk(&|b| b[0] as i32, &zx, &pr.z), mk(&|b| b[0] as i32, &co, &pr.p)));
        chans.push(("x", false, mk(&|b| zx_px(b[2]), &zx, &pr.z), mk(&|b| port_px(b[2]), &co, &pr.p)));
        chans.push(("y", false, mk(&|b| b[3] as i32, &zx, &pr.z), mk(&|b| b[3] as i32, &co, &pr.p)));
        chans.push(("frame", false, mk(&|b| b[4] as i32, &zx, &pr.z), mk(&|b| b[4] as i32, &co, &pr.p)));
        chans.push(("col", false, mk(&|b| b[11] as i32, &zx, &pr.z), mk(&|b| b[7] as i32, &co, &pr.p)));
        chans.push(("v1", true, mk(&|b| b[10] as i32, &zx, &pr.z), mk(&|b| b[5] as i32, &co, &pr.p)));
        for (ch, info, zs, ps) in chans {
            if zs.is_empty() || ps.is_empty() { continue; }
            let v = judge(&zs, &ps, 0, maxd);
            report(&name, &pr.z, ch, &v, info, &mut out, &mut unexpected);
        }
    }
    for z in &unmatched_z {
        let b = first_z[z];
        if b[12] as i32 == room {
            let _ = writeln!(out, "  {:<22} NOT IN THE PORT: zx record {z} (routine {}, frame {}) has no port slot", ROU.get(b[1] as usize).unwrap_or(&"?"), b[1], b[15]);
            unexpected += 1;
        } else if verbose { let _ = writeln!(out, "  (zx {z} routine {} visits from room {}: no port slot matched)", b[1], b[12]); }
    }
    for p in &unmatched_p { if verbose { let _ = writeln!(out, "  (port slot {p} has no zx record in this trace)"); } }

    // ---- flames / water: the ZX has a counter per flame, the port one global counter
    let zf0: Seq = zx.ticks.iter().filter_map(|(n, t)| t.flames.first().map(|f| (*n, f[2]))).collect();
    let pf: Seq = co.ticks.iter().filter_map(|(n, t)| t.v.get("flame_ctr").map(|v| (*n, *v))).collect();
    let nflz = zx.ticks.values().next().map(|t| t.flames.len()).unwrap_or(0);
    let nflp = co.ticks.values().next().and_then(|t| t.v.get("room_flame_count")).copied().unwrap_or(0);
    if nflz > 0 || nflp > 0 {
        let v = if nflz == 0 || nflp == 0 { Verdict::Diverge { first: 0, z: nflz as i32, p: nflp, best_d: 0, best_bad: 1, overlap: 1 } } else { judge(&zf0, &pf, 0, 16) };
        let count_note = if nflz as i32 != nflp { format!(" (count: zx {nflz}, port {nflp}; room 36 adds the fire-pit table)") } else { String::new() };
        report("flames", "flames", "ctr", &v, false, &mut out, &mut unexpected);
        if !count_note.is_empty() && verbose { let _ = writeln!(out, "  flames{count_note}"); }
        let stag = zx.ticks.values().any(|t| t.flames.iter().any(|f| f[2] != t.flames[0][2]));
        if stag { let _ = writeln!(out, "  flames                 zx flames carry DIFFERENT counters (staggered); the port has one global counter"); }
    }
    let zw0: Seq = zx.ticks.iter().filter_map(|(n, t)| t.water.first().map(|f| (*n, f[2]))).collect();
    let pw: Seq = co.ticks.iter().filter_map(|(n, t)| t.v.get("water_ctr").map(|v| (*n, *v))).collect();
    let nwz = zx.ticks.values().next().map(|t| t.water.len()).unwrap_or(0);
    let nwp = co.ticks.values().next().and_then(|t| t.v.get("room_water_count")).copied().unwrap_or(0);
    if nwz > 0 || nwp > 0 {
        let v = if nwz == 0 || nwp == 0 { Verdict::Diverge { first: 0, z: nwz as i32, p: nwp, best_d: 0, best_bad: 1, overlap: 1 } } else { judge(&zw0, &pw, 0, 8) };
        report("water", "water", "ctr", &v, false, &mut out, &mut unexpected);
    }
    // ---- hazard positions (static per room): the ZX lists (x units, y) against the port's pixel tables
    for name in ["flames", "water"] {
        let pick = |t: &Tick, z: bool| -> Vec<(i32, i32)> {
            let l = if name == "flames" { &t.flames } else { &t.water };
            let mut v: Vec<(i32, i32)> = l.iter().map(|f| if z { ((f[0] - 32) * 4, f[1]) } else { (f[0], f[1]) }).collect();
            v.sort();
            v
        };
        let (zt, pt) = (zx.ticks.values().next(), co.ticks.values().next());
        if let (Some(zt), Some(pt)) = (zt, pt) {
            let (a, b) = (pick(zt, true), pick(pt, false));
            if a != b {
                let ex = expects.iter().find(|e| e.room == room && e.entity == name && e.channel == "pos");
                let tag = match ex { Some(e) => { e.used.set(true); format!("  EXPECTED: {}", e.reason) } None => { unexpected += 1; "  <-- UNEXPECTED".into() } };
                let _ = writeln!(out, "  {name:<22} pos       DIVERGE zx {:?} port {:?}{tag}", a, b);
            } else if verbose && !a.is_empty() { let _ = writeln!(out, "  {name:<22} pos       MATCH ({} at {:?})", a.len(), a); }
        }
    }
    // ---- Dizzy: only the facts that change what the actors saw
    let zk = zx.ticks.values().filter(|t| t.kv.get("killed").copied().unwrap_or(0) != 0).count();
    let pk = co.ticks.values().filter(|t| t.kv.get("killed").copied().unwrap_or(0) != 0).count();
    if zk > 0 || pk > 0 {
        let _ = writeln!(out, "  dizzy                  standing still he was killed: zx in {zk} ticks, port in {pk} samples (the trace after a death is not comparable)");
    }
    let zr = zx.ticks.values().filter(|t| t.kv.get("room").copied().unwrap_or(room) != room).count();
    let pr_ = co.ticks.values().filter(|t| t.kv.get("room").copied().unwrap_or(room) != room).count();
    if zr > 0 || pr_ > 0 { let _ = writeln!(out, "  dizzy                  left the room while standing: zx {zr} ticks, port {pr_} samples"); }

    // ---- boxes
    let bz: Vec<i32> = zx.boxes.iter().map(|b| b.0).collect();
    let bp: Vec<i32> = co.boxes.iter().map(|b| b.0).collect();
    if !bz.is_empty() || !bp.is_empty() {
        let _ = writeln!(out, "  boxes                  zx at ticks {:?}; port at ticks {:?}", bz, bp);
        if bz.len() != bp.len() {
            let ex = expects.iter().find(|e| e.room == room && e.channel == "boxes");
            match ex { Some(e) => { e.used.set(true); let _ = writeln!(out, "                         count differs: EXPECTED: {}", e.reason); }
                None => { let _ = writeln!(out, "                         count differs  <-- UNEXPECTED"); unexpected += 1; } }
        }
    }
    for e in &expects {
        if e.room == room && !e.used.get() {
            let _ = writeln!(out, "  STALE-EXPECTATION room {} {} {}: nothing to apply to ({})", e.room, e.entity, e.channel, e.reason);
            unexpected += 1;
        }
    }
    print!("{out}");
    println!("ROOMCMP room={room} unexpected={unexpected}{}", if env_bad { " ENV" } else { "" });
    if env_bad { exit(2); }
    exit(if unexpected > 0 { 1 } else { 0 });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wave() -> Seq { (1..=300).map(|n| (n, (n * 7 % 13) + (n / 40) * 3)).collect() }
    #[test]
    fn equal_data_matches() {
        assert!(matches!(judge(&wave(), &wave(), 0, 120), Verdict::Match));
    }
    #[test]
    fn a_shifted_copy_is_a_phase_offset() {
        let z = wave();
        let p: Seq = z.iter().map(|(n, v)| (n + 5, *v)).collect(); // port(n+5) = zx(n): the port lags by 5
        match judge(&z, &p, 0, 120) { Verdict::Phase { lo, hi } => assert_eq!((lo, hi), (5, 5)), v => panic!("{v:?}") }
    }
    #[test]
    fn one_changed_value_diverges() {
        let z = wave();
        let mut p = wave();
        p.insert(150, -99);
        match judge(&z, &p, 0, 120) { Verdict::Diverge { first, .. } => assert_eq!(first, 150), v => panic!("{v:?}") }
    }
    #[test]
    fn a_small_shift_is_entry_sync() {
        let z = wave();
        let p: Seq = z.iter().map(|(n, v)| (n + 2, *v)).collect();
        assert!(matches!(judge(&z, &p, 0, 120), Verdict::Sync { .. }));
    }
    #[test]
    fn too_few_common_ticks_is_sparse() {
        let z: Seq = (1..=10).map(|n| (n, n)).collect();
        assert!(matches!(judge(&z, &z, 0, 120), Verdict::Sparse));
    }
    #[test]
    fn zx_x_units() {
        assert_eq!(zx_px(60), 112);
        assert_eq!(zx_px(32), 0);
    }
}
