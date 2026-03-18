require 'rack'

app = lambda do |env|
  case env['PATH_INFO']
  when '/' 
    [200, {'Content-Type' => 'text/html'}, 
     ['<h1>🛡️ Thomas IT Rackup v2 LIVE!</h1>',
      '<p>Pharma Network Swap - 50% Faster Cold Starts</p>',
      '<p><a href="/health">Health Check ✓</a></p>']]
  when '/health'
    [200, {'Content-Type' => 'text/plain'}, ['OK']]
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
