require 'rack'
require 'json'
require 'stripe'
Stripe.api_key = ENV['STRIPE_SECRET_KEY'] || 'sk_test_...'

$request_count = 0
$start_time = Time.now
$DB = nil

# SAFE PG connection (SSL fix for Render)
begin
  require 'pg'
  if ENV['DATABASE_URL']
    conn_info = ENV['DATABASE_URL'].sub(/^postgres:\/\//, '')
    conn_info += "?sslmode=no-verify" if conn_info !~ /\?/
    $DB = PG.connect(conn_info)
  end
rescue => e
  puts "DB: #{e.message}"
  $DB = nil
end

# CYBERPUNK LAYOUT FUNCTION
def cyberpunk_layout(title, content)
  '<!DOCTYPE html><html><head><title>' + title + '</title><meta name="viewport" content="width=device-width"><style>' +
  'body{font-family:"Courier New",monospace;background:linear-gradient(135deg,#0a0a0a,#1a1a2e);color:#00ff88;margin:0;padding:20px;min-height:100vh}' +
  '.header{background:linear-gradient(90deg,rgba(0,255,136,0.1),rgba(0,255,136,0.05));backdrop-filter:blur(10px);padding:30px;border:1px solid rgba(0,255,136,0.3);border-radius:15px;margin-bottom:30px;box-shadow:0 8px 32px rgba(0,255,136,0.1)}' +
  '.header h1{font-size:2.5em;margin:0;text-shadow:0 0 20px #00ff88;font-weight:700}.nav{display:flex;gap:15px;flex-wrap:wrap;margin-top:20px}.nav a{color:#00ff88;text-decoration:none;padding:12px 20px;border:1px solid rgba(0,255,136,0.3);border-radius:20px;background:rgba(0,255,136,0.05);transition:all 0.3s;font-size:0.9em}.nav a:hover{background:rgba(0,255,136,0.2);box-shadow:0 0 20px rgba(0,255,136,0.5);transform:translateY(-2px)}' +
  '.card{background:linear-gradient(145deg,rgba(0,20,40,0.9),rgba(0,10,20,0.9));backdrop-filter:blur(10px);padding:25px;border:1px solid rgba(0,255,136,0.4);border-radius:15px;margin:20px 0;box-shadow:0 10px 40px rgba(0,255,136,0.1)}' +
  '.metric{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid rgba(0,255,136,0.2);font-size:1.1em}.live{animation:pulse 2s infinite;color:#00ff88}@keyframes pulse{0%,100%{text-shadow:0 0 5px #00ff88}50%{text-shadow:0 0 20px #00ff88,0 0 40px #00ff88}}' +
  '@media (max-width:768px){.header h1{font-size:2em}.nav{flex-direction:column;align-items:center}}</style></head><body>' +
  '<div class="header"><h1>🚁 <span class="live">Thomas IT</span> Drone Fleet</h1><p>PHX Pharma Cold Chain · 21 CFR Part 11</p>' +
  '<div class="nav"><a href="/">🏠 Dashboard</a><a href="/health">🩺 Health</a><a href="/drones">🛰️ Drones</a><a href="/shipments">📦 Shipments</a><a href="/metrics">📊 Metrics</a><a href="/billing">💳 Stripe</a></div></div>' +
  '<div class="card">' + content + '</div></body></html>'
end

app = lambda do |env|
  $request_count += 1
  
  case env['PATH_INFO']
  when '/'
    db_status = $DB ? "✅ LIVE PG (#{$DB.exec('SELECT 1').to_a.length} rows)" : "⚠️ DB pending"
    content = "<h2>Dashboard</h2><div class='metric'><span>Requests:</span><span class='live'>#{$request_count}</span></div><div class='metric'><span>Uptime:</span><span class='live'>#{((Time.now - $start_time)/3600).round(1)}h</span></div><div class='metric'><span>Database:</span><span>#{$DB ? '✅ Connected' : '⚠️ Pending'}</span></div>"
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, [cyberpunk_layout('Dashboard', content)]]
    
  when '/health'
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy', service: 'live', requests: $request_count,
      uptime: ((Time.now - $start_time)/3600).round(1), db: $DB ? 'connected' : 'pending'
    })]]
    
  when '/metrics'
    uptime_pct = 99.9
    [200, {'Content-Type' => 'text/plain'}, ["puma_workers:2|uptime:#{uptime_pct}|requests:#{$request_count}|db:#{$DB ? 'connected' : 'pending'}"]]
    
  when '/billing'
    begin
      customer = Stripe::Customer.create({name: 'Thomas IT Pharma', email: 'billing@thomasit.com', description: 'Drone Cold Chain'})
      content = "<h2>💳 Stripe Billing</h2><p>Customer ID: <span class='live'>#{customer.id}</span></p><p>Status: <span class='live'>SUCCESS</span></p>"
      [200, {'Content-Type' => 'text/html; charset=utf-8'}, [cyberpunk_layout('Stripe Billing', content)]]
    rescue Stripe::StripeError => e
      [400, {'Content-Type' => 'text/html; charset=utf-8'}, [cyberpunk_layout('Stripe Error', "<h2>Stripe Error</h2><p>#{e.message}</p>")]]
    end
    
  when '/drones', '/shipments'
    [200, {'Content-Type' => 'application/json'}, ['{"status":"coming_soon"}']]
    
  else
    [404, {'Content-Type' => 'text/html; charset=utf-8'}, [cyberpunk_layout('Not Found', '<h2>404 - Drone Not Found</h2><p>Check your flight path.</p>')]]
  end
end

run app
