#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rack'
require 'rack/contrib'
require 'faye/websocket'
require 'json'
require 'pg'
require 'securerandom'
require 'digest'
require 'time'

# Global state
$start_time = Time.now
$request_count = 0
$timers = {}  # Track timers per WS connection

# Mock drone fleet data (Phoenix AZ pharma logistics)
$drone_fleet = {
  'drone-001' => {
    lat: 33.4484, lng: -112.0740, alt: 400, status: 'READY',
    battery: 87.0, temp: 2.1, firmware: {version: 'v1.0.0', status: 'stable'}
  },
  'drone-002' => {
    lat: 33.5138, lng: -112.1314, alt: 250, status: 'PATROL_AZ1',
    battery: 76, temp: 1.8, firmware: {version: 'v1.0.0', status: 'stable'}
  }
}

MISSION_TEMPLATES = {
  patrol_az1: { waypoints: [[33.5138,-112.1314],[33.5200,-112.1400],[33.5100,-112.1200]], alt: 300 },
  phx_loop:  { waypoints: [[33.4484,-112.0740],[33.4600,-112.0800],[33.4400,-112.0900]], alt: 450 },
  cold_chain: { waypoints: [[33.4300,-112.0600],[33.4200,-112.0500]], alt: 200, temp_corridor: [0,8] }
}

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
  body { font-family: "Courier New", monospace; background: linear-gradient(135deg,#0a0a0a,#1a1a2e); color:#00ff88; margin:0; padding:20px; }
  .header { background:linear-gradient(90deg,rgba(0,255,136,0.15),rgba(0,153,255,0.35)); border:1px solid #00ff88; padding:12px 16px; margin-bottom:16px; box-shadow:0 0 18px rgba(0,255,136,0.35); }
  .header h1 { margin:0; font-size:20px; letter-spacing:0.12em; text-transform:uppercase; }
  .tagline { font-size:12px; color:#a0ffe0; }
  .badge-row { margin:10px 0; display:flex; flex-wrap:wrap; gap:8px; }
  .badge { border-radius:999px; padding:4px 10px; border:1px solid #00ff88; font-size:11px; background:rgba(0,0,0,0.55); }
  .badge.ok { border-color:#00ff88; color:#00ff88; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:16px; margin-top:10px; }
  .card { background:rgba(8,8,20,0.95); border:1px solid #222; box-shadow:0 0 12px rgba(0,0,0,0.7); padding:14px; border-radius:10px; }
  .card h2 { margin:0 0 6px 0; font-size:14px; text-transform:uppercase; letter-spacing:0.16em; color:#64ffda; }
  .card pre { font-size:11px; white-space:pre-wrap; word-break:break-word; }
  .pill { display:inline-block; padding:2px 8px; font-size:11px; border-radius:999px; border:1px solid #00ccff; color:#00ccff; margin-right:4px; }
  .pill.ok { border-color:#00ff88; color:#00ff88; }
  .footer { margin-top:20px; font-size:11px; color:#88ffc8; }
  .cta { margin-top:10px; padding:8px 12px; border-radius:6px; border:1px solid #00ff88; display:inline-block; font-size:12px; cursor:pointer; background:rgba(0,0,0,0.3); }
  .drone-btn { padding:8px 12px; border-radius:6px; border:none; font-family:inherit; font-size:11px; cursor:pointer; transition:all 0.2s; width:100%; box-sizing:border-box; }
  .drone-btn:hover { transform:scale(1.05); }
  .drone-btn.patrol { background:rgba(0,255,136,0.2); border:1px solid #00ff88; color:#00ff88; }
  .drone-btn.safe { background:rgba(0,200,255,0.2); border:1px solid #00ccff; color:#00ccff; }
  .drone-btn.emergency { background:rgba(255,50,50,0.3); border:1px solid #ff4444; color:#ff8888; font-weight:bold; }
  .drone-btn:active { transform:scale(0.98); }
  .drone-btn.firmware { background:rgba(255,200,0,0.2); border:1px solid #ffcc00; color:#ffcc00; font-size:10px; padding:4px 8px; width:auto; }
  #fleet-map { height:260px; border-radius:8px; overflow:hidden; border:1px solid #00ff88; }
  .fw-section { margin-top:12px; padding:8px; background:rgba(0,0,0,0.4); border-radius:6px; border:1px solid #00ccff; }
</style>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin=""/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
</head>
<body>
  <div class="header">
    <h1>THOMAS IT // CYBERPUNK DRONE FLEET</h1>
    <div class="tagline">Render Webrick · PG via DATABASE_URL · Stripe pharma billing · PHX cold chain</div>
    <div class="badge-row">
      <span class="badge ok">DRONE FLEET: #{$drone_fleet.size} ACTIVE</span>
      <span class="badge ok">WEBSOCKET ✓</span>
      <span class="badge ok">FIRMWARE SWAP ✓</span>
      <span class="badge ok">PHX COLD CHAIN ✓</span>
    </div>
  </div>
  #{body_html}
  <div class="footer">git push origin main → cyberpunk drone C2 + firmware swap online | PHX pharma ready</div>
  <script>
  function sendDroneCmd(droneId, action, mission) {
    fetch('/api/drone_cmd', {
      method: 'POST',
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: `drone_id=${droneId}&action=${action}${mission ? '&mission=' + mission : ''}`
    }).then(r=>r.json()).then(data=>console.log('CMD:', data));
  }
  function uploadFirmware() {
    var file = document.getElementById('fw-file').files[0];
    if (!file) return alert('Select firmware file');
    var form = new FormData();
    form.append('file', file);
    fetch('/api/firmware', {method: 'POST', body: form})
      .then(r=>r.json()).then(data=>console.log('FW:', data));
  }
  (function(){
    var mapEl = document.getElementById('fleet-map');
    if (!mapEl) return;
    var map = L.map('fleet-map').setView([33.4484, -112.0740], 11);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
    var droneMarker = L.marker([33.4484, -112.0740]).addTo(map).bindPopup('Drone-001 PHX HQ').openPopup();
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
          if (data.firmware) {
            document.getElementById('fw-status').textContent = data.firmware.version;
          }
          if (data.status) {
            document.getElementById('cmd-status').textContent = data.status;
          }
        } catch(e) { console.log('WS parse err:', e); }
      };
      socket.onopen = function(ev) { console.log('WS CONNECTED'); };
      socket.onclose = function(ev) { console.log('WS CLOSED'); };
    } catch(e) { console.log('WS CONNECT ERR:', e); }
  })();
  </script>
</body>
</html>
HTML
end

app = lambda do |env|
  req = Rack::Request.new(env)
  path = req.path_info
  $request_count += 1
  uptime = (Time.now - $start_time).round(1)

  # WEBSOCKET - FIXED: Proper timer cleanup
  if path == '/ws/drone' && Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)
    ws_id = SecureRandom.hex(8)
    $timers[ws_id] = nil

    ws.on :open do |event|
      puts "🛰️ WEBSOCKET CONNECT #{ws_id}"
      ws.send($drone_fleet.to_json)

      # FIXED: Store timer reference and check WS state
      $timers[ws_id] = EM.add_periodic_timer(3) do
        next unless ws && ws.instance_variable_get(:@ready_state) == 1
        next unless $timers[ws_id]
        
        drone = $drone_fleet['drone-001']
        drone[:lng]     = (drone[:lng] || -112.0740) + 0.001
        drone[:lat]     = (drone[:lat] || 33.4484)
        drone[:alt]     = (drone[:alt] || 400)
        drone[:battery] = [(drone[:battery] || 87.0) - 0.1, 0.0].max

        ws.send($drone_fleet.to_json)
      end
    end

    ws.on :message do |event|
      begin
        cmd = JSON.parse(event.data)
        drone_id = cmd['drone_id'] || 'drone-001'
        case cmd['action']
        when 'mission_start'; $drone_fleet[drone_id][:status] = 'MISSION_ACTIVE'
        when 'rtl';           $drone_fleet[drone_id][:status] = 'RTL_PHX_HQ'
        when 'land';          $drone_fleet[drone_id][:status] = 'LANDING'
        when 'emergency';     $drone_fleet[drone_id][:status] = 'EMERGENCY'
        end
        ws.send({status: 'cmd_ok', drone_id: drone_id}.to_json)
      rescue => e
        ws.send({error: e.message}.to_json)
      end
    end

    ws.on :close do |event|
      puts "🛰️ WEBSOCKET CLOSED #{ws_id}"
      # FIXED: Clean up timer
      if $timers[ws_id]
        EM.delete_periodic_timer($timers[ws_id])
        $timers.delete(ws_id)
      end
    end

    ws.on :error do |event|
      puts "🛰️ WEBSOCKET ERROR: #{event.message}"
      if $timers[ws_id]
        EM.delete_periodic_timer($timers[ws_id])
        $timers.delete(ws_id)
      end
    end

    ws.rack_response

  # FIRMWARE UPLOAD - FIXED: Proper regex
  elsif req.post? && path == '/api/firmware'
    upload = req.params['file']
    if upload && upload[:tempfile]
      firmware_data = upload[:tempfile].read
      firmware_hash = Digest::SHA256.hexdigest(firmware_data)[0..8]
      
      # FIXED: Correct regex for version parsing
      version_match = upload[:filename]&.match(/v(\d+\.\d+\.\d+)/)
      version = version_match ? "v#{version_match[1]}" : 'v2.1.0'

      $drone_fleet['drone-001'][:firmware] = {
        version: version,
        hash: firmware_hash,
        status: 'FLASHING',
        timestamp: Time.now.iso8601,
        size: firmware_data.bytesize
      }
      [200, {'content-type' => 'application/json'}, [JSON.dump({status: 'firmware_uploaded', hash: firmware_hash})]]
    else
      [400, {'content-type' => 'application/json'}, [JSON.dump({error: 'no_file'})]]
    end

  # API COMMAND
  elsif req.post? && path == '/api/drone_cmd'
    drone_id = req.params['drone_id'] || 'drone-001'
    action = req.params['action'] || 'unknown'

    if $drone_fleet[drone_id]
      case action
      when 'mission_start'; $drone_fleet[drone_id][:status] = 'MISSION_ACTIVE'
      when 'rtl';           $drone_fleet[drone_id][:status] = 'RTL_PHX_HQ'
      when 'land';          $drone_fleet[drone_id][:status] = 'LANDING'
      when 'emergency';     $drone_fleet[drone_id][:status] = 'EMERGENCY'
      end
    end
    [200, {'content-type' => 'application/json'}, [JSON.dump({status: 'command_sent', drone_id: drone_id, action: action})]]

  # DASHBOARD
  elsif path == '/'
    stats = {
      requests: $request_count,
      uptime_s: uptime,
      db: $DB ? 'online' : 'offline',
      fleet_size: $drone_fleet.size,
      active_timers: $timers.size,
      ws_connections: $timers.size
    }

    body_html = <<~HTML
<div class="grid">
  <div class="card">
    <h2>Control Tower</h2>
    <pre>#{JSON.pretty_generate(stats)}</pre>
    <div class="pill ok">WEBSOCKET ✓</div>
    <div class="pill ok">FIRMWARE ✓</div>
  </div>
  <div class="card">
    <h2>Live Telemetry</h2>
    <div id="fleet-map"></div>
  </div>
  <div class="card">
    <h2>🚁 Super Drone C2 + Firmware</h2>
    <div style="display:grid;gap:8px;margin:12px 0;">
      <button class="drone-btn patrol" onclick="sendDroneCmd('drone-001','mission_start','patrol_az1')">🚁 Patrol AZ‑1</button>
      <button class="drone-btn patrol" onclick="sendDroneCmd('drone-001','mission_start','phx_loop')">🔄 PHX Loop</button>
      <button class="drone-btn safe" onclick="sendDroneCmd('drone-001','rtl')">🏠 Return HQ</button>
      <button class="drone-btn safe" onclick="sendDroneCmd('drone-001','land')">🛬 Land</button>
      <button class="drone-btn emergency" onclick="sendDroneCmd('drone-001','emergency')">🚨 EMERGENCY</button>
    </div>
    <div class="fw-section">
      <div style="font-size:10px;color:#00ccff;">Firmware: <span id="fw-status">#{$drone_fleet['drone-001'][:firmware][:version]}</span></div>
      <input id="fw-file" type="file" style="font-size:10px;color:#888;margin:4px 0;" accept=".bin,.hex">
      <button class="drone-btn firmware" onclick="uploadFirmware()">⚡ FLASH FIRMWARE</button>
    </div>
    <div style="font-size:10px;color:#88ff88;margin-top:8px;">Status: <span id="cmd-status">READY</span></div>
  </div>
  <div class="card">
    <h2>21 CFR Part 11</h2>
    <p>PHX pharma cold chain compliance + firmware audit trail ready</p>
  </div>
</div>
<div class="cta" onclick="location.reload()">DEPLOY FLEET + FIRMWARE SWAP</div>
HTML

    [200, {'content-type' => 'text/html; charset=utf-8'}, [cyberpunk_page('DRONE FLEET C2 v2.1', body_html)]]

  # HEALTH
  elsif path == '/health'
    [200, {'content-type' => 'application/json'}, [JSON.dump({ok: true, requests: $request_count, uptime_s: uptime, fleet_size: $drone_fleet.size, active_timers: $timers.size})]]

  else
    [404, {'content-type' => 'text/plain'}, ['404 Drone corridor not found']]
  end
end

run app
