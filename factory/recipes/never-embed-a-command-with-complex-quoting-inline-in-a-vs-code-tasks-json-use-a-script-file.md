# Never embed a command with complex quoting inline in a VS Code tasks.json — use a script file

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

A VS Code task's inline bash -c one-liner, containing a $'...'-ANSI-C-quoted -keybuf string with embedded \n escapes and nested double-quotes, worked in this session's own sandbox but corrupted on the user's real machine -- twice, including after a plausible-looking but wrong fix (-keybuf-delay) was added. VS Code's type:shell task re-quotes args for whatever shell it invokes on the target machine, an extra quoting layer this project's sandbox test never exercised the same way a real VS Code invocation does. The corruption symptom (an extra character appearing, not just dropped ones) was the tell that this was string mangling before the command reached the target program, not a runtime timing issue -- a distinction that mattered for finding the real fix instead of tuning the wrong one.

## Precondition

Any VS Code task whose command needs nontrivial shell quoting (nested quotes, ANSI-C $'...' strings, embedded escape sequences) should be moved into a real script file and referenced by path in tasks.json's command field with empty/simple args, not embedded as an inline bash -c one-liner. A script file has exactly one layer of shell parsing (its own shebang); an inline JSON-embedded command has at least two (JSON string escaping, then whatever shell VS Code wraps it in), and the second layer isn't reliably testable from outside VS Code's own task runner.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
