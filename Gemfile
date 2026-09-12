source 'https://rubygems.org'

ruby '3.2.3'

gem 'rack', '~> 3.2'
gem 'rackup', '~> 2.3'
gem 'puma', '~> 6.4'   # faye-websocket needs real rack.hijack support; WEBrick's is broken under Rack 3
gem 'sinatra', '~> 4.1', require: 'sinatra/base'
gem 'sequel', '~> 5.87'
gem 'faye-websocket'   # WS for live fleet updates
gem 'json'
gem 'bcrypt', '~> 3.1'      # password hashing
gem 'rotp', '~> 6.3'        # TOTP for two-factor auth
gem 'rqrcode', '~> 2.2'     # QR codes for 2FA enrollment
gem 'rack-session', '~> 2.1' # short-lived pending-2FA state (real login state is the sessions table, not this)

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
