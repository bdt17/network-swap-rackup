require_relative 'test_helper'

class StreamSpecTest < Minitest::Test
  include DroneTestHelpers

  def test_validate_rejects_empty_stream_name
    drone = Drone.first(slug: 'drone-001')
    spec = StreamSpec.new(drone_id: drone.id, stream_name: '  ')

    refute spec.valid?
  end

  def test_valid_with_a_unit
    drone = Drone.first(slug: 'drone-001')
    spec = StreamSpec.new(drone_id: drone.id, stream_name: 'thermal_cam', unit: '°C')

    assert spec.valid?
  end

  def test_valid_without_a_unit
    drone = Drone.first(slug: 'drone-001')
    spec = StreamSpec.new(drone_id: drone.id, stream_name: 'thermal_cam')

    assert spec.valid?
  end

  def test_cascade_deletes_with_its_drone
    drone = Drone.create(slug: 'temp-drone', lat: 1.0, lon: 2.0, battery: 50, status: 'ACTIVE',
                          firmware_version: 'v1')
    spec = StreamSpec.create(drone_id: drone.id, stream_name: 'x', created_at: Time.now)

    drone.destroy

    assert_nil StreamSpec[spec.id]
  end
end
