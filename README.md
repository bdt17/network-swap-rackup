# Cyberpunk Drone C2

A small live dashboard for a demo drone fleet — Thomas IT's separate drone-centric
project (distinct from `network-swap-app`, the IT asset/ticket/billing tool).

Deliberately lightweight: Sinatra (not Rails) over Sequel/Postgres, for fast cold
starts on Render's free tier. Real persistence, a live background fleet
simulator, login + two-factor auth, real WebSocket broadcast, real tests — see
`NEXT_STEPS.md` for what's built and what's next.

## Running locally

```
bundle install
bin/migrate                       # creates/migrates db/development.sqlite3
bin/create_user you@example.com yourpassword   # first login user
bundle exec rackup config.ru -p 4567 -s puma
```

Visit `http://localhost:4567` and sign in. No `DATABASE_URL` needed locally —
it falls back to a file-backed sqlite DB per `RACK_ENV` (default `development`).

Locked out of an authenticator app? `bin/disable_mfa you@example.com` turns
2FA back off (break-glass, run wherever `DATABASE_URL` points).

## Tests

```
RACK_ENV=test bin/migrate    # first time only
bundle exec ruby -Itest test/run.rb
```

## Deploying

`render.yaml` is a Render Blueprint — in the Render dashboard, **New → Blueprint**,
point it at this repo. It provisions both the web service (`cyberpunk-drone-c2`)
and a `drone_db` Postgres database, wired together via `DATABASE_URL`. Migrations
run automatically as part of the build command. After the first deploy, run
`bin/create_user` in the Render shell to create your first login.
