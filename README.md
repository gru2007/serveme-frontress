# serveme, for Team Frontress

A fork of [serveme.tf](https://serveme.tf) that hosts servers for one game:
**Team Frontress**. Reserve a server, get a container running the game with the
right ruleset, play, and the container goes away when the reservation ends.

**Start here:** [docs/DOCKER.md](docs/DOCKER.md) to run the site,
[docs/FRONTRESS.md](docs/FRONTRESS.md) for what makes it Frontress-only and how
the matchmaking coordinator plugs into it.

```bash
cp .env.example .env
$EDITOR .env          # four REQUIRED values
docker compose up -d
```

Docker is the supported way to run this, both halves of it: the site is a
compose stack, and every game server is a container started for one
reservation. There is no per-machine game installation to maintain -- the image
carries the game payload, the Steam Linux Runtime, the rulesets and the agent
that reports match results to the coordinator.

## What is different from upstream

| | |
| --- | --- |
| one game | AppID 5147520, mod directory `tc2`. Nothing branches on "is this a TF2 server?" any more |
| servers are containers | `docker/frontress-server`, on this machine or on docker hosts added in the admin UI |
| two rulesets | `frontress_casual` and `frontress_ranked`, from the game repository |
| matchmaking | the Go coordinator books servers over the API; ranked can only be booked by it |
| no TF2 leagues | ETF2L/RGL/ozfortress configs, whitelist.tf, logs.tf and demos.tf uploads are gone |

## Running without docker

Possible, and not what this fork is set up for. You need:

* Ruby 4.0+ — install via [mise](https://mise.jdx.dev/). See `.tool-versions` for the exact version.
* A Steam API key for user sign in (`STEAM_API_KEY`, or `steam.api_key` in credentials)
* Postgres and Redis
* [libmaxminddb](https://github.com/maxmind/libmaxminddb) for GeoIP lookups, and ripgrep

```bash
gem install bundler && bundle install
bin/rails db:setup
bin/rails s
```

Game servers still want to be containers; `FRONTRESS_LOCAL_DOCKER=1` uses the
docker daemon on the machine Rails runs on.

### Running the test suite
`script/test -a` runs the full check: RuboCop, Brakeman, RSpec, import-map verification, Tapioca, and Swagger regeneration.


## Servers

Game servers are containers, started for a reservation and destroyed with it.
There is nothing to add: with `FRONTRESS_LOCAL_DOCKER=1` this machine hosts
them, and more capacity means more docker hosts, added under
`/admin/docker_hosts`. See [docs/FRONTRESS.md](docs/FRONTRESS.md).

A server you run and maintain yourself can still be registered by hand:

```ruby
SshServer.create(name: "eu1", ip: "server_ip_or_hostname", port: "27015",
                 path: "/home/frontress/hlserver")
```

`path` is the game root -- the directory containing `tc2/` -- and the user
running the web application needs passwordless SSH to the machine:

```
Host server_ip_or_hostname
  Hostname server_ip_or_hostname
  Port remote_ssh_port_if_not_22
  User remote_user
  IdentityFile ~/.ssh/id_rsa_for_remote_server
```

## API
There's a simple JSON API to create and stop reservations. It typically returns a prefilled JSON response, which you can edit and send to one of the URLs listed in the "actions".

### Matchmaking fields

Three fields turn a reservation into a match, and the game coordinator is the
client that sets them:

| | |
| --- | --- |
| `match_id` | the coordinator's match id. It becomes `sv_tags "tfmm:<id>"` on the server |
| `match_mode` | `casual` or `ranked` |
| `match_config` | the ruleset to exec; defaults from the mode |

`find_servers` lists container hosts before machines, so a client that takes
the first server offered gets a container started for its match. Ranked
reservations are refused unless the API user is in the Trusted API group --
see [docs/FRONTRESS.md](docs/FRONTRESS.md).

### Interactive API Documentation
**NEW:** Complete interactive Swagger API documentation is now available at:
- **EU**: https://serveme.tf/api-docs
- **NA**: https://na.serveme.tf/api-docs
- **AU**: https://au.serveme.tf/api-docs
- **SEA**: https://sea.serveme.tf/api-docs

The Swagger documentation provides complete schemas, examples, and a testing interface for all API endpoints.

**Important**: API keys are region-specific. Use the API key from the same region as the endpoint you're calling:
- **EU**: https://serveme.tf (API keys from EU account)
- **NA**: https://na.serveme.tf (API keys from NA account)
- **AU**: https://au.serveme.tf (API keys from AU account)
- **SEA**: https://sea.serveme.tf (API keys from SEA account)

### Authentication
All API endpoints require authentication using one of these methods:
1. **Query Parameter**: Add `?api_key=your_api_key` to any request
2. **Authorization Header**: Use either format:
   - `Authorization: Token token=your_api_key`
   - `Authorization: Bearer your_api_key`

Users can find their API key in their account settings page after signing in with Steam.

### Step 1
```shell
curl -X GET -H "Content-Type: application/json" 'https://serveme.tf/api/reservations/new?api_key=your_api_key'
```

This will return a prefilled JSON response, which you can POST to the action "find_servers"
```json
{
  "reservation": {
    "starts_at": "2014-04-13T18:00:20.415+02:00",
    "ends_at": "2014-04-13T20:00:20.415+02:00"
  },
  "actions": {
    "find_servers": "https://serveme.tf/api/reservations/find_servers"
  }
}
```

### Step 2
POST a reservation with starts_at and ends_at filled in to find_servers.
```shell
curl -X POST -H "Content-Type: application/json" -d '{"reservation":{"starts_at":"2014-04-13T18:00:20.415+02:00","ends_at":"2014-04-13T20:00:20.415+02:00"}}' 'https://serveme.tf/api/reservations/find_servers?api_key=your_api_key'
```

This will return a prefilled JSON response with available servers, whitelists and server configs included:
```json
{
  "reservation": {
    "status": "Unknown",
    "starts_at": "2014-04-13T18:00:20.415+02:00",
    "ends_at": "2014-04-13T20:00:20.415+02:00",
    "server_id": null,
    "password": null,
    "rcon": null,
    "first_map": null,
    "tv_password": "tv",
    "tv_relaypassword": "tv",
    "tv_port": null,
    "server_config_id": null,
    "whitelist_id": null,
    "custom_whitelist_id": null,
    "auto_end": true,
    "enable_plugins": true,
    "enable_demos_tf": false,
    "sdr_ip": null,
    "sdr_port": null,
    "sdr_tv_port": null,
    "sdr_final": false,
    "disable_democheck": false,
    "democheck_mode": "kick"
  },
  "servers": [
    {
      "id": 64,
      "name": "FritzBrigade #10",
      "location": {
        "id": 8,
        "name": "Germany",
        "flag": "de"
      }
    }
  ],
  "server_configs": [
    {
      "id": 2,
      "file": "etf2l_6v6"
    },
    {
      "id": 3,
      "file": "etf2l_9v9"
    }
  ],
  "whitelists": [
    {
      "id": 2,
      "file": "etf2l_whitelist_6v6.txt"
    },
    {
      "id": 3,
      "file": "etf2l_whitelist_9v9.txt"
    }
  ],
  "actions": {
    "create": "https://serveme.tf/api/reservations"
  }
}
```

### Step 3
POST a complete reservation to the "create" action
```shell
curl -X POST -H "Content-Type: application/json" -d '{"reservation":{"starts_at":"2014-04-13T18:00:20.415+02:00","ends_at":"2014-04-13T20:00:20.415+02:00","rcon":"foo","password":"bar","server_id":1337}}' 'https://serveme.tf/api/reservations?api_key=your_api_key'
```

If there's any errors, you'll get a HTTP 422 and a new prefilled reservation JSON with errors:
```json
{
  "reservation": {
    "status": "Unknown",
    "starts_at": "2014-04-13T18:00:20.415+02:00",
    "ends_at": "2014-04-13T20:00:20.415+02:00",
    "server_id": null,
    "password": "bar",
    "rcon": "foo",
    "first_map": null,
    "tv_password": "tv",
    "tv_relaypassword": "tv",
    "tv_port": null,
    "server_config_id": null,
    "whitelist_id": null,
    "custom_whitelist_id": null,
    "auto_end": true,
    "enable_plugins": true,
    "enable_demos_tf": false,
    "sdr_ip": null,
    "sdr_port": null,
    "sdr_tv_port": null,
    "sdr_final": false,
    "disable_democheck": false,
    "democheck_mode": "kick",
    "errors": {
      "server": {
        "error": "can't be blank"
      },
      "starts_at": {
        "error": "can't be more than 15 minutes in the past"
      }
    }
  },
  "actions": {
    "create": "https://serveme.tf/api/reservations"
  },
  "servers": [
    {
      "id": 64,
      "name": "FritzBrigade #10",
      "location": {
        "id": 8,
        "name": "Germany",
        "flag": "de"
      }
    }
  ],
  "server_configs": [
    {
      "id": 19,
      "file": "wptf2l"
    }
  ],
  "whitelists": [
    {
      "id": 9,
      "file": "wp9v9_whitelist.txt"
    }
  ]
}
```

If everything went alright, you'll get a HTTP 200 and shown your reservation details:
```json
{
  "reservation": {
    "id": 12345,
    "server_id": 64,
    "starts_at": "2014-04-13T19:00:20.415+02:00",
    "ends_at": "2014-04-13T20:00:20.415+02:00",
    "password": "bar",
    "rcon": "foo",
    "first_map": null,
    "tv_password": "tv",
    "tv_relaypassword": "tv",
    "tv_port": 27020,
    "server_config_id": null,
    "whitelist_id": null,
    "custom_whitelist_id": null,
    "auto_end": true,
    "enable_plugins": false,
    "enable_demos_tf": false,
    "sdr_ip": null,
    "sdr_port": null,
    "sdr_tv_port": null,
    "sdr_final": false,
    "disable_democheck": false,
    "democheck_mode": "kick",
    "last_number_of_players": 0,
    "inactive_minute_counter": 0,
    "logsecret": "298424416816498481223654962917404607282",
    "start_instantly": false,
    "end_instantly": false,
    "provisioned": true,
    "ended": false,
    "steam_uid": "76561198012345678",
    "status": "Started",
    "server": {
      "id": 64,
      "name": "Server name",
      "flag": "de",
      "ip": "127.0.0.1",
      "port": "27015",
      "ip_and_port": "127.0.0.1:27015",
      "sdr": false,
      "latitude": 52.5,
      "longitude": 13.4
    }
  },
  "actions": {
    "patch": "https://serveme.tf/api/reservations/12345",
    "delete": "https://serveme.tf/api/reservations/12345"
  }
}
```

### Step 4
PATCH an updated reservation to the "update" action
```shell
curl -X PATCH -H "Content-Type: application/json" -d '{"reservation":{"ends_at":"2014-04-13T21:30:20.415+02:00","password":"newpassword","first_map":"cp_badlands"}}' 'https://serveme.tf/api/reservations/12345?api_key=your_api_key'
```

If there's any errors, you'll get a HTTP 422 and a prefilled reservation JSON with errors:
```json
{
  "reservation": {
    "status": "Started",
    "starts_at": "2014-04-13T18:00:20.415+02:00",
    "ends_at": "2014-04-13T20:00:20.415+02:00",
    "server_id": 64,
    "password": "",
    "rcon": "foo",
    "first_map": null,
    "tv_password": "tv",
    "tv_relaypassword": "tv",
    "tv_port": 27020,
    "server_config_id": null,
    "whitelist_id": null,
    "custom_whitelist_id": null,
    "auto_end": true,
    "enable_plugins": false,
    "enable_demos_tf": false,
    "sdr_ip": null,
    "sdr_port": null,
    "sdr_tv_port": null,
    "sdr_final": false,
    "disable_democheck": false,
    "democheck_mode": "kick",
    "errors": {
      "password": {
        "error": "can't be blank"
      },
      "ends_at": {
        "error": "reservation can't be more than 2h long"
      }
    }
  },
  "actions": {
    "patch": "https://serveme.tf/api/reservations/12345"
  },
  "servers": [
    {
      "id": 64,
      "name": "FritzBrigade #10",
      "location": {
        "id": 8,
        "name": "Germany",
        "flag": "de"
      }
    }
  ],
  "server_configs": [
    {
      "id": 19,
      "file": "wptf2l"
    }
  ],
  "whitelists": [
    {
      "id": 9,
      "file": "wp9v9_whitelist.txt"
    }
  ]
}
```

If everything went alright, you'll get a HTTP 200 and shown your updated reservation details:
```json
{
  "reservation": {
    "id": 12345,
    "server_id": 64,
    "starts_at": "2014-04-13T19:00:20.415+02:00",
    "ends_at": "2014-04-13T19:30:20.415+02:00",
    "password": "newpassword",
    "rcon": "foo",
    "first_map": "cp_badlands",
    "tv_password": "tv",
    "tv_relaypassword": "tv",
    "tv_port": 27020,
    "server_config_id": null,
    "whitelist_id": null,
    "custom_whitelist_id": null,
    "auto_end": true,
    "enable_plugins": false,
    "enable_demos_tf": false,
    "sdr_ip": null,
    "sdr_port": null,
    "sdr_tv_port": null,
    "sdr_final": false,
    "disable_democheck": false,
    "democheck_mode": "kick",
    "last_number_of_players": 0,
    "inactive_minute_counter": 0,
    "logsecret": "298424416816498481223654962917404607282",
    "start_instantly": false,
    "end_instantly": false,
    "provisioned": true,
    "ended": false,
    "steam_uid": "76561198012345678",
    "status": "Started",
    "server": {
      "id": 64,
      "name": "Server name",
      "flag": "de",
      "ip": "127.0.0.1",
      "port": "27015",
      "ip_and_port": "127.0.0.1:27015",
      "sdr": false,
      "latitude": 52.5,
      "longitude": 13.4
    }
  },
  "actions": {
    "patch": "https://serveme.tf/api/reservations/12345",
    "delete": "https://serveme.tf/api/reservations/12345"
  }
}
```
### Step 5
After the match is over, you can end your reservation

First, you can check your reservation details:
```shell
curl -X GET -H "Content-Type: application/json" 'https://serveme.tf/api/reservations/12345?api_key=your_api_key'
```

This JSON response will tell you if the reservation hasn't ended by itself already with the "ended" boolean. If you want to end it yourself, you need to send a HTTP DELETE to the "delete" action URL:

```shell
curl -X DELETE -H "Content-Type: application/json" 'https://serveme.tf/api/reservations/12345?api_key=your_api_key'
```

The "delete" action will respond with a 204 if the reservation was deleted before it was started, else it will respond with a 200 and the reservation's information.

## Additional API Endpoints

### List Available Maps
```shell
curl -X GET 'https://serveme.tf/api/maps'
```
Returns a list of all available maps on the servers. This endpoint does not require authentication.

### List Available Servers
```shell
curl -X GET 'https://serveme.tf/api/servers?api_key=your_api_key'
```
Returns a list of all active servers with their details and locations.

### List Your Reservations
```shell
curl -X GET 'https://serveme.tf/api/reservations?api_key=your_api_key'
```
Returns a list of your reservations. Optional parameters:
- `limit` - Number of results to return
- `offset` - Offset for pagination
- `steam_uid` - Filter by Steam UID (for admin/trusted API users)

### Extend a Reservation
```shell
curl -X POST 'https://serveme.tf/api/reservations/12345/extend?api_key=your_api_key'
```
Extends the duration of an active reservation.

### Get User Information
```shell
curl -X GET 'https://serveme.tf/api/users/76561198012345678?api_key=your_api_key'
```
Returns information about a user by their Steam UID.

### Admin Endpoints
The following endpoints require admin permissions:

#### Manage Donators
```shell
# Get donator form template
curl -X GET 'https://serveme.tf/api/donators/new?api_key=your_admin_api_key'

# Get donator details
curl -X GET 'https://serveme.tf/api/donators/76561198012345678?api_key=your_admin_api_key'

# Create/update donator status
curl -X POST -H "Content-Type: application/json" -d '{"donator":{"steam_uid":"76561198012345678","expires_at":"2024-12-31T23:59:59Z"}}' 'https://serveme.tf/api/donators?api_key=your_admin_api_key'

# Remove donator status
curl -X DELETE 'https://serveme.tf/api/donators/76561198012345678?api_key=your_admin_api_key'
```

#### League Requests (League Admin)
```shell
# Search league requests
curl -X GET 'https://serveme.tf/api/league_requests?api_key=your_league_admin_api_key&league_request[ip]=1.2.3.4'
```

---

**For complete API documentation including all endpoints, request/response schemas, and interactive testing, visit the [Swagger documentation](#interactive-api-documentation) for your region.**

## MCP (for AI chatbots)

serveme.tf has an [MCP](https://modelcontextprotocol.io/) endpoint that AI tools can connect to directly over HTTPS. You need an API key from your account settings page — keys are region-specific.

```json
{
  "mcpServers": {
    "serveme-eu": {
      "type": "http",
      "url": "https://serveme.tf/api/mcp",
      "headers": {
        "Authorization": "Bearer your_api_key_here"
      }
    }
  }
}
```

| Region | URL |
|--------|-----|
| Europe | `https://serveme.tf/api/mcp` |
| North America | `https://na.serveme.tf/api/mcp` |
| South-East Asia | `https://sea.serveme.tf/api/mcp` |
| Australia | `https://au.serveme.tf/api/mcp` |

Tools include listing servers, creating/ending reservations, looking up players, linking Discord accounts, and browsing server configs and whitelists. Admin API keys get additional tools for alt detection, log searching, and user management. The tool list and schemas are self-describing via the MCP protocol.
