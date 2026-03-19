require 'rack'
require 'json'

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<h1>🚁 Thomas IT Drone Fleet</h1>',
      '<p>PHX Pharma Cold Chain · 21 CFR Part 11</p>',
      '<p><a href="/health">Health</a> | <a href="/drones">Drones</a> | <a href="/shipments">Shipments</a></p>',
      '<hr><small>Rackup v2 + PostgreSQL Ready</small>'
    ]]
  when '/health'
    [200, {'Content-Type' => 'application/json'}, ['{"status":"healthy","service":"live"}']]
  when '/drones'
    [200, {'Content-Type' => 'application/json'}, ['{"drones":[{"id":"DRONE-001","status":"live","lat":33.4484,"lng":-112.0740},{"id":"DRONE-002","status":"offline","lat":33.6846,"lng":-112.1240}]}']]
  when '/shipments'
    [200, {'Content-Type' => 'application/json'}, ['{"total":47,"pending":12,"delivered":35}']]
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
