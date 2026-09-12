require 'sinatra/base'
require 'json'
require 'rack/utils'
require 'faye/websocket'
require_relative 'models'
require_relative 'db/seeds'

Faye::WebSocket.load_adapter('rack')

# Thread-safe counter for the /health request count (Puma serves requests on
# multiple threads).
class Counter
  def initialize
    @count = 0
    @mutex = Mutex.new
  end

  def increment!
    @mutex.synchronize { @count += 1 }
  end

  def value
    @mutex.synchronize { @count }
  end
end

class App < Sinatra::Base
  START_TIME = Time.now
  REQUEST_COUNT = Counter.new

  set :server, :puma
  set :sockets, []

  configure do
    Seeds.ensure_default_fleet!
  end

  before do
    REQUEST_COUNT.increment!
  end

  helpers do
    def h(text)
      Rack::Utils.escape_html(text.to_s)
    end

    def bump_version(version)
      if version =~ /\Av(\d+)\.(\d+)\.(\d+)\z/
        "v#{Regexp.last_match(1)}.#{Regexp.last_match(2).to_i + 1}.0"
      else
        "#{version}+1"
      end
    end

    def broadcast_fleet!
      payload = { type: 'fleet', drones: Drone.fleet_hash }.to_json
      settings.sockets.each do |socket|
        socket.send(payload)
      rescue StandardError => e
        warn "WS broadcast failed, dropping socket: #{e.message}"
        settings.sockets.delete(socket)
      end
    end

    def handle_command(raw)
      payload = JSON.parse(raw)
      drone = payload['drone_id'] ? Drone.first(slug: payload['drone_id']) : nil
      CommandEvent.create(drone_id: drone&.id, raw_payload: raw, received_at: Time.now)
      { type: 'cmd_ack', status: 'cmd_ok' }
    rescue JSON::ParserError
      CommandEvent.create(drone_id: nil, raw_payload: raw, received_at: Time.now)
      { type: 'cmd_ack', status: 'cmd_error', message: 'invalid JSON' }
    end

    def drone_card_html(drone)
      <<~HTML
        <div class="drone-card"><h3>🚁 #{h(drone.slug)}</h3><div>Lat/Lon: #{drone.lat}°N, #{drone.lon}°W</div><div class="status #{drone.status == 'ACTIVE' ? 'online' : 'offline'}">#{h(drone.status)}</div><div class="battery"><div class="battery-fill" style="width:#{drone.battery}%"></div></div><div>Firmware: #{h(drone.firmware_version)}</div><input id="fw-#{h(drone.slug)}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('#{h(drone.slug)}')">⚡ FLASH</button></div>
      HTML
    end

    def cyberpunk_page(title, initial_count, body_html)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>#{h(title)}</title>
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
        <div id="fleet-status">DRONE FLEET: <span id="fleet-count">#{initial_count}</span> ACTIVE ✓</div>
        <div class="drone-grid" id="drone-grid">#{body_html}</div>
        <script>
        let ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws/drone');
        ws.onmessage=e=>{let msg=JSON.parse(e.data);if(msg.type!=='fleet')return;let f=msg.drones;document.getElementById('fleet-count').textContent=Object.keys(f).length;let g=document.getElementById('drone-grid');g.innerHTML='';for(let i in f){let d=f[i],b=d.battery||0,s=d.status||'UNKNOWN';g.innerHTML+=`<div class="drone-card"><h3>🚁 ${i}</h3><div>Lat/Lon: ${d.lat||0}°N, ${d.lon||0}°W</div><div class="status ${s==='ACTIVE'?'online':'offline'}">${s}</div><div class="battery"><div class="battery-fill" style="width:${b}%"></div></div><div>Firmware: ${d.firmware?.version||'N/A'}</div><input id="fw-${i}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('${i}')">⚡ FLASH</button></div>`}};
        function uploadFirmware(id){let f=document.getElementById('fw-'+id).files[0];if(!f)return alert('Select firmware');let form=new FormData;form.append('firmware',f);form.append('drone_id',id);fetch('/api/firmware',{method:'POST',body:form}).then(r=>r.json()).then(d=>alert('Flash: '+d.status))}
        </script>
        </body>
        </html>
      HTML
    end
  end

  get '/' do
    content_type :html
    cards = Drone.order(:slug).map { |d| drone_card_html(d) }.join
    cyberpunk_page('🛰️ CYBERPUNK DRONE C2 LIVE', Drone.count, cards)
  end

  get '/health' do
    content_type :json
    db_ok = begin
      DB.test_connection
      true
    rescue StandardError
      false
    end
    { ok: db_ok, uptime_s: (Time.now - START_TIME).to_i, requests: REQUEST_COUNT.value,
      fleet_size: Drone.count, db: db_ok }.to_json
  end

  get '/ws/drone' do
    halt 404, 'Upgrade required' unless Faye::WebSocket.websocket?(request.env)

    ws = Faye::WebSocket.new(request.env)
    settings.sockets << ws

    ws.on :open do
      warn "WS CONNECT - fleet size: #{Drone.count}"
      ws.send({ type: 'fleet', drones: Drone.fleet_hash }.to_json)
    end

    ws.on :message do |event|
      ws.send(handle_command(event.data).to_json)
    end

    ws.on :close do |event|
      warn "WS CLOSE #{event.code}"
      settings.sockets.delete(ws)
    end

    ws.rack_response
  end

  post '/api/firmware' do
    content_type :json
    drone_id = params['drone_id']
    halt 400, { error: 'Missing drone_id' }.to_json unless drone_id

    drone = Drone.first(slug: drone_id)
    halt 404, { error: 'Unknown drone' }.to_json unless drone

    from_version = drone.firmware_version
    to_version = bump_version(from_version)
    drone.update(firmware_version: to_version)
    FirmwareEvent.create(drone_id: drone.id, from_version: from_version, to_version: to_version,
                          flashed_at: Time.now)

    broadcast_fleet!

    content_type :json
    { status: 'flashed', drone: drone.slug, version: to_version }.to_json
  end

  # Sinatra runs this for *every* response that ends up with a 404 status -
  # including a deliberate `halt 404, json` from inside a matched route, not
  # just genuinely-unmatched paths - so it must not clobber a JSON body a
  # route already set (see the /api/firmware unknown-drone case).
  not_found do
    next body if response.content_type&.include?('application/json')

    content_type :text
    '404 Drone corridor not found'
  end
end
