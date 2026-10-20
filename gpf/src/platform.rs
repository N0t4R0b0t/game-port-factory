use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::Path;

/// A target platform's capability profile. Loaded from factory/platforms/*.toml.
#[derive(Debug, Deserialize)]
pub struct Platform {
    pub id: String,
    pub name: String,
    pub year: u32,
    pub memory_kb: u32,
    pub axes: BTreeMap<String, String>,
}

/// The transfer axes, and what actually travels along each one when two
/// platforms share a value. This is the core of the model: a port is not
/// "cheaper" as a single number — different artifacts transfer independently.
pub const AXES: [(&str, &str); 6] = [
    ("cpu", "code, hand-written routines, optimisation technique"),
    ("raster", "silhouette + detail budget, sprite dimensions, animation frame counts"),
    ("color", "palette choices, clash strategy, dithering approach"),
    ("audio", "music arrangement, sfx design"),
    ("storage", "loading strategy, disk/tape layout, streaming design"),
    ("memory_tier", "scope reduction, asset budget, paging design"),
];

/// Memory tiers bucket platforms by what scope reduction they force. Two
/// platforms in the same bucket can share design decisions about what to cut.
pub fn memory_tier(kb: u32) -> &'static str {
    match kb {
        0..=4 => "micro",
        5..=24 => "tiny",
        25..=128 => "small",
        129..=1024 => "medium",
        _ => "large",
    }
}

impl Platform {
    /// Axis value, with memory_tier synthesised from memory_kb.
    pub fn axis(&self, name: &str) -> String {
        if name == "memory_tier" {
            return memory_tier(self.memory_kb).to_string();
        }
        self.axes.get(name).cloned().unwrap_or_else(|| "?".into())
    }
}

pub fn load_all(root: &Path) -> Result<Vec<Platform>, String> {
    let dir = root.join("factory").join("platforms");
    let mut out = Vec::new();
    let entries = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for e in entries.filter_map(|e| e.ok()) {
        let p = e.path();
        if p.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let s = std::fs::read_to_string(&p).map_err(|e| e.to_string())?;
        let plat: Platform =
            toml::from_str(&s).map_err(|e| format!("{}: {e}", p.display()))?;
        out.push(plat);
    }
    out.sort_by(|a, b| b.memory_kb.cmp(&a.memory_kb));
    Ok(out)
}

pub fn get<'a>(all: &'a [Platform], id: &str) -> Result<&'a Platform, String> {
    all.iter()
        .find(|p| p.id == id)
        .ok_or_else(|| format!("unknown platform '{id}'"))
}

/// Axis-by-axis transfer report between two platforms.
pub fn transfer(from: &Platform, to: &Platform) -> Vec<(&'static str, bool, String, &'static str)> {
    AXES.iter()
        .map(|(axis, what)| {
            let a = from.axis(axis);
            let b = to.axis(axis);
            (*axis, a == b, format!("{a} -> {b}"), *what)
        })
        .collect()
}

/// Greedy ordering: start with the most capable target (authoring against the
/// most forgiving constraints first, then reducing), then repeatedly take the
/// platform sharing the most axes with everything already done.
pub fn plan<'a>(all: &'a [Platform], ids: &[String]) -> Result<Vec<(&'a Platform, usize)>, String> {
    let mut remaining: Vec<&Platform> = ids
        .iter()
        .map(|id| get(all, id))
        .collect::<Result<_, _>>()?;
    if remaining.is_empty() {
        return Err("no targets given".into());
    }
    // Seed: largest memory. `load_all` already sorted descending.
    let seed_idx = remaining
        .iter()
        .enumerate()
        .max_by_key(|(_, p)| p.memory_kb)
        .map(|(i, _)| i)
        .unwrap();
    let mut done: Vec<&Platform> = vec![remaining.remove(seed_idx)];
    let mut out = vec![(done[0], 0usize)];

    while !remaining.is_empty() {
        // Best = shares the most axes with any single already-done platform.
        let (idx, score) = remaining
            .iter()
            .enumerate()
            .map(|(i, cand)| {
                let best = done
                    .iter()
                    .map(|d| {
                        AXES.iter()
                            .filter(|(axis, _)| d.axis(axis) == cand.axis(axis))
                            .count()
                    })
                    .max()
                    .unwrap_or(0);
                (i, best)
            })
            .max_by_key(|(_, s)| *s)
            .unwrap();
        let p = remaining.remove(idx);
        done.push(p);
        out.push((p, score));
    }
    Ok(out)
}
