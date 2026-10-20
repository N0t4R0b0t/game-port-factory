# games/

One directory per game, holding the platform-neutral **recipe** — the extraction of
concept, rules, narrative, and data that every target implementation shares.

```
games/<game>/recipe/    ruleset, item/critter tables, dialogue graph, quest state,
                        map topology, asset budget
```

Per-target implementation work lives in `ports/<game>-<platform>/`, linked back by the
`game` field in each `PORT.toml`.

Stages 1-4 run once per game and produce the recipe. Stages 5-7 run once per target.
