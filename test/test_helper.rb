ENV['RACK_ENV'] = 'test'

require 'bundler/setup'
require 'minitest/autorun'
require 'rack/test'
require 'sequel'

require_relative '../db'

Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path('../db/migrations', __dir__))

require_relative '../app'
require_relative '../auth'
require_relative '../fleet_simulator'
require_relative '../db/seeds'

# bcrypt's hashing cost is deliberately expensive in production; drop it for
# tests so every example's login doesn't add ~300ms.
BCrypt::Engine.cost = 4

module DroneTestHelpers
  include Rack::Test::Methods

  TEST_EMAIL = 'tester@example.com'
  TEST_PASSWORD = 'testpass123'

  def app
    App
  end

  # Almost every route requires a logged-in session as of the auth phase, so
  # tests log in once per example via the real /login flow (not a shortcut
  # that bypasses it) - that way a bug in login would show up as failures
  # everywhere else too, the same way it would in production.
  def before_setup
    super
    Seeds.reset!
    Session.dataset.delete
    BackupCode.dataset.delete
    User.dataset.delete
    User.create(email: TEST_EMAIL, password: TEST_PASSWORD)
    RateLimiter.reset! # otherwise one test suite run's worth of logins trips the real limit
    post '/login', email: TEST_EMAIL, password: TEST_PASSWORD
  end
end
