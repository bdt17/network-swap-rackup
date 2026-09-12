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

  def test_unauthenticated_request_is_redirected_to_login
    # A fresh Rack::Test session with no cookies at all - before_setup's
    # login doesn't apply here.
    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.get '/'

    assert_equal 302, logged_out.last_response.status
    assert_includes logged_out.last_response.location, '/login'
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

  def test_create_drone
    post '/api/drones', slug: 'drone-003', lat: '10.0', lon: '20.0', battery: '80'

    assert_equal 201, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'created', body['status']

    drone = Drone.first(slug: 'drone-003')
    refute_nil drone
    assert_in_delta 10.0, drone.lat, 0.001
    assert_equal 80, drone.battery
    assert_equal 3, Drone.count
  end

  def test_create_drone_rejects_duplicate_slug
    post '/api/drones', slug: 'drone-001'

    assert_equal 409, last_response.status
  end

  def test_create_drone_requires_slug
    post '/api/drones', {}

    assert_equal 400, last_response.status
  end

  def test_delete_drone_removes_it_and_its_history
    drone = Drone.first(slug: 'drone-001')
    FirmwareEvent.create(drone_id: drone.id, from_version: 'v1', to_version: 'v2', flashed_at: Time.now)

    delete '/api/drones/drone-001'

    assert_equal 200, last_response.status
    assert_nil Drone.first(slug: 'drone-001')
    assert_equal 0, FirmwareEvent.where(drone_id: drone.id).count
  end

  def test_delete_drone_rejects_unknown_slug
    delete '/api/drones/does-not-exist'

    assert_equal 404, last_response.status
  end

  def test_history_page_renders_for_known_drone
    drone = Drone.first(slug: 'drone-001')
    FirmwareEvent.create(drone_id: drone.id, from_version: 'v2.1.0', to_version: 'v2.2.0', flashed_at: Time.now)

    get '/drones/drone-001'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'v2.1.0'
    assert_includes last_response.body, 'v2.2.0'
  end

  def test_history_page_renders_stream_readings
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'camera', 'DEGRADED')

    get '/drones/drone-001'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Camera'
    assert_includes last_response.body, 'DEGRADED'
  end

  def test_index_renders_stream_chips_for_seeded_drones
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'altitude', '120m')

    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '120m'
  end

  def test_history_page_404s_for_unknown_drone
    get '/drones/does-not-exist'

    assert_equal 404, last_response.status
  end

  def test_ws_command_recall_sets_status_to_charging
    drone = Drone.first(slug: 'drone-001')
    result = App.new!.handle_command({ cmd: 'recall', drone_id: 'drone-001' }.to_json)

    assert result[:applied]
    drone.refresh
    assert_equal 'CHARGING', drone.status
  end

  def test_ws_command_set_status_validates_status
    result = App.new!.handle_command({ cmd: 'set_status', drone_id: 'drone-001', status: 'NOT_A_STATUS' }.to_json)

    refute result[:applied]
    assert_match(/must be one of/, result[:error])
  end

  def test_ws_command_unknown_drone
    result = App.new!.handle_command({ cmd: 'recall', drone_id: 'does-not-exist' }.to_json)

    refute result[:applied]
    assert_equal 'unknown drone_id', result[:error]
  end

  def test_ws_command_invalid_json_is_handled
    result = App.new!.handle_command('not json')

    refute result[:applied]
    assert_equal 'invalid JSON', result[:error]
  end

  def test_api_token_bypasses_login
    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    ENV['DRONE_API_TOKEN'] = 'sekrit'
    begin
      logged_out.post '/api/firmware', drone_id: 'drone-001', token: 'sekrit'
      assert_equal 200, logged_out.last_response.status

      logged_out.post '/api/firmware', drone_id: 'drone-001', token: 'wrong'
      assert_equal 302, logged_out.last_response.status
    ensure
      ENV.delete('DRONE_API_TOKEN')
    end
  end
end
