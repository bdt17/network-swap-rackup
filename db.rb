require 'sequel'
require 'fileutils'

RACK_ENV = ENV.fetch('RACK_ENV', 'development')

db_dir = File.expand_path('db', __dir__)
FileUtils.mkdir_p(db_dir)

# DATABASE_URL is set by Render when the drone_db Postgres database (see
# .render.yaml) is attached. Locally/in tests, fall back to a file-backed
# sqlite DB per environment so nothing extra needs installing to get running.
DB = Sequel.connect(ENV.fetch('DATABASE_URL') { "sqlite://#{db_dir}/#{RACK_ENV}.sqlite3" })
