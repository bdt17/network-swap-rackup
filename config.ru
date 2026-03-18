require 'rack'
require 'json'

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/html'}, [
      '<!DOCTYPE html><html><head>',
      '<title>Thomas IT Drone Control v2</title>',
      '<meta name="viewport" content="width=device-width">',
      '<style>body{font-family:monospace;background:#0a0a0a;color:#00ff88;padding:20px}',
      '.header{background:rgba(0,255,136,0.1);padding:20px;border-radius:10px}',
      '.drone-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px}',
      '.drone-card{background:rgba(0,20,40,0.8);padding:20px;border:1px solid #00ff88;border-radius:10px}',
      '.status-online{color:#00ff88}.status-offline{color:#ff4444}.coords{font-family:monospace;font-size:14px}',
      '</style></head><body>',
      '<div class="header"><h1>🚁 <span style="color:#00ff88">Thomas IT</span> Drone Fleet</h1>',
      '<p>Real-time GPS · Pharma Cold Chain · 21 CFR Part 11</p></div>',
      '<div class="drone-grid">',
      '<div class="drone-card"><h3>DRONE-001 <span class="status-online">● LIVE</span></h3>',
      '<p>Last ping: <span id="ping1"></span></p><p class="coords">33.4484° N, 112.0740° W (PHX Sky Harbor)</p>',
      '<p>Temp: 2.3°C | Status: Insulin Delivery</p></div>',
      '<div class="drone-card"><h3>DRONE-002 <span class="status-offline">● OFFLINE</span></h3>',
      '<p>Last ping: 14min ago</p><p class="coords">33.6846° N, 112.1240° W (Glendale)</p>',
      '<p>Temp: 1.8°C | Status: Vaccine Route</p></div></div>',
      '<script>setInterval(() => {document.getElementById("ping1").textContent = new Date().toLocaleTimeString();}, 1000);</script>',
      '</body></html>'
    ]]
    
  when '/health', '/status'
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({"status":"healthy","drones":2,"live":1})]]
    
  when '/drones'
    drones = {"drones": [
      {"id": "DRONE-001", "lat": 33.4484, "lng": -112.0740, "status": "live", "temp": 2.3, "payload": "insulin"},
      {"id": "DRONE-002", "lat": 33.6846, "lng": -112.1240, "status": "offline", "temp": 1.8, "payload": "vaccine"}
    ]}
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(drones)]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
