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

  def test_index_renders_radar_and_alerts_panels
    get '/'

    assert_includes last_response.body, 'radar-blips'
    assert_includes last_response.body, 'fleet-alerts'
  end

  def test_fleet_alerts_shows_nominal_when_healthy
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_fleet_alerts_flags_low_battery
    Drone.first(slug: 'drone-001').update(battery: 10, status: 'ACTIVE')

    get '/'

    assert_includes last_response.body, 'battery low'
  end

  def test_fleet_alerts_flags_degraded_camera
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'camera', 'DEGRADED')

    get '/'

    assert_includes last_response.body, 'camera DEGRADED'
  end

  def test_fleet_alerts_flags_stale_live_stream
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'thermal_cam', '38C', source: 'live')
    StreamReading.where(drone_id: drone.id, stream_name: 'thermal_cam')
                 .update(recorded_at: Time.now - StreamReading::LIVE_STALE_SECONDS - 1)

    get '/'

    assert_includes last_response.body, 'Thermal Cam feed stale'
  end

  def test_fleet_alerts_does_not_flag_fresh_live_stream
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    StreamReading.record!(drone, 'thermal_cam', '38C', source: 'live')

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_fleet_alerts_does_not_flag_stale_simulated_stream
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    StreamReading.record!(drone, 'temperature', '30C') # default source: 'simulated'
    StreamReading.where(drone_id: drone.id, stream_name: 'temperature')
                 .update(recorded_at: Time.now - StreamReading::LIVE_STALE_SECONDS - 1)

    get '/'

    # Not a bare "feed stale" refutation - that string also appears in the
    # always-present JS computeAlerts function definition (only whether it's
    # actually invoked into an alert row differs), same gotcha as the
    # existing FLASH-button check elsewhere in this file.
    assert_includes last_response.body, 'All systems nominal'
  end

  def test_create_alert_rule_requires_admin
    session = viewer_session
    session.post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'gt', threshold: '60'

    assert_equal 403, session.last_response.status
    assert_empty AlertRule.all
  end

  def test_create_global_alert_rule
    post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'gt', threshold: '60'

    assert_equal 201, last_response.status
    rule = AlertRule.first
    assert_nil rule.drone_id
    assert_equal 'thermal_cam', rule.stream_name
    assert_equal 60.0, rule.threshold
  end

  def test_create_drone_scoped_alert_rule
    drone = Drone.first(slug: 'drone-001')
    post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'gt', threshold: '60', drone_slug: 'drone-001'

    assert_equal 201, last_response.status
    assert_equal drone.id, AlertRule.first.drone_id
  end

  def test_create_alert_rule_rejects_unknown_drone
    post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'gt', threshold: '60', drone_slug: 'nope'

    assert_equal 404, last_response.status
  end

  def test_create_alert_rule_rejects_invalid_operator
    post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'nonsense', threshold: '60'

    assert_equal 422, last_response.status
  end

  def test_create_alert_rule_rejects_non_numeric_threshold
    post '/api/alert_rules', stream_name: 'thermal_cam', operator: 'gt', threshold: 'hot'

    assert_equal 422, last_response.status
  end

  def test_delete_alert_rule_requires_admin
    rule = AlertRule.create(stream_name: 'x', operator: 'gt', threshold: 1, created_at: Time.now)
    session = viewer_session
    session.delete "/api/alert_rules/#{rule.id}"

    assert_equal 403, session.last_response.status
    refute_nil AlertRule[rule.id]
  end

  def test_delete_alert_rule
    rule = AlertRule.create(stream_name: 'x', operator: 'gt', threshold: 1, created_at: Time.now)
    delete "/api/alert_rules/#{rule.id}"

    assert_equal 200, last_response.status
    assert_nil AlertRule[rule.id]
  end

  def test_fleet_alerts_triggers_a_global_rule
    drone = Drone.first(slug: 'drone-001')
    AlertRule.create(stream_name: 'thermal_cam', operator: 'gt', threshold: 60, created_at: Time.now)
    StreamReading.record!(drone, 'thermal_cam', '75C', source: 'live')

    get '/'

    assert_includes last_response.body, 'Thermal Cam &gt; 60.0 (current: 75C)'
  end

  def test_fleet_alerts_does_not_trigger_below_threshold
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    AlertRule.create(stream_name: 'thermal_cam', operator: 'gt', threshold: 60, created_at: Time.now)
    StreamReading.record!(drone, 'thermal_cam', '40C', source: 'live')

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_fleet_alerts_scoped_rule_only_applies_to_its_own_drone
    drone1 = Drone.first(slug: 'drone-001')
    drone2 = Drone.first(slug: 'drone-002')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    AlertRule.create(drone_id: drone1.id, stream_name: 'thermal_cam', operator: 'gt', threshold: 60,
                      created_at: Time.now)
    StreamReading.record!(drone2, 'thermal_cam', '90C', source: 'live') # drone2 - rule doesn't apply here

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_fleet_alerts_does_not_misfire_on_non_numeric_stream
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    AlertRule.create(stream_name: 'camera', operator: 'gt', threshold: 0, created_at: Time.now)
    StreamReading.record!(drone, 'camera', 'OK')

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_alert_rules_panel_hidden_from_viewers
    AlertRule.create(stream_name: 'thermal_cam', operator: 'gt', threshold: 60, created_at: Time.now)
    session = viewer_session
    session.get '/'

    refute_includes session.last_response.body, 'Alert Rules'
  end

  def test_create_stream_spec_requires_admin
    session = viewer_session
    session.post '/api/drones/drone-001/stream_specs', stream_name: 'thermal_cam'

    assert_equal 403, session.last_response.status
    assert_empty StreamSpec.all
  end

  def test_create_stream_spec
    drone = Drone.first(slug: 'drone-001')
    post '/api/drones/drone-001/stream_specs', stream_name: 'thermal_cam', unit: '°C'

    assert_equal 201, last_response.status
    spec = StreamSpec.first
    assert_equal drone.id, spec.drone_id
    assert_equal 'thermal_cam', spec.stream_name
    assert_equal '°C', spec.unit
  end

  def test_create_stream_spec_rejects_unknown_drone
    post '/api/drones/does-not-exist/stream_specs', stream_name: 'thermal_cam'

    assert_equal 404, last_response.status
  end

  def test_create_stream_spec_rejects_duplicate
    drone = Drone.first(slug: 'drone-001')
    StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', created_at: Time.now)
    post '/api/drones/drone-001/stream_specs', stream_name: 'thermal_cam'

    assert_equal 409, last_response.status
  end

  def test_delete_stream_spec_requires_admin
    drone = Drone.first(slug: 'drone-001')
    spec = StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', created_at: Time.now)
    session = viewer_session
    session.delete "/api/stream_specs/#{spec.id}"

    assert_equal 403, session.last_response.status
    refute_nil StreamSpec[spec.id]
  end

  def test_delete_stream_spec
    drone = Drone.first(slug: 'drone-001')
    spec = StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', created_at: Time.now)
    delete "/api/stream_specs/#{spec.id}"

    assert_equal 200, last_response.status
    assert_nil StreamSpec[spec.id]
  end

  def test_fleet_alerts_flags_a_stream_expected_but_never_reported
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', created_at: Time.now)

    get '/'

    assert_includes last_response.body, 'Thermal Cam expected but never reported'
  end

  def test_fleet_alerts_does_not_flag_a_stream_once_it_has_reported
    drone = Drone.first(slug: 'drone-001')
    Drone.each { |d| d.update(battery: 80, status: 'ACTIVE') }
    StreamReading.dataset.delete
    StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', created_at: Time.now)
    StreamReading.record!(drone, 'thermal_cam', '42C', source: 'live')

    get '/'

    assert_includes last_response.body, 'All systems nominal'
  end

  def test_history_chart_uses_registered_unit_for_an_ingested_stream
    drone = Drone.first(slug: 'drone-001')
    StreamSpec.create(drone_id: drone.id, stream_name: 'thermal_cam', unit: 'XU', created_at: Time.now)
    2.times { |i| StreamReading.record!(drone, 'thermal_cam', "#{40 + i}C", source: 'live') }

    get '/drones/drone-001'

    assert_includes last_response.body, 'XU'
  end

  def test_radar_blips_stay_within_radius_for_far_outliers
    near = Drone.create(slug: 'radar-near', lat: 33.5, lon: (-112.1), battery: 50, status: 'ACTIVE',
                         firmware_version: 'v1')
    far = Drone.create(slug: 'radar-far', lat: 40.0, lon: (-70.0), battery: 50, status: 'ACTIVE',
                        firmware_version: 'v1')

    blips = App.new!.send(:radar_blips, [near, far])

    blips.each do |b|
      dist = Math.sqrt(((b[:x] - 150)**2) + ((b[:y] - 150)**2))
      assert_operator dist, :<=, 130.1
    end
  end

  def test_drones_csv_export
    get '/drones.csv'

    assert_equal 200, last_response.status
    assert_includes last_response.content_type, 'csv'
    assert_includes last_response.body, 'slug,status,battery'
    assert_includes last_response.body, 'drone-001'
  end

  def test_history_page_renders_charts
    drone = Drone.first(slug: 'drone-001')
    StreamReading.record!(drone, 'battery', '50')
    StreamReading.record!(drone, 'battery', '55')

    get '/drones/drone-001'

    assert_includes last_response.body, 'sparkline'
    assert_includes last_response.body, 'Battery'
  end

  def viewer_session
    User.create(email: 'viewer@example.com', password: 'testpass123', role: 'viewer')
    session = Rack::Test::Session.new(Rack::MockSession.new(App))
    session.post '/login', email: 'viewer@example.com', password: 'testpass123'
    session
  end

  def test_create_drone_requires_admin
    session = viewer_session
    session.post '/api/drones', slug: 'viewer-drone'

    assert_equal 403, session.last_response.status
    assert_nil Drone.first(slug: 'viewer-drone')
  end

  def test_delete_drone_requires_admin
    session = viewer_session
    session.delete '/api/drones/drone-001'

    assert_equal 403, session.last_response.status
    refute_nil Drone.first(slug: 'drone-001')
  end

  def test_flash_firmware_requires_admin
    session = viewer_session
    session.post '/api/firmware', drone_id: 'drone-001'

    assert_equal 403, session.last_response.status
  end

  def test_viewer_can_still_view_the_dashboard
    session = viewer_session
    session.get '/'

    assert_equal 200, session.last_response.status
    # Not a bare "FLASH" check - that string also appears in the always-
    # present JS *function definition* (only its invocation is
    # conditional). This id is only emitted by server-rendered admin
    # controls for this specific seeded drone.
    refute_includes session.last_response.body, 'fw-drone-001'
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

  def fixture_path(name)
    File.expand_path("fixtures/#{name}", __dir__)
  end

  def test_firmware_upload_is_stored_and_downloadable
    drone = Drone.first(slug: 'drone-001')
    file = Rack::Test::UploadedFile.new(fixture_path('sample.bin'), 'application/octet-stream')

    post '/api/firmware', drone_id: 'drone-001', firmware: file

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'sample.bin', body['file']

    event = FirmwareEvent.order(Sequel.desc(:id)).first(drone_id: drone.id)
    refute_nil event.data
    assert_equal 'sample.bin', event.filename

    get "/drones/drone-001/firmware/#{event.id}/download"

    assert_equal 200, last_response.status
    assert_equal File.read(fixture_path('sample.bin')), last_response.body
    assert_includes last_response.headers['Content-Disposition'], 'sample.bin'
  end

  def test_firmware_upload_rejects_wrong_extension
    file = Rack::Test::UploadedFile.new(fixture_path('not_firmware.txt'), 'text/plain')

    post '/api/firmware', drone_id: 'drone-001', firmware: file

    assert_equal 422, last_response.status
    assert_match(/must be one of/, JSON.parse(last_response.body)['error'])
  end

  def test_firmware_upload_rejects_oversized_file
    original = FirmwareEvent::MAX_FILE_SIZE
    FirmwareEvent.send(:remove_const, :MAX_FILE_SIZE)
    FirmwareEvent.const_set(:MAX_FILE_SIZE, 10) # 10 bytes, smaller than the fixture
    file = Rack::Test::UploadedFile.new(fixture_path('sample.bin'), 'application/octet-stream')

    post '/api/firmware', drone_id: 'drone-001', firmware: file

    assert_equal 422, last_response.status
    assert_match(/must be under/, JSON.parse(last_response.body)['error'])
  ensure
    FirmwareEvent.send(:remove_const, :MAX_FILE_SIZE)
    FirmwareEvent.const_set(:MAX_FILE_SIZE, original)
  end

  def test_download_404s_when_no_file_was_ever_attached
    post '/api/firmware', drone_id: 'drone-001' # no file
    event = FirmwareEvent.order(Sequel.desc(:id)).first(drone_id: Drone.first(slug: 'drone-001').id)

    get "/drones/drone-001/firmware/#{event.id}/download"

    assert_equal 404, last_response.status
  end

  def test_firmware_blobs_are_pruned_beyond_the_keep_limit
    drone = Drone.first(slug: 'drone-001')
    (FirmwareEvent::KEEP_BLOBS_PER_DRONE + 3).times do
      file = Rack::Test::UploadedFile.new(fixture_path('sample.bin'), 'application/octet-stream')
      post '/api/firmware', drone_id: 'drone-001', firmware: file
    end

    with_blobs = FirmwareEvent.where(drone_id: drone.id).exclude(data: nil).count
    assert_equal FirmwareEvent::KEEP_BLOBS_PER_DRONE, with_blobs
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

  def test_battery_stream_reading_does_not_duplicate_as_a_chip
    drone = Drone.first(slug: 'drone-001')
    # Battery is recorded as its own StreamReading purely so the history
    # page can chart it (Phase 5) - it already has its own dedicated bar
    # on the card and must not also show up in the generic stream-chip
    # list (Phase 9's "show every stream" generalization briefly
    # regressed this).
    StreamReading.record!(drone, 'battery', '55%')

    get '/'

    refute_includes last_response.body, 'stream-chip">🔋 Battery'
  end

  def test_telemetry_ingest_records_multiple_labeled_streams
    post '/api/drones/drone-001/telemetry', { streams: { 'thermal_cam' => '38.5C', 'gps_fix' => '3D' } }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'recorded', body['status']
    assert_equal %w[thermal_cam gps_fix], body['streams']

    drone = Drone.first(slug: 'drone-001')
    streams = drone.latest_streams
    assert_equal '38.5C', streams['thermal_cam'][:value]
    assert_equal 'live', streams['thermal_cam'][:source]
  end

  def test_telemetry_ingest_shows_up_labeled_on_dashboard_and_history
    post '/api/drones/drone-001/telemetry', { streams: { 'thermal_cam' => '38.5C' } }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status

    get '/'
    assert_includes last_response.body, 'Thermal Cam'
    assert_includes last_response.body, '38.5C'
    assert_includes last_response.body, 'stream-chip live'

    get '/drones/drone-001'
    assert_includes last_response.body, 'Thermal Cam'
  end

  def test_telemetry_ingest_404s_for_unknown_drone
    post '/api/drones/does-not-exist/telemetry', { streams: { 'x' => '1' } }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 404, last_response.status
  end

  def test_telemetry_ingest_rejects_missing_streams
    post '/api/drones/drone-001/telemetry', {}.to_json, { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 400, last_response.status
  end

  def test_telemetry_ingest_rejects_invalid_json
    post '/api/drones/drone-001/telemetry', 'not json', { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 400, last_response.status
  end

  def test_telemetry_ingest_rejects_too_many_streams
    streams = (1..StreamReading::MAX_STREAMS_PER_INGEST + 1).to_h { |i| ["s#{i}", '1'] }
    post '/api/drones/drone-001/telemetry', { streams: streams }.to_json, { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 422, last_response.status
  end

  def test_telemetry_ingest_rejects_invalid_stream_name
    post '/api/drones/drone-001/telemetry', { streams: { 'bad name!' => '1' } }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 422, last_response.status
  end

  def test_telemetry_ingest_rejects_oversized_value
    long_value = '1' * (StreamReading::MAX_VALUE_LENGTH + 1)
    post '/api/drones/drone-001/telemetry', { streams: { 'x' => long_value } }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 422, last_response.status
  end

  def test_telemetry_ingest_rate_limits_per_drone
    body = { streams: { 'x' => '1' } }.to_json
    60.times do
      post '/api/drones/drone-001/telemetry', body, { 'CONTENT_TYPE' => 'application/json' }
      assert_equal 200, last_response.status
    end

    post '/api/drones/drone-001/telemetry', body, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 429, last_response.status

    # A different drone's own limit is untouched.
    post '/api/drones/drone-002/telemetry', body, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
  end

  def test_telemetry_ingest_requires_admin
    session = viewer_session
    session.post '/api/drones/drone-001/telemetry', { streams: { 'x' => '1' } }.to_json,
                 { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 403, session.last_response.status
  end

  def test_telemetry_ingest_via_api_token_without_login
    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    ENV['DRONE_API_TOKEN'] = 'sekrit'
    begin
      logged_out.post '/api/drones/drone-001/telemetry', { streams: { 'x' => '1' } }.to_json,
                       { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_DRONE_TOKEN' => 'sekrit' }
      assert_equal 200, logged_out.last_response.status
    ensure
      ENV.delete('DRONE_API_TOKEN')
    end
  end

  def test_rotate_token_requires_admin
    session = viewer_session
    session.post '/api/drones/drone-001/rotate_token'

    assert_equal 403, session.last_response.status
    assert_nil Drone.first(slug: 'drone-001').token_digest
  end

  def test_rotate_token_issues_a_working_scoped_credential
    post '/api/drones/drone-001/rotate_token'

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    token = body['token']
    refute_nil token

    drone = Drone.first(slug: 'drone-001')
    refute_nil drone.token_digest
    refute_equal token, drone.token_digest # only the digest is stored, never the plaintext

    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.post '/api/drones/drone-001/telemetry', { streams: { 'x' => '1' } }.to_json,
                     { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_DRONE_TOKEN' => token }

    assert_equal 200, logged_out.last_response.status
  end

  def test_rotate_token_invalidates_the_previous_token
    post '/api/drones/drone-001/rotate_token'
    old_token = JSON.parse(last_response.body)['token']
    post '/api/drones/drone-001/rotate_token'

    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.post '/api/drones/drone-001/telemetry', { streams: { 'x' => '1' } }.to_json,
                     { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_DRONE_TOKEN' => old_token }

    refute_equal 200, logged_out.last_response.status
  end

  def test_drone_token_does_not_authorize_a_different_drones_telemetry
    post '/api/drones/drone-001/rotate_token'
    token = JSON.parse(last_response.body)['token']

    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.post '/api/drones/drone-002/telemetry', { streams: { 'x' => '1' } }.to_json,
                     { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_DRONE_TOKEN' => token }

    refute_equal 200, logged_out.last_response.status
  end

  def test_drone_token_does_not_grant_fleet_wide_admin_access
    post '/api/drones/drone-001/rotate_token'
    token = JSON.parse(last_response.body)['token']

    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.post '/api/drones', { slug: 'sneaky' }, { 'HTTP_X_DRONE_TOKEN' => token }

    refute_equal 201, logged_out.last_response.status
    assert_nil Drone.first(slug: 'sneaky')
  end

  def test_revoke_token_requires_admin
    post '/api/drones/drone-001/rotate_token'
    session = viewer_session
    session.delete '/api/drones/drone-001/token'

    assert_equal 403, session.last_response.status
    refute_nil Drone.first(slug: 'drone-001').token_digest
  end

  def test_revoke_token_disables_it
    post '/api/drones/drone-001/rotate_token'
    token = JSON.parse(last_response.body)['token']
    delete '/api/drones/drone-001/token'

    assert_equal 200, last_response.status
    assert_nil Drone.first(slug: 'drone-001').token_digest

    logged_out = Rack::Test::Session.new(Rack::MockSession.new(App))
    logged_out.post '/api/drones/drone-001/telemetry', { streams: { 'x' => '1' } }.to_json,
                     { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_DRONE_TOKEN' => token }

    refute_equal 200, logged_out.last_response.status
  end

  def test_history_page_404s_for_unknown_drone
    get '/drones/does-not-exist'

    assert_equal 404, last_response.status
  end

  # A real dispatch has a bound request (and so a resolvable current_user);
  # App.new! alone doesn't, so these seed @current_user directly to unit-test
  # the command logic in isolation from session/cookie resolution, which has
  # its own dedicated tests elsewhere.
  def ws_app_as(user)
    App.new!.tap { |a| a.instance_variable_set(:@current_user, user) }
  end

  def test_ws_command_recall_sets_status_to_charging
    drone = Drone.first(slug: 'drone-001')
    admin = User.first(email: TEST_EMAIL)
    result = ws_app_as(admin).handle_command({ cmd: 'recall', drone_id: 'drone-001' }.to_json)

    assert result[:applied]
    drone.refresh
    assert_equal 'CHARGING', drone.status
  end

  def test_ws_command_set_status_validates_status
    admin = User.first(email: TEST_EMAIL)
    result = ws_app_as(admin).handle_command(
      { cmd: 'set_status', drone_id: 'drone-001', status: 'NOT_A_STATUS' }.to_json
    )

    refute result[:applied]
    assert_match(/must be one of/, result[:error])
  end

  def test_ws_command_rejects_non_admin
    drone = Drone.first(slug: 'drone-001')
    viewer = User.create(email: 'viewer@example.com', password: 'testpass123', role: 'viewer')
    result = ws_app_as(viewer).handle_command({ cmd: 'recall', drone_id: 'drone-001' }.to_json)

    refute result[:applied]
    assert_equal 'admins only', result[:error]
    drone.refresh
    refute_equal 'CHARGING', drone.status
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
