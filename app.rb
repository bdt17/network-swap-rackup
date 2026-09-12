require 'sinatra/base'
require 'json'
require 'csv'
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

    def stream_chips_html(drone)
      streams = drone.latest_streams
      return '' if streams.empty?

      chips = FleetSimulator::STREAM_LABELS.filter_map do |name, label|
        next unless streams[name]

        "<span class=\"stream-chip\">#{h(label)}: #{h(streams[name][:value])}</span>"
      end.join
      "<div class=\"streams\">#{chips}</div>"
    end

    def radar_status_class(status)
      case status
      when 'ACTIVE', 'PATROL_AZ1', 'PATROL_AZ2' then 'blip-active'
      when 'CHARGING' then 'blip-charging'
      when 'OFFLINE' then 'blip-offline'
      else 'blip-maintenance'
      end
    end

    # Auto-fits every drone's lat/lon into a 300x300 radar circle centered on
    # the fleet's own midpoint - not a real map, just relative positions, so
    # a newly-added drone anywhere on Earth still shows up sensibly rather
    # than off the edge or requiring a fixed real-world scale.
    def radar_blips(drones)
      located = drones.select { |d| d.lat && d.lon }
      return [] if located.empty?

      lats = located.map(&:lat)
      lons = located.map(&:lon)
      center_lat = (lats.min + lats.max) / 2.0
      center_lon = (lons.min + lons.max) / 2.0
      span = [(lats.max - lats.min), (lons.max - lons.min), 0.02].max * 1.4
      radius = 130.0

      located.map do |d|
        dx = (d.lon - center_lon) / span
        dy = (d.lat - center_lat) / span
        x = 150 + (dx * radius * 2)
        y = 150 - (dy * radius * 2)
        dist = Math.sqrt(((x - 150)**2) + ((y - 150)**2))
        if dist > radius
          angle = Math.atan2(y - 150, x - 150)
          x = 150 + (radius * Math.cos(angle))
          y = 150 + (radius * Math.sin(angle))
        end
        { x: x.round(1), y: y.round(1), slug: d.slug, status_class: radar_status_class(d.status) }
      end
    end

    def radar_blips_svg(drones)
      radar_blips(drones).map do |b|
        "<g class=\"radar-blip #{b[:status_class]}\"><circle cx=\"#{b[:x]}\" cy=\"#{b[:y]}\" r=\"6\"/>" \
          "<text x=\"#{b[:x] + 10}\" y=\"#{b[:y] + 4}\">#{h(b[:slug])}</text></g>"
      end.join
    end

    # The sweep <g> is deliberately left untouched by live updates (only
    # #radar-blips gets replaced) so its CSS rotation animation never resets
    # mid-sweep on every simulator tick.
    def radar_svg(drones)
      <<~SVG
        <svg viewBox="0 0 300 300" class="radar">
          <circle cx="150" cy="150" r="130" class="radar-ring"/>
          <circle cx="150" cy="150" r="87" class="radar-ring"/>
          <circle cx="150" cy="150" r="43" class="radar-ring"/>
          <line x1="20" y1="150" x2="280" y2="150" class="radar-crosshair"/>
          <line x1="150" y1="20" x2="150" y2="280" class="radar-crosshair"/>
          <g class="radar-sweep"><path d="M150,150 L280,150 A130,130 0 0,0 249.6,72.8 Z"/></g>
          <g id="radar-blips">#{radar_blips_svg(drones)}</g>
        </svg>
      SVG
    end

    def fleet_alerts(drones)
      alerts = []
      drones.each do |d|
        streams = d.latest_streams
        if d.battery && d.battery <= FleetSimulator::LOW_BATTERY && d.status != 'CHARGING'
          alerts << "🔋 #{d.slug}: battery low (#{d.battery}%)"
        end

        cam = streams['camera']&.dig(:value)
        alerts << "📷 #{d.slug}: camera #{cam}" if %w[DEGRADED OFFLINE].include?(cam)

        signal = streams['link_signal']&.dig(:value)
        alerts << "📶 #{d.slug}: weak signal (#{signal})" if signal && signal.to_s[/-?\d+/].to_i <= -80
      end
      alerts
    end

    def fleet_alerts_html(drones)
      alerts = fleet_alerts(drones)
      return '<div class="alert-row alert-ok">✅ All systems nominal.</div>' if alerts.empty?

      alerts.map { |a| "<div class=\"alert-row\">#{h(a)}</div>" }.join
    end

    def drone_card_html(drone)
      <<~HTML
        <div class="drone-card"><h3>🚁 #{h(drone.slug)}</h3><div>Lat/Lon: #{drone.lat}°N, #{drone.lon}°W</div><div class="status #{drone.status == 'ACTIVE' ? 'online' : 'offline'}">#{h(drone.status)}</div><div class="battery"><div class="battery-fill" style="width:#{drone.battery}%"></div><span class="battery-label">#{drone.battery}%</span></div><div>Firmware: #{h(drone.firmware_version)}</div>#{stream_chips_html(drone)}<input id="fw-#{h(drone.slug)}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('#{h(drone.slug)}')">⚡ FLASH</button><a class="drone-btn hist-link" href="/drones/#{h(drone.slug)}">📜 History</a><button class="drone-btn danger-btn" onclick="removeDrone('#{h(drone.slug)}')">🗑 Remove</button></div>
      HTML
    end

    # Shared by every page in the app - the neon/dark identity, buttons,
    # links. Page-specific layout (grid, radar, charts) is added on top.
    def base_css
      <<~CSS
        body{font-family:"Courier New",monospace;background:linear-gradient(45deg,#0a0a0a,#1a0033,#000066,#330066);background-attachment:fixed;color:#00ffcc;margin:0;padding:20px;min-height:100vh;overflow-x:auto}
        body::before{content:'';position:fixed;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,rgba(0,255,204,.03) 0px,rgba(0,255,204,.03) 1px,transparent 1px,transparent 3px);z-index:-1}
        a{color:#00ffcc}
        h1{text-align:center;font-size:2.2em;text-shadow:0 0 20px #00ffcc;margin-bottom:20px;letter-spacing:1px;animation:glow 2s ease-in-out infinite alternate}
        @keyframes glow{from{text-shadow:0 0 15px #00ffcc;}to{text-shadow:0 0 35px #00ffcc,0 0 55px #00ffcc;}}
        #fw-file,.drone-btn{background:#00ffcc;color:#000;border:none;padding:10px 15px;border-radius:5px;cursor:pointer;font-family:inherit;font-weight:bold;margin:4px 4px 0 0;transition:background .15s,transform .15s}
        .drone-btn:hover{background:#00ccaa;transform:translateY(-1px)}
        .hist-link{display:inline-block;text-decoration:none}
        .danger-btn{background:#ff4444;color:#fff}
        .danger-btn:hover{background:#cc0000}
      CSS
    end

    def cyberpunk_page(title, drones)
      cards = drones.map { |d| drone_card_html(d) }.join
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>#{h(title)}</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        #{base_css}
        .toolbar{max-width:1200px;margin:0 auto 20px;text-align:center}
        .top-row{display:flex;gap:20px;flex-wrap:wrap;max-width:1200px;margin:0 auto 20px;justify-content:center}
        .radar-panel,.alerts-panel{background:rgba(0,255,204,.06);border:1px solid rgba(0,255,204,.35);border-radius:15px;padding:16px}
        .radar-panel{flex:1 1 320px;max-width:340px}
        .alerts-panel{flex:2 1 420px;max-width:640px}
        .radar-panel h3,.alerts-panel h3{margin-top:0}
        .radar{width:100%;max-width:300px;display:block;margin:0 auto}
        .radar-ring{fill:none;stroke:rgba(0,255,204,.25);stroke-width:1}
        .radar-crosshair{stroke:rgba(0,255,204,.15);stroke-width:1}
        .radar-sweep{transform-origin:150px 150px;animation:radar-spin 4s linear infinite}
        .radar-sweep path{fill:rgba(0,255,204,.18)}
        @keyframes radar-spin{to{transform:rotate(360deg)}}
        .radar-blip circle{animation:blip-pulse 1.6s ease-in-out infinite}
        .radar-blip text{font-size:9px;fill:#00ffcc}
        .blip-active circle{fill:#00ff00}
        .blip-charging circle{fill:#ffaa00}
        .blip-offline circle{fill:#ff4444}
        .blip-maintenance circle{fill:#888}
        @keyframes blip-pulse{0%,100%{opacity:1}50%{opacity:.4}}
        .alert-row{padding:6px 0;border-bottom:1px solid rgba(0,255,204,.15);font-size:.92em}
        .alert-ok{color:#00ff00;border-bottom:none}
        .drone-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px;max-width:1200px;margin:0 auto}
        .drone-card{background:rgba(0,255,204,.1);border:2px solid #00ffcc;border-radius:15px;padding:20px;box-shadow:0 10px 30px rgba(0,255,204,.3);transition:all .3s}
        .drone-card:hover{transform:translateY(-6px);box-shadow:0 20px 50px rgba(0,255,204,.5)}
        .status{font-weight:bold;font-size:1.2em}
        .online{color:#00ff00}.offline{color:#ff4444}
        .battery{position:relative;background:#333;height:22px;border-radius:10px;overflow:hidden;margin:10px 0}
        .battery-fill{height:100%;background:linear-gradient(90deg,#ffaa00,#00ff00);transition:width .5s}
        .battery-label{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:.75em;font-weight:bold;color:#000;text-shadow:0 0 2px rgba(255,255,255,.6)}
        .streams{margin:8px 0;display:flex;flex-wrap:wrap;gap:6px}
        .stream-chip{background:rgba(0,255,204,.15);border:1px solid rgba(0,255,204,.4);border-radius:12px;padding:2px 8px;font-size:.8em}
        </style>
        </head>
        <body>
        <h1>🛰️ THOMAS IT // CYBERPUNK DRONE FLEET #NEON</h1>
        <div id="fleet-status">DRONE FLEET: <span id="fleet-count">#{drones.size}</span> ACTIVE ✓</div>
        <div class="toolbar"><button class="drone-btn" onclick="addDrone()">➕ Add Drone</button> <button class="drone-btn" onclick="setToken()">🔑 Set API Token</button> <a class="drone-btn hist-link" href="/drones.csv">⬇ Export CSV</a> <a class="drone-btn hist-link" href="/security/two-factor">🔒 Security</a> <form method="post" action="/logout" style="display:inline"><button class="drone-btn" type="submit">🚪 Sign out</button></form></div>
        <div class="top-row">
          <div class="radar-panel"><h3>📡 Radar</h3>#{radar_svg(drones)}</div>
          <div class="alerts-panel"><h3>⚠️ Fleet Alerts</h3><div id="fleet-alerts">#{fleet_alerts_html(drones)}</div></div>
        </div>
        <div class="drone-grid" id="drone-grid">#{cards}</div>
        <script>
        let apiToken=localStorage.getItem('drone_api_token')||'';
        function authHeaders(extra){extra=extra||{};if(apiToken)extra['X-Drone-Token']=apiToken;return extra}
        function setToken(){let t=prompt('API token (leave blank to clear):',apiToken||'');if(t===null)return;apiToken=t;localStorage.setItem('drone_api_token',t)}
        let ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws/drone'+(apiToken?('?token='+encodeURIComponent(apiToken)):''));
        let streamLabels={camera:'📷 Camera',link_signal:'📶 Link',temperature:'🌡️ Temp',altitude:'📏 Altitude'};
        function streamChipsHtml(streams){if(!streams)return'';return `<div class="streams">`+Object.keys(streamLabels).filter(k=>streams[k]).map(k=>`<span class="stream-chip">${streamLabels[k]}: ${streams[k]}</span>`).join('')+`</div>`}
        function radarStatusClass(s){if(s==='ACTIVE'||s==='PATROL_AZ1'||s==='PATROL_AZ2')return'blip-active';if(s==='CHARGING')return'blip-charging';if(s==='OFFLINE')return'blip-offline';return'blip-maintenance'}
        function computeBlips(f){let entries=Object.entries(f).filter(([,d])=>d.lat!=null&&d.lon!=null);if(!entries.length)return[];let lats=entries.map(([,d])=>d.lat),lons=entries.map(([,d])=>d.lon);let centerLat=(Math.min(...lats)+Math.max(...lats))/2,centerLon=(Math.min(...lons)+Math.max(...lons))/2;let span=Math.max(Math.max(...lats)-Math.min(...lats),Math.max(...lons)-Math.min(...lons),0.02)*1.4;let radius=130;return entries.map(([slug,d])=>{let dx=(d.lon-centerLon)/span,dy=(d.lat-centerLat)/span;let x=150+dx*radius*2,y=150-dy*radius*2;let dist=Math.sqrt((x-150)**2+(y-150)**2);if(dist>radius){let angle=Math.atan2(y-150,x-150);x=150+radius*Math.cos(angle);y=150+radius*Math.sin(angle)}return{x:x.toFixed(1),y:y.toFixed(1),slug,statusClass:radarStatusClass(d.status)}})}
        function updateRadar(f){let g=document.getElementById('radar-blips');if(!g)return;g.innerHTML=computeBlips(f).map(b=>`<g class="radar-blip ${b.statusClass}"><circle cx="${b.x}" cy="${b.y}" r="6"/><text x="${Number(b.x)+10}" y="${Number(b.y)+4}">${b.slug}</text></g>`).join('')}
        function computeAlerts(f){let alerts=[];for(let slug in f){let d=f[slug],streams=d.streams||{};if(d.battery!=null&&d.battery<=15&&d.status!=='CHARGING')alerts.push(`🔋 ${slug}: battery low (${d.battery}%)`);let cam=streams.camera;if(cam==='DEGRADED'||cam==='OFFLINE')alerts.push(`📷 ${slug}: camera ${cam}`);let sig=streams.link_signal;if(sig&&parseInt(sig)<=-80)alerts.push(`📶 ${slug}: weak signal (${sig})`)}return alerts}
        function updateAlerts(f){let el=document.getElementById('fleet-alerts');if(!el)return;let alerts=computeAlerts(f);el.innerHTML=alerts.length?alerts.map(a=>`<div class="alert-row">${a}</div>`).join(''):'<div class="alert-row alert-ok">✅ All systems nominal.</div>'}
        function renderFleet(f){document.getElementById('fleet-count').textContent=Object.keys(f).length;updateRadar(f);updateAlerts(f);let g=document.getElementById('drone-grid');g.innerHTML='';for(let i in f){let d=f[i],b=d.battery||0,s=d.status||'UNKNOWN';g.innerHTML+=`<div class="drone-card"><h3>🚁 ${i}</h3><div>Lat/Lon: ${d.lat||0}°N, ${d.lon||0}°W</div><div class="status ${s==='ACTIVE'?'online':'offline'}">${s}</div><div class="battery"><div class="battery-fill" style="width:${b}%"></div><span class="battery-label">${b}%</span></div><div>Firmware: ${d.firmware?.version||'N/A'}</div>${streamChipsHtml(d.streams)}<input id="fw-${i}" type="file" accept=".bin,.hex"><button class="drone-btn" onclick="uploadFirmware('${i}')">⚡ FLASH</button><a class="drone-btn hist-link" href="/drones/${i}">📜 History</a><button class="drone-btn danger-btn" onclick="removeDrone('${i}')">🗑 Remove</button></div>`}}
        ws.onmessage=e=>{let msg=JSON.parse(e.data);if(msg.type!=='fleet')return;renderFleet(msg.drones)};
        function uploadFirmware(id){let f=document.getElementById('fw-'+id).files[0];if(!f)return alert('Select firmware');let form=new FormData;form.append('firmware',f);form.append('drone_id',id);fetch('/api/firmware',{method:'POST',headers:authHeaders(),body:form}).then(r=>r.json()).then(d=>alert('Flash: '+(d.status||d.error)))}
        function addDrone(){let slug=prompt('New drone id (e.g. drone-003):');if(!slug)return;let lat=prompt('Latitude:','33.45'),lon=prompt('Longitude:','-112.07');let form=new FormData;form.append('slug',slug);form.append('lat',lat);form.append('lon',lon);fetch('/api/drones',{method:'POST',headers:authHeaders(),body:form}).then(r=>r.json()).then(d=>{if(d.error)alert('Error: '+d.error)})}
        function removeDrone(id){if(!confirm('Remove '+id+'? This deletes its history too.'))return;fetch('/api/drones/'+id,{method:'DELETE',headers:authHeaders()}).then(r=>r.json()).then(d=>{if(d.error)alert('Error: '+d.error)})}
        </script>
        </body>
        </html>
      HTML
    end

    def sparkline_svg(history, unit:, width: 560, height: 110)
      return '<div class="chart-empty">Not enough data yet.</div>' if history.size < 2

      values = history.map { |pt| pt[:value] }
      min_v = values.min
      max_v = values.max
      range = (max_v - min_v).zero? ? 1.0 : (max_v - min_v)
      pad = 12
      step = (width - (2 * pad)) / (history.size - 1).to_f

      points = history.each_with_index.map do |pt, i|
        x = pad + (i * step)
        y = pad + ((height - (2 * pad)) * (1 - ((pt[:value] - min_v) / range)))
        [x.round(1), y.round(1)]
      end

      path_d = points.each_with_index.map { |(x, y), i| "#{i.zero? ? 'M' : 'L'}#{x},#{y}" }.join(' ')

      dots = points.each_with_index.map do |(x, y), i|
        pt = history[i]
        "<circle class=\"spark-pt\" cx=\"#{x}\" cy=\"#{y}\" r=\"9\" " \
          "data-value=\"#{h(pt[:value])}#{h(unit)}\" data-time=\"#{h(pt[:recorded_at].strftime('%H:%M:%S'))}\"></circle>"
      end.join

      <<~SVG
        <svg viewBox="0 0 #{width} #{height}" class="sparkline" preserveAspectRatio="none">
          <path d="#{path_d}" class="spark-line"/>
          #{dots}
        </svg>
      SVG
    end

    def history_page(drone)
      stream_label = lambda do |name|
        FleetSimulator::STREAM_LABELS[name] || FleetSimulator::CHART_STREAMS.dig(name, :label) || name
      end
      events = (drone.firmware_events.map { |e| [e.flashed_at, "Firmware #{h(e.from_version)} → #{h(e.to_version)}"] } +
                 drone.command_events.map { |e| [e.received_at, "Command: #{h(e.raw_payload)}"] } +
                 drone.stream_readings.map { |r| [r.recorded_at, "#{h(stream_label.call(r.stream_name))}: #{h(r.value)}"] }
               ).sort_by { |t, _| t }.reverse.first(50)

      rows = events.map { |t, desc| "<div class=\"event-row\"><span class=\"event-time\">#{h(t)}</span> #{desc}</div>" }.join
      rows = '<div class="event-row">No history yet.</div>' if events.empty?

      charts = FleetSimulator::CHART_STREAMS.map do |name, meta|
        history = StreamReading.numeric_history_for(drone.id, name)
        "<div class=\"chart-card\"><h4>#{h(meta[:label])}</h4>#{sparkline_svg(history, unit: meta[:unit])}</div>"
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>#{h(drone.slug)} — History</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        #{base_css}
        .max-w{max-width:1200px;margin:0 auto}
        h1{font-size:1.8em;text-align:left}
        .charts-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin:20px 0}
        .chart-card{background:rgba(0,255,204,.06);border:1px solid rgba(0,255,204,.3);border-radius:12px;padding:14px}
        .chart-card h4{margin:0 0 8px}
        .sparkline{width:100%;height:auto;display:block;overflow:visible}
        .spark-line{fill:none;stroke:#00ffcc;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
        .spark-pt{fill:transparent;cursor:pointer}
        .spark-pt:hover{fill:rgba(0,255,204,.3)}
        .chart-empty{color:#888;font-size:.9em}
        .chart-tooltip{position:fixed;background:#000;border:1px solid #00ffcc;color:#00ffcc;padding:4px 8px;border-radius:4px;font-size:.8em;pointer-events:none;display:none;z-index:10}
        .event-row{border-bottom:1px solid rgba(0,255,204,.2);padding:10px 0}
        .event-time{color:#888;margin-right:10px}
        </style>
        </head>
        <body>
        <div class="max-w">
        <a href="/">&larr; Back to fleet</a>
        <h1>🚁 #{h(drone.slug)} — history</h1>
        <div>Status: #{h(drone.status)} · Battery: #{drone.battery}% · Firmware: #{h(drone.firmware_version)}</div>
        <div class="charts-grid">#{charts}</div>
        <div>#{rows}</div>
        </div>
        <div id="chart-tooltip" class="chart-tooltip"></div>
        <script>
        document.querySelectorAll('.spark-pt').forEach(pt=>{
          pt.addEventListener('mousemove', e=>{
            let tip=document.getElementById('chart-tooltip');
            tip.style.display='block';
            tip.style.left=(e.clientX+12)+'px';
            tip.style.top=(e.clientY+12)+'px';
            tip.textContent=pt.dataset.time+' — '+pt.dataset.value;
          });
          pt.addEventListener('mouseleave', ()=>{document.getElementById('chart-tooltip').style.display='none'});
        });
        </script>
        </body>
        </html>
      HTML
    end
  end

  get '/' do
    content_type :html
    cyberpunk_page('🛰️ CYBERPUNK DRONE C2 LIVE', Drone.order(:slug).all)
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

  get '/drones.csv' do
    content_type 'text/csv'
    attachment 'fleet.csv'
    CSV.generate do |csv|
      csv << %w[slug status battery lat lon firmware_version camera link_signal temperature altitude updated_at]
      Drone.order(:slug).each do |d|
        streams = d.latest_streams
        csv << [d.slug, d.status, d.battery, d.lat, d.lon, d.firmware_version,
                streams['camera']&.dig(:value), streams['link_signal']&.dig(:value),
                streams['temperature']&.dig(:value), streams['altitude']&.dig(:value), d.updated_at]
      end
    end
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
