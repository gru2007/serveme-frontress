# Running serveme with docker compose

One `.env`, one `docker compose up -d`, one port to put a reverse proxy in
front of. No Rails credentials, no master key, no secrets scattered across the
host — and no machine anywhere set up for the game by hand, because game
servers are containers too. What makes this fork Frontress-only, and how the
matchmaking coordinator plugs into it, is in [FRONTRESS.md](FRONTRESS.md).

```bash
cp .env.example .env
$EDITOR .env          # four REQUIRED values
docker compose up -d
```

Then point your proxy at `127.0.0.1:3000` (or whatever `SERVEME_HTTP_PORT`
says) and terminate TLS there. Rails is configured with `force_ssl = false`
precisely so something in front can own HTTPS.

## The four values you must set

| | |
| --- | --- |
| `SECRET_KEY_BASE` | signs cookies and sessions. `openssl rand -hex 64` |
| `STEAM_API_KEY` | from [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey). Steam sign-in is the only way into the site |
| `POSTGRES_PASSWORD` | `openssl rand -hex 24`. Internal to the compose network, but still a password |
| `SITE_URL` | the address users type. It ends up in redirects and in the reservation details handed to game clients, so a wrong value produces links that go nowhere |

Everything else has a working default.

## What runs

| service | what it is | published |
| --- | --- | --- |
| `db` | Postgres | no |
| `redis` | Sidekiq queues, cache, ActionCable | no |
| `migrate` | one-shot `rails db:prepare`, runs before the rest | no |
| `web` | Rails behind Thruster on port 80 | `SERVEME_HTTP_PORT` |
| `sidekiq` | background jobs and the cron schedule | no |
| `logdaemon` | receives srcds console logs over UDP | `SERVEME_LOG_PORT/udp` |
| `discord_bot` | only with `--profile discord` | no |

Two ports leave the box, and they leave for different reasons. The HTTP port is
for your proxy and is bound to `SERVEME_BIND` (`127.0.0.1` by default, so
nothing reaches Rails except through the proxy). The UDP log port has to be
reachable by **every game server in the pool**, which are remote by definition,
so it ignores `SERVEME_BIND` and binds on all interfaces. If there is a
firewall, that is the hole to open.

## Game servers

You do not add any. A reservation starts a `frontress-server` container and
ending it destroys the container, so the pool is however many containers the
machines you have will run.

Out of the box that is **this machine**: `FRONTRESS_LOCAL_DOCKER=1` in `.env`,
the docker socket mounted into `web` and `sidekiq` (docker-compose.yml already
does), and `DOCKER_GID` set to the host's docker group so the unprivileged user
in the container may use the socket:

```bash
getent group docker | cut -d: -f3
```

Two more values matter, because a game server container runs on the **host's**
network and cannot reach this app by its compose-internal name:

```bash
DOCKER_HOST_IP=203.0.113.10        # this machine, as a container sees it
CLOUD_CALLBACK_HOST=203.0.113.10:3000
```

More capacity means more machines: add them under `/admin/docker_hosts` and
serveme sets each one up over SSH. Adding a server you run and maintain
yourself is still possible — see [FRONTRESS.md](FRONTRESS.md) — but it is the
path this fork exists to avoid.

Check the whole picture at once:

```bash
docker compose exec web bin/rails frontress:doctor
```

## Without Rails credentials

The compose path deliberately does not need `RAILS_MASTER_KEY`. What you give
up by leaving it empty:

- Cloudflare (R2 map uploads, DNS), Stripe and PayPal — uploads fall back to
  the local disk (the `storage` volume), so they work, they just live here
- Discord OAuth and the ban-appeal workflow
- the paid VM cloud providers (Hetzner, Vultr, Kamatera). Docker hosts and the
  local docker daemon do not need it

Reservations, servers, RCON, the API and Steam sign-in all work without it.

Three secrets that used to be credentials-only now read the environment first,
which is the same order the rest of this app already uses for IPQS, Fraudlogix
and the cloud providers:

| | |
| --- | --- |
| `STEAM_API_KEY` | `config/initializers/00_steam_api_key.rb` |
| `SENTRY_DSN` | `config/initializers/sentry.rb` |
| `MAXMIND_LICENSE_KEY` | `lib/tasks/maxmind.rake` |

If you do have `config/credentials/production.key`, put its contents in
`RAILS_MASTER_KEY` and everything above becomes available again.

## Maps

With no object storage configured, there is no bucket to list, so the maps this
site knows about are the ones in `FRONTRESS_MAPS` — and when that is empty,
every map named in `config/league_maps.yml`.

That list is load-bearing in three places at once: it fills the map picker, it
is what `/api/maps.txt` serves to every container at boot, and it is what a
reservation's map is validated against. A map that is not in it cannot be
reserved, so adding a map to the pool means adding it there (and putting the
`.bsp` where servers can get it — `FRONTRESS_FASTDL_URL`, or baked into the
image).

Point `ACTIVE_STORAGE_SERVICE` at a service in `config/storage.yml` once you
have object storage, and the bucket listing takes over again.

## GeoIP

IP geolocation needs `doc/GeoLite2-City.mmdb` and `doc/GeoLite2-ASN.mmdb`,
which are gitignored. `doc/` is bind-mounted from the repo, so either drop the
files in yourself or let the app fetch them:

```bash
# needs MAXMIND_LICENSE_KEY in .env
docker compose run --rm web bin/rails maxmind:fetch
```

Without them, geolocation is the only thing that stops working. Nothing fails
to boot.

## Day to day

```bash
docker compose logs -f web              # or sidekiq, logdaemon
docker compose exec web bin/rails console
docker compose exec db psql -U serveme serveme_production
docker compose run --rm web bin/rails db:seed      # the seed server list
docker compose pull && docker compose up -d --build
docker compose down                     # keeps the volumes
docker compose down -v                  # deletes the database. Read that twice
```

Migrations run automatically on every `up`: the `migrate` service goes first
and the rest wait for it to exit cleanly. If a migration fails, nothing else
starts, which is the intended behaviour — a half-migrated database serving
traffic is worse than a site that is down.

## Backups

Everything that matters is in two named volumes, `serveme_postgres_data` and
`serveme_uploads`.

```bash
docker compose exec -T db pg_dump -U serveme serveme_production | gzip > serveme-$(date +%F).sql.gz
```

## Notes

**Do not change `POSTGRES_IMAGE` after the first `up`.** Postgres refuses to
start on a data directory written by a different major version. Moving major
versions means dumping, `down -v`, and restoring.

**If you ran the old compose file**, its volumes were created under a different
project name and its `DATABASE_URL` pointed at the host-side port rather than
the internal one, so it never actually connected. There is nothing to migrate;
start fresh.

**Matchmaking needs a coordinator.** Set `FRONTRESS_COORDINATOR_URL` and
`FRONTRESS_COORDINATOR_SECRET`, and give the coordinator an API key with
`bin/rails frontress:coordinator_key`. Without it reservations still work and
nothing matchmakes. See [FRONTRESS.md](FRONTRESS.md).

**`RAILS_ENV` stays `production`.** The image is built for it — assets are
precompiled at build time and there is no development toolchain in the final
stage.
