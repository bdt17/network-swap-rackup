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

## Known gaps / candidate next steps

Roughly in order of likely value — none of these are blocking; the app is a
working live-ish demo dashboard with real login and telemetry as it stands.

1. **Single-instance only.** `settings.sockets` (WebSocket broadcast) and
   `FleetSimulator`'s tick gate are both in-memory — only work correctly on
   exactly one running instance. Fine for the current single-instance Render
   deploy; would need a pub/sub layer (Redis, or Postgres `LISTEN`/`NOTIFY`)
   for broadcast and a DB-backed lock for the tick gate the moment this runs
   on more than one instance.
2. **Firmware "flashing" is fake.** The upload UI accepts a `.bin`/`.hex`
   file but never reads or stores it — it just bumps a version string.
   Real firmware handling would need file storage (same R2/Active-Storage-
   style decision `network-swap-app` made for ticket photos) and a lot more
   care given what firmware flashing actually implies for real hardware.
3. **No roles.** Any logged-in user can do everything (create/delete drones,
   flash firmware, disable *their own* 2FA) — there's no admin/viewer
   distinction the way `network-swap-app` has admin/tech. Not needed yet at
   one-or-two-user scale; worth adding if this gets more users.
4. **No login rate limiting.** `network-swap-app` rate-limits its public
   mutating endpoints; `/login` and `/two-factor-challenge` here don't have
   that yet, so they're brute-forceable at whatever rate an attacker can hit
   the network with. Worth adding (Rack::Attack or a hand-rolled
   `Rails.cache`-style counter, same idea Phase 30 of the sibling app used
   for its daily request cap) before this is exposed somewhere that matters.
5. **Session cookie has no expiry.** `sessions.last_active_at` is tracked but
   nothing ever reads it to expire an idle session, unlike
   `network-swap-app`'s `SESSION_TIMEOUT_HOURS`. Sessions live until manual
   logout or a DB row deletion.
