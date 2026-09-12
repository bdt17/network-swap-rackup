require_relative 'models'

# Makes the demo fleet feel alive instead of static seed data: drains
# battery while a drone is flying, drifts its position slightly each tick,
# auto-recalls it to CHARGING at low battery, and recharges it back up to
# ACTIVE. MAINTENANCE-status drones are left alone (grounded).
#
# Runs on a single background Thread inside the same process - fine for the
# single-instance deployment this app runs today. It would need a
# coordinator (e.g. an advisory lock, or running it as a separate worker
# process) the moment this runs on more than one instance, so two instances
# don't both drive the same drones. See NEXT_STEPS.md.
module FleetSimulator
  TICK_SECONDS = Integer(ENV['SIMULATOR_TICK_SECONDS'] || 6)
  DRIFT = 0.01
  LOW_BATTERY = 15

  def self.start!(&broadcaster)
    return if @started

    @started = true
    @thread = Thread.new do
      loop do
        sleep TICK_SECONDS
        tick!(&broadcaster)
      end
    end
  end

  def self.tick!
    changed = false
    Drone.each do |drone|
      changes = next_state_for(drone)
      next if changes.empty?

      drone.update(changes)
      changed = true
    end
    yield if changed && block_given?
  rescue StandardError => e
    warn "FleetSimulator tick failed: #{e.class}: #{e.message}"
  end

  def self.next_state_for(drone)
    return {} if drone.status == 'MAINTENANCE'

    if drone.status == 'CHARGING'
      battery = [drone.battery.to_i + rand(4..8), 100].min
      return { battery: battery, status: battery >= 100 ? 'ACTIVE' : 'CHARGING' }
    end

    battery = (drone.battery.to_i - rand(1..3)).clamp(0, 100)
    return { battery: battery, status: 'CHARGING' } if battery <= LOW_BATTERY

    {
      battery: battery,
      lat: (drone.lat.to_f + ((rand - 0.5) * DRIFT)).round(4),
      lon: (drone.lon.to_f + ((rand - 0.5) * DRIFT)).round(4)
    }
  end
end
