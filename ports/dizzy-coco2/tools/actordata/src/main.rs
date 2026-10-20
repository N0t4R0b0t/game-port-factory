//! Extracts the original's two interactive-object tables out of X-ALL.TXT
//! into neutral JSON:
//!
//!   * `movingdata` -- the live per-room actor list (T0011/T0013). 16 bytes
//!     per slot, dispatched by a type byte through the `movingrous` jump
//!     table. This is every enemy, NPC, pickup-able item and moving
//!     platform in the game.
//!   * the `prox*` proximity triggers -- a SECOND, simpler interaction
//!     mechanism: static `(room, x, y, w, h)` boxes each followed by their
//!     own handler, dispatched via `checkproximity1`. NOTES.md (T0013)
//!     flagged these as "not yet extracted ... would need a small
//!     dedicated parser recognizing the defb room / defb x,y / defb w,h
//!     pattern"; this is that parser.
//!
//! Both are parsed SYMBOLICALLY from the assembler source rather than from
//! assembled bytes, because the fields that matter most (which behaviour
//! routine, which message, which proximity handler) are label references,
//! not numbers -- they'd be unrecoverable addresses in a binary dump.

use clap::Parser;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Path to X-ALL.TXT (the full assembled source listing)
    #[arg(long)]
    source: PathBuf,
    #[arg(long)]
    output: PathBuf,
}

/// One 16-byte movingdata cell: either a literal number or a symbol
/// reference (a `defw` label spans two cells, both tagged with it).
#[derive(Clone, Debug, Serialize)]
#[serde(untagged)]
enum Cell {
    Num(i64),
    Sym(String),
}

#[derive(Serialize)]
struct Actor {
    slot: usize,
    /// Source label naming this slot, if any (e.g. "trollhere") -- the
    /// handle other code uses to reach it, so behaviour ports need it.
    label: Option<String>,
    room: i64,
    routine: String,
    x: i64,
    /// Real screen pixel x: `(x - 32) * 4`, the SAME transform T0008/
    /// T0014 found for room-placement x_byte ("Correction #2" in
    /// NOTES.md) -- confirmed to apply here too by tracing the
    /// original's shared `frame` blit routine (X-ALL.TXT ~4136, `sub
    /// 32` / `srl a` on frmx) that BOTH thinglp (room placements) and
    /// printmoving (movingdata actors) feed identically. Dizzy's own
    /// x is the one exception -- he's drawn via a separate routine
    /// (`plotnew`/`prtdizzy`) that never goes through `frame`, so his
    /// coordinates stay raw pixels; found live, via a user playtest
    /// noticing actors suspiciously clustered in the same narrow band
    /// as the original room-placement bug.
    pixel_x: i64,
    y: i64,
    frame: i64,
    /// cells 5-6: oldx/oldy for most types, but repurposed as a message
    /// pointer by `pickupable` (and others that show text).
    message: Option<String>,
    /// cells 7-8: ofrm/dly normally, repurposed as a proximity-handler
    /// pointer by the types that have one.
    prox: Option<String>,
    colour: i64,
    orig_room: i64,
    orig_x: i64,
    orig_y: i64,
    orig_frame: i64,
    /// All 16 raw cells, so a later consumer can reinterpret fields this
    /// tool got wrong without re-parsing the source.
    cells: Vec<Cell>,
}

#[derive(Serialize)]
struct ProxTrigger {
    name: String,
    room: i64,
    x: i64,
    /// Same (x-32)*4 transform as Actor::pixel_x -- confirmed for
    /// proximity boxes specifically too: `proximitycollide`
    /// (X-ALL.TXT ~1923) applies the identical `sub 32`/`srl a` to the
    /// box's own x before using it (traced the exact register flow:
    /// HL=(y,x) after checkproximity1's `ex de,hl`, so `ld a,l / sub
    /// 32 / srl a` operates on x specifically). Width's treatment is
    /// NOT resolved with the same confidence -- it separately gets
    /// `srl b` in the original's OWN fill-loop, but that could be a
    /// Spectrum-specific pixels-to-bytes step unrelated to whether the
    /// stored value itself needs the *4 scale. Left as extracted (w
    /// unscaled); revisit if a trigger box's size feels visibly wrong
    /// once actually used, not just its position.
    pixel_x: i64,
    y: i64,
    w: i64,
    h: i64,
    /// The handler label that immediately follows the box definition.
    handler: String,
}

/// One `cointable` entry: a collectable coin, which is NOT an actor and
/// NOT a proximity trigger -- it is a third, even simpler mechanism.
/// `putcoinsinroom` draws frame 0 at each uncollected coin belonging to
/// the room being entered, and `pickupcoins` collects one by setting bit
/// 7 of its ROOM byte (so the table doubles as the save state).
#[derive(Serialize)]
struct Coin {
    /// Raw table x, in the same 4-pixel +32-biased units as everything
    /// else the original's `frame` blitter consumes.
    x: i64,
    pixel_x: i64,
    y: i64,
    room: i64,
}

#[derive(Serialize)]
struct Output {
    source_file: String,
    actors: Vec<Actor>,
    triggers: Vec<ProxTrigger>,
    coins: Vec<Coin>,
    /// routine name -> how many slots use it, a quick sanity view of which
    /// behaviours actually matter.
    routine_histogram: BTreeMap<String, usize>,
}

/// Evaluate the simple `A+B+C` / bare-number / bare-symbol operand forms
/// the source uses. Returns Err(symbol) when it is not numeric.
fn eval(tok: &str) -> Result<i64, String> {
    let t = tok.trim();
    if t.is_empty() {
        return Err(String::new());
    }
    if t.contains('+') {
        let mut acc = 0i64;
        for part in t.split('+') {
            match eval(part) {
                Ok(v) => acc += v,
                Err(s) => return Err(s),
            }
        }
        return Ok(acc);
    }
    if let Some(hex) = t.strip_prefix('$') {
        return i64::from_str_radix(hex, 16).map_err(|_| t.to_string());
    }
    t.parse::<i64>().map_err(|_| t.to_string())
}

fn strip_comment(line: &str) -> &str {
    // PDS uses `;` for comments; `;;;` blocks are common in this source.
    match line.find(';') {
        Some(i) => &line[..i],
        None => line,
    }
}

fn split_operands(s: &str) -> Vec<String> {
    s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect()
}

/// Source path as written into the JSON: made relative to the current directory when it lies
/// under it, so no machine-specific absolute path ends up in generated files.
fn display_rel(p: &std::path::Path) -> String {
    if p.is_absolute() {
        if let Ok(cwd) = std::env::current_dir() {
            if let Ok(r) = p.strip_prefix(&cwd) {
                return r.display().to_string();
            }
        }
    }
    p.display().to_string()
}

fn main() {
    let args = Args::parse();
    let text = fs::read_to_string(&args.source).expect("read source");
    let lines: Vec<&str> = text.lines().collect();

    // ---- movingdata -------------------------------------------------
    let start = lines.iter().position(|l| l.trim_start().starts_with("movingdata")).expect("no movingdata label");
    let end = lines
        .iter()
        .position(|l| l.trim_start().starts_with("endofmovingdata"))
        .expect("no endofmovingdata label");

    let mut cells: Vec<Cell> = Vec::new();
    // slot index -> label, captured when a bare label line appears
    let mut labels: BTreeMap<usize, String> = BTreeMap::new();
    let mut pending_label: Option<String> = None;

    for raw in &lines[start + 1..end] {
        let line = strip_comment(raw);
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // The mnemonic may be separated from its operands by spaces OR
        // tabs -- this source uses tabs freely (`defw\t\t\tbagmess`), and
        // matching only "defb " silently drops every tab-separated defw,
        // which desynchronises the whole 16-byte slot stream.
        let mut parts = trimmed.splitn(2, |c: char| c.is_whitespace());
        let mnemonic = parts.next().unwrap_or("").to_ascii_lowercase();
        let operand_text = parts.next().unwrap_or("").to_string();
        let is_defb = mnemonic == "defb";
        let is_defw = mnemonic == "defw";
        if !is_defb && !is_defw {
            // A bare label line names the slot that starts next.
            let name = trimmed.split_whitespace().next().unwrap_or("").to_string();
            if !name.is_empty() {
                pending_label = Some(name);
            }
            continue;
        }
        if let Some(l) = pending_label.take() {
            // cells.len() is a byte offset; 16 bytes per slot.
            labels.insert(cells.len() / 16, l);
        }
        let ops = split_operands(&operand_text);
        for op in ops {
            match eval(&op) {
                Ok(v) => {
                    cells.push(Cell::Num(v));
                    if is_defw {
                        // a numeric defw still occupies two bytes
                        cells.push(Cell::Num(0));
                    }
                }
                Err(sym) => {
                    cells.push(Cell::Sym(sym.clone()));
                    if is_defw {
                        cells.push(Cell::Sym(sym));
                    }
                }
            }
        }
    }

    assert!(
        cells.len() % 16 == 0,
        "movingdata is {} bytes, not a multiple of 16 -- field layout is wrong",
        cells.len()
    );

    let num = |c: &Cell| match c {
        Cell::Num(v) => *v,
        Cell::Sym(_) => -1,
    };
    let sym = |c: &Cell| match c {
        Cell::Sym(s) => Some(s.clone()),
        Cell::Num(_) => None,
    };

    let mut actors = Vec::new();
    let mut routine_histogram: BTreeMap<String, usize> = BTreeMap::new();
    for (slot, chunk) in cells.chunks(16).enumerate() {
        let routine = sym(&chunk[1]).unwrap_or_else(|| format!("#{}", num(&chunk[1])));
        *routine_histogram.entry(routine.clone()).or_insert(0) += 1;
        actors.push(Actor {
            slot,
            label: labels.get(&slot).cloned(),
            room: num(&chunk[0]),
            routine,
            x: num(&chunk[2]),
            pixel_x: (num(&chunk[2]) - 32) * 4,
            y: num(&chunk[3]),
            frame: num(&chunk[4]),
            message: sym(&chunk[5]),
            prox: sym(&chunk[7]),
            colour: num(&chunk[11]),
            orig_room: num(&chunk[12]),
            orig_x: num(&chunk[13]),
            orig_y: num(&chunk[14]),
            orig_frame: num(&chunk[15]),
            cells: chunk.to_vec(),
        });
    }

    // ---- proximity triggers -----------------------------------------
    // Shape in source:
    //     proxjug  defb 36        ;room
    //              defb x,y
    //              defb w,h
    //     proxjugrou <handler code>
    let mut triggers = Vec::new();
    for (i, raw) in lines.iter().enumerate() {
        let trimmed = strip_comment(raw).trim().to_string();
        if trimmed.is_empty() {
            continue;
        }
        let mut it = trimmed.split_whitespace();
        let name = match it.next() {
            Some(n) if n.starts_with("prox") && !n.ends_with("rou") => n.to_string(),
            _ => continue,
        };
        // Collect the next three defb lines' worth of numeric operands.
        let mut vals: Vec<i64> = Vec::new();
        let rest: String = it.collect::<Vec<_>>().join(" ");
        // Same tab-vs-space caveat as the movingdata parser above.
        let consider = |s: &str, vals: &mut Vec<i64>| {
            let t = s.trim();
            let mut it = t.splitn(2, |c: char| c.is_whitespace());
            if it.next().map(|m| m.eq_ignore_ascii_case("defb")) != Some(true) {
                return false;
            }
            for op in split_operands(it.next().unwrap_or("")) {
                if let Ok(v) = eval(&op) {
                    vals.push(v);
                }
            }
            true
        };
        consider(&rest, &mut vals);
        let mut j = i + 1;
        let mut handler = String::new();
        while j < lines.len() && vals.len() < 5 {
            let l = strip_comment(lines[j]).trim().to_string();
            j += 1;
            if l.is_empty() {
                continue;
            }
            if !consider(&l, &mut vals) {
                break;
            }
        }
        // The handler label is the next non-defb, non-empty line.
        while j < lines.len() {
            let l = strip_comment(lines[j]).trim().to_string();
            j += 1;
            if l.is_empty() {
                continue;
            }
            if l.to_ascii_lowercase().starts_with("defb ") {
                continue;
            }
            handler = l.split_whitespace().next().unwrap_or("").to_string();
            break;
        }
        if vals.len() >= 5 {
            triggers.push(ProxTrigger {
                name,
                room: vals[0],
                x: vals[1],
                pixel_x: (vals[1] - 32) * 4,
                y: vals[2],
                w: vals[3],
                h: vals[4],
                handler,
            });
        }
    }

    // ---- cointable --------------------------------------------------
    // `defb x,y,room` triples between `cointable` and `endcointable`.
    // Note the column order is x,y,ROOM -- the opposite of movingdata's
    // room-first layout, and the source's own header comment says so.
    let mut coins = Vec::new();
    let cstart = lines.iter().position(|l| l.trim_start().starts_with("cointable"))
        .expect("no cointable label");
    let cend = lines.iter().position(|l| l.trim_start().starts_with("endcointable"))
        .expect("no endcointable label");
    for line in &lines[cstart + 1..cend] {
        let l = strip_comment(line).trim().to_string();
        if !l.to_ascii_lowercase().starts_with("defb ") {
            continue;
        }
        let v: Vec<i64> = split_operands(&l[5..]).iter().filter_map(|t| eval(t).ok()).collect();
        if v.len() == 3 {
            coins.push(Coin { x: v[0], pixel_x: (v[0] - 32) * 4, y: v[1], room: v[2] });
        }
    }

    let out = Output {
        source_file: display_rel(&args.source),
        actors,
        triggers,
        coins,
        routine_histogram,
    };
    let n_actors = out.actors.len();
    let n_trig = out.triggers.len();
    let n_coin = out.coins.len();
    fs::write(&args.output, serde_json::to_string_pretty(&out).unwrap()).expect("write");
    println!(
        "extracted {n_actors} actor slots ({} bytes), {n_trig} proximity triggers \
         and {n_coin} coins -> {}",
        cells.len(),
        args.output.display()
    );
}
