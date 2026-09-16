# cyberpunk-drone-c2 — Status & Next Steps

_Last updated: 2026-09-15. Keep this file updated in place — do not create
timestamped copies of it, following the same convention `network-swap-app`
(the sibling repo) settled on after getting burned by dozens of those._

## What this app is

A small live dashboard for a demo drone fleet — a **separate, drone-centric**
Thomas IT project, distinct from `network-swap-app` (the real product: IT
asset/ticket/billing tracking for client sites, no drones in it). This app is
deliberately lightweight: Sinatra + Sequel/Postgres rather than Rails, chosen
for fast cold starts on Render's free tier — that's the whole reason a prior
session rewrote it out of an earlier full-Rails version into raw Rack, before
this session added real persistence back on top without reintroducing Rails.

## Repo history note (2026-09-12)

Before this session, four different local checkouts of this app existed on
disk in inconsistent states — two of them (`network-swap-rackup`,
`network-swap-rackup-backup`) had their git remote pointed at
`network-swap-app.git` (the *other*, unrelated repo) instead of this one, a
real hazard: a push from either would have landed drone-app history in the
wrong repo. (It turned out this had already happened once, and been
reverted — see `network-swap-app`'s own git history for the "Revert
'Rackup migration...'" commit.) Both were deleted after confirming every
commit in them was already reachable in `network-swap-app`'s local git
objects, so nothing was lost. A third copy (`rackup-fix`) was a strict git
ancestor of this one and was also deleted. This directory
(`network-swap-rackup-new` locally, `bdt17/network-swap-rackup` on GitHub) is
now the only copy — keep it that way.

## Phase 1 — Real backing app — DONE (2026-09-12)

The app was a 91-line `config.ru` with an in-memory `$drone_fleet` hash (state
lost on every restart/deploy) and a handful of real bugs. Rebuilt with real
persistence, without adding Rails:

- **Framework.** Sinatra (`Sinatra::Base`, modular style) over the same bare
  Rack/`rackup` stack — `app.rb` holds the app, `config.ru` just requires and
  runs it.
- **Persistence.** Sequel + Postgres in production (`DATABASE_URL`, provided
  by the `drone_db` database declared in `render.yaml`), falling back to a
  file-backed sqlite DB per `RACK_ENV` locally/in tests — nothing extra to
  install to get running. Three tables: `drones` (replaces the in-memory
  hash), `firmware_events` (audit trail of every flash: from/to version,
  timestamp), `command_events` (every WebSocket message received, for later
  analysis). Migrations in `db/migrations/`, run via `bin/migrate` locally or
  `bundle exec sequel -m db/migrations "$DATABASE_URL"` (wired into
  `render.yaml`'s build command, same "migrate on every deploy" pattern
  `network-swap-app` uses).
- **Real bugs fixed:**
  - `render.yaml` referenced a `drone_db` database via `fromDatabase` that was
    never actually declared anywhere in the file — the Render Blueprint would
    have failed to resolve it. Added the `databases:` section.
  - The file was named `.render.yaml` (dotfile); Render's Blueprint UI looks
    for `render.yaml` by default and reported "not found." Renamed.
  - `/api/firmware` hardcoded every flash to `v2.2.0` regardless of current
    version, and threw an unhandled `NoMethodError` (500) for an unknown
    `drone_id` instead of a 404. Now bumps the minor version for real and
    validates the drone exists first.
  - Sinatra's `not_found`/`error 404` handler fires for **any** response that
    ends up with a 404 status — including a deliberate `halt 404, json` from
    inside a matched route, not just genuinely-unmatched paths — and it was
    silently overwriting the `/api/firmware` "Unknown drone" JSON body with
    the generic plain-text 404 page. Fixed to pass through an already-JSON
    body untouched.
  - The WebSocket message handler didn't distinguish message types — a
    command-ack response (`{status:'cmd_ok'}`) would get misinterpreted by
    the client as a full fleet-state push and corrupt the UI. Both server and
    client now tag messages with `type: 'fleet'` / `type: 'cmd_ack'`.
  - **Server swapped from WEBrick to Puma.** `faye-websocket`'s WEBrick
    support relies on `rack.hijack`, and under this Rack 3.2/`rackup` 2.3
    combination it produced a broken handshake — the server logged a
    successful connection, but the client saw "Invalid HTTP response" and
    never actually connected. Confirmed via a real end-to-end WebSocket
    client test, not just reasoning about it. Puma is a well-supported,
    widely-used pairing with `faye-websocket`; `network-swap-app` already
    runs Puma too, so this is now consistent across both of Brett's apps.
  - Firmware flashes and inbound WebSocket commands weren't broadcast to
    *other* connected viewers — only the socket that triggered them (or
    none, for HTTP-triggered flashes) ever saw the update. `broadcast_fleet!`
    now pushes the new state to every open socket after any mutation.
- **Dead weight removed.** `public/` had a dozen files not wired to any
  route — six one-line `<h1>...(stub)</h1>` placeholders, a fake
  login-redirect page, an AR.js overlay experiment, alternate dashboards
  pulling `cdn.tailwindcss.com` (the exact CDN anti-pattern `network-swap-app`
  already fixed once), and a PWA manifest/service-worker referencing assets
  that don't exist in this app. None of it was reachable through `config.ru`'s
  routing, but Sinatra auto-serves anything under `public/` as a static file,
  so switching frameworks would have made all of it live. Deleted rather than
  carried forward.
- **Tests.** `test/app_test.rb` (Minitest + Rack::Test) covers health,
  homepage rendering, a successful firmware flash (version bump + event
  logged), the unknown-drone 404, the missing-`drone_id` 400, and a generic
  404. `Seeds.reset!` reseeds the two demo drones before every test.

Verified end-to-end by hand this session: booted the app for real (not just
the test client), hit every HTTP route with `curl`, and ran a real
`faye-websocket` client against a live Puma-served instance — confirmed the
initial fleet push on connect *and* a live broadcast of a firmware flash to
an already-connected client. Also confirmed against the deployed Render
instance itself (not just locally): `/health`, homepage rendering, a real
firmware version bump, the unknown-drone 404, and a real `wss://` client
receiving both the initial fleet push and a live broadcast of an
HTTP-triggered flash.

## Phase 2 — Fleet realism, real commands, fleet management, login + MFA — DONE (2026-09-12)

- **Live fleet simulator** (`fleet_simulator.rb`). A background `Thread`,
  started from `config.ru` (not `app.rb`, so requiring it for tests doesn't
  spin one up), ticks every `SIMULATOR_TICK_SECONDS` (default 6): drains
  battery while a drone is flying, drifts its lat/lon slightly, auto-recalls
  it to `CHARGING` at ≤15% battery, recharges it back to `ACTIVE`, and leaves
  `MAINTENANCE` drones alone. Broadcasts the updated fleet after any tick
  that actually changed something. Verified locally by watching a drone's
  battery/position actually change over several ticks with zero manual
  action, and confirmed the same fleet-hash the simulator writes is what the
  already-existing `/` page and WebSocket broadcast read — no separate state.
- **Real WebSocket commands.** `handle_command`/`apply_command` now support
  `recall` (→ `CHARGING`), `resume` (→ `ACTIVE`), and `set_status` (any of
  `Drone::STATUSES`, rejecting anything else with a real error message
  instead of silently no-op'ing). Every command is still logged to
  `command_events` regardless of outcome; a command that actually changed
  state triggers `broadcast_fleet!` so every connected viewer sees it, not
  just whoever sent it.
- **Fleet management.** `POST /api/drones` (create — validates a non-empty,
  unique slug) and `DELETE /api/drones/:slug` (destroy — cascades its
  firmware/command history via the existing FK `on_delete` rules) replace
  the fixed two-drone fleet. The dashboard has "➕ Add Drone" / "🗑 Remove"
  buttons (`prompt()`/`confirm()`-based, consistent with the existing
  `uploadFirmware` style — no build step added).
- **Per-drone history page.** `GET /drones/:slug` renders the drone's
  `firmware_events` + `command_events` as one time-ordered timeline. Linked
  from every drone card ("📜 History").
- **Login + two-factor auth**, mirroring the pattern already proven in
  `network-swap-app`: bcrypt-hashed passwords (`User#password=`/`#authenticate`),
  a `sessions` table holding an opaque token (the cookie itself only carries
  that token, not any session data), and TOTP two-factor via `rotp` +
  `rqrcode` (QR enrollment, 10 one-time hashed backup codes shown once).
  `bin/create_user` / `bin/disable_mfa` are the break-glass scripts (this app
  has no `rake`, unlike the sibling repo, so these are plain Ruby instead of
  rake tasks). A global `before` filter requires a logged-in session for
  every route except `/login`, `/two-factor-challenge`, and `/health` —
  **except** a route matched by a configured `DRONE_API_TOKEN` (unchanged
  from Phase 1: opt-in, inert unless set), so scripts/curl can still hit the
  mutating API endpoints without a browser session. The "landing page" is
  the login form itself (`GET /login` when logged out) rather than a
  separate marketing page — kept in scope; a real landing page is easy to
  add later if this needs one.
- **Tests.** 26 total (`test/run.rb` runs every `*_test.rb` — a plain
  `ruby a_test.rb b_test.rb` silently only runs the first file, since Ruby
  treats the second as an ARGV string). New coverage: create/delete drone,
  the history page, all three WebSocket commands (called directly via
  `App.new!` — the bang version, since `App.new` returns Sinatra's
  Rack-middleware wrapper, not an instance you can call helpers on), the
  token-bypasses-login path, login success/failure, the full 2FA
  enroll → confirm → logout → challenge round-trip (using a real generated
  TOTP code, not a stub), a wrong-code rejection, a backup code working
  exactly once, and disabling 2FA requiring the password. `BCrypt::Engine.cost
  = 4` in `test_helper.rb` keeps bcrypt's deliberately-slow hashing from
  making every login-per-test add ~300ms.
- **Real bug caught by the tests, not just written correctly the first
  time:** `ROTP::TOTP` has no `otpauth_uri` method — the real one is
  `provisioning_uri`. Caught immediately because the 2FA enrollment test
  actually renders the page and asserts on it, rather than mocking TOTP out.

## Phase 3 — Named telemetry streams, and a real production bug fix — DONE (2026-09-12)

- **Named simulated telemetry streams.** Beyond the drone's core state
  (lat/lon/battery/status, unchanged), each drone now has four independent,
  labeled data channels updated every simulator tick: **📷 Camera**
  (`OK`/`DEGRADED`, `OFFLINE` when grounded for maintenance), **📶 Link**
  (signal strength, stronger when grounded/near base), **🌡️ Temp** (warmer
  while flying), **📏 Altitude** (0 when grounded). New `stream_readings`
  table (`StreamReading` model) — self-limiting like `AssistantFeedback` in
  the sibling app: each write prunes that drone+stream pair down to the
  most recent 20 readings, so it never needs a cron job to stay bounded.
  Shown as labeled chips on each drone card (both server-rendered and the
  WebSocket-updated view) and merged into the per-drone history timeline
  alongside firmware/command events.
- **Real production bug found and fixed: the background-thread simulator
  never actually worked in production.** Phase 2's `Thread.new`-based
  simulator was verified working *locally* (a real WebSocket client received
  a broadcast every tick for 20+ seconds), but in production the thread
  reliably died within its first few seconds on every boot —
  `thread_alive?` false, zero ticks completed, and no exception caught even
  under a temporarily widened `rescue Exception` — while the rest of the
  process (Puma, the DB, broadcasts triggered from real HTTP requests)
  worked correctly for the process's entire lifetime. That combination
  (dies immediately, nothing in Ruby can observe why, everything else is
  fine) means something outside the language was killing it — not a bug
  reachable by fixing the rescue clause. Root-caused via a health-endpoint
  diagnostic (`FleetSimulator.status`: tick count, last tick time, last
  error) added specifically to compare "did it ever run" against "is it
  alive now," rather than guessing blind. **Fix:** `FleetSimulator.tick_if_due!`
  replaces the Thread entirely — `App`'s global `before` filter calls it on
  every real incoming request, a mechanism already proven 100% reliable
  here. Render's own health-check polling alone keeps it ticking even with
  zero dashboard tabs open. Non-blocking (`Mutex#try_lock`), so a tick can
  never add latency to a concurrent unrelated request.
- Verified end-to-end against the deployed instance after each fix: `/health`
  showing real tick counts advancing, a real `wss://` client receiving the
  initial fleet push, and the dashboard/history page rendering live stream
  chips.

## Phase 4 — CI — DONE (2026-09-12)

`.github/workflows/ci.yml`, modeled on `network-swap-app`'s: an `audit` job
(`bundler-audit`, dependency CVE scanning) and a `test` job (real Postgres
service container, matching production's adapter rather than the sqlite
fallback). No Brakeman/Rubocop jobs — this app has neither gem installed nor
config for them, and adding both well for a Sinatra (not Rails) app was more
setup than the payoff justified right now.

Setting this up immediately caught something real: `bundler-audit` flagged
two **High** severity CVEs in Puma 6.6.1 (`CVE-2026-47736`/`-47737`, PROXY
protocol v1 memory exhaustion), fixed in ≥8.0.2. Bumped `puma` to `~> 8.0`
and re-verified the fragile part by hand — a real `faye-websocket` client
authenticating with a session cookie against a live Puma-8-served instance,
confirmed still receiving fleet data correctly (this is the same dependency
pair that broke once already going from WEBrick to Puma 6, so it got a real
check rather than trusting semver). Also verified the whole test suite
passes against a real local Postgres server, not just sqlite, since that's
what CI (and production) actually run against.

## Phase 5 — Real front-end design pass + operational functions — DONE (2026-09-12)

Kept the "cyberpunk neon" identity (deliberate choice over a generic redesign)
but executed it properly, plus real new functionality:

- **Live radar map.** Replaces plain "Lat/Lon: X, Y" text with an actual
  SVG radar (`radar_svg`/`radar_blips` in `app.rb`): concentric rings, a
  continuously-rotating sweep, and a pulsing status-colored blip per drone,
  labeled with its slug. Auto-fits every drone's lat/lon into the circle
  around the fleet's own midpoint (not a real map/no tiles), so a
  newly-added drone anywhere on Earth still shows up sensibly rather than
  needing a fixed real-world scale — verified with a drone at `(0,0)` and
  one at `(10,10)` both clamping inside the circle. The sweep's rotation
  `<g>` is deliberately left untouched by live WebSocket updates (only
  `#radar-blips` gets replaced each tick) so the animation never resets
  mid-sweep — a naive full-redraw-on-every-tick approach would have made it
  visibly stutter every 6 seconds.
- **Fleet alerts panel.** Live-computed anomaly list: battery ≤15% (and not
  already charging), camera `DEGRADED`/`OFFLINE`, link signal ≤ ‑80dBm — or
  "✅ All systems nominal" when clean. Computed both server-side (initial
  render) and client-side (`computeAlerts`, mirrors the Ruby logic exactly)
  so it updates live via the same WebSocket broadcast everything else uses.
- **Real history charts.** Sparkline SVGs (thin 2px line, single hue,
  hover tooltips showing exact value + time) for battery, temperature, link
  signal, and altitude on the per-drone history page — using the
  `dataviz` skill's mark specs (thin marks, rounded data, no dual-axis, one
  hue per magnitude series, status colors reserved and always paired with a
  text label, never color-alone). Battery is now also logged to
  `stream_readings` on every change specifically so it has real history to
  chart — previously only its *current* value ever persisted anywhere.
- **CSV export** (`GET /drones.csv`) — the whole fleet's current state and
  latest telemetry in one file, matching the CSV-export pattern
  `network-swap-app` already uses for devices/tickets/invoices.
- **Visual polish.** A subtle animated scanline texture, a numeric
  percentage readout overlaid on the battery bar (previously just a color
  bar with no number), button hover states, shared `base_css` extracted so
  the dashboard and history page stay visually consistent instead of
  duplicating (and drifting from) the same rules.
- 7 new tests (radar clamping, alerts nominal/low-battery/degraded-camera,
  CSV export, chart rendering). 44 tests total, all passing.

## Phase 6 — Login rate limiting — DONE (2026-09-12)

`rate_limiter.rb`: an in-memory limiter (10 attempts / 3 minutes / IP,
matching `network-swap-app`'s own `rate_limit to: 10, within: 3.minutes` on
its SessionsController) applied to both `POST /login` and
`POST /two-factor-challenge` — a 429 with "Too many attempts" past the
limit. In-memory rather than DB-backed, consistent with everything else in
this app (`settings.sockets`, `FleetSimulator`'s tick gate) being
single-instance-only by design already (gap #1 below).

Verified locally by booting the app and sending 11 rapid wrong-password
attempts at `/login` — first 10 came back 401, 11th 429. **That passed
locally but did nothing in production** — the same 11 attempts against the
live instance all came back 401. Root cause, found via a temporary debug
log rather than guessing: Rack's `request.ip` was picking the *wrong* hop
out of Render's proxy chain. Given
`X-Forwarded-For: "172.59.204.44, 172.70.214.67"`, the leftmost entry
(`172.59.204.44`, the real client) was identical across every request from
the same curl session, but `request.ip` returned the *rightmost* entry,
which rotated between requests - so every attempt landed in a different
rate-limit bucket and the count never accumulated. Fixed with a `client_ip`
helper that explicitly takes the leftmost `X-Forwarded-For` entry (falling
back to `request.ip` when the header is absent, e.g. local dev/tests) -
not spoof-proof against a client that could reach the origin directly
bypassing Cloudflare, but correct for how this app is actually deployed.
Reverified against the live instance afterward with a real distinguishing
signal (custom `X-Forwarded-For` via curl), not just re-trusting the local
test. Also fixed a rare pre-existing flake surfaced while adding these:
`test_next_state_for_active_drone_drains_and_drifts` asserted only `lat`
changed, which had a small chance of failing when that axis's random drift
happened to round to exactly 0.0 - now checks that at least one of lat/lon
changed. 51 tests total (including two regression tests specifically for
the leftmost-hop behavior, since Rack::Test sends no X-Forwarded-For at all
and so never exercised the code path that broke), all passing.

## Phase 7 — Roles + session expiry — DONE (2026-09-12)

- **Roles.** `users.role` (`admin`/`viewer`, migration backfills existing
  accounts to `admin` so nobody's own access silently changed). Viewers can
  sign in, view the dashboard/history/radar/alerts, and manage their own
  password/2FA, but can't create/delete drones, flash firmware, or send
  WebSocket commands (`recall`/`resume`/`set_status`) - `require_admin!`
  gates the HTTP routes (halts 403), `admin_access?` gates the WebSocket
  command handler (halt doesn't work in an async callback outside the
  request cycle, so it just returns an unapplied result with an error
  instead). A configured `DRONE_API_TOKEN` keeps its original full-access
  design either way - it's a shared secret for scripts with no associated
  user, not subject to role checks. The UI hides admin-only controls
  (Add Drone, Flash, Remove) for viewers server-side on first render and
  client-side on every live WebSocket update, rather than showing buttons
  that would just 403 on click. `bin/create_user` takes an optional role
  argument (default `admin`, since nothing in this app provisions other
  accounts through a UI the way `network-swap-app` does - explicit `viewer`
  for a read-only account).
- **Session expiry.** `SESSION_TIMEOUT_HOURS` (unset = sessions never idle
  out, matching `network-swap-app`'s own env var of the same name and
  same default-off behavior) - a session idle longer than that is destroyed
  on its next request rather than checked on a timer.
- Verified locally end-to-end for both: a viewer account blocked (403) from
  creating a drone via curl, its dashboard confirmed to render zero
  firmware-upload inputs; a session's `last_active_at` backdated past a
  short `SESSION_TIMEOUT_HOURS` and confirmed to bounce to `/login` on its
  next request.
- 9 new tests (admin gating on all three HTTP mutation routes + the
  WebSocket command path, viewer UI omission, session expiry both with and
  without the env var set). 58 tests total, all passing (3 runs in a row).

## Phase 8 — Real firmware file storage — DONE (2026-09-14)

The upload UI always looked real (a file picker, a FLASH button that built
real `FormData`) but the server never read `params['firmware']` at all -
every flash just bumped a version string regardless of what was picked.

- `firmware_events` gained `filename`/`content_type`/`data` (`File` column
  type - `bytea` on Postgres, `BLOB` on sqlite, portable across both).
  Stored directly in Postgres rather than R2/S3: unlike `network-swap-app`'s
  ticket photos (real photos, meaningfully large, no size cap chosen
  deliberately), firmware images are small binary blobs with a sensible
  cap, so this needed no new infrastructure or env vars to ship working.
- `POST /api/firmware` now validates the extension (`.bin`/`.hex`) and size
  (≤8MB) before storing, with a real 422 for either violation instead of
  silently accepting anything.
- `GET /drones/:slug/firmware/:event_id/download` serves the exact bytes
  back, linked from the history page next to each flash that has one.
- **Self-limiting like `StreamReading`, but split differently:** the full
  from/to-version audit trail stays forever (it's tiny, text-only) - only
  the actual binary blobs get pruned, keeping just the most recent 10 per
  drone, so a demo app doesn't accumulate unbounded binary storage from
  repeated flashes while still keeping its complete version history intact.
- Verified for real, not just via tests: a real `curl -F` multipart upload
  against a live local instance, downloaded it back, and diffed the bytes
  against the original file - identical. Also hand-verified the wrong-
  extension rejection with a real request.
- 5 new tests (upload + download round-trip with byte-for-byte comparison,
  wrong extension, oversized file, downloading when no file was ever
  attached, blob pruning beyond the keep limit). 63 tests total, all
  passing across 3 repeated runs.

## Phase 9 — Real telemetry ingestion API — DONE (2026-09-15)

Phase 3's four telemetry channels (camera/link/temp/altitude) were entirely
server-side fiction - `FleetSimulator` invented every value, and nothing let
an actual drone (or a script standing in for one) report its own sensors.
This phase adds a real ingestion path so a drone can push multiple, freely
named data streams in one call and have them labeled and displayed the same
way the simulated ones are.

- **`POST /api/drones/:slug/telemetry`.** JSON body `{"streams": {"thermal_cam":
  "42.7C", "gps_fix": "3D", ...}}` - a batch in one call, since a real drone
  reports several sensors per cycle rather than one HTTP round-trip per
  value. Gated by `require_admin!`, same as `/api/firmware` and
  `/api/drones` - a configured `DRONE_API_TOKEN` lets headless hardware post
  without a browser session. Validates the drone exists (404), `streams` is
  a non-empty object (400), stream count (`StreamReading::MAX_STREAMS_PER_INGEST`
  = 25), stream-name shape (`StreamReading::NAME_PATTERN`, ≤40 chars,
  `[a-zA-Z0-9_.-]`), and value length (`MAX_VALUE_LENGTH` = 100) - real 422s
  for any violation rather than silently accepting garbage. Each reading is
  stored via the existing self-pruning `StreamReading.record!`, now tagged
  `source: 'live'` (vs `'simulated'` for `FleetSimulator`'s own writes - new
  `stream_readings.source` column, migration 010, backfills existing rows
  as `'simulated'`).
- **The simulator backs off a stream once real data starts arriving for
  it.** Before this, `FleetSimulator` would have overwritten a just-posted
  live reading on its very next tick (≤6s later), fighting any real feed.
  `StreamReading.live?(drone_id, stream_name, within:)` checks for a recent
  live reading; `FleetSimulator.tick!` skips faking a stream if one exists
  within `LIVE_PREEMPT_SECONDS` (3 ticks' worth). The simulator reclaims the
  stream on its own once the real feed goes quiet - no manual toggle needed.
- **Labeling generalized beyond the four hardcoded names.** `stream_label`
  (app.rb) falls back to a humanized name (`thermal_cam` → "📡 Thermal Cam")
  for anything not in `FleetSimulator::STREAM_LABELS`/`CHART_STREAMS`, so an
  ad-hoc stream name a real drone invents still shows up labeled instead of
  being silently dropped. `stream_chips_html` now renders *every* stream
  present on the drone (known ones first in their usual order, then extras
  alphabetically), not just the simulator's fixed four - and tags a chip
  `.stream-chip.live` (magenta accent) when its latest reading came from a
  real POST rather than the simulator. The live/WebSocket-updated view
  mirrors this exactly (`streamChipsHtml`/`streamLabel` in the page's own
  JS), matching the existing "server-rendered and WS-updated must agree"
  rule from Phase 5's alerts panel. `Drone#to_fleet_json` gained a parallel
  `stream_sources` map alongside `streams` (name→'live'/'simulated') rather
  than nesting source inside each stream value, so nothing that already
  reads `streams` as plain name→value strings (alert thresholds, CSV
  export) needed to change shape.
- **History-page charts generalized too.** Beyond `FleetSimulator::CHART_STREAMS`'s
  four curated entries, any other stream whose latest value looks numeric
  (`/\A-?\d/` - a real leading number, not a status string like "OK") gets
  its own sparkline automatically, labeled the same way as its chip. A
  chart card is only rendered once a stream actually has readings, rather
  than always showing four (now potentially many) permanent "not enough
  data yet" placeholders.
- Verified for real, not just via tests: booted the app locally, posted a
  telemetry batch with three never-before-seen stream names
  (`thermal_cam`/`gps_fix`/`vibration`) via `curl` with the API token,
  confirmed they rendered labeled and tagged `stream-chip live` on the
  dashboard, and got their own sparkline charts on the history page. Also
  hand-verified the 422s (bad stream name, >25 streams in one request) and
  that an unauthenticated request is bounced (redirected to login) exactly
  like every other route.
- 12 new tests (8 in `test/app_test.rb` covering the happy path, labeling/live
  badge on both dashboard and history page, unknown drone, missing/invalid
  JSON, too-many-streams, invalid name, oversized value, admin gating, and
  token bypass; 2 in `test/fleet_simulator_test.rb` covering the
  live-preempts-simulated behavior and its own expiry). 75 tests total, all
  passing.

## Phase 10 — Stale live-feed alerts — DONE (2026-09-15)

Phase 9 let a real drone push its own labeled telemetry, but gave no signal
if that feed ever stopped - a `source: 'live'` reading just sits there as
the permanent "latest value" with nothing indicating it's gone quiet
(unlike the four simulator-known streams, which the simulator reclaims and
keeps fresh forever). For a live-ops dashboard, a silently-dead real feed
is a more dangerous failure mode than a low battery - it means you've lost
visibility into that sensor entirely and don't know it.

- **`StreamReading::LIVE_STALE_SECONDS`** (default 120, overridable via
  `LIVE_STREAM_STALE_SECONDS` - same env-var-override convention as
  `FleetSimulator::TICK_SECONDS`). `fleet_alerts` now flags any stream
  whose latest reading has `source: 'live'` and is older than this as
  `"🛰️ <slug>: <label> feed stale (last update <age> ago)"` - reusing the
  same `stream_label` fallback labeling from Phase 9, so an ad-hoc stream
  name still reads clearly in the alert. A `'simulated'`-source stream
  never triggers this regardless of age, since the simulator itself
  guarantees freshness for those.
- **Live WebSocket view mirrors this exactly**, per the same
  "server-rendered and WS-updated must agree" rule Phase 5 established for
  the rest of the alerts panel. `Drone#to_fleet_json` gained a third
  parallel map, `stream_ages_s` (seconds since each stream's last reading,
  computed fresh per broadcast) alongside the existing `streams`/
  `stream_sources`, so the page's own JS can compute staleness without
  needing a client-side clock/timer - it just re-evaluates on every
  broadcast, which happens roughly every simulator tick regardless of
  whether the stale stream itself changed.
- Caught and fixed during manual verification, not by a test: the first
  version used the same 📡 emoji for both the alert-row prefix and
  `stream_label`'s own fallback-label prefix for unknown stream names,
  producing a visibly doubled "📡 ... 📡 Thermal Cam feed stale". Switched
  the alert prefix to 🛰️ to disambiguate "this is about a drone's feed"
  from "this stream has no curated label."
- Verified for real: booted locally with `LIVE_STREAM_STALE_SECONDS=3` for
  a fast manual check, posted live telemetry via curl, confirmed no alert
  immediately after, then confirmed `"🛰️ drone-001: 📡 Thermal Cam feed
  stale (last update 4s ago)"` appeared after waiting past the threshold.
- 3 new tests (stale live stream flagged, fresh live stream not flagged,
  stale *simulated* stream never flagged). One of the three caught a real
  test-writing mistake, not app code: a naive `refute_includes body, "feed
  stale"` was tripped by the string always being present in the page's own
  JS `computeAlerts` function source, not by an actual rendered alert - the
  same gotcha already documented elsewhere in `test/app_test.rb` for the
  "FLASH" button text. Fixed to assert the positive "All systems nominal"
  state instead. 78 tests total, all passing.

## Phase 11 — Rate-limit telemetry ingestion — DONE (2026-09-16)

Item 3 off the candidate list (`ROADMAP.txt`), picked first over the other
open items because it's the tightest-scoped and lowest-risk: a near-direct
reuse of `RateLimiter` (Phase 6) rather than a new credential model
(item 2) or new infrastructure (item 1's multi-instance support) that
deserve their own discussion first.

- **New `:telemetry` bucket** in `RateLimiter::LIMITS` (60 requests / 60
  seconds), keyed by **drone slug**, not caller IP like `:login`/
  `:two_factor` - the thing worth protecting here is a single drone's feed
  (and the fleet-wide broadcast every successful post triggers), not a
  particular network origin. `POST /api/drones/:slug/telemetry` checks it
  right after confirming the drone exists, a real 429 past the limit.
- `app.rb` now requires `rate_limiter` directly rather than relying on
  `auth.rb` happening to load it first (true today per `config.ru`'s
  require order, but the route body referencing `RateLimiter` is a real
  dependency of `app.rb` itself, so it shouldn't depend on load-order
  coincidence from another file).
- Verified for real, not just via tests: booted locally and sent 61 rapid
  telemetry POSTs with a real drone token via curl - the first 60 came
  back 200, the 61st came back 429, matching the unit-level expectation
  exactly.
- 2 new tests (`RateLimiter`'s own bucket behavior - limit, independent
  per-drone bucketing; and a real end-to-end hit against the route
  confirming both the 429 and that a *different* drone's own bucket is
  untouched). 80 tests total, all passing.

## Phase 12 — Per-drone ingestion credentials — DONE (2026-09-16)

Item 2 off the candidate list - the highest-value remaining item, since
`DRONE_API_TOKEN` (Phase 9) is one shared secret for the *entire fleet*
and, because it also satisfies `admin_access?`, a single leaked token
grants full command/firmware/fleet-management rights, not just telemetry
posting for the drone it was meant for.

- **`drones.token_digest`** (migration 011, nullable - existing drones
  have no scoped credential until an admin issues one). `Drone.hash_token`
  (SHA-256, no salt) mirrors `BackupCode.hash_code`'s own reasoning: a
  high-entropy generated credential, not a human-memorized password, so
  bcrypt's deliberate slowness buys nothing here.
- **`POST /api/drones/:slug/rotate_token`** (admin-only) issues a fresh
  `SecureRandom.hex(24)` token, returned in the response body exactly
  once - like the 2FA backup codes, only its digest is ever persisted, so
  it can't be recovered later, only rotated again. **`DELETE
  /api/drones/:slug/token`** (admin-only) revokes it outright.
- **Strictly scoped, by design - never folded into `admin_access?`.** A
  new `valid_drone_telemetry_token?(drone)` helper (auth.rb) only ever
  authorizes `POST /api/drones/:slug/telemetry` for *that exact drone* -
  checked directly against `request.path_info` in the global `before`
  filter (ahead of Sinatra's own route-param binding, which hasn't
  happened yet at that point in dispatch) so a valid scoped token can skip
  `require_login!` the same way `DRONE_API_TOKEN` already does, without
  ever satisfying `require_admin!`/`admin_access?` for anything else. A
  token for drone-001 posting telemetry for drone-002, or trying to hit
  `DELETE /api/drones/drone-002`, is rejected exactly like an unauthenticated
  request would be.
- **Dashboard gets Issue/Rotate/Revoke Token admin buttons**, mirroring
  the FLASH/Remove pattern - `Drone#to_fleet_json` gained a `has_token`
  boolean (not sensitive - just presence, never the digest or plaintext)
  so both the server-rendered and live WebSocket-updated card show the
  right button set, per the same server/WS-parity rule used everywhere
  else in this app. A new token is shown once via `alert()`, consistent
  with how every other one-shot result (flash status, create/delete
  errors) is already surfaced in this app's deliberately build-step-free
  frontend.
- Verified for real against a live local instance with **no
  `DRONE_API_TOKEN` configured at all**, to isolate the new scoped-token
  path from the pre-existing fleet-wide one: logged in, rotated a token
  for drone-001, then - from a completely logged-out request with no
  cookie - posted telemetry for drone-001 successfully (200), confirmed
  the *same* token was rejected for drone-002's telemetry and for
  `DELETE /api/drones/drone-002` (both redirected to login, same as any
  unauthenticated request), then revoked it and confirmed the old token
  stopped working. Also caught a verification-methodology gotcha, not an
  app bug: a naive `grep` across the whole rendered page matched "Revoke
  Token" from the page's own always-present JS template source, not an
  actually-rendered button - scoping the grep to only the server-rendered
  drone cards (excluding `<script>`) showed the real, correct state.
- 8 new tests (rotate/revoke admin-gating, a rotated token actually
  working end-to-end, rotating invalidating the previous token, scoping
  to one drone's telemetry only, confirming no fleet-wide admin access,
  revoke disabling the token). 87 tests total, all passing.

## Phase 13 — Multi-instance support — DONE (2026-09-16)

Item 1 off the candidate list, and the last of the three deliberately-
deferred items - closes the "single-instance only" gap flagged since
Phase 8. All three in-memory mechanisms (`settings.sockets`' broadcast
reach, `FleetSimulator`'s tick gate, `RateLimiter`) only ever saw state
from the one process they ran in; with more than one instance behind a
load balancer, each would silently do its own separate thing - duplicate
simulator ticks draining batteries too fast, a WebSocket viewer on
instance B never seeing a mutation that happened to land on instance A,
and `RateLimiter` allowing up to the limit *per instance* instead of
fleet-wide. The app currently runs as exactly one instance on Render's
free plan, so none of this was reachable in production today - but the
code no longer assumes it stays that way.

**The hard constraint this had to design around:** Phase 3 already proved
a persistent background Thread reliably gets killed within seconds in this
specific hosting environment, for reasons invisible to Ruby itself -
that's the entire reason `FleetSimulator` runs off opportunistic
per-request polling instead of a thread ticking on its own schedule. A
naive multi-instance design (e.g. Postgres `LISTEN`/`NOTIFY` with a
blocking subscriber thread per instance) would almost certainly hit the
exact same failure mode. Everything below deliberately avoids any
long-lived background thread or blocking wait, sticking to the same
"opportunistic work off real request traffic" pattern already proven
reliable here.

- **New `cluster_state` table** (migration 013): a tiny shared key-value
  table, two known rows only (not a general-purpose store):
  - `fleet_last_changed_at` - a timestamp marker any instance can check
    to know "has fleet state changed since I last relayed it."
  - `simulator_next_tick_at` - the shared "when's the next tick due" gate,
    replacing `FleetSimulator`'s old in-memory `@next_tick_at`.
  Both rows are seeded directly in the migration so runtime code never has
  to distinguish "row missing" from "not due yet."
- **`ClusterState.claim_due!`** (models.rb): a single atomic conditional
  `UPDATE ... WHERE value <= now` - no explicit transaction or row lock
  needed, since one UPDATE statement is already atomic on its own in both
  Postgres and SQLite. Returns true only for whichever instance's UPDATE
  actually lands first for a given slot; every other instance (or thread)
  checking the same slot sees 0 rows affected and correctly backs off.
  `FleetSimulator.tick_if_due!` now claims via this instead of comparing
  against its own in-memory `@next_tick_at` - so with N instances, exactly
  one of them runs a given tick, not one per instance. `@tick_count`/
  `@last_tick_at` stay per-instance (useful on `/health` as "is *this*
  instance pulling its weight"); `next_tick_at` in `/health` now reads the
  shared cluster-wide value instead.
- **Cross-instance WebSocket relay, via polling instead of pub/sub.**
  `App.broadcast_fleet!` now does two things: pushes to its own locally-
  connected sockets immediately (unchanged), and records `Time.now` into
  `fleet_last_changed_at`. Every instance's global `before` filter calls
  the new `relay_remote_broadcasts!` on every incoming request (one cheap
  indexed single-row `SELECT`) - if the marker has moved since that
  instance last relayed it, it pushes to its own local sockets too. The
  originating instance recognizes its own marker as already-relayed and
  skips the redundant re-push. This means cross-instance delivery has the
  same small, accepted latency as the simulator's own ticks - bounded by
  how often each instance happens to receive a request - rather than true
  instant push, which is the direct tradeoff for not using a blocking
  subscriber thread.
- **`RateLimiter` moved off its in-memory `@hits` Hash onto a new
  `rate_limit_hits` table** (migration 012, `RateLimitHit` model) - an
  in-memory counter only ever saw attempts that landed on that exact
  process, so two instances behind a load balancer would each
  independently allow up to the limit (effectively doubling it, or more,
  with more instances). Same lazy per-key pruning behavior as before
  (a bucket+key's stale rows are deleted on that same key's next check),
  just DB-backed now. A per-process `Mutex` is kept around the check+insert
  purely to narrow (not eliminate) a same-instance race between two
  concurrent requests; it can't do anything about a simultaneous request
  on a *different* instance, which is an accepted, minor over-count risk
  at this app's scale - the same "good enough, not bulletproof" bar
  `client_ip`'s own comment already sets.
- Verified for real, not just via unit tests - and specifically against
  **two separate local server processes on different ports sharing one
  real local Postgres database** (matching production's adapter, not the
  sqlite fallback), since none of this is meaningfully testable within a
  single process:
  - `/health` on both instances immediately after boot showed instance A
    had ticked (`tick_count: 1`) and instance B correctly had not
    (`tick_count: 0`), both agreeing on the same shared `next_tick_at` -
    confirming exactly-once tick claiming across processes.
  - A real `faye-websocket` client connected to *each* instance; a
    firmware flash POSTed only to instance A was received by *both*
    clients - instance A's client immediately, instance B's client only
    after a follow-up request was sent to instance B (proving the
    relay-on-next-request design, not a lucky coincidence).
  - 11 bad login attempts split 6-against-instance-A/5-against-instance-B
    (shared limit: 10/3min) - the 10th (B's 4th) still came back 401, the
    11th (B's 5th) came back a real 429, confirming the rate limit is
    genuinely shared rather than reset per instance.
  - Full suite also run against real local Postgres directly (not just
    the two-instance setup) to confirm the new `ClusterState.claim_due!`
    virtual-row comparison generates correct SQL on both adapters, not
    only sqlite.
- 2 existing test files updated for the new coordination mechanism
  (`fleet_simulator_test.rb`'s `instance_variable_set(:@next_tick_at,
  nil)` calls replaced with a `force_tick_due!` helper that sets the
  shared `cluster_state` row instead; `rate_limiter_test.rb`'s direct
  `@hits` Hash manipulation replaced with real `RateLimitHit` rows). 1 new
  test (`rate_limiter_test.rb`: hits written directly to the table, as if
  by a different process, still count toward the same limit). 88 tests
  total, all passing (checked 4 repeated runs against sqlite plus one full
  run against real Postgres).

## Phase 14 — Admin-configurable alert thresholds, and three real bugs caught along the way — DONE (2026-09-16)

Item 4 off the candidate list: battery/camera/link-signal alert conditions
were hardcoded constants in `fleet_alerts`, and now that a drone can report
arbitrary numeric streams (Phase 9), there was no way to say "alert if
`thermal_cam` exceeds 60" without a code deploy.

- **New `alert_rules` table** (migration 014, `AlertRule` model):
  `drone_id` (nullable - `nil` means a *global* rule, checked against every
  drone that reports the stream, not just one), `stream_name`, `operator`
  (`gt`/`gte`/`lt`/`lte`), `threshold`. `AlertRule#triggered?` parses the
  reading's leading number the same way charts already do, but returns
  `false` (not a misleading `0`) for a non-numeric value like `"OK"` - a
  new `StreamReading.numeric_value` helper, stricter than the existing
  `numeric_history_for` (which keeps its own `0.0`-for-charts fallback
  unchanged).
- **`POST /api/alert_rules`** / **`DELETE /api/alert_rules/:id`**
  (admin-only). Dashboard gets an admin-only "🔔 Alert Rules" section under
  the alerts panel - add via sequential prompts (stream name, operator,
  threshold, optional drone slug to scope it), each rule listed with a 🗑
  delete button. `fleet_alerts` checks `AlertRule.for_drone(d)` alongside
  the fixed rules. The live/WebSocket view embeds the current rule set
  once at page render and re-evaluates it against every fresh broadcast -
  a rule added or removed only takes effect for an already-open tab on its
  next reload, the same accepted tradeoff as the "Set API Token" flow.

**Three real, independent bugs caught while building and verifying this -
none by unit tests, all by deliberately exercising the real thing:**

1. **Sequel's `where(column: [x, nil])` silently drops every row where the
   column is actually `NULL`.** `AlertRule.for_drone` was first written as
   `where(drone_id: [drone.id, nil])`, which generates
   `WHERE drone_id IN (?, NULL)` - and SQL's `IN` never matches `NULL`
   (three-valued logic: `NULL IN (1, NULL)` isn't true). Every *global*
   rule was silently invisible to `fleet_alerts`. Caught by a failing
   integration test, then confirmed at the SQL level by printing the
   actual generated query rather than guessing. Fixed with
   `Sequel.|({ drone_id: drone.id }, { drone_id: nil })`, which generates a
   real `(drone_id = ? OR drone_id IS NULL)`.
2. **A parse-breaking bug in the dashboard's own `<script>` block, live in
   production since Phase 12, invisible to every verification method used
   so far.** Ruby heredocs interpret backslash escapes in *string*
   content, not just real Ruby `/regex/` literals - so JS meant to be
   embedded literally (`\d`, `\w`, `\.`, `\n`) was silently mangled: `\d`,
   `\w`, `\.` lost their backslash entirely (Ruby drops the backslash for
   an escape it doesn't recognize), and worse, `\b` turned into an actual
   backspace *byte*, and `rotateToken`'s `'...\n\n'+d.token` became a
   **raw literal newline inside a single-quoted JS string** -
   `SyntaxError: Unexpected token` in any real JS engine. That one broke
   parsing of the *entire* script block, not just the one function -
   meaning no live WebSocket updates, no radar animation, and no admin
   button on the dashboard has actually worked in a real browser since
   Phase 12 shipped, despite every previous phase's "verified for real"
   checks passing. Every prior verification in this app's history checked
   server-rendered HTML (`curl`) or raw WebSocket JSON payloads
   (`faye-websocket` scripts) - never an actual JS engine parsing the
   `<script>` tag, so this class of bug had no way to get caught until now.
   Found via `node --check` against the real bytes a live local instance
   served (not the Ruby source), confirmed via `cat -A` showing a literal
   line break mid-string, and fixed by doubling the offending backslashes
   in the Ruby source so a single one survives into the output. Re-verified
   three ways: `node --check` on the complete real script block from both
   the dashboard and history pages (clean parse), a Node REPL executing
   the real extracted functions against realistic data, and - the real
   proof - an actual Chrome tab loading the live dashboard with zero
   console errors, a genuine WebSocket connection (`connected_sockets`
   went 0 → 1), and a firmware flash POSTed via `curl` appearing in the
   open tab's DOM with no page reload.
3. **A real UI regression caught only by that same live-browser check,
   not by any test:** Phase 9's generalization of `stream_chips_html` (to
   show every stream present, not just the four simulator-known ones)
   accidentally started showing `battery` as a duplicate chip - it's
   recorded as its own `StreamReading` purely so the history page can
   chart it (Phase 5), and deliberately excluded from `STREAM_LABELS`
   since it already has its own bar on the card. Fixed by explicitly
   excluding `'battery'` from the "extras" list in both the Ruby and JS
   versions of the chip-building logic; regression test added.

This phase is the strongest evidence yet in this app's history for why
"verified for real" has to include actually running the thing the way a
user would, not just checking the parts that are easy to inspect from the
outside (rendered HTML, JSON payloads) - a whole category of client-side
bugs was shipping silently for phases at a time.

- 14 new tests (8 for the alert-rules API/model in `app_test.rb`, 7 in a
  new `test/alert_rule_test.rb` for `AlertRule`'s own logic, 1 regression
  test for the battery-chip duplication). Also fixed a pre-existing test-
  isolation gap while debugging bug #1: `Seeds.reset!` cleared every
  drone-scoped table via cascade, but `AlertRule.drone_id` is nullable, so
  a *global* rule created in one test silently leaked into the next -
  `Seeds.reset!` now explicitly clears `AlertRule` too. 108 tests total,
  all passing (repeated runs against sqlite and one full run against real
  Postgres).

## Phase 15 — Drone-declared stream schema — DONE (2026-09-16)

Item 5 off the candidate list. Stale-feed detection (Phase 10) and
AlertRule (Phase 14) only ever apply to a stream *after* it's reported at
least once - neither could flag "this drone was supposed to report
`vibration` and has never once done so." Ingested numeric streams also had
no real unit for their history chart (`StreamReading` stores only a value
string like `"42.7C"`, never a unit).

- **New `stream_specs` table** (migration 015, `StreamSpec` model): a
  per-drone manifest entry, `drone_id` + `stream_name` + optional `unit`,
  unique per (drone, stream). Distinct from `AlertRule` - this is a
  presence/labeling manifest, not a threshold check on a value.
- **`fleet_alerts` flags a spec whose `stream_name` never appears** in
  that drone's `latest_streams` at all: `"📋 <slug>: <label> expected but
  never reported"` - clears itself automatically the moment the stream
  actually shows up, same as every other alert here (nothing to
  acknowledge or resolve manually). The live WebSocket view mirrors this
  via a `streamSpecs` map (drone slug → expected stream names) embedded
  once at page render, same tradeoff as `alertRules`.
- **History-page charts use the registered unit** for any ingested stream
  that has one, instead of the previous blank unit for anything outside
  `FleetSimulator::CHART_STREAMS`.
- **Admin-only "📋 Expected Streams" panel added to the per-drone history
  page** (not the main dashboard - this is inherently per-drone, and the
  history page is already where a drone's own data lives). Add via two
  prompts (stream name, optional unit), each listed with a 🗑 delete
  button. `.rules-block`/`.rule-row` CSS (previously only in the
  dashboard's own `<style>` block) moved into the shared `base_css` so
  both pages can use it without duplicating rules - the same
  don't-duplicate-styling principle Phase 5 already established.
- Verified for real: booted locally, registered an expected `thermal_cam`
  stream for drone-001 with unit `C`, confirmed the "expected but never
  reported" alert appeared; posted real telemetry for it via curl and
  confirmed the alert cleared on its own; posted a second reading and
  confirmed the history-page sparkline rendered with the registered unit
  (`data-value="55.0C"`). Given Phase 14's finding that a browser-breaking
  bug can hide behind passing server-rendered checks, both the dashboard's
  and the history page's real served `<script>` blocks were also run
  through `node --check` before considering this done.
- 13 new tests (9 in `app_test.rb` for the API/alerts/chart-unit
  integration, 4 in a new `test/stream_spec_test.rb` for the model's own
  validation and cascade-delete behavior). 121 tests total, all passing
  (sqlite + real Postgres).

## Known gaps / candidate next steps

Roughly in order of likely value — none of these are blocking; the app is a
working live-ish demo dashboard with real login and telemetry as it stands.

~~1. Single-instance only~~ — **done, Phase 13.**
~~2. Per-drone ingestion credentials~~ — **done, Phase 12.**
~~3. Rate-limit telemetry ingestion~~ — **done, Phase 11.**
~~4. Admin-configurable alert thresholds~~ — **done, Phase 14.**
~~5. Drone-declared stream schema~~ — **done, Phase 15.**
6. **Outbound alert delivery.** Every alert (low battery, degraded camera,
   stale live feed) only ever appears inside the dashboard's own panel -
   nobody is notified unless someone is actively looking at the page. A
   webhook POST (or email/Slack) fired on a *new* alert - not every poll,
   which needs some form of edge-detection/dedup state - would close the
   loop for actual operational use rather than a monitor-required demo.
7. **Firmware integrity verification.** `POST /api/firmware` validates
   extension and size but not authenticity - nothing stops a bit-flipped
   or malicious `.bin` from being "flashed" as long as it's under 8MB. A
   required checksum (or a real signature, if firmware will ever come from
   an untrusted supply chain) before marking a flash as applied would
   close an obvious gap for anything beyond a demo.
8. **Bulk drone provisioning.** `POST /api/drones` and `GET /drones.csv`
   handle one drone and read-only export respectively; there's no CSV/bulk
   *import* counterpart for standing up a fleet larger than a couple of
   manually-added demo drones at once.
