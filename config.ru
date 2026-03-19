require 'rack'
require 'json'
require 'pg' rescue nil

$DB = begin
  PG.connect(ENV['DATABASE_URL']) if ENV['DATABASE_URL']
rescue => e
  puts "DB connect: #{e.message}"
  nil
end

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? "✅ LIVE (#{($DB.exec('SELECT COUNT(*) FROM drones').first['count'].to_i)} drones)" : '⚠️ Add DATABASE_URL'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<h1>🚁 Thomas IT Drone Fleet</h1>',
      "<p><strong>Database:</strong> #{db_status}</p>",
      '<p>PHX Pharma Cold Chain · 21 CFR Part 11 Compliant</p>',
      '<ul>',
      '<li><a href="/health">Health Check</a></li>',
      '<li><a href="/drones">Live Drones</a></li>',
      '<li><a href="/shipments">Shipments</a></li>',
      '</ul>'
    ]]
    
  when '/health'
    if $DB
      drones_count = $DB.exec('SELECT COUNT(*) FROM drones').first['count'].to_i
      shipments_count = $DB.exec('SELECT COUNT(*) FROM shipments').first['count'].to_i
    else
      drones_count = shipments_count = 0
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy',
      database: $DB ? 'connected' : 'disconnected',
      drones: drones_count,
      shipments: shipments_count
    })]]
    
  when '/drones'
    if $DB
      drones = $DB.exec('SELECT id, lat, lng, status, temp, payload, battery, eta FROM drones ORDER BY last_ping DESC').to_a
    else
      drones = []
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(drones)]]
    
  when '/shipments'
    if $DB
      shipments = $DB.exec('SELECT id, drone_id, payload, status FROM shipments ORDER BY created_at DESC LIMIT 10').to_a
    else
      shipments = []
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(shipments)]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
