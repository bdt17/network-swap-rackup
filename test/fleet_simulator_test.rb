require_relative 'test_helper'
require_relative '../fleet_simulator'

class FleetSimulatorTest < Minitest::Test
  include DroneTestHelpers

  # Forces the shared cluster_state row into "due now" - the multi-instance
  # replacement for what used to be
  # `FleetSimulator.instance_variable_set(:@next_tick_at, nil)`.
  def force_tick_due!
    ClusterState.set!('simulator_next_tick_at', (Time.now - 1).utc.iso8601)
  end

  def test_next_state_for_charging_drone_recharges
    drone = Drone.new(status: 'CHARGING', battery: 90, lat: 1.0, lon: 2.0)
    changes = FleetSimulator.next_state_for(drone)

    assert changes[:battery] > 90
    assert_includes %w[ACTIVE CHARGING], changes[:status]
  end

  def test_next_state_for_active_drone_drains_and_drifts
    drone = Drone.new(status: 'ACTIVE', battery: 80, lat: 10.0, lon: 20.0)
    changes = FleetSimulator.next_state_for(drone)

    assert changes[:battery] < 80
    # Checking both lat and lon (rather than just lat) avoids a rare flake:
    # each axis's random drift independently has a small chance of rounding
    # to exactly 0.0000, but not both at once.
    refute(changes[:lat] == 10.0 && changes[:lon] == 20.0)
  end

  def test_next_state_for_low_battery_forces_charging
    drone = Drone.new(status: 'ACTIVE', battery: 2, lat: 1.0, lon: 2.0)
    changes = FleetSimulator.next_state_for(drone)

    assert_equal 'CHARGING', changes[:status]
  end

  def test_next_state_for_maintenance_drone_is_untouched
    drone = Drone.new(status: 'MAINTENANCE', battery: 50, lat: 1.0, lon: 2.0)

    assert_empty FleetSimulator.next_state_for(drone)
  end

  def test_stream_updates_for_includes_every_named_stream
    drone = Drone.new(status: 'ACTIVE', battery: 80, lat: 1.0, lon: 2.0)
    updates = FleetSimulator.stream_updates_for(drone)

    assert_equal FleetSimulator::STREAM_LABELS.keys.sort, updates.keys.sort
  end

  def test_stream_updates_for_grounds_altitude_when_charging
    drone = Drone.new(status: 'CHARGING', battery: 50, lat: 1.0, lon: 2.0)

    assert_equal '0m', FleetSimulator.stream_updates_for(drone)['altitude']
  end

  def test_camera_reading_is_offline_for_maintenance_drone
    drone = Drone.new(status: 'MAINTENANCE', battery: 50, lat: 1.0, lon: 2.0)

    assert_equal 'OFFLINE', FleetSimulator.camera_reading(drone)
  end

  def test_tick_records_stream_readings_and_prunes_old_ones
    drone = Drone.first(slug: 'drone-001')

    (StreamReading::MAX_PER_STREAM + 5).times do
      force_tick_due!
      FleetSimulator.tick_if_due! {}
    end

    count = StreamReading.where(drone_id: drone.id, stream_name: 'camera').count
    assert_equal StreamReading::MAX_PER_STREAM, count

    latest = drone.latest_streams
    assert_includes FleetSimulator::STREAM_LABELS.keys, latest.keys.first
  end

  def test_tick_skips_a_stream_with_a_recent_live_reading
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'camera', 'LIVE-VALUE', source: 'live')
    force_tick_due!

    FleetSimulator.tick_if_due! {}

    latest = drone.latest_streams
    assert_equal 'LIVE-VALUE', latest['camera'][:value]
    assert_equal 'live', latest['camera'][:source]
    # The other simulated streams still tick normally - only the live one is preempted.
    refute_nil latest['link_signal']
    assert_equal 'simulated', latest['link_signal'][:source]
  end

  def test_tick_resumes_simulating_once_the_live_reading_goes_stale
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'camera', 'STALE-VALUE', source: 'live')
    StreamReading.where(drone_id: drone.id, stream_name: 'camera')
                 .update(recorded_at: Time.now - FleetSimulator::LIVE_PREEMPT_SECONDS - 1)
    force_tick_due!

    FleetSimulator.tick_if_due! {}

    latest = drone.latest_streams
    assert_equal 'simulated', latest['camera'][:source]
  end

  def test_tick_if_due_mutates_state_and_broadcasts_once_then_waits
    broadcasts = 0
    force_tick_due!

    before_battery = Drone.first(slug: 'drone-001').battery
    FleetSimulator.tick_if_due! { broadcasts += 1 }
    after_battery = Drone.first(slug: 'drone-001').battery

    refute_equal before_battery, after_battery
    assert_equal 1, broadcasts

    # Calling again immediately should be a no-op - not due yet.
    FleetSimulator.tick_if_due! { broadcasts += 1 }
    assert_equal 1, broadcasts
  end
end
