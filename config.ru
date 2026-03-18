require 'rack'
require 'json'

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<!DOCTYPE html>',
      '<html><head>',
      '<title>Thomas IT Drone Control v2</title>',
      '<meta name="viewport" content="width=device-width">',
      '<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">',
      '<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>',
      '<style>',
      'body{font-family:monospace;background:#0a0a0a;color:#00ff88;margin:0;padding:20px;height:100vh;overflow:hidden}',
      '.header{background:rgba(0,255,136,0.1);padding:20px;border-radius:10px;margin-bottom:20px}',
      '.drone-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;height:calc(100vh - 140px)}',
      '.drone-list{background:rgba(0,20,40,0.9);padding:20px;border:1px solid #00ff88;border-radius:10px;overflow:auto}',
      '.drone-card{margin-bottom:15px;padding:15px;background:rgba(0,30,60,0.6);border-left:3px solid #00ff88;border-radius:5px}',
      '.status-online{color:#00ff88}.status-offline{color:#ff4444}.coords{font-size:12px}',
      '#map{height:100%;border:1px solid #00ff88;border-radius:10px}',
      '</style>',
      '</head><body>',
      '<div class="header">',
      '<h1>🚁 <span style="color:#00ff88">Thomas IT</span> Drone Fleet</h1>',
      '<p>Real-time GPS · Pharma Cold Chain · 21 CFR Part 11</p>',
      '</div>',
      '<div class="drone-grid">',
      '<div class="drone-list">',
      '<h3 style="margin-top:0;color:#00ff88">Active Fleet (2)</h3>',
      '<div class="drone-card">',
      '<h4>DRONE-001 <span class="status-online">● LIVE</span></h4>',
      '<p>Last ping: <span id="ping1"></span></p>',
      '<p class="coords">33.4484° N, 112.0740° W (PHX Sky Harbor)</p>',
      '<p>Temp: 2.3°C | Insulin | 87% Battery | ETA: 14min</p>',
      '</div>',
      '<div class="drone-card">',
      '<h4>DRONE-002 <span class="status-offline">● OFFLINE</span></h4>',
      '<p>Last ping: 14min ago</p>',
      '<p class="coords">33.6846° N, 112.1240° W (Glendale)</p>',
      '<p>Temp: 1.8°C | Vaccine | 23% Battery | Stalled</p>',
      '</div>',
      '</div>',
      '<div id="map"></div>',
      '</div>',
      '<script>',
      'setInterval(()=>document.getElementById("ping1").textContent=new Date().toLocaleTimeString(),1000);',
      'const map=L.map("map").setView([33.52,-112.05],11);',
      'L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png").addTo(map);',
      'L.marker([33.4484,-112.0740]).addTo(map).bindPopup("DRONE-001<br>Insulin<br>LIVE").openPopup();',
      'L.marker([33.6846,-112.1240]).addTo(map).bindPopup("DRONE-002<br>Vaccine<br>OFFLINE");',
      'L.circle([33.4484,-112.0740],{color:"#00ff88",radius:500}).addTo(map);',
      '</script>',
      '</body></html>'
    ]]
    
  when '/health', '/status'
    [200, {'Content-Type' => 'application/json'}, ['{"status":"healthy","drones":2,"live":1}']]
    
  when '/drones'
    [200, {'Content-Type' => 'application/json'}, ['{"drones":[{"id":"DRONE-001","lat":33.4484,"lng":-112.0740,"status":"live","temp":2.3,"payload":"insulin","battery":87,"eta":"14min"},{"id":"DRONE-002","lat":33.6846,"lng":-112.1240,"status":"offline","temp":1.8,"payload":"vaccine","battery":23,"eta":"stalled"}]}']]
    
  when '/shipments'
    [200, {'Content-Type' => 'application/json'}, ['{"total":47,"pending":12,"delivered":35,"failed":0}']]
    
  when '/compliance'
    [200, {'Content-Type' => 'application/json'}, ['{"21 CFR Part 11":"Compliant","signatures":1247,"chain_of_custody":100,"cold_chain_breaches":0}']]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
