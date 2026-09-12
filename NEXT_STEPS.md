# cyberpunk-drone-c2 — Status & Next Steps

_Last updated: 2026-09-12. Keep this file updated in place — do not create
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

## Known gaps / candidate next steps

Roughly in order of likely value — none of these are blocking; the app is a
working live-ish demo dashboard with real login and telemetry as it stands.

1. **Single-instance only.** `settings.sockets` (WebSocket broadcast),
   `FleetSimulator`'s tick gate, and `RateLimiter` are all in-memory — only
   work correctly on exactly one running instance. Fine for the current
   single-instance Render deploy; would need a shared store (Redis, or
   Postgres `LISTEN`/`NOTIFY` for broadcast) the moment this runs on more
   than one instance.
2. **Firmware "flashing" is fake.** The upload UI accepts a `.bin`/`.hex`
   file but never reads or stores it — it just bumps a version string.
   Real firmware handling would need file storage (same R2/Active-Storage-
   style decision `network-swap-app` made for ticket photos) and a lot more
   care given what firmware flashing actually implies for real hardware.
