require_relative '../models'

# Seeds the two demo drones the app originally shipped with (in-memory, before
# this app had real persistence). Safe to call repeatedly: no-ops once any
# drones exist. Used both on app boot and by tests (via Seeds.reset!).
module Seeds
  DEFAULT_FLEET = [
    { slug: 'drone-001', name: 'Drone 001', lat: 33.5138, lon: -112.1314, battery: 76,
      status: 'ACTIVE', firmware_version: 'v2.1.0' },
    { slug: 'drone-002', name: 'Drone 002', lat: 33.4484, lon: -112.0740, battery: 92,
      status: 'PATROL_AZ1', firmware_version: 'v2.1.0' }
  ].freeze

  def self.ensure_default_fleet!
    return unless Drone.count.zero?

    DEFAULT_FLEET.each { |attrs| Drone.create(attrs) }
  end

  # Test-only: wipes and reseeds so each test run starts from a known state.
  def self.reset!
    CommandEvent.dataset.delete
    FirmwareEvent.dataset.delete
    Drone.dataset.delete
    DEFAULT_FLEET.each { |attrs| Drone.create(attrs) }
  end
end
