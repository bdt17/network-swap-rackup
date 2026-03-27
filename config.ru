app = lambda do |env|
  req = Rack::Request.new(env)
  path = req.path_info
  $request_count += 1
  uptime = (Time.now - $start_time).round(1)

  # WEBSOCKET
  if path == '/ws/drone' && Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)
    ws.on :open do |event|
      puts "🛰️ WEBSOCKET CONNECT"
      ws.send($drone_fleet.to_json)

      EM.add_periodic_timer(3) do
        next unless ws && ws.instance_variable_get(:@ready_state) == 1
        $drone_fleet['drone-001'][:lng] += 0.001 if rand < 0.3
        $drone_fleet['drone-001'][:battery] -= 0.1
        ws.send($drone_fleet.to_json)
      end
    end

    ws.on :message do |event|
      begin
        cmd = JSON.parse(event.data)
        drone_id = cmd['drone_id'] || 'drone-001'
        case cmd['action']
        when 'mission_start'; $drone_fleet[drone_id][:status] = 'MISSION_ACTIVE'
        when 'rtl';         $drone_fleet[drone_id][:status] = 'RTL_PHX_HQ'
        when 'land';        $drone_fleet[drone_id][:status] = 'LANDING'
        when 'emergency';   $drone_fleet[drone_id][:status] = 'EMERGENCY'
        end
        ws.send({status: 'cmd_ok', drone_id: drone_id}.to_json)
      rescue => e
        ws.send({error: e.message}.to_json)
      end
    end

    ws.on :close do |event|
      puts "🛰️ WEBSOCKET CLOSED"
    end

    ws.on :error do |event|
      puts "🛰️ WEBSOCKET ERROR: #{event.message}"
    end

    ws.rack_response

  # FIRMWARE UPLOAD
  elsif req.post? && path == '/api/firmware'
    upload = req.params['file']
    if upload && upload[:tempfile]
      firmware_data = upload[:tempfile].read
      firmware_hash = Digest::SHA256.hexdigest(firmware_data)[0..8]

      $drone_fleet['drone-001'][:firmware] = {
        version: upload[:filename].match(/v(\d+\.\d+\.\d+)/) ? upload[:filename] : 'v2.1.0',
        hash:  firmware_hash,
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
    action   = req.params['action']   || 'unknown'

    if $drone_fleet[drone_id]
      case action
      when 'mission_start'; $drone_fleet[drone_id][:status] = 'MISSION_ACTIVE'
      when 'rtl';         $drone_fleet[drone_id][:status] = 'RTL_PHX_HQ'
      when 'land';        $drone_fleet[drone_id][:status] = 'LANDING'
      when 'emergency';   $drone_fleet[drone_id][:status] = 'EMERGENCY'
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
      stripe_key_present: !Stripe.api_key.to_s.empty?
    }

    body_html = <<~HTML
<div class="grid">
  <div class="card">
    <h2>Control Tower</h2>
    <pre>#{JSON.pretty_generate(stats)}</pre>
    <div class="pill ok">WEBSOCKET ✓</div>
    <div class="pill ok">FIRMWARE ✓</div>
  </div>
  <!-- ... rest of your cards / buttons ... -->
</div>
<div class="cta" onclick="location.reload()">DEPLOY FLEET + FIRMWARE SWAP</div>
HTML

    [200, {'content-type' => 'text/html; charset=utf-8'}, [cyberpunk_page('DRONE FLEET C2 v2.1', body_html)]]

  # HEALTH
  elsif path == '/health'
    [200, {'content-type' => 'application/json'}, [JSON.dump({ok: true, requests: $request_count, uptime_s: uptime, fleet_size: $drone_fleet.size})]]

  else
    [404, {'content-type' => 'text/plain'}, ['404 Drone corridor not found']]
  end
end

run app















































