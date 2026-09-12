require_relative 'db'

class Drone < Sequel::Model
  plugin :timestamps, update_on_create: true
  one_to_many :firmware_events, order: :flashed_at
  one_to_many :command_events

  STATUSES = %w[ACTIVE PATROL_AZ1 PATROL_AZ2 CHARGING OFFLINE MAINTENANCE].freeze

  def validate
    super
    errors.add(:slug, 'cannot be empty') if slug.nil? || slug.strip.empty?
    errors.add(:status, "must be one of #{STATUSES.join(', ')}") if status && !STATUSES.include?(status)
    errors.add(:battery, 'must be between 0 and 100') if battery && !(0..100).cover?(battery)
  end

  # Shape expected by the frontend's WebSocket handler: { lat:, lon:, battery:, status:, firmware: { version: } }
  def to_fleet_json
    {
      lat: lat,
      lon: lon,
      battery: battery,
      status: status,
      firmware: { version: firmware_version }
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
