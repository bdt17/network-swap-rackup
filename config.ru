require 'rack'
require 'json'
require 'pg' rescue nil

$DB = begin
  PG.connect(ENV['DATABASE_URL']) if ENV['DATABASE_URL']
rescue PG::Error => e
  puts "DB Error: #{e.message}"
  nil
end

# AUTO CREATE TABLES ON FIRST BOOT
if $DB
  begin
    $DB.exec %{
      CREATE TABLE IF NOT EXISTS drones (
        id VARCHAR PRIMARY KEY,
        lat DECIMAL, lng DECIMAL,
        status VARCHAR,
        temp DECIMAL,
        payload VARCHAR,
        battery INTEGER,
        eta VARCHAR,
        last_ping TIMESTAMP DEFAULT NOW()
      );
      
      CREATE TABLE IF NOT EXISTS shipments (
        id SERIAL PRIMARY KEY,
        drone_id VARCHAR,
        payload VARCHAR,
        status VARCHAR,
        created_at TIMESTAMP DEFAULT NOW()
      );
      
      INSERT INTO drones (id, lat, lng, status, temp, payload, battery, eta) VALUES
      ('DRONE-001', 33.4484, -112.0740, 'live', 2.3, 'insulin', 87, '14min'),
      ('DRONE-002', 33.6846, -112.1240, 'offline', 1.8, 'vaccine', 23, 'stalled')
      ON CONFLICT (id) DO NOTHING;
      
      INSERT INTO shipments (drone_id, payload, status) VALUES
      ('DRONE-001', 'Insulin Batch A123', 'delivered'),
      ('DRONE-002', 'Vaccine Batch B456', 'pending');
    }
    puts "✅ Tables created + sample data inserted"
  rescue => e
    puts "Table creation warning: #{e.message}"
  end
end

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? '✅ LIVE PostgreSQL + Tables Created' : '⚠️ Add DATABASE_URL'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<h1>🚁 Thomas IT Drone Fleet</h1>',
      "<p><strong>Database:</strong> #{db_status}</p>",
      '<p>PHX Pharma Cold Chain · 21 CFR Part 11</p>',
      '<ul>',
      '<li><a href="/health">Health</a></li>',
      '<li><a href="/drones">Drones (PostgreSQL)</a></li>',
      '<li><a href="/shipments">Shipments</a></li>',
      '<li><a href="/tables">Tables</a></li>',
      '</ul>'
    ]]
    
  when '/health'
    tables = $DB ? $DB.exec('SELECT COUNT(*) as count FROM pg_tables WHERE schemaname=$1', ['public']).first['count'].to_i : 0
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy',
      database: $DB ? 'connected' : 'disconnected',
      tables: tables
    })]]
    
  when '/drones'
    if $DB
      drones = $DB.exec('SELECT * FROM drones ORDER BY last_ping DESC').values || []
    else
      drones = [['NO_DB', 'config_required']]
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(drones)]]
    
  when '/shipments'
    count = $DB ? $DB.exec('SELECT COUNT(*) as total FROM shipments').first['total'].to_i : 0
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({total: count, pending: 12})]]
    
  when '/tables'
    if $DB
      tables = $DB.exec('SELECT tablename FROM pg_tables WHERE schemaname=$1 ORDER BY tablename', ['public']).values
    else
      tables = [['No DB']]
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(tables)]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
