require_relative 'models'

# Makes the demo fleet feel alive instead of static seed data: drains
# battery while a drone is flying, drifts its position slightly each tick,
# auto-recalls it to CHARGING at low battery, and recharges it back up to
# ACTIVE. MAINTENANCE-status drones are left alone (grounded).
#
# Ticks opportunistically off real incoming requests (`App`'s global
# `before` filter calls `tick_if_due!` on every request) rather than a
# free-standing background Thread. A Thread-based version was tried first
# and worked perfectly in local testing (verified with a real WebSocket
# client receiving a broadcast every tick), but in production the thread
# reliably died within its first few seconds of life on every boot, with
# `thread_alive?` false, zero ticks completed, and no exception caught even
# under `rescue Exception` - meaning something outside Ruby killed it in a
# way the language can't observe, while the rest of the process (including
# broadcasts triggered from real requests) kept working correctly the whole
# time. Piggybacking on request traffic sidesteps that entirely: Render's
# own health-check polling alone is frequent enough to keep this ticking
# even with no dashboard open. See NEXT_STEPS.md.
#
# Single-process only: `@next_tick_at` is in-memory, so two instances would
# each tick independently and drive the same drones. Fine for the current
# single-instance deployment; would need a coordinator (e.g. a DB-backed
# lock) the moment this runs on more than one instance.
module FleetSimulator
  TICK_SECONDS = Integer(ENV['SIMULATOR_TICK_SECONDS'] || 6)
  DRIFT = 0.01
  LOW_BATTERY = 15

  # Named telemetry channels distinct from the drone's core state
  # (lat/lon/battery/status, which live on the drones table directly). Each
  # is labeled and displayed separately on the dashboard and history page.
  STREAM_LABELS = {
    'camera' => '📷 Camera',
    'link_signal' => '📶 Link',
    'temperature' => '🌡️ Temp',
    'altitude' => '📏 Altitude'
  }.freeze

  @mutex = Mutex.new
  @tick_count = 0
  @last_tick_at = nil
  @last_error = nil
  @next_tick_at = nil

  def self.status
    {
      tick_count: @tick_count,
      last_tick_at: @last_tick_at&.iso8601,
      next_tick_at: @next_tick_at&.iso8601,
      last_error: @last_error
    }
  end

  # Called from App's `before` filter on every request. Non-blocking: if
  # another request is already mid-tick, this just returns rather than
  # queuing behind it, so a tick can never add latency to unrelated requests.
  def self.tick_if_due!(&broadcaster)
    return unless @mutex.try_lock

    begin
      now = Time.now
      return if @next_tick_at && now < @next_tick_at

      @next_tick_at = now + TICK_SECONDS
      tick!(&broadcaster)
    ensure
      @mutex.unlock
    end
  end

  def self.tick!
    changed = false
    Drone.each do |drone|
      changes = next_state_for(drone)
      unless changes.empty?
        drone.update(changes)
        changed = true
      end

      stream_updates_for(drone).each do |name, value|
        StreamReading.record!(drone, name, value)
        changed = true
      end
    end
    @tick_count += 1
    @last_tick_at = Time.now
    yield if changed && block_given?
  rescue StandardError => e
    @last_error = "#{e.class}: #{e.message}"
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

  def self.stream_updates_for(drone)
    grounded = %w[CHARGING OFFLINE MAINTENANCE].include?(drone.status)

    {
      'camera' => camera_reading(drone),
      'link_signal' => "#{grounded ? rand(-55..-45) : rand(-90..-60)}dBm",
      'temperature' => "#{grounded ? rand(18..24) : rand(28..42)}°C",
      'altitude' => grounded ? '0m' : "#{rand(80..150)}m"
    }
  end

  def self.camera_reading(drone)
    return 'OFFLINE' if drone.status == 'MAINTENANCE'

    rand(100) < 5 ? 'DEGRADED' : 'OK'
  end
end
