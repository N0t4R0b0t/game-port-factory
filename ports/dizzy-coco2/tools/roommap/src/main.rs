//! Generates the game's MAP topology document from the extracted room,
//! actor and coin tables.
//!
//! WHY THIS EXISTS: sessions are weeks apart and rooms were being
//! referred to as "the one with the stairs". A room number means
//! nothing on its own, and the connection rule lives in four scattered
//! routines in the original source. This turns both into one page.
//!
//! The topology is not a graph in the original at all -- it is a GRID,
//! and the whole of it is these four routines (X-ALL.TXT ~6298):
//!
//!   goneleft   roomno - 1     and x := 56
//!   goneright  roomno + 1     and x := 2
//!   goneup     roomno + 16    and y := y + 118
//!   gonedown   roomno - 16    and y := y - 114
//!   newroom    and 127
//!
//! So room = row*16 + col with 8 rows, UP is +16 (higher numbers are
//! higher in the world), and there is no exit table: every room has
//! four neighbours by arithmetic. Whether you can actually walk between
//! two of them is decided by the room's own art -- a wall at the screen
//! edge is the only thing stopping you. That is why this document
//! distinguishes "adjacent" from "reachable" and never claims the
//! second.
use clap::Parser;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// extracted/rooms.json (tools/roomdata)
    #[arg(long)]
    rooms: PathBuf,
    /// extracted/actors.json (tools/actordata) -- actors, proximity
    /// triggers and coins, all keyed by room
    #[arg(long)]
    actors: Option<PathBuf>,
    /// Rooms this port actually builds, so the map can show the slice
    #[arg(long, value_delimiter = ',')]
    built: Vec<usize>,
    /// Row stride of the room-number grid (16 for Dizzy's `add a,16`)
    #[arg(long, default_value_t = 16)]
    stride: usize,
    /// Room numbers wrap at this many (Dizzy's `and 127`)
    #[arg(long, default_value_t = 128)]
    wrap: usize,
    /// `N=text` for a room number that is not a PLACE -- a title
    /// screen, an alternate-state redraw of another room, a demo. Those
    /// exist only in code (Dizzy's `checkfireout` swaps room 36 for
    /// room 2 once the fire is out) and no extraction can find them, so
    /// they are passed in and shown apart from the world grid. Repeat
    /// the flag; deliberately NOT comma-separated, since the notes
    /// themselves contain commas.
    #[arg(long)]
    special: Vec<String>,

    #[arg(long)]
    title: String,
    #[arg(long)]
    output: PathBuf,
}

#[derive(Deserialize)]
struct RoomsFile {
    rooms: Vec<Room>,
}

#[derive(Deserialize)]
struct Room {
    index: usize,
    is_empty: bool,
    name: Option<String>,
    things: Vec<serde_json::Value>,
}

#[derive(Deserialize, Default)]
struct ActorsFile {
    #[serde(default)]
    actors: Vec<ActorRec>,
    #[serde(default)]
    triggers: Vec<Trigger>,
    #[serde(default)]
    coins: Vec<Coin>,
}

#[derive(Deserialize)]
struct ActorRec {
    room: i64,
    routine: String,
    label: Option<String>,
}

#[derive(Deserialize)]
struct Trigger {
    name: String,
    room: i64,
}

#[derive(Deserialize)]
struct Coin {
    room: i64,
}

/// The original's text encoding -- ':'=space, ';'=apostrophe, '<'=comma,
/// '='=hyphen, '>'=period, '?'=question, '@'=exclamation. Recovered in
/// T0010 and documented in the generated font_data.asm.
fn decode_name(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            ':' => ' ',
            ';' => '\'',
            '<' => ',',
            '=' => '-',
            '>' => '.',
            '?' => '?',
            '@' => '!',
            other => other,
        })
        .collect::<String>()
        .trim()
        .to_string()
}

fn main() {
    let args = Args::parse();
    let rf: RoomsFile =
        serde_json::from_str(&fs::read_to_string(&args.rooms).expect("read rooms.json")).unwrap();
    let af: ActorsFile = match &args.actors {
        Some(p) => serde_json::from_str(&fs::read_to_string(p).expect("read actors.json")).unwrap(),
        None => ActorsFile::default(),
    };

    let built: BTreeSet<usize> = args.built.iter().copied().collect();
    let special: BTreeMap<usize, String> = args
        .special
        .iter()
        .filter_map(|s| s.split_once('='))
        .map(|(k, v)| (k.trim().parse::<usize>().expect("special key"), v.trim().to_string()))
        .collect();
    let mut name = BTreeMap::new();
    let mut things = BTreeMap::new();
    let mut live = BTreeSet::new();
    for r in &rf.rooms {
        if r.is_empty {
            continue;
        }
        live.insert(r.index);
        things.insert(r.index, r.things.len());
        if let Some(n) = &r.name {
            let d = decode_name(n);
            if !d.is_empty() {
                name.insert(r.index, d);
            }
        }
    }

    let mut per_room_actors: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for a in &af.actors {
        if a.room < 0 || a.room as usize >= args.wrap {
            continue;
        }
        let label = a.label.clone().unwrap_or_default();
        per_room_actors.entry(a.room as usize).or_default().push(if label.is_empty() {
            a.routine.clone()
        } else {
            format!("{} ({label})", a.routine)
        });
    }
    let mut per_room_trig: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for t in &af.triggers {
        if t.room >= 0 && (t.room as usize) < args.wrap {
            per_room_trig.entry(t.room as usize).or_default().push(t.name.clone());
        }
    }
    let mut per_room_coins: BTreeMap<usize, usize> = BTreeMap::new();
    for c in &af.coins {
        if c.room >= 0 {
            *per_room_coins.entry(c.room as usize).or_default() += 1;
        }
    }

    let rows = args.wrap / args.stride;
    let label = |i: usize| -> String {
        match name.get(&i) {
            Some(n) => n.clone(),
            None if live.contains(&i) => "(unnamed)".into(),
            None => String::new(),
        }
    };

    let mut out = String::new();
    writeln!(out, "# {} -- map\n", args.title).unwrap();
    writeln!(out, "<!-- GENERATED by tools/roommap. Do not edit by hand; regenerate. -->\n").unwrap();
    writeln!(
        out,
        "## The topology is a grid, not an exit table\n\n\
         There is no room-connection data anywhere in the original. Four routines ARE the map\n\
         (X-ALL.TXT ~6298):\n\n\
         | leaving | new room | and | \n|---|---|---|\n\
         | left edge | `roomno - 1` | x := 56 |\n\
         | right edge | `roomno + 1` | x := 2 |\n\
         | top edge | `roomno + {stride}` | y := y + 118 |\n\
         | bottom edge | `roomno - {stride}` | y := y - 114 |\n\n\
         then `and 127`. So **room = row x {stride} + column**, **UP IS +{stride}** (higher numbers are\n\
         higher in the world), and every room has four neighbours by arithmetic.\n\n\
         That means adjacency below is *arithmetic*, not *reachability*: whether you can walk\n\
         between two neighbours is decided entirely by the rooms' own art -- a wall drawn at the\n\
         screen edge is the only thing that stops you. Nothing in the data says which edges are\n\
         open, so this document never claims it.\n",
        stride = args.stride
    )
    .unwrap();

    if !special.is_empty() {
        writeln!(out, "## Rooms that are not places\n").unwrap();
        writeln!(
            out,
            "These room numbers hold art, so they look like rooms in any extraction, but nothing\n\
             walks into them from a neighbour -- game code selects them directly. They are listed\n\
             here and left out of the world grid below.\n"
        )
        .unwrap();
        writeln!(out, "| room | what it really is |\n|---|---|").unwrap();
        for (i, note) in &special {
            writeln!(out, "| {i} | {note} |").unwrap();
        }
        writeln!(out).unwrap();
    }

    writeln!(out, "## The world\n").unwrap();
    writeln!(out, "Rows are printed top-down, so up the page is up in the game.").unwrap();
    writeln!(out, "**Bold** = built by this port. Blank = no room data at that number.\n").unwrap();
    write!(out, "| row |").unwrap();
    for c in 0..args.stride {
        write!(out, " +{c} |").unwrap();
    }
    writeln!(out).unwrap();
    write!(out, "|---|").unwrap();
    for _ in 0..args.stride {
        write!(out, "---|").unwrap();
    }
    writeln!(out).unwrap();
    for row in (0..rows).rev() {
        write!(out, "| **{}** |", row * args.stride).unwrap();
        for col in 0..args.stride {
            let i = row * args.stride + col;
            let cell = if !live.contains(&i) {
                String::new()
            } else if special.contains_key(&i) {
                format!("_{i}: not a place_")
            } else if built.contains(&i) {
                format!("**{i}<br>{}**", label(i))
            } else {
                format!("{i}<br>{}", label(i))
            };
            write!(out, " {cell} |").unwrap();
        }
        writeln!(out).unwrap();
    }
    writeln!(out).unwrap();

    // Mermaid: the built slice plus every arithmetic neighbour of it, so
    // the diagram shows the frontier -- what the next room to add is.
    if !built.is_empty() {
        // Specials are not places, so they have no neighbours and must
        // not pull their arithmetic ones into the picture -- room 2 is
        // room 36's fire-out redraw, and showing it wired to rooms 1 and
        // 3 would be a lie drawn in a diagram, which is the worst place
        // to put one.
        let mut shown: BTreeSet<usize> =
            built.iter().copied().filter(|i| !special.contains_key(i)).collect();
        for &b in &built {
            if special.contains_key(&b) {
                continue;
            }
            for n in neighbours(b, args.stride, args.wrap) {
                if live.contains(&n) && !special.contains_key(&n) {
                    shown.insert(n);
                }
            }
        }
        writeln!(out, "## The built slice and its frontier\n").unwrap();
        writeln!(
            out,
            "Solid boxes are built; dashed are the rooms one step outside it.\n"
        )
        .unwrap();
        writeln!(out, "```mermaid\nflowchart TB").unwrap();
        for &i in &shown {
            let n = label(i);
            writeln!(out, "  R{i}[\"{i}<br>{n}\"]").unwrap();
        }
        let mut drawn = BTreeSet::new();
        for &i in &shown {
            // right (+1) and up (+stride) only -- drawing both directions
            // of every pair doubles the edges and says nothing extra.
            for (d, arrow) in [(1usize, "-- E/W ---"), (args.stride, "-- N/S ---")] {
                let j = (i + d) % args.wrap;
                // +1 must not wrap round a row's end into the next row's
                // first column: that pair is adjacent in ARITHMETIC only.
                if d == 1 && (i % args.stride) == args.stride - 1 {
                    continue;
                }
                if shown.contains(&j) && drawn.insert((i, j)) {
                    writeln!(out, "  R{i} {arrow} R{j}").unwrap();
                }
            }
        }
        for &i in &shown {
            if !built.contains(&i) {
                writeln!(out, "  style R{i} stroke-dasharray: 4 3").unwrap();
            }
        }
        writeln!(out, "```\n").unwrap();
    }

    writeln!(out, "## Room index\n").unwrap();
    writeln!(
        out,
        "| room | name | built | art | coins | actors | proximity triggers |\n\
         |---|---|---|---|---|---|---|"
    )
    .unwrap();
    for &i in &live {
        writeln!(
            out,
            "| {i} | {} | {} | {} | {} | {} | {} |",
            special.get(&i).cloned().unwrap_or_else(|| label(i)),
            if built.contains(&i) { "yes" } else { "" },
            things.get(&i).copied().unwrap_or(0),
            per_room_coins.get(&i).map(|n| n.to_string()).unwrap_or_default(),
            per_room_actors.get(&i).map(|v| v.join(", ")).unwrap_or_default(),
            per_room_trig.get(&i).map(|v| v.join(", ")).unwrap_or_default(),
        )
        .unwrap();
    }

    fs::write(&args.output, out).expect("write map");
    println!(
        "mapped {} live rooms ({} named, {} built) -> {}",
        live.len(),
        name.len(),
        built.len(),
        args.output.display()
    );
}

fn neighbours(i: usize, stride: usize, wrap: usize) -> Vec<usize> {
    let mut v = vec![(i + stride) % wrap, (i + wrap - stride) % wrap];
    if i % stride != stride - 1 {
        v.push((i + 1) % wrap);
    }
    if i % stride != 0 {
        v.push(i - 1);
    }
    v
}
