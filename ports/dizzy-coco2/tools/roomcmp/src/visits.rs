//! `roomcmp visits`: compares the PASSIVE logs of a whole bot run (harness/roomcmp_log.lua), ZX against CoCo, phase-free.
//!
//! Both bots play the same plan, so each room is visited on both machines, but at different moments and with Dizzy doing different things.  What
//! must agree is how each actor BEHAVES: for every actor record and every channel (x, y, frame, colour, room) the log gives the stretches in which
//! the channel held one value ("runs").  A run that both starts and ends on an observed change inside one visit is COMPLETE; its (value, duration in
//! actor ticks) pair is a fact about the actor's timing that does not depend on when the visit happened.  The two machines agree on an actor when the
//! sets of complete (value, duration) pairs agree.  Positions that depend on Dizzy (a rat chasing, a platform carrying him) legitimately differ and are
//! named in expectations.toml.
use std::collections::{BTreeMap, BTreeSet};

use crate::{ROU, load_expect, port_px, zx_px};

#[derive(Default)]
struct Log {
    machine: String,
    inits: BTreeMap<String, [i32; 5]>,
    /// room visits: (room, first tick, last tick exclusive)
    visits: Vec<(i32, i32, i32)>,
    /// per id: (tick, bytes) events in log order
    events: BTreeMap<String, Vec<(i32, Vec<u8>)>>,
    deaths: Vec<i32>,
    boxes: Vec<(i32, i32)>,
    /// Dizzy's animation: (sequence, animation counter) -> set of frame numbers seen (all rooms, whole run)
    dz: BTreeMap<(i32, i32), BTreeSet<i32>>,
    /// segment starts: (segment index, start tick); M events: (tick, keys of the original strings printed)
    segs: Vec<(i32, i32)>,
    /// the original-string keys this machine's recorder could observe (the comparison uses the intersection of the two sets)
    tapped: BTreeSet<String>,
    msgs: Vec<(i32, Vec<String>)>,
}

fn hexbytes(s: &str) -> Vec<u8> {
    (0..s.len() / 2).filter_map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()).collect()
}

fn load(path: &str) -> Log {
    let txt = std::fs::read_to_string(path).unwrap_or_else(|e| { eprintln!("roomcmp: cannot read {path}: {e}"); std::process::exit(2) });
    let mut l = Log::default();
    let mut last_tick = 0;
    for line in txt.lines() {
        let p: Vec<&str> = line.split_whitespace().collect();
        if p.is_empty() { continue; }
        match p[0] {
            "H" => for w in &p[1..] { if let Some(v) = w.strip_prefix("machine=") { l.machine = v.to_string(); } },
            "I" if p.len() >= 3 => {
                let v: Vec<i32> = p[2].split(',').filter_map(|x| x.parse().ok()).collect();
                if v.len() == 5 { l.inits.insert(p[1].to_string(), [v[0], v[1], v[2], v[3], v[4]]); }
            }
            "R" if p.len() >= 3 => {
                let (t, r): (i32, i32) = (p[1].parse().unwrap_or(0), p[2].parse().unwrap_or(0));
                if let Some(v) = l.visits.last_mut() { v.2 = t; }
                l.visits.push((r, t, i32::MAX));
                last_tick = t;
            }
            "D" if p.len() >= 4 => {
                let t: i32 = p[1].parse().unwrap_or(0);
                l.events.entry(p[2].to_string()).or_default().push((t, hexbytes(p[3])));
                last_tick = last_tick.max(t);
            }
            "K" if p.len() >= 2 => { l.tapped.insert(p[1].to_string()); }
            "S" if p.len() >= 3 => l.segs.push((p[2].parse().unwrap_or(0), p[1].parse().unwrap_or(0))),
            "M" if p.len() >= 4 => l.msgs.push((p[1].parse().unwrap_or(0), p[3..].iter().map(|x| x.to_string()).collect())),
            "Z" if p.len() >= 5 => {
                let v: Vec<i32> = p[1..].iter().filter_map(|x| x.parse().ok()).collect();
                // the ZX bot samples AFTER updatedizzy has already advanced `animation` (ld (animation),a with a = (e+1)&7, after ff was
                // read from seq0[sequence*8+e]); the port samples with the counter that selected the frame.  Normalise to the selecting one.
                if v.len() >= 4 { let an = if l.machine == "zx" { (v[2] + 7) & 7 } else { v[2] }; l.dz.entry((v[1], an)).or_default().insert(v[3]); }
            }
            "X" if p.len() >= 2 => l.deaths.push(p[1].parse().unwrap_or(0)),
            "B" if p.len() >= 3 => l.boxes.push((p[1].parse().unwrap_or(0), p[2].parse().unwrap_or(0))),
            _ => {}
        }
    }
    if let Some(v) = l.visits.last_mut() { v.2 = last_tick + 1; }
    l
}

type Run = (i32, i32); // (value, duration)

/// complete runs of one channel of one record, per visit of `room`; `f` maps the record bytes to the channel value
fn runs(log: &Log, id: &str, room: i32, f: &dyn Fn(&[u8]) -> i32) -> Vec<Run> {
    let mut out = vec![];
    let Some(ev) = log.events.get(id) else { return out };
    for &(r, t0, t1) in &log.visits {
        if r != room { continue; }
        // events of this record inside the visit; the first one is the entry state, so a run that starts there is incomplete
        let inside: Vec<&(i32, Vec<u8>)> = ev.iter().filter(|(t, _)| *t >= t0 && *t < t1).collect();
        let mut cur: Option<(i32, i32, bool)> = None; // value, start tick, started on an observed change
        for (t, b) in inside {
            let v = f(b);
            match cur {
                None => cur = Some((v, *t, false)),
                Some((cv, ct, complete)) if cv != v => {
                    if complete { out.push((cv, *t - ct)); }
                    cur = Some((v, *t, true));
                }
                _ => {}
            }
        }
    }
    out
}

pub fn main(args: &[String]) {
    let (mut zxp, mut cop, mut exp, mut room_filter) = (None, None, None, None::<i32>);
    let mut verbose = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--zx" => { zxp = args.get(i + 1).cloned(); i += 1; }
            "--coco" => { cop = args.get(i + 1).cloned(); i += 1; }
            "--expect" => { exp = args.get(i + 1).cloned(); i += 1; }
            "--room" => { room_filter = args.get(i + 1).and_then(|x| x.parse().ok()); i += 1; }
            "-v" => verbose = true,
            o => { eprintln!("roomcmp visits: unknown argument {o}"); std::process::exit(2) }
        }
        i += 1;
    }
    let zx = load(&zxp.unwrap_or_else(|| { eprintln!("--zx missing"); std::process::exit(2) }));
    let co = load(&cop.unwrap_or_else(|| { eprintln!("--coco missing"); std::process::exit(2) }));
    if zx.machine != "zx" || co.machine != "coco" { eprintln!("roomcmp visits: --zx/--coco logs are for the wrong machines"); std::process::exit(2) }
    let expects: Vec<crate::Expect> = exp.map(|p| load_expect(&p)).unwrap_or_default().into_iter().filter(|e| e.mode != "trace").collect();
    // pairing: the same rule as the standing-still comparer, over the first record each side logged
    let first_z: BTreeMap<&String, &Vec<u8>> = zx.events.iter().filter_map(|(k, v)| v.first().map(|e| (k, &e.1))).collect();
    let mut taken: BTreeSet<String> = BTreeSet::new();
    let mut pairs: Vec<(String, String, usize, i32)> = vec![]; // zid, pid, rou, origroom
    for (zid, b) in &first_z {
        if b.len() < 16 { continue; }
        let (rou, orm, orx, ofr) = (b[1] as usize, b[12] as i32, zx_px(b[13]), b[15] as i32);
        let pick = [0u8, 1, 2].iter().find_map(|&s| {
            let c: Vec<&String> = co.inits.iter().filter(|(pid, v)| !taken.contains(*pid) && v[4] as usize == rou && (v[0] == orm && match s {
                0 => v[1] == orx && v[3] == ofr, 1 => v[1] == orx, _ => v[3] == ofr } || (s == 2 && v[0] == 255 && v[3] == ofr))).map(|(k, _)| k).collect();
            if c.len() == 1 || (!c.is_empty() && s == 0) { Some(c[0].clone()) } else { None }
        });
        if let Some(p) = pick { taken.insert(p.clone()); pairs.push(((*zid).clone(), p, rou, orm)); }
    }
    let mut unexpected = 0usize;
    let rooms: BTreeSet<i32> = zx.visits.iter().map(|v| v.0).filter(|r| co.visits.iter().any(|c| c.0 == *r)).collect();
    println!("VISITS zx: {} room visits, {} deaths, {} boxes; coco: {} room visits, {} deaths, {} boxes; {} paired records",
        zx.visits.len(), zx.deaths.len(), zx.boxes.len(), co.visits.len(), co.deaths.len(), co.boxes.len(), pairs.len());
    for &room in &rooms {
        if room_filter.map(|r| r != room).unwrap_or(false) { continue; }
        let mut lines = vec![];
        for (zid, pid, rou, _orm) in &pairs {
            if *rou == 2 { continue; } // pickupables: no behaviour
            let chans: Vec<(&str, Box<dyn Fn(&[u8]) -> i32>, Box<dyn Fn(&[u8]) -> i32>)> = vec![
                ("x", Box::new(|b: &[u8]| zx_px(b[2])), Box::new(|b: &[u8]| port_px(b[2]))),
                ("y", Box::new(|b: &[u8]| b[3] as i32), Box::new(|b: &[u8]| b[3] as i32)),
                ("frame", Box::new(|b: &[u8]| b[4] as i32), Box::new(|b: &[u8]| b[4] as i32)),
                ("col", Box::new(|b: &[u8]| b[11] as i32), Box::new(|b: &[u8]| b[7] as i32)),
            ];
            for (ch, fz, fp) in chans {
                let rz = runs(&zx, zid, room, &*fz);
                let rp = runs(&co, pid, room, &*fp);
                if rz.is_empty() && rp.is_empty() { continue; }
                let sz: BTreeSet<Run> = rz.iter().cloned().collect();
                let sp: BTreeSet<Run> = rp.iter().cloned().collect();
                let only_z: Vec<&Run> = sz.difference(&sp).collect();
                let only_p: Vec<&Run> = sp.difference(&sz).collect();
                let name = format!("{}({}/{})", ROU.get(*rou).unwrap_or(&"?"), zid, pid);
                let ex = expects.iter().find(|e| e.room == room && (e.entity == *zid || e.entity == "*") && e.channel == ch);
                if only_z.is_empty() && only_p.is_empty() {
                    if verbose { lines.push(format!("  {name:<24} {ch:<6} MATCH ({} runs zx, {} coco)", rz.len(), rp.len())); }
                    if let Some(e) = ex { e.used.set(true); lines.push(format!("  {name:<24} {ch:<6} STALE-EXPECTATION: {}", e.reason)); unexpected += 1; }
                    continue;
                }
                let hist = |r: &Vec<Run>| { let mut h: BTreeMap<i32, usize> = BTreeMap::new(); for x in r { *h.entry(x.1).or_default() += 1; } h };
                let tag = match ex { Some(e) => { e.used.set(true); format!("  EXPECTED: {}", e.reason) } None => { unexpected += 1; "  <-- UNEXPECTED".to_string() } };
                let show = |v: &Vec<&Run>| v.iter().take(5).map(|r| format!("{}x{}t", r.0, r.1)).collect::<Vec<_>>().join(" ");
                lines.push(format!("  {name:<24} {ch:<6} DIFFER: runs zx {} / coco {}; only zx [{}] only coco [{}]{tag}", rz.len(), rp.len(), show(&only_z), show(&only_p)));
                let (hz, hp) = (hist(&rz), hist(&rp));
                lines.push(format!("      durations zx {:?}  coco {:?}", hz.iter().take(8).collect::<Vec<_>>(), hp.iter().take(8).collect::<Vec<_>>()));
            }
        }
        if !lines.is_empty() { println!("ROOM {room}"); for l in lines { println!("{l}"); } }
    }
    // ---- the original strings each machine printed, per (paired) segment: the dialogue's identity and ORDER
    if !zx.msgs.is_empty() && !co.msgs.is_empty() && !zx.segs.is_empty() && !co.segs.is_empty() {
        // a box is printed while the game is modal, so its strings carry the SAME tick as the box's own B event; strings read at any other
        // tick are ambient (redraws) and are dropped.  One entry per box tick = one run of boxes (a chatter stream is several boxes at once).
        let common: BTreeSet<&String> = zx.tapped.intersection(&co.tapped).collect();
        let per_seg = |l: &Log| -> BTreeMap<i32, Vec<Vec<String>>> {
            let box_ticks: BTreeSet<i32> = l.boxes.iter().map(|b| b.0).collect();
            let mut m: BTreeMap<i32, Vec<Vec<String>>> = BTreeMap::new();
            for (n, (idx, t0)) in l.segs.iter().enumerate() {
                let t1 = l.segs.get(n + 1).map(|x| x.1).unwrap_or(i32::MAX);
                let v = m.entry(*idx).or_default();
                let mut cur_tick = -1;
                for (t, keys) in &l.msgs {
                    if *t < *t0 || *t >= t1 || !box_ticks.contains(t) { continue; }
                    if *t != cur_tick { v.push(vec![]); cur_tick = *t; }
                    let run = v.last_mut().unwrap();
                    for k in keys { if common.contains(k) && run.last() != Some(k) { run.push(k.clone()); } }
                }
            }
            for runs in m.values_mut() { runs.retain(|r| !r.is_empty()); }
            m
        };
        let (mz, mc) = (per_seg(&zx), per_seg(&co));
        let (mut same, mut diff_n, mut total) = (0usize, 0usize, 0usize);
        for (idx, vz) in &mz {
            let Some(vc) = mc.get(idx) else { continue };
            total += 1;
            if vz == vc { same += 1; continue; }
            let ex = expects.iter().find(|e| e.channel == "msgs" && e.room == *idx);
            let first = vz.iter().zip(vc.iter()).position(|(a, b)| a != b).unwrap_or(vz.len().min(vc.len()));
            let ctx = |runs: &Vec<Vec<String>>, other: &Vec<Vec<String>>| -> String {
                match runs.get(first) {
                    None => "(none)".to_string(),
                    Some(r) => {
                        let o = other.get(first).cloned().unwrap_or_default();
                        let k = r.iter().zip(o.iter()).position(|(a, b)| a != b).unwrap_or(r.len().min(o.len()));
                        format!("run of {} strings, differs from key #{k}: {:?}", r.len(), r.iter().skip(k.saturating_sub(1)).take(4).map(|x| x.trim_start_matches("X-ALL:")).collect::<Vec<_>>())
                    }
                }
            };
            let (fz, fc) = (ctx(vz, vc), ctx(vc, vz));
            let tag = match ex { Some(e) => { e.used.set(true); format!("  EXPECTED: {}", e.reason) } None => { unexpected += 1; "  <-- UNEXPECTED".to_string() } };
            diff_n += 1;
            println!("MSGS segment {idx}: zx {} box runs, port {}; first difference at run #{first}: zx {} | port {}{tag}", vz.len(), vc.len(), fz, fc);
        }
        println!("MSGS: {same} of {total} paired segments print the same original strings in the same order (box runs) ({diff_n} differ)");
    }
    // ---- Dizzy's animation tables: which frame each (sequence, animation counter) shows, over the whole run
    if !zx.dz.is_empty() && !co.dz.is_empty() {
        let mut bad = vec![];
        for (k, zs) in &zx.dz {
            match co.dz.get(k) {
                // The ZX sample can also catch the moment `sequence`/`animation` were reset by a jump start or a room change, which adds
                // frames of the neighbouring sequence to a combination; what must hold is that the port never shows a frame the original
                // does not show for the same (sequence, counter).
                Some(cs) if cs.is_subset(zs) => {}
                Some(cs) => bad.push(format!("seq {} anim {}: zx frames {:?} port {:?}", k.0, k.1, zs, cs)),
                None => {}   // a combination the port's run never produced (the ZX run is longer: extra egg trip); not a difference by itself
            }
        }
        let common = zx.dz.keys().filter(|k| co.dz.contains_key(*k)).count();
        if bad.is_empty() { println!("DIZZY animation: {common} (sequence, counter) combinations seen on both machines, all show the same frame"); }
        else {
            let ex = expects.iter().find(|e| e.channel == "dizzy-anim");
            let tag = match ex { Some(e) => { e.used.set(true); format!(" EXPECTED: {}", e.reason) } None => { unexpected += 1; " <-- UNEXPECTED".to_string() } };
            println!("DIZZY animation: {} of {common} combinations differ{tag}", bad.len());
            for b in bad.iter().take(12) { println!("    {b}"); }
        }
    }
    for e in &expects { if !e.used.get() && room_filter.map(|r| r == e.room).unwrap_or(true) { println!("  STALE-EXPECTATION room {} {} {}: nothing to apply to ({})", e.room, e.entity, e.channel, e.reason); unexpected += 1; } }
    println!("ROOMCMP-VISITS unexpected={unexpected}");
    std::process::exit(if unexpected > 0 { 1 } else { 0 });
}
