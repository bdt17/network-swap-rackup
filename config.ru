require 'rack'
require 'json'
require 'pg' rescue nil

$DB = begin
  PG.connect(ENV['DATABASE_URL']) if ENV['DATABASE_URL']
rescue PG::Error => e
  puts "DB Error: #{e.message}"
  nil
end

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? '✅ LIVE PostgreSQL' : '⚠️ No DB URL'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [
      '<h1>🚁 Thomas IT Drone Fleet</h1>',
      "<p><strong>Database:</strong> #{db_status}</p>",
      '<p>PHX Pharma Cold Chain · 21 CFR Part 11</p>',
      '<ul>',
      '<li><a href="/health">Health Check</a></li>',
      '<li><a href="/drones">Drones API</a></li>',
      '<li><a href="/shipments">Shipments</a></li>',
      '<li><a href="/tables">DB Tables</a></li>',
      '</ul>'
    ]]
    
  when '/health'
    tables = $DB ? $DB.exec('SELECT COUNT(*) as count FROM pg_tables WHERE schemaname=$1', ['public']).first['count'].to_i : 0
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy',
      database: $DB ? 'connected' : 'disconnected',
      tables: tables,
      drones_table: $DB ? $DB.table_exists?('drones') : false
    })]]
    
  when '/drones'
    if $DB && $DB.exec('SELECT 1 FROM drones LIMIT 1').ntuples > 0
      drones = $DB.exec('SELECT * FROM drones ORDER BY last_ping DESC').values
    else
      drones = [['DRONE-001', 'live'], ['DRONE-002', 'offline']]
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(drones)]]
    
  when '/shipments'
    count = $DB ? $DB.exec('SELECT COUNT(*) as total FROM shipments').first['total'].to_i : 0
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({total: count, pending: 12})]]
    
  when '/tables'
    if $DB
      tables = $DB.exec('SELECT tablename FROM pg_tables WHERE schemaname=$1', ['public']).values
    else
      tables = [['No DB']]
    end
    [200, {'Content-Type' => 'application/json'}, [JSON.generate(tables)]]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
