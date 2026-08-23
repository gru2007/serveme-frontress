# Baked-in configs

These are copies of `game/tc2/cfg/*` from the game repository, and the game
repository is the source of truth for them: the coordinator execs
`frontress_casual` or `frontress_ranked` by name before every match, so a
server whose copy is stale plays a different ruleset than the one the match was
formed under.

Refresh them with:

```bash
cp ../team-frontress/game/tc2/cfg/frontress_*.cfg .
cp ../team-frontress/game/tc2/cfg/whitelist_competitive.txt .
```

| | |
| --- | --- |
| `frontress_match.cfg` | the base both rulesets exec: hibernation, teams, bots |
| `frontress_casual.cfg` | Casual Frontline: open queue, backfilled, no restrictions |
| `frontress_ranked.cfg` | Ranked: class limits, no crits, no spread, whitelist, no votes |
| `whitelist_competitive.txt` | the weapon whitelist ranked runs |
