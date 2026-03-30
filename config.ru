#!/usr/bin/env ruby
require 'rack'
require 'faye/websocket'
require 'json'
require 'pg'

$start_time = Time.now
$request_count = 0
$drone_fleet = {
  'drone-001' => { lat: 33.4484, lng: -112.0740, alt: 400, status: 'READY', battery: 87.0 },
  'drone-002' => { lat: 33.5138, lng: -112.1314, alt: 250, status: 'PATROL_AZ1', battery: 76 }
}

app = lambda do |env|
  req = Rack::Request.new(env)
  path = req.path_info
  $request_count += 1

  if path == '/ws/drone' && Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)
    ws.on :open do |event|
      puts "🛰️ WEBSOCKET CONNECT"
      ws.send($drone_fleet.to_json)
    end
    ws.rack_response

  elsif req.post? && path == '/api/drone_cmd'
    drone_id = req.params['drone_id'] || 'drone-001'
    action = req.params['action'] || 'status'
    $drone_fleet[drone_id][:status] = case action
    when 'mission_start' then 'MISSION_ACTIVE'
    when 'rtl' then 'RTL_PHX_HQ'
    when 'land' then 'LANDING'
    when 'emergency' then 'EMERGENCY'
    end
    [200, {'Content-Type' => 'application/json'}, [{status: 'ok', drone_id: drone_id}.to_json]]

  elsif path == '/'
    [200, {'Content-Type' => 'text/plain'}, ["DRONE FLEET: #{$drone_fleet.size} ACTIVE\nPATROL_AZ1: drone-002 OK"]]
  else
    [404, {}, ['Not found']]
  end
end

run app

# CYBERPUNK HTML FUNCTION (complete)
def cyberpunk_page(title, body_html)
  <<~HTML
<!DOCTYPE html>
<html>
<head>
<title>#{title}</title>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body { 
  font-family: "Courier New", monospace; 
  background: linear-gradient(45deg, #0a0a0a, #1a0033, #000066, #330066); 
  color: #00ffcc; 
  margin: 0; 
  padding: 20px; 
  min-height: 100vh;
  overflow-x: auto;
}
h1 { 
  text-align: center; 
  font-size: 2.5em; 
  text-shadow: 0 0 20px #00ffcc; 
  margin-bottom: 30px;
  animation: glow 2s ease-in-out infinite alternate;
}
@keyframes glow {
  from { text-shadow: 0 0 20px #00ffcc; }
  to { text-shadow: 0 0 40px #00ffcc, 0 0 60px #00ffcc; }
}
.drone-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 20px;
  max-width: 1200px;
  margin: 0 auto;
}
.drone-card {
  background: rgba(0, 255, 204, 0.1);
  border: 2px solid #00ffcc;
  border-radius: 15px;
  padding: 20px;
  box-shadow: 0 10px 30px rgba(0, 255, 204, 0.3);
  transition: all 0.3s;
}
.drone-card:hover {
  transform: translateY(-10px);
  box-shadow: 0 20px 50px rgba(0, 255, 204, 0.5);
}
.status { font-weight: bold; font-size: 1.2em; }
.online { color: #00ff00; }
.offline { color: #ff4444; }
.battery { background: #333; height: 20px; border-radius: 10px; overflow: hidden; margin: 10px 0; }
.battery-fill { height: 100%; background: linear-gradient(90deg, #ffaa00, #00ff00); transition: width 0.5s; }
#fw-file, .drone-btn { 
  background: #00ffcc; 
  color: #000; 
  border: none; 
  padding: 10px 15px; 
  border-radius: 5px; 
  cursor: pointer; 
  font-family: inherit;
  font-weight: bold;
}
.drone-btn:hover { background: #00ccaa; }
</style>
</head>
<body>
<h1>🛰️ THOMAS IT // CYBERPUNK DRONE FLEET</h1>
<div id="fleet-status">DRONE FLEET: <span id="fleet-count">0</span> ACTIVE</div>
<div class="drone-grid" id="drone-grid">
#{body_html}
</div>
<script>
let ws = new WebSocket('ws://' + location.host + '/ws/drone');
ws.onmessage = function(event) {
  let fleet = JSON.parse(event.data);
  document.getElementById('fleet-count').textContent = Object.keys(fleet).length;
  let grid = document.getElementById('drone-grid');
  grid.innerHTML = '';
  for (let id in fleet) {
    let drone = fleet[id];
    let bat = drone.battery || 0;
    let status = drone.status || 'UNKNOWN';
    grid.innerHTML += `
      <div class="drone-card">
        <h3>🚁 ${id}</h3>
        <div>Lat/Lon: ${drone.lat || 0}, ${drone.lon || 0}</div>
        <div class="status ${status === 'ACTIVE' ? 'online' : 'offline'}">${status}</div>
        <div class="battery"><div class="battery-fill" style="width: ${bat}%"></div></div>
        <div>Firmware: ${drone.firmware?.version || 'N/A'}</div>
        <input id="fw-${id}" type="file" accept=".bin,.hex">
        <button class="drone-btn firmware" onclick="uploadFirmware('${id}')">⚡ FLASH</button>
      </div>
    `;
  }
};
function uploadFirmware(droneId) {
  let file = document.getElementById('fw-' + droneId).files[0];
  if (!file) return alert('Select firmware file');
  let form = new FormData();
  form.append('firmware', file);
  form.append('drone_id', droneId);
  fetch('/api/firmware', {method: 'POST', body: form})
    .then(r => r.json()).then(d => alert('Firmware flash: ' + d.status));
}
</script>
</body>
</html>
HTML
end

# DRONE FLEET DATA
$drone_fleet = {
  'drone-001' => {lat: 33.5138, lon: -112.1314, battery: 76, status: 'ACTIVE', firmware: {version: 'v2.1.0'}},
  'drone-002' => {lat: 33.4484, lon: -112.0740, battery: 92, status: 'PATROL_AZ1', firmware: {version: 'v2.1.0'}}
}

# MAIN RACK APP (fixed syntax)
app = lambda do |env|
  req = Rack::Request.new(env)
  path = req.path
  $request_count ||= 0
  $request_count += 1

  if path == '/'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [cyberpunk_page('🛰️ THOMAS IT CYBERPUNK DRONE FLEET', 
      '<div class="drone-card"><h3>FLEET LIVE</h3><div>PHX COLD CHAIN ✓</div></div>')]]

  elsif path == '/health'
    uptime = (Time.now - ($start_time || Time.now)).to_i
    [200, {'Content-Type' => 'application/json'}, [JSON.dump({ok: true, requests: $request_count, uptime_s: uptime, fleet_size: $drone_fleet.size})]]

  elsif path == '/ws/drone' && Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)
    ws.on :open do |event|
      puts "🛰️ WEBSOCKET CONNECT"
      ws.send($drone_fleet.to_json)  # Safe: no timer
    end
    ws.on :message do |event|
      puts "📡 DRONE CMD: #{event.data}"
      ws.send({status: 'cmd_received'}.to_json)
    end
    ws.on :close do |event|
      puts "🔌 WS CLOSE #{event.code}"
      ws = nil
    end
    ws.rack_response  # Async Rack response [web:14]

  elsif req.post? && path == '/api/firmware'
    drone_id = req.params['drone_id'] || 'unknown'
    # Simulate firmware upload
    $drone_fleet[drone_id][:firmware][:version] = 'v2.2.0'
    [200, {'Content-Type' => 'application/json'}, [JSON.dump({status: 'flashed', drone: drone_id, version: 'v2.2.0'})]]

  else
    [404, {'Content-Type' => 'text/plain'}, ['404 Drone corridor not found']]
  end
end

run app
