require_relative 'test_helper'
require_relative '../fleet_simulator'

class FleetSimulatorTest < Minitest::Test
  include DroneTestHelpers

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
    refute_equal 10.0, changes[:lat]
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

  def test_tick_if_due_mutates_state_and_broadcasts_once_then_waits
    broadcasts = 0
    FleetSimulator.instance_variable_set(:@next_tick_at, nil)

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
