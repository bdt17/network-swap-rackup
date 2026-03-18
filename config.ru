require 'rack'

app = lambda do |env|
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/html'}, [
      '<h1>Rackup v2 LIVE</h1>',
      '<p>Thomas IT Web Service</p>',
      '<ul>',
      '<li><a href="/health">Health Check</a></li>',
      '<li><a href="/status">Status</a></li>',
      '<li><a href="/version">Version</a></li>',
      '</ul>'
    ]]
    
  when '/health'
    [200, {'Content-Type' => 'application/json'}, ['{"status":"healthy"}']]
    
  when '/status'
    [200, {'Content-Type' => 'text/plain'}, ['OK']]
    
  when '/version'
    [200, {'Content-Type' => 'text/plain'}, ['Rackup v2.0']]
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

run app
