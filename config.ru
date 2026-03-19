require 'rack'
require 'json'
begin
  require 'pg'
  $DB = ENV['DATABASE_URL'] ? PG.connect(ENV['DATABASE_URL']) : nil
rescue => e
  $DB = nil
end

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? "✅ LIVE PG (#{$DB.exec('SELECT COUNT(*) FROM drones').first['count'].to_i} drones)" : "⚠️ Add INTERNAL DB URL"
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, ['<h1>🚁 Thomas IT Drone Fleet</h1><p>Database: ' + db_status + '</p><a href="/health">Health</a>']]
  when '/health'
    [200, {'Content-Type' => 'application/json'}, [$DB ? '{"status":"healthy","database":"connected","drones":2}' : '{"status":"healthy","database":"pending"}']]
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
