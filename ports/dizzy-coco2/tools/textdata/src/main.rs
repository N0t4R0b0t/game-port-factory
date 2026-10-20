//! Extracts quoted string literals (game text: room titles, on-screen
//! messages, dialogue) directly out of the vendored Z80 source files,
//! rather than decoding the `prtmessage` control-code bytecode that
//! actually renders them.
//!
//! Ground truth from `EDITOR/PRTMESS.ASM` (the message-print routine): each
//! message is a byte stream mixing control codes (0=end, 1=set x/y,
//! 2=set pen colour, 3=plot char/attr, 4=gosub, 5/6=repeat/endrepeat,
//! 7/8=move x/move y, 150+=embedded sprite) with literal character bytes
//! (code>=16, printed via a font-table lookup after `sub 32`). Decoding
//! that bytecode losslessly (positions, colors, embedded icons) is real
//! recover-stage work — not attempted here.
//!
//! What IS directly extractable without touching the bytecode: the source
//! embeds visible text as plain ASCII inside `"..."` quoted literals right
//! alongside the control-code bytes (e.g. `defb mxy+19,49,mpen+3,
//! "FANTASY:WORLD"` — confirmed in PRTDIZZY.PDS's title-screen block, and
//! matching the `info/rooms` room-title convention). This tool scans every
//! given file character-by-character (not line-by-line, so a `;` inside a
//! quoted string — used as an apostrophe, e.g. "SMUGGLER;S:HIDEOUT" — is
//! never mistaken for a PDS comment marker) and collects every quoted span.
//!
//! Confirmed character substitutions used in these strings (matched against
//! `info/rooms`' documented room names): `:` = space, `;` = apostrophe.
//! `@` also appears in some strings (e.g. "GOING:DOWN:THE:WELL@") but its
//! meaning isn't confirmed (a font glyph? fixed-width padding?) — left
//! untouched in `decoded`, flagged in `raw` for whoever tackles the font
//! table next.

use clap::Parser;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Files to scan for quoted string literals
    inputs: Vec<PathBuf>,

    #[arg(long)]
    output: PathBuf,
}

#[derive(Serialize)]
struct StringLiteral {
    file: String,
    line: usize,
    raw: String,
    decoded: String,
}

fn decode(raw: &str) -> String {
    raw.chars()
        .map(|c| match c {
            ':' => ' ',
            ';' => '\'',
            other => other,
        })
        .collect()
}

fn extract_from_file(path: &PathBuf) -> Vec<StringLiteral> {
    let text = fs::read_to_string(path).unwrap_or_default();
    let file_name = path.display().to_string();
    let mut out = Vec::new();

    let mut line_no = 1usize;
    let mut in_quotes = false;
    let mut current = String::new();
    let mut current_line = 1usize;

    for c in text.chars() {
        if c == '\n' {
            line_no += 1;
        }
        if c == '"' {
            if in_quotes {
                // closing quote: emit only plausible game text. A real
                // `defb "..."` literal never spans a line break, and these
                // are 32-column-display strings, so anything containing a
                // newline or implausibly long is a stray unmatched `"`
                // inside a comment (or a `'` used as an apostrophe
                // confusing the span), not real text — observed several
                // such multi-hundred/thousand-char spans on the first pass.
                if current.chars().count() >= 2
                    && current.chars().count() <= 60
                    && !current.contains('\n')
                {
                    out.push(StringLiteral {
                        file: file_name.clone(),
                        line: current_line,
                        raw: current.clone(),
                        decoded: decode(&current),
                    });
                }
                current.clear();
                in_quotes = false;
            } else {
                in_quotes = true;
                current_line = line_no;
            }
            continue;
        }
        if in_quotes {
            current.push(c);
        }
    }
    out
}

fn main() {
    let args = Args::parse();
    let mut all = Vec::new();
    for input in &args.inputs {
        all.extend(extract_from_file(input));
    }
    // De-duplicate identical (decoded) strings while keeping first occurrence's
    // file/line as provenance — the same literal (e.g. a reused icon label)
    // can appear more than once across the source.
    let mut seen = std::collections::HashSet::new();
    all.retain(|s| seen.insert(s.decoded.clone()));

    fs::write(&args.output, serde_json::to_string_pretty(&all).unwrap()).expect("write output");
    println!("extracted {} unique string literals -> {}", all.len(), args.output.display());
}
