#!/usr/bin/env ruby

require 'bundler/setup'
require 'rack'
require 'json'
require 'faye/websocket'
Faye::WebSocket.load_adapter('rack')

# GLOBAL STATE
$start_time    = Time.now
$request_count = 0
$drone_fleet   = {
  'drone-001' => {lat: 33.5138, lon: -112.1314, battery: 76, status: 'ACTIVE', firmware: {version: 'v2.1.0'}},
  'drone-002' => {lat: 33.4484, lon: -112.0740, battery: 92, status: 'PATROL_AZ1', firmware: {version: 'v2.1.0'}}
}

# CYBERPUNK UI (minified)
def cyberpunk_page(title, body_html='')
  <<~HTML
<!DOCTYPE html>
<html>
<head>
<title>#{title}</title>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:"Courier New",monospace;background:linear-gradient(45deg,#0a0a0a,#1a0033,#000066,#330066);color:#00ffcc;margin:0;padding:20px;min-height:100vh;overflow-x:auto}
h1{text-align:center;font-size:2.5em;text-shadow:0 0 20px #00ffcc;margin-bottom:30px;animation:glow 2s ease-in-out infinite alternate}
@keyframes glow{from{text-shadow:0 0 20px #00ffcc;}to{text-shadow:0 0 40px #00ffcc,0 0 60px #00ffcc;}}
.drone-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px;max-width:1200px;margin:0 auto}
.drone-card{background:rgba(0,255,204,.1);border:2px solid #00ffcc;border-radius:15px;padding:20px;box-shadow:0 10px 30px rgba(0,255,204,.3);transition:all .3s}
.drone-card:hover{transform:translateY(-10px);box-shadow:0 20px 50px rgba(0,255,204,.5)}
.status{font-weight:bold;font-size:1.2em;}
.online{color:#00ff00}.offline{color:#ff4444}
.battery{background:#333;height:20px;border-radius:10px;overflow:hidden;margin:10px 0}
.battery-fill{height:100%;background:linear-gradient(90deg,#ffaa00,#00ff00);transition:width .5s}
#fw-file,.drone-btn{background:#00ffcc;color:#000;border:none;padding:10px 15px;border-radius:5px;cursor:pointer;font-family:inherit;font-weight:bold}
.drone-btn:hover{background:#00ccaa}
</style>
</head>
<body>
<h1>🛰️ THOMAS IT // CYBERPUNK DRONE FLEET #NEON</h1>
<div id="fleet-status">DRONE FLEET: <span id="fleet-count">0</span> ACTIVE ✓</div>
<div class="drone-grid" id="drone-grid">#{body_html}</div>
<script>
let ws=new WebSocket('ws://'+location.host+'/ws/drone');
ws.onmessage=e=>{let f=JSON.parse(e.data);document.getElementById('fleet-count').textContent=Object.keys(f).length;let g=document.getElementById('drone-grid');g.innerHTML='';for(let i in f){let d=f[i],b=d.battery||0,s=d.status||'UNKNOWN';g.innerHTML+=`<div class="drone-card"><h3>🚁 ${i}</h3><div>Lat/Lon: ${d.lat||0}°N, ${d.lon||0}°W</div><div class="status ${s==='ACTIVE'?'online':'offline'}">${s}</div><div class="battery"><div class="battery-fill" style="width:${b}%"></div></div><div>Firmware: ${d.firmware?.version||'N/A'}</div><input id="fw-${i}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('${i}')">⚡ FLASH</button></div>`}};
function uploadFirmware(id){let f=document.getElementById('fw-'+id).files[0];if(!f)return alert('Select firmware');let form=new FormData;form.append('firmware',f);form.append('drone_id',id);fetch('/api/firmware',{method:'POST',body:form}).then(r=>r.json()).then(d=>alert('Flash: '+d.status))}
</script>
</body>
</html>
HTML
end

# 🔥 MAIN RACK APP - RACK 3.0+ COMPLIANT (LOWERCASE HEADERS)
app = lambda do |env|
  req = Rack::Request.new(env)
  path = req.path
  $request_count ||= 0; $request_count += 1

  case path
  when '/'
    [200, {'content-type' => 'text/html; charset=utf-8'}, [cyberpunk_page('🛰️ CYBERPUNK DRONE C2 LIVE', '<div class="drone-card"><h3>PHX COLD CHAIN ✓</h3><div>2 ACTIVE DRONES</div></div>')]]
  when '/health'
    uptime = (Time.now - $start_time).to_i
    [200, {'content-type' => 'application/json'}, [JSON.dump({ok: true, uptime_s: uptime, requests: $request_count, fleet_size: $drone_fleet.size, phx: true})]]
  when '/ws/drone'
    return [404, {'content-type' => 'text/plain'}, ['Upgrade required']] unless Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)
    ws.on :open do
      puts "🛰️ WS CONNECT - FLEET SIZE: #{$drone_fleet.size}"
      ws.send($drone_fleet.to_json)
    end
    ws.on :message do |event|
      puts "📡 CMD: #{event.data}"
      ws.send({status: 'cmd_ok'}.to_json)
    end
    ws.on :close do |event|
      puts "🔌 WS CLOSE #{event.code}"
    end
    ws.rack_response
  when '/api/firmware'
    return [400, {'content-type' => 'text/plain'}, ['Missing drone_id']] unless req.post? && (drone_id = req.params['drone_id'])
    $drone_fleet[drone_id][:firmware][:version] = 'v2.2.0'
    [200, {'content-type' => 'application/json'}, [JSON.dump({status: 'flashed', drone: drone_id, version: 'v2.2.0'})]]
  else
    [404, {'content-type' => 'text/plain'}, ['404 Drone corridor not found']]
  end
end

run app
