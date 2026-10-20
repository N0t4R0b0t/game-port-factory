# Game assets are not included

The MIT license in `LICENSE` covers the code, tools, harnesses and documentation in this
repository. It does **not** cover any game.

- **No game data is distributed here.** No original code, art, music, text or level data
  from any game, and no tape/disk images or built binaries.
- *Fantasy World Dizzy* (1989) is copyright of its authors and publisher. "Dizzy" and
  related names are trademarks of Oliver Twins Ltd and Codemasters. This project is
  unaffiliated with and unendorsed by them.
- The Oliver Twins' released source and data for the game (Wireframe #19, redistributed in
  `picosonic/D3`) remain their copyrighted material. **They are not in this repository and
  never will be.** The Dizzy port builds from them only when *you* supply them.
- Supplying them: `ports/dizzy-coco2/tools/inputs.toml` lists every input with its sha256 and
  where it comes from, and `ports/dizzy-coco2/tools/bootstrap.sh` verifies each file, refuses
  anything that does not match, and never downloads. See
  [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md#the-golden-example-build-dizzy-from-your-own-copy).
  The Tandy CoCo ROMs (to run the result) and a Spectrum ROM and tape (only for the
  original-vs-port harnesses) are likewise yours to supply.
- Everything the bootstrap generates (extracted data, converted art, music captures, the
  filled-in text, and the final tape/disk images) is written to gitignored paths and is never
  committed. The build is reproducible: your artifacts must match
  `ports/dizzy-coco2/docs/BUILD-HASHES.txt` byte for byte.

## Text policy

**Running dialogue and message text from the original is never quoted in a tracked file** (docs,
comments, notes, task text, harness data, test fixtures). **Identifiers may be named**: room titles, item
names and UI labels such as FANTASY WORLD, for identification. Refer to a message by its source line
(`[X-ALL.TXT line 733]`, or the key `X-ALL:733`), never by its words. Which strings are which is decided by
source region in `ports/dizzy-coco2/tools/textsplit/categories.txt` (room table, item table, UI boxes versus
the `PEOPLE TALKING` / `DOING THINGS` / `ALL DEAD` message sections; unknown lines count as messages).
Harness scripts that need the real strings for a pixel or text comparison read them from the generated,
gitignored `harness/orig_text.lua`, never from literals.

Work only from media you own.
