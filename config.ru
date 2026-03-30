#!/usr/bin/env ruby
# Thomas IT Drone C2 - 100% Rack 3.0 compliant

require 'json'

$drone_fleet = {
  'drone-001' => {status: 'READY', battery: 87.0, lat: 33.4484, lng: -112.0740},
  'drone-002' => {status: 'PATROL_AZ1', battery: 76.0, lat: 33.5138, lng: -112.1314}
}
$request_count = 0
$start_time ||= Time.now

app = proc do |env|
  req = Rack::Request.new(env)
  $request_count += 1
  path = req.path_info
  uptime = (Time.now - $start_time).round(1)
  
  case path
  when '/'
    body = ["🛰️ THOMAS IT // DRONE FLEET C2\n",
            "ACTIVE DRONES: #{$drone_fleet.size}\n", 
            "drone-002 PATROL_AZ1: 33.5138°N 112.1314°W (76% 🔋)\n",
            "Uptime: #{uptime}s | Requests: #{$request_count}"]
    [200, {'content-type' => 'text/plain;charset=utf-8'}, body]
    
  when '/health'
    body = [JSON.generate({ok: true, fleet: $drone_fleet.keys, requests: $request_count})]
    [200, {'content-type' => 'application/json'}, body]
    
  when '/api/drone_002'
    body = [JSON.generate($drone_fleet['drone-002'])]
    [200, {'content-type' => 'application/json'}, body]
    
  else
    [404, {'content-type' => 'text/plain'}, ['404 Drone corridor not found']]
  end
end

run app
