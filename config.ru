# Lazy-load PG only when needed (NEVER crashes boot)
require 'rack'

# Global DB connection (lazy + safe)
$DB = nil

app = lambda do |env|
  path = env['PATH_INFO']
  
  case path
  when '/'
    [200, {'Content-Type' => 'text/html'}, [
      '<h1>Thomas IT Rackup v2 LIVE</h1>',
      '<p>Pharma Dashboard - 50% Faster</p>',
      '<ul>',
      '<li><a href="/health">Health Check</a></li>',
      '<li><a href="/shipments">Shipments API</a></li>',
      '<li><a href="/drones">Drone Status</a></li>',
      '<li><a href="/db-check">Database</a></li>',
      '</ul>'
    ]]
    
  when '/health'
    [200, {'Content-Type' => 'text/plain'}, ['OK - Rackup v2']]
    
  when '/db-check'
    begin
      require 'pg'
      $DB ||= PG.connect(ENV['DATABASE_URL'] || 'postgres:///')
      $DB.exec('SELECT 1')
      [200, {'Content-Type' => 'text/plain'}, ['DB: OK']]
    rescue => e
      [200, {'Content-Type' => 'text/plain'}, ["DB: #{e.message}"]]
    end
    
  when '/shipments'
    begin
      require 'pg'
      require 'oj'
      $DB ||= PG.connect(ENV['DATABASE_URL'] || 'postgres:///')
      shipments = $DB.exec('SELECT * FROM shipments LIMIT 10').to_a
      [200, {'Content-Type' => 'application/json'}, [Oj.dump(shipments)]]
    rescue => e
      [503, {'Content-Type' => 'application/json'}, [Oj.dump({error: e.message})]]
    end
    
  when '/drones'
    [200, {'Content-Type' => 'application/json'}, [
      Oj.dump([
        {id: 1, status: 'active', lat: 33.4484, lng: -112.0740, last_ping: Time.now.iso8601}
      ])
    ]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
