# serveme for Team Frontress

This is a fork of [serveme.tf](https://serveme.tf) that hosts one game: **Team
Frontress**. Not "TF2 and also Frontress" — one game, one container image, one
set of rulesets, and a matchmaking coordinator that books servers through the
API.

What that means concretely:

| | |
| --- | --- |
| the game | AppID `5147520`, mod directory `tc2`, dedicated payload from Tool AppID `5150320` |
| a server | a `frontress-server` container, started for a reservation and destroyed with it |
| the rulesets | `frontress_casual` and `frontress_ranked`, from the game repository |
| matchmaking | the Go coordinator books servers here; an agent in each container reports the result |

Everything Team Fortress league-shaped is gone: ETF2L/RGL/ozfortress configs,
whitelist.tf, logs.tf and demos.tf uploads, the TF2 version check against
Steam, the opt-in page for "Team Comtress servers". None of it has a meaning
for a game that is not TF2.

## Running it

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

The four values every serveme needs are in [DOCKER.md](DOCKER.md). The ones
that are ours:

| | |
| --- | --- |
| `FRONTRESS_SERVER_IMAGE` | the game server image. Default `ghcr.io/gru2007/frontress-server:latest` |
| `FRONTRESS_LOCAL_DOCKER` | run game servers on this machine's docker daemon |
| `DOCKER_GID` | the host's docker group, so the app may use the mounted socket |
| `DOCKER_HOST_IP` / `CLOUD_CALLBACK_HOST` | how a container reaches this app back |
| `FRONTRESS_COORDINATOR_URL` / `_SECRET` | the matchmaking coordinator |

Check what it thinks it is doing:

```bash
docker compose exec web bin/rails frontress:doctor
```

## Game servers are containers

There is no "set up a machine for the game" step, because there is nothing to
set up: the image carries the game payload, the Steam Linux Runtime, TF2's
content files, the rulesets and the coordinator agent. A machine that can run a
container can host a match.

Two ways to have containers:

**This machine.** `FRONTRESS_LOCAL_DOCKER=1` and the docker socket mounted
(docker-compose.yml does that already). Reservations get a container on the
same box as the site, up to `FRONTRESS_LOCAL_DOCKER_MAX_CONTAINERS`.

**Other machines.** Add them under `/admin/docker_hosts`. Each one is set up
over SSH by `DockerHostSetupService` — docker, the seccomp profile, the image
pull — and then hosts up to `max_containers` at a time. A host you add by hand
needs this site's public key in root's `authorized_keys`:

```bash
docker compose exec web bin/rails frontress:ssh_key
```

Both appear to the API as servers with ids at or above `1_000_000_000`, which
is how the coordinator's `prefer_docker` tells them apart from machines
somebody runs by hand.

The image is built from [`docker/frontress-server`](../docker/frontress-server).
It downloads the dedicated payload published by the game repository's release
workflow (`frontress-dedicated-linux.tar.gz`) rather than building the game, so
building it takes minutes, not an afternoon.

```bash
docker build -t ghcr.io/gru2007/frontress-server:latest --build-arg FRONTRESS_VERSION=120125 docker/frontress-server
```

CI does the same thing on `.github/workflows/server-image.yml` and pushes to
GHCR — run it by hand ("Game server image" → Run workflow) with the payload URL
and build version, or let a change under `docker/frontress-server/` trigger it.
Note the size: the base stage downloads the Steam Linux Runtime and TF2's
content files, about 15GB, which is why the workflow clears the runner's disk
first.

Until the image exists somewhere `docker` can pull it from, provisioning fails
with an image-not-found error, and no amount of correct configuration helps.

## One site, one name

Upstream serveme runs four sites (`serveme.tf`, `na.`, `au.`, `sea.`) and the
code knows it: a region switcher in the navigation, per-region Stripe keys,
per-region league bans, a banner telling North Americans to go somewhere else,
`direct.` hostnames for game servers, `fastdl.serveme.tf` links, an API-key
label with another site's name on it.

This fork is one site, and every one of those now derives from `SITE_URL`:

| | |
| --- | --- |
| page copy, API-key label, API docs | `SITE_HOST` |
| where servers send logs and which host may RCON | `FRONTRESS_DIRECT_HOST`, `FRONTRESS_LOG_ADDRESS` |
| map download links | `FRONTRESS_FASTDL_URL` (no link at all when unset) |
| Discord invite and slash command | `FRONTRESS_DISCORD_URL`, `FRONTRESS_DISCORD_COMMAND` |
| source link | `FRONTRESS_SOURCE_URL` |
| cloud regions, log time zone | `FRONTRESS_REGION`, `FRONTRESS_TIME_ZONE` |
| league bans and divisions | `FRONTRESS_LEAGUE` (none by default) |

`SITE_HOST` is derived from `SITE_URL` when it is not set separately, because
setting one and forgetting the other is how a site ends up calling itself
`localhost` on every page.

The region predicates (`au_system?` and friends) still exist and all answer
false, so the branches behind them never render. That is deliberate: it keeps a
dozen views compiling without rewriting each one.

What is *not* touched: `config/deploy.*.yml` and `.kamal/` still describe
upstream's own machines. They are inert in a compose deployment; delete them if
you never plan to run kamal.

## Ports

Containers run on the **host's** network, so every port below is a port on the
machine running them, and the slots are per container: the first container gets
27015, the second 27025, and so on in steps of ten.

| | | |
| --- | --- | --- |
| `27015 + 10n` | udp+tcp | the game, and RCON. Must be reachable by players |
| `27020 + 10n` | udp | SourceTV |
| `41001 + n` | udp | srcds' own client port |
| `30001 + n` | udp | the Steam port |
| `22000 + n` | tcp | sshd in the container, so serveme can push configs. LAN or localhost only |
| `40001` | udp | serveme's log daemon. Every game server sends its console log here |
| `3000` | tcp | the site, behind your proxy (`SERVEME_HTTP_PORT`) |
| `27100` | tcp | the coordinator, reachable by game clients (`listen`) |

The client port starts at 41001 rather than 40001 on purpose: 40001 is the log
daemon's, and on a one-box deployment the first container would take it and no
log would ever arrive.

For players you need `27015 + 10n` open per container, in both protocols. For a
box that hosts four servers, that is 27015-27055.

## The SSH key

This app logs into every game server container over SSH — that is how
`reservation.cfg` gets in and how logs and demos come out. Upstream keeps the
keypair in Rails credentials; here there is a chain, ending in one that needs
no setup:

| | |
| --- | --- |
| `tmp/cloud_ssh_key` | a key file you manage |
| `FRONTRESS_SSH_PRIVATE_KEY` | the PEM in the environment |
| credentials | `cloud_servers.ssh_private_key`, as upstream |
| generated | created on first use and kept in `site_settings` |

The public half is handed to each container as it starts, so changing the key
strands containers already running with the old one. `frontress:doctor` says
which source is in use.

## GSLTs

A Game Server Login Token for AppID 5147520 (from
[managegameservers](https://steamcommunity.com/dev/managegameservers)) is what
gives connecting players their inventory. A token belongs to one running server
at a time, so `FRONTRESS_GSLT` takes a list and each container gets the one for
its port slot:

```bash
FRONTRESS_GSLT=token1,token2,token3,token4
```

Give it as many tokens as the machine runs containers. Without any, servers
still run and players connect without items.

## Maps

The map list is one list with three jobs: the picker on the reservation form,
`/api/maps.txt` (which every container fetches at boot), and the validation
that decides whether a reservation may name a given map. A map missing from it
cannot be reserved at all.

Where it comes from, in order:

| | |
| --- | --- |
| `FRONTRESS_MAPS` | an explicit space- or comma-separated list |
| `config/league_maps.yml` | every map named there, when the above is empty |
| the bucket | when `ACTIVE_STORAGE_SERVICE` points at object storage, its `maps/` prefix wins |

Serving the `.bsp` itself is a separate question: either bake it into the image
or put it behind `FRONTRESS_FASTDL_URL`, which the container downloads its first
map from and which clients download what they are missing from.

## The coordinator

The matchmaking coordinator (`services/coordinator` in the game repository)
never touches this site's web interface. It is an API client with an API key,
and it does exactly what any other API client does: asks which servers are
free, creates a reservation, plays a match on it, ends the reservation.

Give it a key:

```bash
docker compose exec web bin/rails frontress:coordinator_key
```

That creates a user in the **Trusted API** group and prints the provider block
to paste into `coordinator.json`:

```json
{ "kind": "serveme", "region": "eu",
  "base_url": "https://serveme.example.org",
  "api_key": "...", "prefer_docker": true, "reserve_mins": 120 }
```

### What a match reservation carries

Three fields on a reservation make it a match rather than a booking:

| | |
| --- | --- |
| `match_id` | the coordinator's match id. It becomes `sv_tags "tfmm:<id>"` |
| `match_mode` | `casual` or `ranked` |
| `match_config` | the ruleset to exec, defaulting from the mode |

`reservation.cfg` writes the tag and execs the ruleset last, so a ranked match
cannot inherit a casual convar from anything before it. The container is also
given `GC_URL`, `GC_SECRET` and `MATCH_ID`, which is what the agent inside it
needs to report the result.

**Only the coordinator may book ranked.** `Reservations::MatchValidator`
refuses a ranked reservation from anyone who is not in the Trusted API or
Admin group, because a ranked match nobody formed still reports a result
against real players' records.

### The whole path

```text
  player queues
        |
   coordinator forms a match, picks a map
        |  POST /api/reservations/find_servers      (container hosts first)
        |  POST /api/reservations                   (match_id, match_mode, first_map, password)
        v
   serveme starts a frontress-server container
        |  the container writes server.cfg, waits for reservation.cfg
        |  callbacks: ssh_ready -> configs pushed -> tf2_ready
        v
   coordinator polls the reservation until it is "Ready"
        |  RCON: sv_password, sv_tags, maxplayers, exec <ruleset>, changelevel
        v
   players connect; greyline-agent heartbeats the match
        |
   game over -> agent POSTs /v1/gs/result to the coordinator
        |
   coordinator DELETEs the reservation -> the container is destroyed
```

The coordinator waits for the reservation to reach `Ready` before it RCONs
anything. A container takes half a minute to come up, and an address that is
not listening yet would be read as "this server is broken" and cost the players
their match.

## Casual and ranked

The two queues differ in the game (a ruleset) and in the coordinator (what it
is allowed to do), and this site only has to know about the first.

| | casual | ranked |
| --- | --- | --- |
| ruleset | `frontress_casual` | `frontress_ranked` |
| class limits | none | `mp_sixes 1` |
| random crits | on | off |
| damage spread | on | off |
| whitelist | none | `whitelist_competitive.txt` |
| votes | kick and scramble | none |
| match filling | keeps taking players while it runs | fixed roster |
| who may book it | anyone | the coordinator only |

The restrictions on *who may queue* — party size, matches played, abandon
cooldowns — live in the coordinator, not here. See its README.

## Adding a server you run yourself

Still possible, and still not the recommended path:

```bash
docker compose exec web bin/rails console
```

```ruby
SshServer.create(name: "eu1", ip: "203.0.113.11", port: "27015",
                 path: "/home/frontress/hlserver")
```

`path` is the game root — the directory that contains `tc2/` — because
everything this app writes goes to `path + "/" + tc2 + "/cfg"`.
