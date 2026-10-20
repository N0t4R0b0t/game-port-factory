//! Local-model advisor. Reports what is installed, what the hardware can actually
//! run, and what is worth pulling — and refuses to pull anything that will not fit.
//!
//! Consent is the caller's job; feasibility is this module's job.

use serde::Deserialize;
use std::path::Path;
use std::process::Command;

/// Headroom multiplier over the model's on-disk size, covering KV cache and
/// context. A model that only just fits in VRAM will thrash or spill to CPU.
const VRAM_HEADROOM: f64 = 1.25;
/// Never fill the model partition completely.
const DISK_MARGIN_GB: f64 = 10.0;

#[derive(Debug, Deserialize)]
struct Roster {
    #[serde(default)]
    model: Vec<Recommended>,
}

#[derive(Debug, Deserialize)]
struct Recommended {
    name: String,
    role: String,
    size_gb: f64,
    why: String,
}

pub struct Resources {
    pub ram_total_gb: f64,
    pub ram_avail_gb: f64,
    pub vram_total_gb: f64,
    pub vram_free_gb: f64,
    pub gpu_name: String,
    pub store: String,
    pub disk_free_gb: f64,
}

fn meminfo_gb(key: &str) -> f64 {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with(key))
                .and_then(|l| l.split_whitespace().nth(1)?.parse::<f64>().ok())
        })
        .map(|kb| kb / 1024.0 / 1024.0)
        .unwrap_or(0.0)
}

/// ollama's model store, which is often NOT ~/.ollama when it runs as a service.
fn resolve_store() -> String {
    if let Ok(v) = std::env::var("OLLAMA_MODELS") {
        if !v.is_empty() {
            return v;
        }
    }
    if let Ok(out) = Command::new("systemctl").args(["show", "ollama", "-p", "Environment"]).output() {
        let s = String::from_utf8_lossy(&out.stdout);
        for tok in s.split_whitespace() {
            if let Some(v) = tok.strip_prefix("OLLAMA_MODELS=") {
                return v.to_string();
            }
        }
    }
    format!("{}/.ollama/models", std::env::var("HOME").unwrap_or_default())
}

fn disk_free_gb(path: &str) -> f64 {
    Command::new("df")
        .args(["-BG", "--output=avail", path])
        .output()
        .ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .nth(1)?
                .trim()
                .trim_end_matches('G')
                .parse::<f64>()
                .ok()
        })
        .unwrap_or(0.0)
}

pub fn resources() -> Resources {
    let mut gpu_name = "none detected".to_string();
    let (mut vram_total, mut vram_free) = (0.0, 0.0);
    if let Ok(o) = Command::new("nvidia-smi")
        .args(["--query-gpu=name,memory.total,memory.free", "--format=csv,noheader,nounits"])
        .output()
    {
        let s = String::from_utf8_lossy(&o.stdout);
        if let Some(line) = s.lines().next() {
            let f: Vec<&str> = line.split(',').map(|x| x.trim()).collect();
            if f.len() >= 3 {
                gpu_name = f[0].to_string();
                vram_total = f[1].parse::<f64>().unwrap_or(0.0) / 1024.0;
                vram_free = f[2].parse::<f64>().unwrap_or(0.0) / 1024.0;
            }
        }
    }
    let store = resolve_store();
    Resources {
        ram_total_gb: meminfo_gb("MemTotal"),
        ram_avail_gb: meminfo_gb("MemAvailable"),
        vram_total_gb: vram_total,
        vram_free_gb: vram_free,
        gpu_name,
        disk_free_gb: disk_free_gb(&store),
        store,
    }
}

/// Installed model names, via the HTTP API (the CLI corrupts piped output).
pub fn installed() -> Vec<String> {
    let out = Command::new("curl")
        .args(["-s", "--max-time", "5", "http://localhost:11434/api/tags"])
        .output();
    let body = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => return Vec::new(),
    };
    // Minimal extraction — avoids a JSON dependency for one field.
    let mut names = Vec::new();
    for part in body.split("\"name\":\"").skip(1) {
        if let Some(end) = part.find('"') {
            names.push(part[..end].to_string());
        }
    }
    names
}

/// Tag-exact. Matching on the base name alone would report `qwen2.5:14b` as
/// installed merely because `qwen2.5:7b` is — a false positive that silently
/// skips a pull the user actually needs.
fn is_installed(installed: &[String], name: &str) -> bool {
    if name.contains(':') {
        return installed.iter().any(|i| i == name);
    }
    let with_latest = format!("{name}:latest");
    installed.iter().any(|i| i == name || i == &with_latest)
}

/// Feasibility verdict for one model on this hardware.
pub enum Fit {
    Installed,
    GpuResident,
    /// Fits total VRAM but not what is free right now — a desktop is using some.
    GpuIfIdle,
    CpuOffload,
    NoDisk,
    TooBig,
}

impl Fit {
    pub fn label(&self) -> &'static str {
        match self {
            Fit::Installed => "INSTALLED",
            Fit::GpuResident => "fits GPU",
            Fit::GpuIfIdle => "fits GPU if idle",
            Fit::CpuOffload => "CPU/partial — slow",
            Fit::NoDisk => "NO DISK",
            Fit::TooBig => "won't run",
        }
    }
}

pub fn fit(r: &Resources, size_gb: f64, already: bool) -> Fit {
    if already {
        return Fit::Installed;
    }
    if size_gb > r.disk_free_gb - DISK_MARGIN_GB {
        return Fit::NoDisk;
    }
    if size_gb * VRAM_HEADROOM <= r.vram_free_gb {
        return Fit::GpuResident;
    }
    // Free VRAM fluctuates with whatever the desktop is doing; judging against
    // total avoids a misleading "won't fit" for a model that fits a quiet GPU.
    if size_gb * VRAM_HEADROOM <= r.vram_total_gb {
        return Fit::GpuIfIdle;
    }
    if size_gb * VRAM_HEADROOM <= r.ram_avail_gb {
        return Fit::CpuOffload;
    }
    Fit::TooBig
}

pub fn report(root: &Path) -> Result<(), String> {
    let path = root.join("factory").join("models.toml");
    let s = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let roster: Roster = toml::from_str(&s).map_err(|e| e.to_string())?;
    let r = resources();
    let inst = installed();

    println!("=== resources ===");
    println!("GPU        {} — {:.1} GB VRAM ({:.1} GB free)", r.gpu_name, r.vram_total_gb, r.vram_free_gb);
    println!("RAM        {:.1} GB total ({:.1} GB available)", r.ram_total_gb, r.ram_avail_gb);
    println!("store      {} ({:.0} GB free)", r.store, r.disk_free_gb);
    if inst.is_empty() {
        println!("ollama     NOT REACHABLE at localhost:11434 — is the service running?");
    } else {
        println!("ollama     {} model(s) installed", inst.len());
    }

    println!("\n=== roster ===");
    let mut pulls: Vec<(&str, f64, &str)> = Vec::new();
    for m in &roster.model {
        let already = is_installed(&inst, &m.name);
        let f = fit(&r, m.size_gb, already);
        println!("{:<22} {:<10} {:>5.1} GB  {:<20} {}", m.name, m.role, m.size_gb, f.label(), m.why);
        if matches!(f, Fit::GpuResident | Fit::GpuIfIdle | Fit::CpuOffload) {
            pulls.push((&m.name, m.size_gb, f.label()));
        }
    }

    if pulls.is_empty() {
        println!("\nNothing worth pulling — roster is either installed or won't fit.");
        return Ok(());
    }
    let total: f64 = pulls.iter().map(|(_, s, _)| s).sum();
    println!("\n=== suggested pulls ({:.1} GB total) ===", total);
    for (name, size, fitlabel) in &pulls {
        println!("  ollama pull {name:<22} # {size:.1} GB, {fitlabel}");
    }
    println!("\nNOT pulled. These are multi-GB downloads — ask the user before running any of");
    println!("them, then use `gpf models --pull <name>`, which re-checks resources first.");
    Ok(())
}

/// Pull one model, but only after re-verifying it fits. Consent is the caller's
/// responsibility; this refuses the physically impossible.
pub fn pull(root: &Path, name: &str) -> Result<(), String> {
    let path = root.join("factory").join("models.toml");
    let s = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let roster: Roster = toml::from_str(&s).map_err(|e| e.to_string())?;
    let m = roster
        .model
        .iter()
        .find(|m| m.name == name)
        .ok_or_else(|| format!("'{name}' is not in factory/models.toml — add it there first, with a size and a reason"))?;
    let r = resources();
    let already = is_installed(&installed(), name);
    match fit(&r, m.size_gb, already) {
        Fit::Installed => {
            println!("{name} is already installed.");
            return Ok(());
        }
        Fit::NoDisk => {
            return Err(format!(
                "refusing: {name} needs {:.1} GB, only {:.0} GB free at {} (keeping {DISK_MARGIN_GB:.0} GB margin)",
                m.size_gb, r.disk_free_gb, r.store
            ))
        }
        Fit::TooBig => {
            return Err(format!(
                "refusing: {name} ({:.1} GB) exceeds both VRAM ({:.1} GB free) and available RAM ({:.1} GB)",
                m.size_gb, r.vram_free_gb, r.ram_avail_gb
            ))
        }
        Fit::GpuIfIdle => println!("note: {name} fits VRAM only when the GPU is otherwise idle ({:.1} GB free of {:.1} GB now).", r.vram_free_gb, r.vram_total_gb),
        Fit::CpuOffload => println!("warning: {name} will not fit in VRAM ({:.1} GB free) — expect CPU offload and slow inference.", r.vram_free_gb),
        Fit::GpuResident => println!("{name} fits in VRAM. Pulling {:.1} GB...", m.size_gb),
    }
    let st = Command::new("ollama")
        .args(["pull", name])
        .status()
        .map_err(|e| format!("could not run ollama: {e}"))?;
    if !st.success() {
        return Err(format!("ollama pull {name} failed"));
    }
    println!("pulled {name}");
    Ok(())
}
