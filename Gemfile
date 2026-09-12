source 'https://rubygems.org'

ruby '3.2.3'

gem 'rack', '~> 3.2'
gem 'rackup', '~> 2.3'
gem 'puma', '~> 6.4'   # faye-websocket needs real rack.hijack support; WEBrick's is broken under Rack 3
gem 'sinatra', '~> 4.1', require: 'sinatra/base'
gem 'sequel', '~> 5.87'
gem 'faye-websocket'   # WS for live fleet updates
gem 'json'

group :production do
  gem 'pg', '~> 1.5'
end

group :development, :test do
  gem 'sqlite3', '~> 2.1'
end

group :test do
  gem 'minitest', '~> 5.25'
  gem 'rack-test', '~> 2.1'
end
