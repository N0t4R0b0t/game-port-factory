# factory/tools/

Promoted tools — reusable across ports.

**Empty by design.** Nothing arrives here until a *second* port needs it. New tools are
built inside `ports/<slug>/tools/` where they belong to one problem; they move here only
once there are two callers, because that is the first moment the real interface is
knowable rather than guessable.

See `docs/SELF-IMPROVEMENT.md`.
