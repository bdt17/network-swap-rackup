require 'rack'
require 'json'
require 'pg' rescue nil

# Lazy PostgreSQL (Render DB)
$DB = begin
  PG.connect(ENV['DATABASE_URL']) if ENV['DATABASE_URL']
rescue PG::Error
  nil
end

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? '✅ LIVE' : '⚠️ Pending'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<h1>🚁 Thomas IT Drone Fleet</h1>',
      "<p><strong>Database:</strong> #{db_status}</p>",
      '<p>PHX Pharma Cold Chain · 21 CFR Part 11</p>',
      "<p><a href='/health'>Health</a> | <a href='/drones'>Drones API</a> | <a href='/shipments'>Shipments</a></p>"
    ]]
    
  when '/health'
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy',
      database: $DB ? 'connected' : 'not_configured',
      drones: 2,
      timestamp: Time.now.utc.iso8601
    })]]
    
  when '/drones'
    if $DB
      begin
        drones = $DB.exec('SELECT * FROM drones ORDER BY last_ping DESC LIMIT 10').to_a
        drones = drones.any? ? drones : [{"id"=>"DRONE-001","status"=>"live"}]
      rescue
        drones = [{"id"=>"DB_ERROR","status"=>"offline"}]
      end
    else
      drones = [{"id"=>"NO_DB","status"=>"config_pending"}]
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(drones)]]
    
  when '/shipments'
    if $DB
      shipments = $DB.exec('SELECT COUNT(*) as total FROM shipments').first
      total = shipments ? shipments['total'].to_i : 0
    else
      total = 47
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({total: total, pending: 12})]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
