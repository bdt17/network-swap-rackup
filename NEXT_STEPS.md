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
an already-connected client.

## Known gaps / candidate next steps

Roughly in order of likely value — none of these are blocking; the app is a
working demo/dashboard as it stands.

1. **The "fleet" isn't real.** `drone-001`/`drone-002` are seed data with
   fixed lat/lon; nothing ever moves them, drains their battery, or changes
   their status — there's no actual drone (or simulator) feeding this app
   real telemetry. Before this is more than a static demo, decide what the
   data source actually is: real hardware (DJI SDK or similar), a simulated
   flight-path generator, or manual operator input.
2. **WebSocket commands don't do anything yet.** Inbound messages are logged
   to `command_events` and acked, but nothing acts on them — there's no
   defined command vocabulary (e.g. "recall," "set patrol route," "change
   status"). Worth defining once there's a real fleet to command.
3. **Single-process broadcast only.** `settings.sockets` is an in-memory
   array — `broadcast_fleet!` only reaches sockets connected to the *same*
   process. Fine for one Render instance; would need a pub/sub layer (Redis,
   or Postgres `LISTEN`/`NOTIFY`) the moment this runs on more than one
   instance.
4. **No auth.** The dashboard and `/api/firmware` are wide open to anyone
   with the URL. Fine for an internal demo; worth a token-in-URL scheme
   (`network-swap-app`'s `/assistant/:token` pattern is a reusable model) or
   real login before this is anything more than that.
5. **Firmware "flashing" is fake.** The upload UI accepts a `.bin`/`.hex`
   file but never reads or stores it — it just bumps a version string.
   Real firmware handling would need file storage (same R2/Active-Storage-
   style decision `network-swap-app` made for ticket photos) and a lot more
   care given what firmware flashing actually implies for real hardware.
6. **No CI.** `network-swap-app` has a GitHub Actions workflow running tests
   + Brakeman + bundler-audit on every push; this repo has none yet. Worth
   copying that pattern once this app has more than a handful of routes.
