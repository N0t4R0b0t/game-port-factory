# Reserve real gpf task IDs before dispatching parallel builder agents that reference their own task number

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Ran gpf task add for a dialogue-branching scouting task (landed as T0036) at roughly the same time a parallel dialogpager builder agent -- which has no gpf access and can't check the real ledger -- guessed 'T0036' for its own unrelated work in code comments and a NOTES.md heading, since that was the next number it could infer from reading tasks.toml at the time it started. The agent caught its own collision before finishing (re-read tasks.toml, saw T0036 was taken, renamed itself to T0037) and fixed the cross-reference in the other section too -- but that was the agent noticing on its own, not a structural guarantee. A less careful agent, or one that finished before checking, would have left a real, confusing ID collision in committed files.

## Precondition

When dispatching multiple parallel builder agents whose deliverables will each get a task ID and each agent needs to reference in comments/docs, reserve the real IDs with gpf task add up front and pass each agent its actual assigned number in the prompt, rather than letting agents guess and self-correct. Cheaper and more reliable than relying on an agent to notice a collision before it commits to files.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

**Recurred the very next dispatch, same session.** Fanned out two more parallel builder
agents (the T0036 dialogue-graph extractor and interpreter) without reserving their IDs
first — despite this decision existing. The interpreter agent guessed "T0038," which was
already taken (the combat resolver, registered in the prior turn). Caught and fixed by hand
during this session's own review (`sed -i 's/T0038/T0041/g'` across four files) rather than
by the agent noticing itself this time. The precondition above is correct; the failure was
not following it. Treat this as a checklist item when writing the NEXT parallel-dispatch
prompt, not a one-time fix: reserve IDs with `gpf task add` BEFORE writing agent prompts,
every time, not just when it's convenient to remember.
