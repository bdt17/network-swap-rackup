require_relative 'test_helper'

class AppTest < Minitest::Test
  include DroneTestHelpers

  def test_health_reports_ok_and_fleet_size
    get '/health'

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert body['ok']
    assert body['db']
    assert_equal 2, body['fleet_size']
  end

  def test_index_renders_seeded_drones
    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'drone-001'
    assert_includes last_response.body, 'drone-002'
  end

  def test_firmware_flash_bumps_version_and_logs_event
    drone = Drone.first(slug: 'drone-001')
    assert_equal 'v2.1.0', drone.firmware_version

    post '/api/firmware', drone_id: 'drone-001'

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'flashed', body['status']
    assert_equal 'v2.2.0', body['version']

    drone.refresh
    assert_equal 'v2.2.0', drone.firmware_version

    event = FirmwareEvent.first(drone_id: drone.id)
    refute_nil event
    assert_equal 'v2.1.0', event.from_version
    assert_equal 'v2.2.0', event.to_version
  end

  def test_firmware_flash_rejects_unknown_drone
    post '/api/firmware', drone_id: 'does-not-exist'

    assert_equal 404, last_response.status
    assert_equal 'Unknown drone', JSON.parse(last_response.body)['error']
  end

  def test_firmware_flash_requires_drone_id
    post '/api/firmware', {}

    assert_equal 400, last_response.status
    assert_equal 'Missing drone_id', JSON.parse(last_response.body)['error']
  end

  def test_unknown_route_returns_404
    get '/nope'

    assert_equal 404, last_response.status
  end
end
