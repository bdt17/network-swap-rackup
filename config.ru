require 'rack'
require 'json'
require 'oj'                # Fast JSON
require 'pg'                # PostgreSQL connection

# Database connection (Render PostgreSQL)
DB = PG.connect(
  host: ENV['DATABASE_URL']&.split('@')&.last&.split('/')&.first || 'localhost',
  port: 5432,
  dbname: ENV['DATABASE_URL']&.split('/')&.last&.split('?')&.first || 'thomasit',
  user: ENV['DATABASE_URL']&.split(':')&.last&.split('@')&.first || 'postgres',
  password: ENV['DATABASE_URL']&.split(':p')&.last || 'password'
) rescue PG.connect(dbname: 'postgres')

app = lambda do |env|
  path = env['PATH_INFO']
  
  case path
  when '/'
    [200, {'Content-Type' => 'text/html'}, [
      '<h1>🛡️ Thomas IT Pharma Dashboard v2</h1>',
      '<p><a href="/shipments">Shipments</a> | ',
      '<a href="/drones">Drones</a> | ',
      '<a href="/compliance">21 CFR Part 11</a> | ',
      '<a href="/health">Health</a></p>'
    ]]
    
  when '/health'
    [200, {'Content-Type' => 'text/plain'}, ['OK - Rackup v2']]
    
  when '/shipments'
    shipments = DB.exec("SELECT * FROM shipments ORDER BY created_at DESC LIMIT 20").to_a
    [200, {'Content-Type' => 'application/json'}, [Oj.dump(shipments)]]
    
  when '/drones'
    drones = DB.exec("SELECT * FROM drones ORDER BY last_ping DESC LIMIT 10").to_a
    [200, {'Content-Type' => 'application/json'}, [Oj.dump(drones)]]
    
  when '/compliance'
    compliance = DB.exec("SELECT COUNT(*) as total, 
                                COUNT(CASE WHEN signed_at IS NOT NULL THEN 1 END) as signed 
                         FROM chain_of_custody").first
    [200, {'Content-Type' => 'application/json'}, [Oj.dump(compliance)]]
    
  when '/shipments/new', '/drones/new'
    [200, {'Content-Type' => 'text/html'}, ['<h2>CRUD Forms Coming...</h2>']]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
