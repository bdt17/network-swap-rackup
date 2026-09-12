ENV['RACK_ENV'] = 'test'

require 'bundler/setup'
require 'minitest/autorun'
require 'rack/test'
require 'sequel'

require_relative '../db'

Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path('../db/migrations', __dir__))

require_relative '../app'
require_relative '../db/seeds'

module DroneTestHelpers
  include Rack::Test::Methods

  def app
    App
  end

  def before_setup
    super
    Seeds.reset!
  end
end
