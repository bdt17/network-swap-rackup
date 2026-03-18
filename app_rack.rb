require 'rack'
require 'json'

class NetworkSwapRack
  def self.call(env)
    req = Rack::Request.new(env)
    
    # Proxy to Rails for ALL routes (zero code rewrite)
    if File.exist?('config/environment.rb')
      require './config/environment'
      Rails.application.call(env)
    else
      # Fallback routes
      case req.path
      when '/' then index_page
      when '/health' then [200, {'Content-Type' => 'text/plain'}, ['OK']]
      else [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
      end
    end
  end

  def self.index_page
    [200, {'Content-Type' => 'text/html'}, [File.read('public/index.html', encoding: 'utf-8')]]
  end
end
