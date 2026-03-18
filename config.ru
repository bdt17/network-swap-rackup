require 'bundler/setup'

# Middleware stack
use Rack::Deflater
use Rack::Static, :urls => ['/css', '/js', '/images'], :root => 'public'
use Rack::Session::Cookie, :secret => ENV['SESSION_SECRET'] || 'devkey'
use Rack::Cors do
  allow do
    origins '*'
    resource '*', :headers => :any, :methods => [:get, :post, :put, :patch, :delete, :options]
  end
end

# Load Rails as Rack app (simplest migration)
require File.expand_path('config.ru.rails', __dir__) if File.exist?('config.ru.rails')
require './app_rack'  # Main Rack app

run NetworkSwapRack
