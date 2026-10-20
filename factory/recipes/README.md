# factory/recipes/

Reusable judgement calls, recorded with `gpf decide`.

Each recipe carries the **axis** it travels along and the **precondition** under which it
applies. A later port checks the precondition before reuse; if it doesn't hold, re-derive
rather than copy.

**Empty by design** — recipes are extracted from real ports, never written speculatively.

See `docs/SELF-IMPROVEMENT.md`.
