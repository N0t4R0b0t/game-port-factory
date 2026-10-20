use brickfall_model::Scenario;
use std::{env, fs, path::Path, process::exit};

fn load(p: &Path) -> Scenario {
    let t = fs::read_to_string(p).unwrap_or_else(|e| {
        eprintln!("{}: {e}", p.display());
        exit(2)
    });
    Scenario::parse(&t).unwrap_or_else(|e| {
        eprintln!("{}: {e}", p.display());
        exit(2)
    })
}

fn main() {
    let a: Vec<String> = env::args().skip(1).collect();
    match a.as_slice() {
        [c, f] if c == "run" => print!("{}", load(Path::new(f)).trace()),
        [c, dir] if c == "--golden" => {
            // scenarios dir is ../scenarios relative to the model crate; golden goes to <dir>
            let sdir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scenarios");
            fs::create_dir_all(dir).unwrap();
            let mut names: Vec<_> = fs::read_dir(&sdir)
                .unwrap()
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().map_or(false, |x| x == "toml"))
                .collect();
            names.sort();
            for p in names {
                let out = Path::new(dir).join(p.file_stem().unwrap()).with_extension("trace");
                fs::write(&out, load(&p).trace()).unwrap();
                println!("wrote {}", out.display());
            }
        }
        _ => {
            eprintln!("usage: brickfall-model run <scenario.toml> | --golden <dir>");
            exit(2)
        }
    }
}
