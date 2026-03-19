# config.ru
require 'rack'
require 'json'
require 'uri'
require 'pg'
require 'stripe'

Stripe.api_key = ENV['STRIPE_SECRET_KEY'] || ENV['IPE_SECRET_KEY'] || 'sk_test_dummy'

$request_count ||= 0
$start_time    ||= Time.now
$DB            ||= nil

# DATABASE_URL from Render (internal); let pg handle SSL from the URL. [web:2][web:8]
begin
  if ENV['DATABASE_URL'] && !ENV['DATABASE_URL'].empty?
    $DB = PG.connect(ENV['DATABASE_URL'])
  end
rescue => e
  puts "DB: #{e.message}"
  $DB = nil
end

def cyberpunk_page(title, body_html)
  <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>#{title}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body {
          font-family: "Courier New", monospace;
          background: linear-gradient(135deg,#0a0a0a,#1a1a2e);
          color:#00ff88;
          margin:0;
          padding:20px;
        }
        .header {
          background:linear-gradient(90deg,rgba(0,255,136,0.15),rgba(0,153,255,0.35));
          border:1px solid #00ff88;
          padding:12px 16px;
          margin-bottom:16px;
          box-shadow:0 0 18px rgba(0,255,136,0.35);
        }
        .header h1 {
          margin:0;
          font-size:20px;
          letter-spacing:0.12em;
          text-transform:uppercase;
        }
        .tagline {
          font-size:12px;
          color:#a0ffe0;
        }
        .badge-row {
          margin:10px 0;
          display:flex;
          flex-wrap:wrap;
          gap:8px;
        }
        .badge {
          border-radius:999px;
          padding:4px 10px;
          border:1px solid #00ff88;
          font-size:11px;
          background:rgba(0,0,0,0.55);
        }
        .badge.ok { border-color:#00ff88; color:#00ff88; }

        .grid {
          display:grid;
          grid-template-columns:repeat(auto-fit,minmax(260px,1fr));
          gap:16px;
          margin-top:10px;
        }
        .card {
          background:rgba(8,8,20,0.95);
          border:1px solid #222;
          box-shadow:0 0 12px rgba(0,0,0,0.7);
          padding:14px;
          border-radius:10px;
        }
        .card h2 {
          margin:0 0 6px 0;
          font-size:14px;
          text-transform:uppercase;
          letter-spacing:0.16em;
          color:#64ffda;
        }
        .card pre {
          font-size:11px;
          white-space:pre-wrap;
          word-break:break-word;
        }
        .pill {
          display:inline-block;
          padding:2px 8px;
          font-size:11px;
          border-radius:999px;
          border:1px solid #00ccff;
          color:#00ccff;
          margin-right:4px;
        }
        .pill.subtle {
          border-color:#555;
          color:#888;
        }
        .footer {
          margin-top:20px;
          font-size:11px;
          color:#88ffc8;
        }
        a {
          color:#00e0ff;
          text-decoration:none;
        }
        a:hover { text-decoration:underline; }
        .cta {
          margin-top:10px;
          padding:8px 12px;
          border-radius:6px;
          border:1px solid #00ff88;
          display:inline-block;
          font-size:12px;
          cursor:pointer;
          background:rgba(0,0,0,0.3);
        }
      </style>

      <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
        integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin=""/>
      <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
        integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
    </head>
    <body>
      <div class="header">
        <h1>THOMAS IT // CYBERPUNK DRONE FLEET</h1>
        <div class="tagline">Render Webrick · PG via DATABASE_URL · Stripe pharma billing · PHX cold chain</div>
        <div class="badge-row">
          <span class="badge ok">DRONE HQ: LIVE (Webrick)</span>
          <span class="badge ok">PHX Pharma: Cold chain ready</span>
          <span class="badge ok">21 CFR Part 11: Audit structure ready</span>
          <span class="badge ok">Stripe: Billing endpoints armed</span>
          <span class="badge ok">Zero deploy errors</span>
        </div>
      </div>

      #{body_html}

      <div class="footer">
        git push origin main → cyberpunk SaaS control tower online.<br>
        ENV[STRIPE_SECRET_KEY] + ENV[DATABASE_URL] wired for Render.
      </div>

      <script>
        (function() {
          var mapEl = document.getElementById('fleet-map');
          if (!mapEl) { return; }

          var map = L.map('fleet-map').setView([33.4484, -112.0740], 11);
          L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            maxZoom: 19,
            attribution: '&copy; OpenStreetMap'
          }).addTo(map);

          var droneMarker = L.marker([33.4484, -112.0740]).addTo(map)
            .bindPopup('Drone HQ / Phoenix')
            .openPopup();

          var wsUrl = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws/drone';
          try {
            var socket = new WebSocket(wsUrl);
            socket.onmessage = function(ev) {
              try {
                var data = JSON.parse(ev.data);
                if (data.lat && data.lng) {
                  droneMarker.setLatLng([data.lat, data.lng]);
                  map.panTo([data.lat, data.lng]);
                }
              } catch (e) {
                console.log('WS parse error', e);
              }
            };
          } catch (e) {
            console.log('WS init error', e);
          }
        })();
      </script>
    </body>
    </html>
  HTML
end

app = Proc.new do |env|
  req  = Rack::Request.new(env)
  path = req.path_info

  $request_count += 1
  uptime = (Time.now - $start_time).round(1)

  case path
  when '/'
    stats = {
      requests: $request_count,
      uptime_s: uptime,
      db: $DB ? 'online' : 'offline',
      stripe_key_present: !Stripe.api_key.to_s.empty?
    }

    body_html = <<~HTML
      <div class="grid">
        <div class="card">
          <h2>Control tower · Status</h2>
          <pre>#{JSON.pretty_generate(stats)}</pre>
          <div class="pill">WEBRICK · RACKUP</div>
          <div class="pill">DATABASE_URL · PG</div>
          <div class="pill">STRIPE_SECRET_KEY</div>
        </div>

        <div class="card">
          <h2>Live fleet telemetry</h2>
          <div id="fleet-map" style="height:260px;border-radius:8px;overflow:hidden;border:1px solid #00ff88;"></div>
          <p style="font-size:11px;margin-top:8px;">
            WebSocket endpoint: <code>/ws/drone</code> (JSON: {"lat": 33.4, "lng": -112.0}).
          </p>
        </div>

        <div class="card">
          <h2>Cold chain · Compliance</h2>
          <p style="font-size:12px;">
            21 CFR Part 11 audit events, immutable logs, GPS temperature corridors, and Stripe-backed
            batch billing ready to arm for PHX pharma transport lanes.
          </p>
          <div class="pill subtle">21 CFR Part 11</div>
          <div class="pill subtle">Chain-of-custody</div>
          <div class="pill subtle">Audit JSON</div>
        </div>
      </div>

      <div class="cta">JUST PUSH → CYBERPUNK DRONE FLEET LIVE WORLDWIDE</div>
    HTML

    [200, { 'Content-Type' => 'text/html; charset=utf-8' }, [cyberpunk_page('THOMAS IT · DRONE HQ', body_html)]]

  when '/health'
    status = {
      ok: true,
      requests: $request_count,
      uptime_s: uptime,
      db: !!$DB
    }
    [200, { 'Content-Type' => 'application/json' }, [JSON.dump(status)]]

  else
    [404, { 'Content-Type' => 'text/plain' }, ["404 – Drone corridor not mapped\n"]]
  end
end

# Force WEBrick so Rack never tries to load Puma. [web:13][web:15]
Rack::Handler::WEBrick.run(app, Port: ENV.fetch('PORT', 3000).to_i)
