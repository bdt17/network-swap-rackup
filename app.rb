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
  COMMANDS = %w[recall resume set_status].freeze

  set :server, :puma
  set :sockets, []

  configure do
    Seeds.ensure_default_fleet!
  end

  before do
    REQUEST_COUNT.increment!
    FleetSimulator.tick_if_due! { self.class.broadcast_fleet! } if defined?(FleetSimulator)
  end

  # Broadcasts are also triggered from FleetSimulator, which runs on a plain
  # background Thread with no request/instance context - so this has to be
  # callable as a class method, not just a route helper.
  def self.broadcast_fleet!
    payload = { type: 'fleet', drones: Drone.fleet_hash }.to_json
    sockets.each do |socket|
      socket.send(payload)
    rescue StandardError => e
      warn "WS broadcast failed, dropping socket: #{e.message}"
      sockets.delete(socket)
    end
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
      self.class.broadcast_fleet!
    end

    def handle_command(raw)
      payload = JSON.parse(raw)
      drone = payload['drone_id'] ? Drone.first(slug: payload['drone_id']) : nil
      result = apply_command(drone, payload)
      CommandEvent.create(drone_id: drone&.id, raw_payload: raw, received_at: Time.now)
      broadcast_fleet! if result[:applied]
      { type: 'cmd_ack' }.merge(result)
    rescue JSON::ParserError
      CommandEvent.create(drone_id: nil, raw_payload: raw, received_at: Time.now)
      { type: 'cmd_ack', applied: false, error: 'invalid JSON' }
    end

    def apply_command(drone, payload)
      return { applied: false, error: 'unknown drone_id' } unless drone

      case payload['cmd']
      when 'recall'
        drone.update(status: 'CHARGING')
        { applied: true, cmd: 'recall', status: drone.status }
      when 'resume'
        drone.update(status: 'ACTIVE')
        { applied: true, cmd: 'resume', status: drone.status }
      when 'set_status'
        status = payload['status']
        unless Drone::STATUSES.include?(status)
          return { applied: false, error: "status must be one of #{Drone::STATUSES.join(', ')}" }
        end

        drone.update(status: status)
        { applied: true, cmd: 'set_status', status: drone.status }
      else
        { applied: false, error: "unknown cmd #{payload['cmd'].inspect}, must be one of #{COMMANDS.join(', ')}" }
      end
    end

    def drone_card_html(drone)
      <<~HTML
        <div class="drone-card"><h3>🚁 #{h(drone.slug)}</h3><div>Lat/Lon: #{drone.lat}°N, #{drone.lon}°W</div><div class="status #{drone.status == 'ACTIVE' ? 'online' : 'offline'}">#{h(drone.status)}</div><div class="battery"><div class="battery-fill" style="width:#{drone.battery}%"></div></div><div>Firmware: #{h(drone.firmware_version)}</div><input id="fw-#{h(drone.slug)}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('#{h(drone.slug)}')">⚡ FLASH</button><a class="drone-btn hist-link" href="/drones/#{h(drone.slug)}">📜 History</a><button class="drone-btn danger-btn" onclick="removeDrone('#{h(drone.slug)}')">🗑 Remove</button></div>
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
        .toolbar{max-width:1200px;margin:0 auto 20px;text-align:center}
        .drone-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px;max-width:1200px;margin:0 auto}
        .drone-card{background:rgba(0,255,204,.1);border:2px solid #00ffcc;border-radius:15px;padding:20px;box-shadow:0 10px 30px rgba(0,255,204,.3);transition:all .3s}
        .drone-card:hover{transform:translateY(-10px);box-shadow:0 20px 50px rgba(0,255,204,.5)}
        .status{font-weight:bold;font-size:1.2em;}
        .online{color:#00ff00}.offline{color:#ff4444}
        .battery{background:#333;height:20px;border-radius:10px;overflow:hidden;margin:10px 0}
        .battery-fill{height:100%;background:linear-gradient(90deg,#ffaa00,#00ff00);transition:width .5s}
        #fw-file,.drone-btn{background:#00ffcc;color:#000;border:none;padding:10px 15px;border-radius:5px;cursor:pointer;font-family:inherit;font-weight:bold;margin:4px 4px 0 0}
        .drone-btn:hover{background:#00ccaa}
        .hist-link{display:inline-block;text-decoration:none}
        .danger-btn{background:#ff4444;color:#fff}
        .danger-btn:hover{background:#cc0000}
        </style>
        </head>
        <body>
        <h1>🛰️ THOMAS IT // CYBERPUNK DRONE FLEET #NEON</h1>
        <div id="fleet-status">DRONE FLEET: <span id="fleet-count">#{initial_count}</span> ACTIVE ✓</div>
        <div class="toolbar"><button class="drone-btn" onclick="addDrone()">➕ Add Drone</button> <button class="drone-btn" onclick="setToken()">🔑 Set API Token</button> <a class="drone-btn hist-link" href="/security/two-factor">🔒 Security</a> <form method="post" action="/logout" style="display:inline"><button class="drone-btn" type="submit">🚪 Sign out</button></form></div>
        <div class="drone-grid" id="drone-grid">#{body_html}</div>
        <script>
        let apiToken=localStorage.getItem('drone_api_token')||'';
        function authHeaders(extra){extra=extra||{};if(apiToken)extra['X-Drone-Token']=apiToken;return extra}
        function setToken(){let t=prompt('API token (leave blank to clear):',apiToken||'');if(t===null)return;apiToken=t;localStorage.setItem('drone_api_token',t)}
        let ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws/drone'+(apiToken?('?token='+encodeURIComponent(apiToken)):''));
        function renderFleet(f){document.getElementById('fleet-count').textContent=Object.keys(f).length;let g=document.getElementById('drone-grid');g.innerHTML='';for(let i in f){let d=f[i],b=d.battery||0,s=d.status||'UNKNOWN';g.innerHTML+=`<div class="drone-card"><h3>🚁 ${i}</h3><div>Lat/Lon: ${d.lat||0}°N, ${d.lon||0}°W</div><div class="status ${s==='ACTIVE'?'online':'offline'}">${s}</div><div class="battery"><div class="battery-fill" style="width:${b}%"></div></div><div>Firmware: ${d.firmware?.version||'N/A'}</div><input id="fw-${i}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('${i}')">⚡ FLASH</button><a class="drone-btn hist-link" href="/drones/${i}">📜 History</a><button class="drone-btn danger-btn" onclick="removeDrone('${i}')">🗑 Remove</button></div>`}}
        ws.onmessage=e=>{let msg=JSON.parse(e.data);if(msg.type!=='fleet')return;renderFleet(msg.drones)};
        function uploadFirmware(id){let f=document.getElementById('fw-'+id).files[0];if(!f)return alert('Select firmware');let form=new FormData;form.append('firmware',f);form.append('drone_id',id);fetch('/api/firmware',{method:'POST',headers:authHeaders(),body:form}).then(r=>r.json()).then(d=>alert('Flash: '+(d.status||d.error)))}
        function addDrone(){let slug=prompt('New drone id (e.g. drone-003):');if(!slug)return;let lat=prompt('Latitude:','33.45'),lon=prompt('Longitude:','-112.07');let form=new FormData;form.append('slug',slug);form.append('lat',lat);form.append('lon',lon);fetch('/api/drones',{method:'POST',headers:authHeaders(),body:form}).then(r=>r.json()).then(d=>{if(d.error)alert('Error: '+d.error)})}
        function removeDrone(id){if(!confirm('Remove '+id+'? This deletes its history too.'))return;fetch('/api/drones/'+id,{method:'DELETE',headers:authHeaders()}).then(r=>r.json()).then(d=>{if(d.error)alert('Error: '+d.error)})}
        </script>
        </body>
        </html>
      HTML
    end

    def history_page(drone)
      events = (drone.firmware_events.map { |e| [e.flashed_at, "Firmware #{h(e.from_version)} → #{h(e.to_version)}"] } +
                 drone.command_events.map { |e| [e.received_at, "Command: #{h(e.raw_payload)}"] }).sort_by { |t, _| t }.reverse

      rows = events.map { |t, desc| "<div class=\"event-row\"><span class=\"event-time\">#{h(t)}</span> #{desc}</div>" }.join
      rows = '<div class="event-row">No history yet.</div>' if events.empty?

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>#{h(drone.slug)} — History</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body{font-family:"Courier New",monospace;background:linear-gradient(45deg,#0a0a0a,#1a0033,#000066,#330066);color:#00ffcc;margin:0;padding:20px;min-height:100vh}
        h1{font-size:1.8em}
        a{color:#00ffcc}
        .event-row{border-bottom:1px solid rgba(0,255,204,.2);padding:10px 0}
        .event-time{color:#888;margin-right:10px}
        </style>
        </head>
        <body>
        <a href="/">&larr; Back to fleet</a>
        <h1>🚁 #{h(drone.slug)} — history</h1>
        <div>Status: #{h(drone.status)} · Battery: #{drone.battery}% · Firmware: #{h(drone.firmware_version)}</div>
        <div style="margin-top:20px">#{rows}</div>
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
    simulator = defined?(FleetSimulator) ? FleetSimulator.status : { note: 'not loaded' }
    { ok: db_ok, uptime_s: (Time.now - START_TIME).to_i, requests: REQUEST_COUNT.value,
      fleet_size: Drone.count, db: db_ok, connected_sockets: settings.sockets.size,
      simulator: simulator }.to_json
  end

  get '/drones/:slug' do
    drone = Drone.first(slug: params['slug'])
    halt 404, 'Drone not found' unless drone

    content_type :html
    history_page(drone)
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

    { status: 'flashed', drone: drone.slug, version: to_version }.to_json
  end

  post '/api/drones' do
    content_type :json
    slug = params['slug'].to_s.strip
    halt 400, { error: 'Missing slug' }.to_json if slug.empty?
    halt 409, { error: 'Drone already exists' }.to_json if Drone.first(slug: slug)

    drone = Drone.new(
      slug: slug,
      name: params['name'] || slug,
      lat: params['lat']&.to_f,
      lon: params['lon']&.to_f,
      battery: (params['battery'] || 100).to_i,
      status: params['status'] || 'ACTIVE',
      firmware_version: params['firmware_version'] || 'v1.0.0'
    )

    unless drone.valid?
      halt 422, { error: drone.errors.full_messages.join(', ') }.to_json
    end

    drone.save
    broadcast_fleet!

    status 201
    { status: 'created', drone: drone.to_fleet_json.merge(slug: drone.slug) }.to_json
  end

  delete '/api/drones/:slug' do
    content_type :json
    drone = Drone.first(slug: params['slug'])
    halt 404, { error: 'Unknown drone' }.to_json unless drone

    drone.destroy
    broadcast_fleet!

    { status: 'deleted', drone: params['slug'] }.to_json
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
