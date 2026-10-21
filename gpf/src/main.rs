mod model;
mod models;
mod platform;
mod seeds;

use clap::{Parser, Subcommand};
use model::*;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(name = "gpf", about = "Game Port Factory — on-disk state for resumable porting projects")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a new port project under ports/<slug>/
    Init {
        slug: String,
        #[arg(long)]
        title: String,
        /// Game id; ports of the same game share games/<game>/recipe/
        #[arg(long, default_value = "")]
        game: String,
        /// Source platform (optional only with --original)
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        target: String,
        /// Original game with no source binary to excavate: seeds a design/oracle
        /// task list, strategy=reimplement, stage=scaffold
        #[arg(long)]
        original: bool,
        /// Also seed the public-release chain (provenance audit, inputs manifest,
        /// bootstrap, hash list, export gates, clean-clone proof), modelled on
        /// ports/dizzy-coco2. With --original only the subset that applies is seeded
        /// (no user-supplied media, so no inputs manifest and no original-text gate).
        #[arg(long)]
        public: bool,
    },
    /// List all port projects and their stage
    List,
    /// Full state dump for a port — run this FIRST in every session
    Status { slug: String },
    /// Print the single next actionable task
    Next { slug: String },
    /// Set the current stage
    Stage { slug: String, stage: String },
    /// Set the porting strategy
    Strategy { slug: String, strategy: String },
    /// Record what the next session should do. Run this LAST in every session.
    Handoff {
        slug: String,
        message: String,
        #[arg(long, default_value = "")]
        blocked_on: String,
    },
    /// Append a line to the port's SESSION-LOG.md
    Log { slug: String, message: String },
    /// List known target platforms and their capability axes
    Platforms,
    /// What transfers between two platforms, axis by axis
    Transfer { from: String, to: String },
    /// Order a set of targets to maximise reuse
    Plan {
        /// Comma-separated platform ids
        targets: String,
    },
    /// Record a reusable decision in factory/recipes/. Carries its preconditions
    /// so a later port can check whether it still applies.
    Decide {
        #[arg(long)]
        title: String,
        #[arg(long)]
        axis: String,
        #[arg(long)]
        because: String,
        #[arg(long, default_value = "")]
        precondition: String,
    },
    /// End-of-session extraction gate. Run BEFORE handoff.
    Harvest { slug: String },
    /// Local-model advisor: what is installed, what fits this hardware, what to pull.
    Models {
        /// Pull one roster model after re-checking resources. ASK THE USER FIRST.
        #[arg(long, default_value = "")]
        pull: String,
    },
    /// Manage tasks
    #[command(subcommand)]
    Task(TaskCmd),
}

#[derive(Subcommand)]
enum TaskCmd {
    Add {
        slug: String,
        #[arg(long)]
        stage: String,
        #[arg(long)]
        title: String,
        /// Comma-separated task ids this depends on
        #[arg(long, default_value = "")]
        depends: String,
        /// Cheapest tier believed capable: local | haiku | sonnet | opus
        #[arg(long, default_value = "sonnet")]
        tier: String,
        /// Shell command that proves the work correct
        #[arg(long, default_value = "")]
        verify: String,
    },
    /// Edit a task in place (id, dependencies and notes are preserved)
    Edit {
        slug: String,
        id: String,
        #[arg(long)]
        title: Option<String>,
        /// local | haiku | sonnet | opus
        #[arg(long)]
        tier: Option<String>,
        /// Shell command that proves the work correct
        #[arg(long)]
        verify: Option<String>,
        #[arg(long)]
        stage: Option<String>,
        /// APPEND text to the task's note (joined with " | " to any existing note;
        /// never replaces). Escalate and block still set the note.
        #[arg(long)]
        note: Option<String>,
    },
    Start { slug: String, id: String },
    /// Mark a task done. With --run-verify, first run its verify string.
    Done {
        slug: String,
        id: String,
        /// Run the task's verify command (`sh -c`, from the repo root); refuse to
        /// mark done on a nonzero exit (exit code 1, tail of output printed) and
        /// record the result in SESSION-LOG.md. Error if the task has no verify.
        #[arg(long)]
        run_verify: bool,
    },
    Block {
        slug: String,
        id: String,
        #[arg(long, default_value = "")]
        note: String,
    },
    /// A lower tier hit a wall — hand the task up, carrying the reason.
    Escalate {
        slug: String,
        id: String,
        #[arg(long)]
        reason: String,
    },
    List { slug: String },
}

fn main() {
    if let Err(e) = run() {
        eprintln!("gpf: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let cli = Cli::parse();
    let root = find_root()?;
    match cli.cmd {
        Cmd::Init { slug, title, game, source, target, original, public } => {
            let n = init(&root, &slug, &title, &game, source.as_deref(), &target, original, public)?;
            println!("created ports/{slug}/ with {n} seeded tasks");
            println!("next: gpf status {slug}");
            Ok(())
        }
        Cmd::Platforms => platforms(&root),
        Cmd::Transfer { from, to } => transfer(&root, &from, &to),
        Cmd::Plan { targets } => plan(&root, &targets),
        Cmd::Decide { title, axis, because, precondition } => {
            decide(&root, &title, &axis, &because, &precondition)
        }
        Cmd::Harvest { slug } => harvest(&root, &slug),
        Cmd::Models { pull } => {
            if pull.is_empty() {
                models::report(&root)
            } else {
                models::pull(&root, &pull)
            }
        }
        Cmd::List => list(&root),
        Cmd::Status { slug } => status(&root, &slug),
        Cmd::Next { slug } => next(&root, &slug),
        Cmd::Stage { slug, stage } => set_stage(&root, &slug, &stage),
        Cmd::Strategy { slug, strategy } => set_strategy(&root, &slug, &strategy),
        Cmd::Handoff { slug, message, blocked_on } => handoff(&root, &slug, &message, &blocked_on),
        Cmd::Log { slug, message } => {
            log_line(&root, &slug, &message)?;
            println!("logged.");
            Ok(())
        }
        Cmd::Task(t) => task(&root, t),
    }
}

/// Walk up from cwd looking for the .gpf-root marker, then fall back to
/// $GPF_ROOT so the binary is usable from anywhere once it is on PATH.
fn find_root() -> Result<PathBuf, String> {
    let mut d = std::env::current_dir().map_err(|e| e.to_string())?;
    loop {
        if d.join(".gpf-root").exists() {
            return Ok(d);
        }
        if !d.pop() {
            break;
        }
    }
    if let Ok(v) = std::env::var("GPF_ROOT") {
        let p = PathBuf::from(&v);
        if p.join(".gpf-root").exists() {
            return Ok(p);
        }
        return Err(format!("$GPF_ROOT is set to '{v}' but there is no .gpf-root marker there"));
    }
    Err("not inside a game-port-factory repo. Either cd into it, or set GPF_ROOT \
         (e.g. export GPF_ROOT=~/projects/game-port-factory)"
        .into())
}

fn port_dir(root: &Path, slug: &str) -> PathBuf {
    root.join("ports").join(slug)
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

fn load_port(root: &Path, slug: &str) -> Result<PortFile, String> {
    let p = port_dir(root, slug).join("PORT.toml");
    let s = fs::read_to_string(&p).map_err(|_| format!("no such port '{slug}' ({})", p.display()))?;
    toml::from_str(&s).map_err(|e| format!("PORT.toml parse error: {e}"))
}

fn save_port(root: &Path, slug: &str, pf: &PortFile) -> Result<(), String> {
    let s = toml::to_string_pretty(pf).map_err(|e| e.to_string())?;
    fs::write(port_dir(root, slug).join("PORT.toml"), s).map_err(|e| e.to_string())
}

fn load_tasks(root: &Path, slug: &str) -> Result<TaskFile, String> {
    let p = port_dir(root, slug).join("tasks.toml");
    let s = fs::read_to_string(&p).unwrap_or_default();
    toml::from_str(&s).map_err(|e| format!("tasks.toml parse error: {e}"))
}

fn save_tasks(root: &Path, slug: &str, tf: &TaskFile) -> Result<(), String> {
    let s = toml::to_string_pretty(tf).map_err(|e| e.to_string())?;
    fs::write(port_dir(root, slug).join("tasks.toml"), s).map_err(|e| e.to_string())
}

fn log_line(root: &Path, slug: &str, msg: &str) -> Result<(), String> {
    use std::io::Write;
    let p = port_dir(root, slug).join("SESSION-LOG.md");
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
        .map_err(|e| e.to_string())?;
    writeln!(f, "- {} — {}", today(), msg).map_err(|e| e.to_string())
}

const RECIPE_STUB: &str = "# {game} — platform-neutral recipe\n\n\
    Shared by every port of this game. Fill these in; ports diff against the reference model.\n\n\
    ## Rules\n\n_TBD_\n\n\
    ## State contract (the harness interface)\n\n_TBD_\n\n\
    ## Input contract\n\n_TBD_\n\n\
    ## Acceptance (what \"done\" means for a port)\n\n_TBD_\n";

/// Create a port. Returns the number of seeded tasks. Pure w.r.t. stdout.
///
/// Directories: only what the mode uses, because git drops empty ones.
/// harness/ and target/ always (each gets a .gitkeep so they survive a clone);
/// a normal port (with a binary to excavate) also gets source/ and extracted/
/// (gitignored, no .gitkeep) and research/ (tracked notes live there, so it gets one).
#[allow(clippy::too_many_arguments)]
fn init(
    root: &Path,
    slug: &str,
    title: &str,
    game: &str,
    source: Option<&str>,
    target: &str,
    original: bool,
    public: bool,
) -> Result<usize, String> {
    let source = match (source, original) {
        (Some(s), _) => s,
        (None, true) => target,
        (None, false) => return Err("--source is required (it is optional only with --original)".into()),
    };
    let dir = port_dir(root, slug);
    if dir.exists() {
        return Err(format!("port '{slug}' already exists"));
    }
    let mut subdirs = vec!["harness", "target"];
    if !original {
        subdirs.extend(["source", "extracted", "research"]);
    }
    for sub in subdirs {
        fs::create_dir_all(dir.join(sub)).map_err(|e| e.to_string())?;
        if matches!(sub, "harness" | "target" | "research") {
            fs::write(dir.join(sub).join(".gitkeep"), "").map_err(|e| e.to_string())?;
        }
    }
    let game = if game.is_empty() { slug.to_string() } else { game.to_string() };
    let recipe_dir = root.join("games").join(&game).join("recipe");
    let recipe_readme = recipe_dir.join("README.md");
    // A second port of the same game inherits the recipe and reference model.
    // An unfilled stub (still carrying the generator's `_TBD_` markers) does not count.
    let recipe_exists = original
        && fs::read_to_string(&recipe_readme).map(|b| !b.contains("_TBD_")).unwrap_or(false);

    let base = if original { seeds::original() } else { seeds::standard(slug) };
    let seed = if public { seeds::chain(base, seeds::public(slug, original)) } else { base };

    let mut tf = TaskFile::default();
    let mut ids: Vec<(&str, String)> = Vec::new();
    for sd in &seed {
        let id = tf.next_id();
        ids.push((sd.key, id.clone()));
        let depends_on = sd
            .deps
            .iter()
            .map(|d| ids.iter().find(|(k, _)| k == d).map(|(_, i)| i.clone()).expect("seed deps are ordered"))
            .collect();
        let mut t = Task {
            id,
            stage: sd.stage.into(),
            title: sd.title.clone(),
            status: "todo".into(),
            depends_on,
            note: sd.note.clone(),
            tier: sd.tier.into(),
            verify: sd.verify.clone(),
            attempts: 0,
        };
        if recipe_exists && matches!(sd.key, "recipe" | "refmodel") {
            t.status = "done".into();
            t.note = format!(
                "pre-closed by gpf init: games/{game}/recipe/README.md already exists (a previous port of this game). \
                 Re-read it and the shared reference model/goldens under games/{game}/recipe/ before relying on them."
            );
        }
        tf.tasks.push(t);
    }

    let next_action = if recipe_exists {
        let first = tf.next().map(|t| format!("{}: {}", t.id, t.title)).unwrap_or_default();
        format!(
            "Original game, second port: games/{game}/recipe/ already exists, so the recipe and reference-model tasks are pre-closed. Start with {first}"
        )
    } else if original {
        "Original game: no excavation. Start with T0001 (write the recipe spec), T0003 (toolchain) can run in parallel.".into()
    } else {
        "Run stage 1 (identify). Start with T0001.".into()
    };
    let pf = PortFile {
        port: Port {
            slug: slug.into(),
            title: title.into(),
            game: game.clone(),
            created: today(),
            source_platform: source.into(),
            target_platform: target.into(),
            strategy: if original { "reimplement" } else { "unknown" }.into(),
            stage: if original { "scaffold" } else { "identify" }.into(),
        },
        status: Status { next_action, blocked_on: String::new(), last_session: today() },
    };
    save_port(root, slug, &pf)?;
    save_tasks(root, slug, &tf)?;

    let sections = if original {
        "## Design notes\n\n_Original design: no source binary. Rules live in games/<game>/recipe/._\n\n\
         ## Toolchain\n\n_TBD_\n\n"
    } else {
        "## Source inventory\n\n_TBD — task T0001_\n\n\
         ## Engine / toolchain\n\n_TBD — task T0002_\n\n\
         ## Prior art\n\n_TBD — task T0003_\n\n\
         ## State addresses (oracle)\n\n_TBD — state addresses_ (found with `gpfdiff watch`; record the command and the evidence)\n\n"
    };
    fs::write(
        dir.join("NOTES.md"),
        format!(
            "# {title}\n\n\
             `{source}` -> `{target}`\n\n\
             Durable findings only. Anything you would be annoyed to re-derive in three weeks\n\
             goes here: file format notes, memory maps, addresses, gotchas, dead ends and WHY\n\
             they were dead.\n\n\
             {sections}\
             ## Format notes\n\n\
             ## Dead ends\n"
        ),
    )
    .map_err(|e| e.to_string())?;

    fs::write(
        dir.join("SESSION-LOG.md"),
        format!("# Session log — {title}\n\nAppend-only. One line per session, newest at the bottom.\n\n"),
    )
    .map_err(|e| e.to_string())?;
    log_line(root, slug, "port initialised")?;
    if original {
        log_line(root, slug, "strategy -> reimplement (original design: no source binary to excavate); stage -> scaffold")?;
        if recipe_exists {
            log_line(root, slug, &format!("games/{game}/recipe/README.md exists: recipe and reference-model tasks pre-closed"))?;
        } else {
            fs::create_dir_all(&recipe_dir).map_err(|e| e.to_string())?;
            fs::write(&recipe_readme, RECIPE_STUB.replace("{game}", &game)).map_err(|e| e.to_string())?;
        }
    }
    if public {
        if original {
            log_line(root, slug, "--public with --original: seeded the subset that applies (no user-supplied media: no inputs manifest, no original-text gate)")?;
        } else {
            log_line(root, slug, "--public: seeded the public-release chain (model: ports/dizzy-coco2)")?;
        }
    }
    Ok(tf.tasks.len())
}

fn list(root: &Path) -> Result<(), String> {
    let dir = root.join("ports");
    let mut found = false;
    let mut entries: Vec<_> = fs::read_dir(&dir)
        .map_err(|e| e.to_string())?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| !n.starts_with('.'))
        .collect();
    entries.sort();
    for slug in entries {
        if let Ok(pf) = load_port(root, &slug) {
            let tf = load_tasks(root, &slug).unwrap_or_default();
            println!(
                "{:<24} {:<10} {:<12} {}/{} done",
                pf.port.slug,
                pf.port.stage,
                pf.port.strategy,
                tf.count("done"),
                tf.tasks.len()
            );
            found = true;
        }
    }
    if !found {
        println!("no ports yet. create one:\n  gpf init <slug> --title <t> --source <plat> --target <plat>");
    }
    Ok(())
}

fn status(root: &Path, slug: &str) -> Result<(), String> {
    let pf = load_port(root, slug)?;
    let tf = load_tasks(root, slug)?;
    println!("=== {} ({}) ===", pf.port.title, pf.port.slug);
    println!("{} -> {}", pf.port.source_platform, pf.port.target_platform);
    println!("stage:    {}", pf.port.stage);
    println!("strategy: {}", pf.port.strategy);
    println!(
        "tasks:    {} todo / {} doing / {} blocked / {} done  (of {})",
        tf.count("todo"),
        tf.count("doing"),
        tf.count("blocked"),
        tf.count("done"),
        tf.tasks.len()
    );
    println!("last:     {}", pf.status.last_session);
    if !pf.status.blocked_on.is_empty() {
        println!("\n!! BLOCKED ON: {}", pf.status.blocked_on);
    }
    println!("\nHANDOFF FROM LAST SESSION:\n  {}", pf.status.next_action);
    match tf.next() {
        Some(t) => println!(
            "\nNEXT TASK:\n  [{}] ({}) {}\n  tier={} verify={}",
            t.id,
            t.stage,
            t.title,
            t.tier,
            if t.verify.is_empty() { "none" } else { &t.verify }
        ),
        None => println!("\nNEXT TASK:\n  none actionable — add tasks or unblock something"),
    }
    Ok(())
}

fn next(root: &Path, slug: &str) -> Result<(), String> {
    let tf = load_tasks(root, slug)?;
    match tf.next() {
        Some(t) => {
            println!("[{}] ({}) {}", t.id, t.stage, t.title);
            println!("tier: {}{}", t.tier, if t.attempts > 0 { format!("  (escalated {}x)", t.attempts) } else { String::new() });
            if t.verify.is_empty() {
                println!("verify: NONE — no machine check, so do not push this below its tier");
            } else {
                println!("verify: {}", t.verify);
            }
            if !t.note.is_empty() {
                println!("note: {}", t.note);
            }
        }
        None => println!("no actionable task"),
    }
    Ok(())
}

fn set_stage(root: &Path, slug: &str, stage: &str) -> Result<(), String> {
    if !STAGES.contains(&stage) {
        return Err(format!("unknown stage '{stage}'. one of: {}", STAGES.join(", ")));
    }
    let mut pf = load_port(root, slug)?;
    pf.port.stage = stage.into();
    save_port(root, slug, &pf)?;
    log_line(root, slug, &format!("stage -> {stage}"))?;
    println!("stage = {stage}");
    Ok(())
}

fn set_strategy(root: &Path, slug: &str, strategy: &str) -> Result<(), String> {
    if !STRATEGIES.contains(&strategy) {
        return Err(format!("unknown strategy '{strategy}'. one of: {}", STRATEGIES.join(", ")));
    }
    let mut pf = load_port(root, slug)?;
    pf.port.strategy = strategy.into();
    save_port(root, slug, &pf)?;
    log_line(root, slug, &format!("strategy -> {strategy}"))?;
    println!("strategy = {strategy}");
    Ok(())
}

fn handoff(root: &Path, slug: &str, message: &str, blocked_on: &str) -> Result<(), String> {
    let mut pf = load_port(root, slug)?;
    pf.status.next_action = message.into();
    pf.status.blocked_on = blocked_on.into();
    pf.status.last_session = today();
    save_port(root, slug, &pf)?;
    log_line(root, slug, &format!("handoff: {message}"))?;
    println!("handoff recorded.");
    Ok(())
}

fn task(root: &Path, cmd: TaskCmd) -> Result<(), String> {
    match cmd {
        TaskCmd::Escalate { slug, id, reason } => escalate(root, &slug, &id, &reason),
        TaskCmd::Add { slug, stage, title, depends, tier, verify } => {
            let id = task_add(root, &slug, &stage, &title, &depends, &tier, &verify)?;
            println!("added {id}: {title}");
            Ok(())
        }
        TaskCmd::Edit { slug, id, title, tier, verify, stage, note } => {
            let changes = task_edit(root, &slug, &id, title, tier, verify, stage, note)?;
            println!("{id} edited: {changes}");
            Ok(())
        }
        TaskCmd::Start { slug, id } => set_task_status(root, &slug, &id, "doing", ""),
        TaskCmd::Done { slug, id, run_verify } => {
            if run_verify {
                run_task_verify(root, &slug, &id)?;
            }
            set_task_status(root, &slug, &id, "done", "")
        }
        TaskCmd::Block { slug, id, note } => set_task_status(root, &slug, &id, "blocked", &note),
        TaskCmd::List { slug } => {
            let tf = load_tasks(root, &slug)?;
            let rank = |s: &str| STAGES.iter().position(|x| *x == s).unwrap_or(usize::MAX);
            let mut ts: Vec<&Task> = tf.tasks.iter().collect();
            ts.sort_by_key(|t| (rank(&t.stage), t.id.clone()));
            for t in ts {
                let mark = match t.status.as_str() {
                    "done" => "x",
                    "doing" => ">",
                    "blocked" => "!",
                    _ => " ",
                };
                let deps = if t.depends_on.is_empty() {
                    String::new()
                } else {
                    format!("  <- {}", t.depends_on.join(","))
                };
                println!("[{}] {} {:<10} {:<7} {}{}", mark, t.id, t.stage, t.tier, t.title, deps);
                if !t.note.is_empty() {
                    println!("      note: {}", t.note);
                }
            }
            Ok(())
        }
    }
}

fn task_add(
    root: &Path,
    slug: &str,
    stage: &str,
    title: &str,
    depends: &str,
    tier: &str,
    verify: &str,
) -> Result<String, String> {
    if !TIERS.contains(&tier) {
        return Err(format!("unknown tier '{tier}'. one of: {}", TIERS.join(", ")));
    }
    if !STAGES.contains(&stage) {
        return Err(format!("unknown stage '{stage}'. one of: {}", STAGES.join(", ")));
    }
    let mut tf = load_tasks(root, slug)?;
    let id = tf.next_id();
    let deps: Vec<String> = depends
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    for d in &deps {
        if !tf.tasks.iter().any(|t| &t.id == d) {
            return Err(format!("dependency '{d}' does not exist"));
        }
    }
    tf.tasks.push(Task {
        id: id.clone(),
        stage: stage.into(),
        title: title.into(),
        status: "todo".into(),
        depends_on: deps,
        note: String::new(),
        tier: tier.into(),
        verify: verify.into(),
        attempts: 0,
    });
    save_tasks(root, slug, &tf)?;
    Ok(id)
}

/// Edit fields of a task in place. Validates everything before writing.
fn task_edit(
    root: &Path,
    slug: &str,
    id: &str,
    title: Option<String>,
    tier: Option<String>,
    verify: Option<String>,
    stage: Option<String>,
    note: Option<String>,
) -> Result<String, String> {
    if title.is_none() && tier.is_none() && verify.is_none() && stage.is_none() && note.is_none() {
        return Err("nothing to edit: give at least one of --title --tier --verify --stage --note".into());
    }
    if let Some(t) = &tier {
        if !TIERS.contains(&t.as_str()) {
            return Err(format!("unknown tier '{t}'. one of: {}", TIERS.join(", ")));
        }
    }
    if let Some(s) = &stage {
        if !STAGES.contains(&s.as_str()) {
            return Err(format!("unknown stage '{s}'. one of: {}", STAGES.join(", ")));
        }
    }
    let mut tf = load_tasks(root, slug)?;
    let t = tf
        .tasks
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or_else(|| format!("no task '{id}'"))?;
    let mut parts = Vec::new();
    if let Some(v) = title {
        parts.push(format!("title '{}' -> '{v}'", t.title));
        t.title = v;
    }
    if let Some(v) = tier {
        parts.push(format!("tier {} -> {v}", t.tier));
        t.tier = v;
    }
    if let Some(v) = verify {
        parts.push(format!("verify '{}' -> '{v}'", t.verify));
        t.verify = v;
    }
    if let Some(v) = stage {
        parts.push(format!("stage {} -> {v}", t.stage));
        t.stage = v;
    }
    if let Some(v) = note {
        t.note = if t.note.is_empty() { v.clone() } else { format!("{} | {v}", t.note) };
        parts.push(format!("note += '{v}'"));
    }
    let summary = parts.join("; ");
    save_tasks(root, slug, &tf)?;
    log_line(root, slug, &format!("{id} edited: {summary}"))?;
    Ok(summary)
}

/// Run a task's verify string (`sh -c`, cwd = repo root). Ok only on exit 0.
/// The outcome goes to SESSION-LOG.md either way; a failure prints the output tail.
fn run_task_verify(root: &Path, slug: &str, id: &str) -> Result<(), String> {
    let tf = load_tasks(root, slug)?;
    let t = tf.tasks.iter().find(|t| t.id == id).ok_or_else(|| format!("no task '{id}'"))?;
    if t.verify.trim().is_empty() {
        return Err(format!(
            "{id} has no verify command, so --run-verify has nothing to run. \
             Set one with `gpf task edit {slug} {id} --verify '<cmd>'`, or mark it done without --run-verify"
        ));
    }
    let cmd = t.verify.clone();
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(&cmd)
        .current_dir(root)
        .output()
        .map_err(|e| format!("could not run sh: {e}"))?;
    if out.status.success() {
        log_line(root, slug, &format!("{id} verify PASSED: {cmd}"))?;
        println!("{id} verify passed: {cmd}");
        return Ok(());
    }
    let code = out.status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into());
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    let lines: Vec<&str> = text.lines().collect();
    let tail = lines[lines.len().saturating_sub(20)..].join("\n");
    log_line(root, slug, &format!("{id} verify FAILED (exit {code}): {cmd}"))?;
    Err(format!("{id} verify FAILED (exit {code}): {cmd}\n--- last output ---\n{tail}\n{id} NOT marked done"))
}

fn set_task_status(root: &Path, slug: &str, id: &str, status: &str, note: &str) -> Result<(), String> {
    debug_assert!(STATUSES.contains(&status));
    let mut tf = load_tasks(root, slug)?;
    let t = tf
        .tasks
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or_else(|| format!("no task '{id}'"))?;
    t.status = status.into();
    if !note.is_empty() {
        t.note = note.into();
    }
    let title = t.title.clone();
    save_tasks(root, slug, &tf)?;
    log_line(root, slug, &format!("{id} -> {status} ({title})"))?;
    println!("{id} = {status}");
    Ok(())
}

// ---------------------------------------------------------------------------
// Factory-level commands: platform capability model and knowledge capture.
// ---------------------------------------------------------------------------

fn platforms(root: &Path) -> Result<(), String> {
    let all = platform::load_all(root)?;
    println!(
        "{:<16} {:>5} {:>7}  {:<6} {:<16} {:<18} {:<8} {}",
        "id", "year", "mem KB", "cpu", "raster", "color", "audio", "storage"
    );
    for p in &all {
        println!(
            "{:<16} {:>5} {:>7}  {:<6} {:<16} {:<18} {:<8} {}",
            p.id,
            p.year,
            p.memory_kb,
            p.axis("cpu"),
            p.axis("raster"),
            p.axis("color"),
            p.axis("audio"),
            p.axis("storage")
        );
    }
    Ok(())
}

fn transfer(root: &Path, from: &str, to: &str) -> Result<(), String> {
    let all = platform::load_all(root)?;
    let a = platform::get(&all, from)?;
    let b = platform::get(&all, to)?;
    println!("{} -> {}\n", a.name, b.name);
    let rows = platform::transfer(a, b);
    let carried = rows.iter().filter(|(_, same, _, _)| *same).count();
    for (axis, same, delta, what) in &rows {
        let mark = if *same { "CARRIES " } else { "re-derive" };
        println!("{mark}  {axis:<12} {delta}");
        println!("            {what}");
    }
    println!("\n{carried}/{} axes carry.", rows.len());
    Ok(())
}

fn plan(root: &Path, targets: &str) -> Result<(), String> {
    let all = platform::load_all(root)?;
    let ids: Vec<String> = targets
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let ordered = platform::plan(&all, &ids)?;
    println!("Suggested port order (most capable first, then maximise carry-over):\n");
    for (i, (p, score)) in ordered.iter().enumerate() {
        if i == 0 {
            println!("{}. {:<28} seed — author against this one first", i + 1, p.name);
        } else {
            println!("{}. {:<28} carries {} axes from an earlier target", i + 1, p.name, score);
        }
    }
    println!("\nPer-hop detail:");
    for w in ordered.windows(2) {
        let (a, _) = w[0];
        let (b, _) = w[1];
        let rows = platform::transfer(a, b);
        let carried: Vec<&str> = rows
            .iter()
            .filter(|(_, same, _, _)| *same)
            .map(|(axis, _, _, _)| *axis)
            .collect();
        println!(
            "  {} -> {}: carries [{}]",
            a.id,
            b.id,
            if carried.is_empty() { "nothing".into() } else { carried.join(", ") }
        );
    }
    Ok(())
}

fn slugify(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn decide(root: &Path, title: &str, axis: &str, because: &str, precondition: &str) -> Result<(), String> {
    let known: Vec<&str> = platform::AXES.iter().map(|(a, _)| *a).collect();
    if !known.contains(&axis) {
        return Err(format!("unknown axis '{axis}'. one of: {}", known.join(", ")));
    }
    let dir = root.join("factory").join("recipes");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(format!("{}.md", slugify(title)));
    if path.exists() {
        return Err(format!("recipe already exists: {}", path.display()));
    }
    let body = format!(
        "# {title}\n\n\
         - **axis:** `{axis}` — this decision travels to any platform sharing that axis value\n\
         - **recorded:** {}\n\n\
         ## Decision\n\n{because}\n\n\
         ## Precondition\n\n{}\n\n\
         A later port MUST check this precondition before reusing the decision. If it does\n\
         not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.\n\n\
         ## Outcome\n\n_Fill in after the port ships: did this hold up?_\n",
        today(),
        if precondition.is_empty() { "_UNSTATED — this recipe is unsafe to reuse until filled in._" } else { precondition }
    );
    fs::write(&path, body).map_err(|e| e.to_string())?;
    println!("recorded factory/recipes/{}.md", slugify(title));
    Ok(())
}

fn harvest(root: &Path, slug: &str) -> Result<(), String> {
    let pf = load_port(root, slug)?;
    let local_tools = port_dir(root, slug).join("tools");
    let mut local: Vec<String> = Vec::new();
    if local_tools.exists() {
        local = fs::read_dir(&local_tools)
            .map_err(|e| e.to_string())?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
    }
    let recipes = root.join("factory").join("recipes");
    // README.md is scaffolding, not a recipe.
    let n_recipes = fs::read_dir(&recipes)
        .map(|d| {
            d.filter_map(|e| e.ok())
                .filter(|e| {
                    let n = e.file_name().to_string_lossy().to_string();
                    n.ends_with(".md") && n != "README.md"
                })
                .count()
        })
        .unwrap_or(0);

    println!("=== HARVEST: {} ===\n", pf.port.title);
    println!("Track 2 runs alongside the port. Answer all four before `gpf handoff`.\n");
    println!("1. TOOL — did you write anything this session that a later port would want?");
    if local.is_empty() {
        println!("     ports/{slug}/tools/ is empty.");
    } else {
        println!("     ports/{slug}/tools/ holds: {}", local.join(", "));
        println!("     RULE OF TWO: promote to factory/tools/ only when a SECOND port needs it.");
    }
    println!("\n2. DECISION — did you make a judgement call that will recur?");
    println!("     gpf decide --title <t> --axis <axis> --because <why> --precondition <when it holds>");
    println!("     factory/recipes/ currently holds {n_recipes} recipe(s).");
    println!("\n3. DEAD END — did something not work? Record it in NOTES.md with the REASON.");
    println!("     An unrecorded dead end gets retried by a future session. That is the");
    println!("     most expensive kind of forgetting.");
    println!("\n4. FRICTION — did the factory itself get in your way?");
    println!("     Fix it now, or add a task. The factory is the other deliverable.");
    Ok(())
}

/// Hand a task up a tier, carrying the reason. Escalations are appended to
/// factory/escalations.log — they are the feedback signal for the routing table.
/// A task class that keeps escalating was mis-tiered, and that is worth knowing.
fn escalate(root: &Path, slug: &str, id: &str, reason: &str) -> Result<(), String> {
    use std::io::Write;
    let mut tf = load_tasks(root, slug)?;
    let t = tf
        .tasks
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or_else(|| format!("no task '{id}'"))?;
    let from = t.tier.clone();
    let to = next_tier(&from)
        .ok_or_else(|| format!("{id} is already at the top tier ('{from}') — this needs a human, not a bigger model"))?;
    t.tier = to.into();
    t.attempts += 1;
    t.status = "todo".into();
    // The reason must survive: escalating without it just buys a retry at a
    // higher price, since the next tier restarts from zero.
    t.note = format!("escalated from {from}: {reason}");
    let title = t.title.clone();
    let attempts = t.attempts;
    save_tasks(root, slug, &tf)?;

    let logp = root.join("factory").join("escalations.log");
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&logp)
        .map_err(|e| e.to_string())?;
    writeln!(f, "{}\t{slug}\t{id}\t{from}->{to}\tattempt={attempts}\t{reason}", today())
        .map_err(|e| e.to_string())?;

    log_line(root, slug, &format!("{id} escalated {from}->{to}: {reason}"))?;
    println!("{id} '{title}' escalated {from} -> {to} (attempt {attempts})");
    println!("reason carried into task note so the next tier does not restart cold.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("gpf-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(p.join("ports")).unwrap();
        fs::write(p.join(".gpf-root"), "").unwrap();
        p
    }

    fn mk(root: &Path) {
        init(root, "demo-c64", "Demo", "demo", Some("c64"), "c64", false, false).unwrap();
    }

    #[test]
    fn toml_roundtrip_port_and_tasks() {
        let root = temp_root("roundtrip");
        mk(&root);
        let pf = load_port(&root, "demo-c64").unwrap();
        save_port(&root, "demo-c64", &pf).unwrap();
        let pf2 = load_port(&root, "demo-c64").unwrap();
        assert_eq!(format!("{pf:?}"), format!("{pf2:?}"));
        let tf = load_tasks(&root, "demo-c64").unwrap();
        save_tasks(&root, "demo-c64", &tf).unwrap();
        assert_eq!(format!("{tf:?}"), format!("{:?}", load_tasks(&root, "demo-c64").unwrap()));
    }

    #[test]
    fn legacy_toml_defaults_load() {
        let tf: TaskFile = toml::from_str("[[tasks]]\nid='T0001'\nstage='identify'\ntitle='x'\nstatus='todo'\n").unwrap();
        assert_eq!(tf.tasks[0].tier, "sonnet");
        assert_eq!(tf.tasks[0].attempts, 0);
        let pf: PortFile = toml::from_str(
            "[port]\nslug='a'\ntitle='A'\ncreated='2020-01-01'\nsource_platform='x'\ntarget_platform='y'\n",
        )
        .unwrap();
        assert_eq!(pf.port.strategy, "unknown");
        assert_eq!(pf.port.stage, "identify");
    }

    #[test]
    fn init_normal() {
        let root = temp_root("init-normal");
        assert_eq!(init(&root, "demo-c64", "Demo", "", Some("zx"), "c64", false, false).unwrap(), 11);
        let pf = load_port(&root, "demo-c64").unwrap();
        assert_eq!(pf.port.stage, "identify");
        assert_eq!(pf.port.strategy, "unknown");
        assert_eq!(pf.port.source_platform, "zx");
        assert_eq!(pf.port.game, "demo-c64");
        assert!(!root.join("games").exists());
        assert!(init(&root, "demo-c64", "Demo", "", Some("zx"), "c64", false, false).unwrap_err().contains("already exists"));
    }

    #[test]
    fn init_requires_source_unless_original() {
        let root = temp_root("init-nosrc");
        let e = init(&root, "d", "D", "", None, "c64", false, false).unwrap_err();
        assert!(e.contains("--source"));
        assert!(!port_dir(&root, "d").exists());
    }

    #[test]
    fn init_original() {
        let root = temp_root("init-original");
        let n = init(&root, "demo-c64", "Demo", "demo", None, "c64", true, false).unwrap();
        assert_eq!(n, 6);
        let pf = load_port(&root, "demo-c64").unwrap();
        assert_eq!(pf.port.stage, "scaffold");
        assert_eq!(pf.port.strategy, "reimplement");
        assert_eq!(pf.port.source_platform, "c64");
        let tf = load_tasks(&root, "demo-c64").unwrap();
        for t in &tf.tasks {
            let l = t.title.to_lowercase();
            assert!(!l.contains("inventory") && !l.contains("fingerprint") && !l.contains("prior art"), "{}", t.title);
            assert!(t.verify.is_empty());
            assert!(STAGES.contains(&t.stage.as_str()) && TIERS.contains(&t.tier.as_str()));
            for d in &t.depends_on {
                assert!(tf.tasks.iter().any(|x| &x.id == d));
            }
        }
        assert_eq!(tf.tasks[1].tier, "sonnet"); // reference model oracle
        assert_eq!(tf.next().unwrap().id, "T0001"); // earliest stage (recover) first
        let log = fs::read_to_string(port_dir(&root, "demo-c64").join("SESSION-LOG.md")).unwrap();
        assert!(log.contains("original design"));
        let readme = root.join("games/demo/recipe/README.md");
        let body = fs::read_to_string(&readme).unwrap();
        assert!(body.contains("## Rules") && body.contains("## State contract") && body.contains("## Acceptance"));
    }

    #[test]
    fn init_original_never_overwrites_recipe() {
        let root = temp_root("init-recipe");
        let r = root.join("games/demo/recipe");
        fs::create_dir_all(&r).unwrap();
        fs::write(r.join("README.md"), "MINE").unwrap();
        init(&root, "demo-c64", "Demo", "demo", None, "c64", true, false).unwrap();
        init(&root, "demo-zx", "Demo", "demo", None, "zx", true, false).unwrap();
        assert_eq!(fs::read_to_string(r.join("README.md")).unwrap(), "MINE");
    }

    #[test]
    fn task_transitions_and_dependency_gating() {
        let root = temp_root("gating");
        mk(&root);
        let s = "demo-c64";
        // T0001 and T0003 have no deps; T0002 needs T0001.
        let tf = load_tasks(&root, s).unwrap();
        let t2 = tf.tasks.iter().find(|t| t.id == "T0002").unwrap();
        assert!(!tf.is_actionable(t2));
        assert_eq!(tf.next().unwrap().id, "T0001");
        set_task_status(&root, s, "T0001", "doing", "").unwrap();
        assert_eq!(load_tasks(&root, s).unwrap().next().unwrap().id, "T0001"); // doing wins
        set_task_status(&root, s, "T0001", "done", "").unwrap();
        let tf = load_tasks(&root, s).unwrap();
        assert!(tf.is_actionable(tf.tasks.iter().find(|t| t.id == "T0002").unwrap()));
        assert_eq!(tf.count("done"), 1);
        set_task_status(&root, s, "T0002", "blocked", "why").unwrap();
        let tf = load_tasks(&root, s).unwrap();
        assert_eq!(tf.tasks[1].status, "blocked");
        assert_eq!(tf.tasks[1].note, "why");
        assert!(!tf.is_actionable(&tf.tasks[1]));
        assert!(set_task_status(&root, s, "T9999", "done", "").unwrap_err().contains("no task"));
    }

    #[test]
    fn task_add_cases() {
        let root = temp_root("add");
        mk(&root);
        let s = "demo-c64";
        let id = task_add(&root, s, "slice", "new", "T0001, T0002", "haiku", "true").unwrap();
        assert_eq!(id, "T0012");
        let tf = load_tasks(&root, s).unwrap();
        let t = tf.tasks.last().unwrap();
        assert_eq!(t.depends_on, vec!["T0001", "T0002"]);
        assert_eq!(t.verify, "true");
        assert!(task_add(&root, s, "slice", "x", "T0099", "haiku", "").unwrap_err().contains("does not exist"));
        assert!(task_add(&root, s, "bogus", "x", "", "haiku", "").unwrap_err().contains("unknown stage"));
        assert!(task_add(&root, s, "slice", "x", "", "gpt", "").unwrap_err().contains("unknown tier"));
        assert_eq!(load_tasks(&root, s).unwrap().tasks.len(), 12);
    }

    #[test]
    fn task_edit_in_place() {
        let root = temp_root("edit");
        mk(&root);
        let s = "demo-c64";
        set_task_status(&root, s, "T0002", "blocked", "keep me").unwrap();
        let before = load_tasks(&root, s).unwrap();
        task_edit(&root, s, "T0002", Some("new title".into()), Some("opus".into()), Some("true".into()), Some("recover".into()), None).unwrap();
        let after = load_tasks(&root, s).unwrap();
        assert_eq!(after.tasks.len(), before.tasks.len());
        let (b, a) = (&before.tasks[1], &after.tasks[1]);
        assert_eq!((a.title.as_str(), a.tier.as_str(), a.verify.as_str(), a.stage.as_str()), ("new title", "opus", "true", "recover"));
        assert_eq!((&a.id, &a.depends_on, &a.note, &a.status), (&b.id, &b.depends_on, &b.note, &b.status));
        // partial edit leaves other fields alone
        task_edit(&root, s, "T0002", None, Some("haiku".into()), None, None, None).unwrap();
        let a = &load_tasks(&root, s).unwrap().tasks[1];
        assert_eq!((a.title.as_str(), a.tier.as_str(), a.verify.as_str()), ("new title", "haiku", "true"));
        let log = fs::read_to_string(port_dir(&root, s).join("SESSION-LOG.md")).unwrap();
        assert!(log.contains("T0002 edited"));
    }

    #[test]
    fn task_edit_errors_do_not_write() {
        let root = temp_root("edit-err");
        mk(&root);
        let s = "demo-c64";
        let p = port_dir(&root, s).join("tasks.toml");
        let before = fs::read_to_string(&p).unwrap();
        assert!(task_edit(&root, s, "T0099", Some("x".into()), None, None, None, None).unwrap_err().contains("no task"));
        assert!(task_edit(&root, s, "T0001", None, Some("gpt".into()), None, None, None).unwrap_err().contains("unknown tier"));
        assert!(task_edit(&root, s, "T0001", Some("x".into()), None, None, Some("nope".into()), None).unwrap_err().contains("unknown stage"));
        assert!(task_edit(&root, s, "T0001", None, None, None, None, None).unwrap_err().contains("nothing to edit"));
        assert_eq!(fs::read_to_string(&p).unwrap(), before);
    }

    #[test]
    fn unknown_port_errors() {
        let root = temp_root("noport");
        assert!(load_port(&root, "nope").unwrap_err().contains("no such port"));
        assert!(set_stage(&root, "nope", "slice").is_err());
        assert!(set_stage(&root, "nope", "bogus").unwrap_err().contains("unknown stage"));
    }

    fn ids_of(tf: &TaskFile) -> Vec<String> {
        tf.tasks.iter().map(|t| t.id.clone()).collect()
    }

    #[test]
    fn init_normal_oracle_chain_and_dirs() {
        let root = temp_root("oracle");
        init(&root, "demo-zx", "Demo", "demo", Some("zx"), "c64", false, false).unwrap();
        let tf = load_tasks(&root, "demo-zx").unwrap();
        assert_eq!(tf.tasks.len(), 11);
        assert!(!tf.tasks.iter().any(|t| t.title.starts_with("Stand up differential harness")));
        let t = |n: usize| &tf.tasks[n - 1];
        assert_eq!((t(7).tier.as_str(), t(10).tier.as_str(), t(11).tier.as_str()), ("sonnet", "sonnet", "opus"));
        assert_eq!(t(8).depends_on, vec!["T0007"]);
        assert_eq!(t(7).depends_on, vec!["T0003", "T0006"]); // prior art + toolchain
        assert!(t(8).verify.contains("gpfdiff capture ports/demo-zx") && t(11).verify.contains("gpfdiff check ports/demo-zx") && t(10).verify.contains("Diff triage"));
        assert_eq!(t(11).depends_on, vec!["T0010"]);
        assert!(t(8).title.contains("ports/demo-zx/harness.toml"));
        let ids = ids_of(&tf);
        assert!(tf.tasks.iter().all(|t| t.depends_on.iter().all(|d| ids.contains(d))));
        let d = port_dir(&root, "demo-zx");
        for sub in ["harness", "target", "source", "extracted", "research"] {
            assert!(d.join(sub).is_dir(), "{sub}");
        }
        assert!(d.join("harness/.gitkeep").exists() && d.join("target/.gitkeep").exists());
        assert!(fs::read_to_string(d.join("NOTES.md")).unwrap().contains("State addresses (oracle)"));
        // no --public: no release chain
        assert!(!tf.tasks.iter().any(|t| t.title.contains("Public")));
    }

    #[test]
    fn init_original_dirs_minimal() {
        let root = temp_root("orig-dirs");
        init(&root, "demo-c64", "Demo", "demo", None, "c64", true, false).unwrap();
        let d = port_dir(&root, "demo-c64");
        assert!(d.join("harness/.gitkeep").exists() && d.join("target/.gitkeep").exists());
        for sub in ["source", "extracted", "research"] {
            assert!(!d.join(sub).exists(), "{sub}");
        }
    }

    #[test]
    fn init_public_adds_chain() {
        let root = temp_root("public");
        let n = init(&root, "demo-zx", "Demo", "demo", Some("zx"), "c64", false, true).unwrap();
        let tf = load_tasks(&root, "demo-zx").unwrap();
        assert_eq!(n, 11 + 6);
        let last: Vec<_> = tf.tasks[11..].iter().map(|t| t.title.as_str()).collect();
        assert!(last[0].contains("provenance audit") && last[1].contains("inputs manifest"));
        assert!(last.iter().any(|t| t.contains("no original text and no binaries")));
        assert!(last.last().unwrap().contains("clean-clone"));
        assert!(tf.tasks.last().unwrap().verify.contains("bootstrap.sh --verify"));
        let ids = ids_of(&tf);
        assert!(tf.tasks.iter().all(|t| t.depends_on.iter().all(|d| ids.contains(d))));
        let log = fs::read_to_string(port_dir(&root, "demo-zx").join("SESSION-LOG.md")).unwrap();
        assert!(log.contains("--public"));
    }

    #[test]
    fn init_public_original_is_subset() {
        let root = temp_root("public-orig");
        let n = init(&root, "demo-c64", "Demo", "demo", None, "c64", true, true).unwrap();
        assert_eq!(n, 6 + 5);
        let tf = load_tasks(&root, "demo-c64").unwrap();
        assert!(!tf.tasks.iter().any(|t| t.title.contains("inputs manifest") || t.title.contains("original text")));
        assert!(tf.tasks.iter().any(|t| t.note.contains("--original")));
        let log = fs::read_to_string(port_dir(&root, "demo-c64").join("SESSION-LOG.md")).unwrap();
        assert!(log.contains("no user-supplied media"));
    }

    #[test]
    fn second_original_port_preclosed() {
        let root = temp_root("second");
        init(&root, "demo-c64", "Demo", "demo", None, "c64", true, false).unwrap();
        let first = load_port(&root, "demo-c64").unwrap();
        assert!(first.status.next_action.contains("T0001 (write the recipe spec)"));
        // the first port left only the generated stub: a second port is NOT pre-closed
        init(&root, "demo-stub", "Demo", "demo", None, "zx", true, false).unwrap();
        assert_eq!(load_tasks(&root, "demo-stub").unwrap().tasks[0].status, "todo");
        // once the recipe is really written, it is
        fs::write(root.join("games/demo/recipe/README.md"), "# Demo\n\nreal rules\n").unwrap();
        init(&root, "demo-zx", "Demo", "demo", None, "zx", true, false).unwrap();
        let tf = load_tasks(&root, "demo-zx").unwrap();
        assert_eq!((tf.tasks[0].status.as_str(), tf.tasks[1].status.as_str()), ("done", "done"));
        assert!(tf.tasks[0].note.contains("pre-closed"));
        assert_eq!(tf.tasks[2].status, "todo");
        let pf = load_port(&root, "demo-zx").unwrap();
        assert!(!pf.status.next_action.contains("write the recipe"));
        assert!(pf.status.next_action.contains("T0003"));
        assert_eq!(tf.next().unwrap().id, "T0003");
        assert_eq!(tf.count("done"), 2);
    }

    #[test]
    fn task_edit_note_appends() {
        let root = temp_root("note");
        mk(&root);
        let s = "demo-c64";
        task_edit(&root, s, "T0001", None, None, None, None, Some("first".into())).unwrap();
        task_edit(&root, s, "T0001", None, None, None, None, Some("second".into())).unwrap();
        let tf = load_tasks(&root, s).unwrap();
        assert_eq!(tf.tasks[0].note, "first | second");
        assert_eq!(tf.tasks[0].title, "Inventory and hash source files; record exact versions/regions in NOTES.md");
    }

    #[test]
    fn run_verify_pass_fail_and_empty() {
        let root = temp_root("verify");
        mk(&root);
        let s = "demo-c64";
        // empty verify is an error with a clear message
        let e = run_task_verify(&root, s, "T0001").unwrap_err();
        assert!(e.contains("no verify command"), "{e}");
        // passing: runs from the repo root
        fs::write(root.join("marker.txt"), "x").unwrap();
        task_edit(&root, s, "T0001", None, None, Some("test -f marker.txt".into()), None, None).unwrap();
        run_task_verify(&root, s, "T0001").unwrap();
        // failing: nonzero exit, output tail reported, status untouched
        task_edit(&root, s, "T0002", None, None, Some("echo boom-line; echo err-line >&2; exit 3".into()), None, None).unwrap();
        let e = run_task_verify(&root, s, "T0002").unwrap_err();
        assert!(e.contains("exit 3") && e.contains("boom-line") && e.contains("err-line") && e.contains("NOT marked done"), "{e}");
        assert_eq!(load_tasks(&root, s).unwrap().tasks[1].status, "todo");
        let log = fs::read_to_string(port_dir(&root, s).join("SESSION-LOG.md")).unwrap();
        assert!(log.contains("T0001 verify PASSED") && log.contains("T0002 verify FAILED (exit 3)"));
    }

    #[test]
    fn run_verify_tail_is_bounded() {
        let root = temp_root("verify-tail");
        mk(&root);
        task_edit(&root, "demo-c64", "T0001", None, None, Some("seq 1 100; exit 1".into()), None, None).unwrap();
        let e = run_task_verify(&root, "demo-c64", "T0001").unwrap_err();
        assert!(e.contains("\n100\n") && e.contains("\n81\n") && !e.contains("\n80\n"), "{e}");
    }
}
