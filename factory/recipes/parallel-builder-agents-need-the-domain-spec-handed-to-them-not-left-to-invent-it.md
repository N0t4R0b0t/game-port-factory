# Parallel builder agents need the domain spec handed to them, not left to invent it

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Fanned out 3 gpf-builder agents in parallel (sprite encoder, combat resolver, dialogue pager) for the fallout1-c64 iterate-stage work. All three succeeded cleanly with zero scope collisions and each independently caught a real bug (wrong KERNAL vector, print routine edge cases) -- because each prompt supplied the actual formulas/data/format decisions up front (exact to-hit/damage formulas with real recipe.json values already picked out, exact VIC sprite byte layout, exact LOAD secondary-address convention) rather than asking the agent to derive Fallout's mechanics or invent a format itself. This matches docs/COST-MODEL.md's existing warning about a weak tier confidently inventing plausible-looking wrong output, but the fix here isn't a stronger tier -- it's the orchestrator doing the domain-specific judgment calls (which formula, which real data, which byte layout) before delegating, so the builder's job is implementation and testing, not design.

## Precondition

Before fanning out any future engine-subsystem work (map renderer, save/load, inventory) to a builder agent, write the concrete spec first -- exact formulas, exact data source, exact file format, exact verify command -- the same way this session's three prompts did. An agent asked to 'build the X subsystem' with no spec will either stall asking questions or invent domain specifics with false confidence; neither is what a parallel fan-out is for.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
