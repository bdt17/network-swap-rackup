# Cyberpunk Drone C2

A small live dashboard for a demo drone fleet — Thomas IT's separate drone-centric
project (distinct from `network-swap-app`, the IT asset/ticket/billing tool).

Deliberately lightweight: Sinatra (not Rails) over Sequel/Postgres, for fast cold
starts on Render's free tier. Real persistence, a live fleet simulator, login +
two-factor auth, real WebSocket broadcast, real telemetry ingestion from actual
drones, admin-configurable alerts, and real tests — see `NEXT_STEPS.md` for the
full build history and `ROADMAP.txt` for what's next.

## Building & running locally

```
bundle install
bin/migrate                       # creates/migrates db/development.sqlite3
bin/create_user you@example.com yourpassword   # first login user (admin by default)
bundle exec rackup config.ru -p 4567 -s puma
```

Visit `http://localhost:4567` and sign in. No `DATABASE_URL` needed locally —
it falls back to a file-backed sqlite DB per `RACK_ENV` (default `development`).
Point `DATABASE_URL` at a real Postgres instance (e.g.
`postgres:///cyberpunk_drone_dev`) to run against the same database engine as
production instead.

Locked out of an authenticator app? `bin/disable_mfa you@example.com` turns
2FA back off (break-glass, run wherever `DATABASE_URL` points).

`bin/create_user` takes an optional role argument for a read-only account:
`bin/create_user viewer@example.com pass viewer` (default is `admin`).

## Tests

```
RACK_ENV=test bin/migrate    # first time only
bundle exec ruby -Itest test/run.rb
```

CI (and production) run against real Postgres, not the sqlite fallback — to
match that locally:

```
createdb cyberpunk_drone_test
DATABASE_URL="postgres:///cyberpunk_drone_test" RACK_ENV=test bin/migrate
DATABASE_URL="postgres:///cyberpunk_drone_test" RACK_ENV=test bundle exec ruby -Itest test/run.rb
```

A single test file can be run directly (`bundle exec ruby -Itest test/app_test.rb`),
but `ruby -Itest test/run.rb` is the only way to run the *whole* suite — Ruby
treats a second file argument as an ARGV string, not a second file to load, so
`ruby a_test.rb b_test.rb` silently only runs `a_test.rb`.

Server-rendered HTML and JSON payloads only tell you so much — this app's own
history (see NEXT_STEPS.md Phase 14) includes a real bug that only broke actual
browser-executed JavaScript, invisible to `curl`-based checks. For anything
touching the dashboard's live/WebSocket behavior, also sanity-check with a real
browser (or at minimum `node --check` against the page's own `<script>` block)
before considering it verified.

## Adding drones

### Via the dashboard (admin only)

Click **➕ Add Drone**, enter a slug (e.g. `drone-004`) and starting
lat/lon. The new drone joins the fleet simulator immediately — no restart
needed — and starts reporting the four simulated channels (camera, link
signal, temperature, altitude) right away.

### Via the API (scripts/automation)

```
curl -X POST http://localhost:4567/api/drones \
  -H "X-Drone-Token: $DRONE_API_TOKEN" \
  -d "slug=drone-004" -d "lat=33.45" -d "lon=-112.07"
```

Any mutating endpoint (`/api/drones`, `/api/firmware`, `/api/drones/:slug/telemetry`,
etc.) accepts a session cookie *or* the shared `DRONE_API_TOKEN` env var, via
either an `X-Drone-Token` header or a `?token=` query param — set it once (in
`.env` locally, or as a Render env var) to script against the API without a
browser session. It's opt-in and inert unless set.

### Connecting a real drone (live telemetry, not simulated)

The fleet simulator only ever fakes four channels (camera/link/temperature/
altitude). An actual drone reports its own sensors by posting to the
telemetry endpoint instead:

**1. Register the drone** (if it doesn't already exist) via the dashboard or
`POST /api/drones` above.

**2. Issue it a scoped credential.** Click **🔑 Issue Token** on its card (or
`POST /api/drones/:slug/rotate_token` as an admin) — the plaintext token is
shown exactly once; only its hash is ever stored. Unlike the fleet-wide
`DRONE_API_TOKEN`, this token authorizes *only* that one drone's telemetry
endpoint, nothing else — a leaked token can't touch any other drone or the
admin API.

**3. Have the drone post its readings**, batched in one call — as often as it
reports (up to 60 posts/minute per drone; see `RateLimiter::LIMITS`):

```
curl -X POST http://localhost:4567/api/drones/drone-004/telemetry \
  -H "Content-Type: application/json" \
  -H "X-Drone-Token: <the token from step 2>" \
  -d '{"streams": {"thermal_cam": "42.7C", "gps_fix": "3D-DGPS", "vibration": "0.03g"}}'
```

Stream names are freeform (1–40 chars, letters/digits/`_`/`.`/`-`) — an
unrecognized name still gets a humanized label (`thermal_cam` → "📡 Thermal
Cam") and shows up on the dashboard tagged **live** (vs the simulator's
readings), gets its own history chart if its values look numeric, and is
flagged in the alerts panel if it goes quiet for over 2 minutes
(`LIVE_STREAM_STALE_SECONDS`, overridable). The simulator automatically backs
off faking a channel by the same name once real data starts arriving for it,
and reclaims it if the real feed goes stale.

### Setting an alert threshold on a stream

Admins can configure a threshold on any numeric stream (built-in or a real
drone's own) from the **🔔 Alert Rules** panel under Fleet Alerts — leave the
drone field blank to apply a rule fleet-wide, or scope it to one drone.
Equivalent via the API:

```
curl -X POST http://localhost:4567/api/alert_rules \
  -H "X-Drone-Token: $DRONE_API_TOKEN" \
  -d "stream_name=thermal_cam" -d "operator=gt" -d "threshold=60"
```

## Environment variables

| Variable | Required? | Purpose |
|---|---|---|
| `DATABASE_URL` | Production only | Postgres connection string. Unset locally/in tests, where it falls back to a file-backed sqlite DB per `RACK_ENV`. |
| `RACK_ENV` | No (default `development`) | `development`, `test`, or `production`. |
| `DRONE_API_TOKEN` | No | Shared fleet-wide credential bypassing login for scripts — full admin access. Opt-in, inert unless set. |
| `SESSION_SECRET` | No (auto-generated if unset) | Signs the short-lived pending-2FA session; set explicitly in production so restarts don't invalidate in-flight logins. |
| `SESSION_TIMEOUT_HOURS` | No (default: never expire) | Idle session timeout. |
| `SIMULATOR_TICK_SECONDS` | No (default `6`) | How often the fleet simulator advances. |
| `LIVE_STREAM_STALE_SECONDS` | No (default `120`) | How long a live (real-drone) stream can go quiet before the alerts panel flags it. |

## Deploying

`render.yaml` is a Render Blueprint — in the Render dashboard, **New → Blueprint**,
point it at this repo. It provisions both the web service (`cyberpunk-drone-c2`)
and a `drone_db` Postgres database, wired together via `DATABASE_URL`. Migrations
run automatically as part of the build command. After the first deploy, run
`bin/create_user` in the Render shell to create your first login.
