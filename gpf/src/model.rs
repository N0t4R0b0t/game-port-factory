use serde::{Deserialize, Serialize};

/// The seven stages every port passes through. Order matters: `gpf next` prefers
/// tasks in the earliest incomplete stage.
pub const STAGES: [&str; 7] = [
    "identify",  // 1. what is this, what engine, who has done work on it already
    "classify",  // 2. pick the porting strategy — see docs/STRATEGY.md
    "excavate",  // 3. unpack containers, convert assets to neutral intermediates
    "recover",   // 4. recover game logic (disasm/decomp/read source)
    "scaffold",  // 5. toolchain, emulator, build, hello-world on target
    "slice",     // 6. vertical slice — smallest playable/demoable thing
    "iterate",   // 7. grow the slice, diff against original, repeat
];

pub const STATUSES: [&str; 4] = ["todo", "doing", "done", "blocked"];

/// The three porting strategies. Choosing wrong is the most expensive mistake
/// available, which is why `classify` is its own stage.
pub const STRATEGIES: [&str; 4] = [
    "source-port",  // source exists — retarget it. Cheapest by far.
    "recompile",    // binary -> static recompilation. Requires target >= source in power.
    "reimplement",  // assets port, logic is rewritten against the original as reference.
    "unknown",      // not yet classified
];

#[derive(Debug, Serialize, Deserialize)]
pub struct PortFile {
    pub port: Port,
    #[serde(default)]
    pub status: Status,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Port {
    pub slug: String,
    pub title: String,
    /// The game this port belongs to. Several ports of one game share a
    /// platform-neutral recipe under games/<game>/recipe/.
    #[serde(default)]
    pub game: String,
    pub created: String,
    pub source_platform: String,
    pub target_platform: String,
    #[serde(default = "unknown_strategy")]
    pub strategy: String,
    #[serde(default = "first_stage")]
    pub stage: String,
}

fn unknown_strategy() -> String {
    "unknown".into()
}
fn first_stage() -> String {
    STAGES[0].into()
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Status {
    /// Free text written at the END of every session. This is the single most
    /// important field in the repo — it is what a cold session reads first.
    #[serde(default)]
    pub next_action: String,
    #[serde(default)]
    pub blocked_on: String,
    #[serde(default)]
    pub last_session: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct TaskFile {
    #[serde(default)]
    pub tasks: Vec<Task>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub stage: String,
    pub title: String,
    pub status: String,
    #[serde(default)]
    pub depends_on: Vec<String>,
    #[serde(default)]
    pub note: String,
    /// Cheapest tier believed capable of this task. See docs/COST-MODEL.md.
    #[serde(default = "default_tier")]
    pub tier: String,
    /// Shell command that PROVES the work is correct. A task with a verifier can
    /// be pushed down a tier safely, because a wrong answer is caught by machine
    /// rather than by the weak model noticing its own mistake.
    #[serde(default)]
    pub verify: String,
    /// Escalation count. Non-zero means a lower tier failed this task.
    #[serde(default)]
    pub attempts: u32,
}

fn default_tier() -> String {
    "sonnet".into()
}

/// Ordered cheapest-first. Escalation walks this list upward.
pub const TIERS: [&str; 4] = ["local", "haiku", "sonnet", "opus"];

pub fn next_tier(current: &str) -> Option<&'static str> {
    let i = TIERS.iter().position(|t| *t == current)?;
    TIERS.get(i + 1).copied()
}

impl TaskFile {
    /// A task is actionable when it is `todo` and every dependency is `done`.
    pub fn is_actionable(&self, t: &Task) -> bool {
        t.status == "todo"
            && t.depends_on.iter().all(|d| {
                self.tasks
                    .iter()
                    .find(|x| &x.id == d)
                    .map(|x| x.status == "done")
                    .unwrap_or(false)
            })
    }

    /// Next task to work on: earliest stage first, then declaration order.
    pub fn next(&self) -> Option<&Task> {
        // An in-flight task always wins — finish what a previous session started.
        if let Some(t) = self.tasks.iter().find(|t| t.status == "doing") {
            return Some(t);
        }
        let rank = |s: &str| STAGES.iter().position(|x| *x == s).unwrap_or(usize::MAX);
        self.tasks
            .iter()
            .filter(|t| self.is_actionable(t))
            .min_by_key(|t| rank(&t.stage))
    }

    pub fn next_id(&self) -> String {
        let n = self
            .tasks
            .iter()
            .filter_map(|t| t.id.trim_start_matches('T').parse::<u32>().ok())
            .max()
            .unwrap_or(0);
        format!("T{:04}", n + 1)
    }

    pub fn count(&self, status: &str) -> usize {
        self.tasks.iter().filter(|t| t.status == status).count()
    }
}
