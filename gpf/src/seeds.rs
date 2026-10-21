//! Opening task lists seeded by `gpf init`. Tasks refer to each other by key;
//! keys are resolved to T-ids in declaration order when the list is written.

pub struct Seed {
    pub key: &'static str,
    pub stage: &'static str,
    pub title: String,
    pub deps: Vec<&'static str>,
    pub tier: &'static str,
    pub verify: String,
    pub note: String,
}

fn s(key: &'static str, stage: &'static str, title: &str, deps: &[&'static str], tier: &'static str) -> Seed {
    Seed { key, stage, title: title.into(), deps: deps.to_vec(), tier, verify: String::new(), note: String::new() }
}

impl Seed {
    fn verify(mut self, v: String) -> Self {
        self.verify = v;
        self
    }
    fn note(mut self, n: &str) -> Self {
        self.note = n.into();
        self
    }
}

const GPFDIFF_DOC: &str = "factory/tools/gpfdiff/README.md";

/// Existing game with a binary: identify -> classify -> toolchain -> oracle chain.
pub fn standard(slug: &str) -> Vec<Seed> {
    let p = format!("ports/{slug}");
    // Determinism proof on the ORIGINAL: two independent captures must be byte-identical.
    let determinism = format!(
        "d=$(mktemp -d) && gpfdiff capture {p} --scenario all --out $d/a && \
         gpfdiff capture {p} --scenario all --out $d/b && diff -r $d/a $d/b"
    );
    vec![
        s("inventory", "identify", "Inventory and hash source files; record exact versions/regions in NOTES.md", &[], "haiku"),
        s("fingerprint", "identify", "Fingerprint the engine and toolchain the original was built with", &["inventory"], "sonnet"),
        // Deliberately depends on nothing: the sweep needs a title, not the media,
        // and its result can cancel the project before you ever dump a disk.
        s("prior", "identify", "PRIOR ART SWEEP: existing disassemblies, decomps, source releases, ports, format docs", &[], "sonnet"),
        s("answer", "classify", "Answer: does source exist? is target >= source in capability?", &["fingerprint", "prior"], "opus"),
        s("strategy", "classify", "Commit to a strategy (source-port | recompile | reimplement) and record why", &["answer"], "opus"),
        s("toolchain", "scaffold", "Stand up target toolchain + emulator; build and run a hello-world on target", &["strategy"], "sonnet"),
        // ---- oracle chain: the original is the oracle (docs: factory/tools/gpfdiff/README.md) ----
        s("addr", "scaffold",
            &format!("Oracle 1/5: find the original's state addresses with `gpfdiff watch` (candidates from the prior-art disassembly); record addresses + evidence in NOTES.md ({GPFDIFF_DOC}: watch, Keys mode)"),
            &["prior", "toolchain"], "sonnet")
            .verify(format!("! grep -q 'TBD — state addresses' {p}/NOTES.md"))
            .note("Evidence = the watch command line and which bytes moved for which key. Section '## State addresses (oracle)' in NOTES.md; the check passes when its TBD marker is gone."),
        s("fieldmap", "scaffold",
            &format!("Oracle 2/5: write the field map + ready gate in {p}/harness.toml; prove `gpfdiff watch`/`capture` runs deterministically on the ORIGINAL ({GPFDIFF_DOC}: harness.toml reference, Boot and the ready gate)"),
            &["addr"], "sonnet")
            .verify(determinism)
            .note("Scenarios come from games/<game>/recipe/scenarios. Replace 'all' in the verify with the scenario set if the recipe has no scenarios yet."),
        s("golden", "scaffold",
            &format!("Oracle 3/5: capture the original's golden traces for the scenario set with `gpfdiff capture` into {p}/harness/golden ({GPFDIFF_DOC}: capture, Oracle sources)"),
            &["fieldmap"], "haiku")
            .verify(format!(
                "gpfdiff capture {p} --scenario all --out {p}/harness/golden && ls {p}/harness/golden/*.trace"
            ))
            .note("Set [oracle] source = \"trace\", dir = \"harness/golden\" in harness.toml. Traces of a commercial original stay private (gitignore them)."),
        s("triage", "scaffold",
            &format!("Oracle 4/5: first `gpfdiff check {p}` against the oracle; triage every diff into platform physics vs port bug and record it in {p}/NOTES.md '## Diff triage' ({GPFDIFF_DOC}: check, Expected deviations)"),
            &["golden", "toolchain"], "sonnet")
            .verify(format!("grep -q '## Diff triage' {p}/NOTES.md"))
            .note("Expect FAILs on the first run: that is how deviations are discovered. Exit 1 = a diff to triage; exit 2 = environment (run `gpfdiff doctor`), not a port bug."),
        s("expect", "scaffold",
            &format!("Oracle 5/5: write {p}/expectations.toml (platform deviations, each with a reason), fix the real bugs, then `gpfdiff check {p}` passes with the determinism gate: every scenario PASS or EXPECTED ({GPFDIFF_DOC}: Expected deviations)"),
            &["triage"], "opus")
            .verify(format!("gpfdiff check {p} --repeat 2"))
            .note("A judgement: which differences are platform physics and which are port bugs. Silent deviations are bugs; every EXPECTED needs a reason; a STALE warning means remove the entry."),
    ]
}

/// An original design has no binary to excavate and nothing to classify: the
/// oracle is a reference model we write ourselves.
pub fn original() -> Vec<Seed> {
    vec![
        s("recipe", "recover", "Write platform-neutral recipe: games/<game>/recipe/README.md (rules, state contract, input contract, acceptance)", &[], "opus"),
        s("refmodel", "recover", "Reference model as oracle: implement the recipe rules in Rust, emit golden traces", &["recipe"], "sonnet"),
        s("toolchain", "scaffold", "Stand up target toolchain + emulator; build and run a hello-world on target", &[], "sonnet"),
        s("harness", "scaffold", "Stand up differential harness: scripted input, state capture, diff against reference-model traces", &["refmodel", "toolchain"], "sonnet"),
        s("slice", "slice", "Vertical slice on target: smallest playable thing, passing the harness", &["harness"], "sonnet"),
        s("polish", "iterate", "Art and sound polish within the asset budget", &["slice"], "sonnet"),
    ]
}

/// Public-release chain, modelled on ports/dizzy-coco2 (docs/PROVENANCE.md,
/// tools/bootstrap.sh, docs/BUILD-HASHES.txt, scripts/export-public.sh).
/// `original`: no user-supplied media exists, so the inputs manifest is not seeded
/// and the provenance/gate tasks shrink to the subset that applies.
pub fn public(slug: &str, original: bool) -> Vec<Seed> {
    let p = format!("ports/{slug}");
    let mut v = Vec::new();
    if original {
        v.push(
            s("provenance", "iterate",
                &format!("Public 1: provenance audit: classify every tracked and needed file as ours or generated into {p}/docs/PROVENANCE.md (model: ports/dizzy-coco2/docs/PROVENANCE.md)"),
                &["toolchain"], "sonnet")
                .verify(format!("test -s {p}/docs/PROVENANCE.md"))
                .note("--original: the game is ours, so there is no user-supplied category and no inputs manifest or original-text gate; only ours/generated is audited."),
        );
    } else {
        v.push(
            s("provenance", "iterate",
                &format!("Public 1: provenance audit: classify every file as ours / user-supplied / generated into {p}/docs/PROVENANCE.md (model: ports/dizzy-coco2/docs/PROVENANCE.md)"),
                &["toolchain"], "opus")
                .verify(format!("test -s {p}/docs/PROVENANCE.md"))
                .note("Judgement: what may ship. Anything derived from the original's media or text is generated-and-gitignored, never committed."),
        );
        v.push(
            s("inputs", "iterate",
                &format!("Public 2: inputs manifest {p}/tools/inputs.toml: every user-supplied input with its sha256 and where to obtain it (model: ports/dizzy-coco2/tools/inputs.toml)"),
                &["provenance"], "sonnet")
                .verify(format!("test -s {p}/tools/inputs.toml && grep -q sha256 {p}/tools/inputs.toml")),
        );
    }
    let boot_deps: &[&'static str] = if original { &["provenance"] } else { &["provenance", "inputs"] };
    v.push(
        s("bootstrap", "iterate",
            &format!("Public: {p}/tools/bootstrap.sh regenerates every derived file into gitignored paths{}; never downloads (model: ports/dizzy-coco2/tools/bootstrap.sh)",
                if original { "" } else { ", after verifying inputs by sha256" }),
            boot_deps, "sonnet")
            .verify(format!("{p}/tools/bootstrap.sh --list && git check-ignore -q {p}/extracted/x"))
            .note("Steps run in PROVENANCE.md regeneration order; supports --list, --steps, --verify. Add every generated path to .gitignore."),
    );
    v.push(
        s("hashes", "iterate",
            &format!("Public: reference artifact hash list {p}/docs/BUILD-HASHES.txt in sha256sum format (paths relative to {p}/); bootstrap --verify compares against it"),
            &["bootstrap"], "haiku")
            .verify(format!("cd {p} && sha256sum -c docs/BUILD-HASHES.txt")),
    );
    let gate_title = if original {
        format!("Public: export gate: no binaries in the public export; extend scripts/export-public.sh and .public-exclude for {p}")
    } else {
        format!("Public: export gates: no original text and no binaries in the public export; extend scripts/export-public.sh, .public-exclude and the text gates for {p} (model: ports/dizzy-coco2/docs/PROVENANCE.md, Text policy)")
    };
    v.push(
        s("gates", "iterate", &gate_title, &["provenance"], "sonnet")
            .verify(format!("git check-ignore -q {p}/extracted/x && git check-ignore -q {p}/source/x")),
    );
    v.push(
        s("cleanclone", "iterate",
            &format!("Public: clean-clone proof: in a fresh clone, `{p}/tools/bootstrap.sh --verify` matches docs/BUILD-HASHES.txt"),
            &["bootstrap", "hashes", "gates"], "haiku")
            .verify(format!(
                "d=$(mktemp -d) && git clone -q . $d/c && $d/c/{p}/tools/bootstrap.sh --verify"
            ))
            .note("Commit first: the clone sees only committed files. Supply user inputs to bootstrap per tools/inputs.toml if the port has any."),
    );
    v
}

/// Append `extra` to `base`, renumbering nothing: keys resolve against both lists.
pub fn chain(base: Vec<Seed>, extra: Vec<Seed>) -> Vec<Seed> {
    let mut v = base;
    v.extend(extra);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check_graph(v: &[Seed]) {
        for (i, t) in v.iter().enumerate() {
            for d in &t.deps {
                let j = v.iter().position(|x| x.key == *d).unwrap_or_else(|| panic!("{} -> missing {d}", t.key));
                assert!(j < i, "{} depends on later task {d}", t.key);
            }
            assert!(crate::model::STAGES.contains(&t.stage));
            assert!(crate::model::TIERS.contains(&t.tier));
        }
        let mut keys: Vec<_> = v.iter().map(|t| t.key).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), v.len(), "duplicate keys");
    }

    #[test]
    fn graphs_are_well_formed() {
        check_graph(&standard("x"));
        check_graph(&original());
        check_graph(&chain(standard("x"), public("x", false)));
        check_graph(&chain(original(), public("x", true)));
    }

    #[test]
    fn oracle_chain_tiers_and_verifies() {
        let v = standard("x");
        let get = |k: &str| v.iter().find(|t| t.key == k).unwrap();
        assert_eq!(get("addr").tier, "sonnet");
        assert_eq!(get("triage").tier, "sonnet");
        assert_eq!(get("expect").tier, "opus");
        assert!(get("triage").deps.contains(&"golden") && get("expect").deps.contains(&"triage"));
        assert!(get("fieldmap").verify.contains("gpfdiff capture ports/x") && get("fieldmap").verify.contains("diff -r"));
        assert!(get("expect").verify.contains("gpfdiff check ports/x"));
        assert!(get("triage").verify.contains("Diff triage"));
        assert!(get("fieldmap").deps.contains(&"addr") && get("addr").deps.contains(&"toolchain"));
        assert!(v.iter().all(|t| !t.title.is_empty()));
    }

    #[test]
    fn public_original_is_subset() {
        let a: Vec<_> = public("x", false).iter().map(|t| t.key).collect();
        let b: Vec<_> = public("x", true).iter().map(|t| t.key).collect();
        assert!(a.contains(&"inputs") && !b.contains(&"inputs"));
        assert!(b.iter().all(|k| a.contains(k)));
        let t = public("x", true);
        assert!(!t.iter().any(|t| t.title.contains("original text")));
    }
}
