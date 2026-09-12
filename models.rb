require 'bcrypt'
require 'digest'
require_relative 'db'

class Drone < Sequel::Model
  plugin :timestamps, update_on_create: true
  one_to_many :firmware_events, order: :flashed_at
  one_to_many :command_events
  one_to_many :stream_readings, order: Sequel.desc(:recorded_at)

  STATUSES = %w[ACTIVE PATROL_AZ1 PATROL_AZ2 CHARGING OFFLINE MAINTENANCE].freeze

  def validate
    super
    errors.add(:slug, 'cannot be empty') if slug.nil? || slug.strip.empty?
    errors.add(:status, "must be one of #{STATUSES.join(', ')}") if status && !STATUSES.include?(status)
    errors.add(:battery, 'must be between 0 and 100') if battery && !(0..100).cover?(battery)
  end

  # The latest reading per named stream (e.g. "camera" => "OK"), keyed by
  # stream name so the frontend/history page can label each one.
  def latest_streams
    StreamReading.latest_for(id)
  end

  # Shape expected by the frontend's WebSocket handler: { lat:, lon:, battery:, status:, firmware: { version: }, streams: {} }
  def to_fleet_json
    {
      lat: lat,
      lon: lon,
      battery: battery,
      status: status,
      firmware: { version: firmware_version },
      streams: latest_streams.transform_values { |r| r[:value] }
    }
  end

  def self.fleet_hash
    all.each_with_object({}) { |d, h| h[d.slug] = d.to_fleet_json }
  end
end

class FirmwareEvent < Sequel::Model
  many_to_one :drone
end

class CommandEvent < Sequel::Model
  many_to_one :drone
end

# A named, ongoing telemetry channel per drone (e.g. "camera", "link_signal") -
# distinct from the drone's core state (lat/lon/battery/status), which lives
# directly on the drones table. Self-limiting like AssistantFeedback in the
# sibling app: each write prunes older rows for that (drone, stream) pair
# down to MAX_PER_STREAM, so this never needs a cron job to stay bounded.
class StreamReading < Sequel::Model
  many_to_one :drone

  MAX_PER_STREAM = 20

  def self.record!(drone, stream_name, value)
    create(drone_id: drone.id, stream_name: stream_name.to_s, value: value.to_s, recorded_at: Time.now)
    prune!(drone.id, stream_name)
  end

  def self.prune!(drone_id, stream_name)
    keep_ids = where(drone_id: drone_id, stream_name: stream_name)
               .reverse_order(:recorded_at)
               .limit(MAX_PER_STREAM)
               .select_map(:id)
    return if keep_ids.empty?

    where(drone_id: drone_id, stream_name: stream_name).exclude(id: keep_ids).delete
  end

  # => { "camera" => { value:, recorded_at: }, "link_signal" => {...}, ... }
  def self.latest_for(drone_id)
    where(drone_id: drone_id)
      .reverse_order(:recorded_at)
      .all
      .group_by(&:stream_name)
      .transform_values { |rows| { value: rows.first.value, recorded_at: rows.first.recorded_at } }
  end
end

class User < Sequel::Model
  plugin :timestamps, update_on_create: true
  one_to_many :sessions
  one_to_many :backup_codes

  def validate
    super
    errors.add(:email, 'cannot be empty') if email.nil? || email.strip.empty?
    errors.add(:password_digest, 'cannot be empty') if password_digest.nil? || password_digest.empty?
  end

  # Assigning `password=` (rather than password_digest directly) is how
  # every caller - bin/create_user, the future admin-facing user management
  # this app doesn't have yet - sets a password, so it's never stored plain.
  def password=(plain)
    self.password_digest = BCrypt::Password.create(plain)
  end

  def authenticate(plain)
    return false if password_digest.to_s.empty?

    BCrypt::Password.new(password_digest) == plain
  rescue BCrypt::Errors::InvalidHash
    false
  end
end

class Session < Sequel::Model
  many_to_one :user
end

class BackupCode < Sequel::Model
  many_to_one :user

  def self.hash_code(code)
    Digest::SHA256.hexdigest(code.to_s.strip.downcase)
  end
end
