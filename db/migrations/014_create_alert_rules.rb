Sequel.migration do
  change do
    # Admin-configurable thresholds on any numeric stream - fleet_alerts
    # (app.rb) previously only ever checked battery/camera/link_signal,
    # hardcoded. Now that a drone can report arbitrary numeric streams
    # (Phase 9), there was no way to say "alert if thermal_cam exceeds 60"
    # without a code deploy.
    create_table(:alert_rules) do
      primary_key :id
      # NULL drone_id = a global rule, checked against every drone that
      # reports this stream_name, not just one.
      foreign_key :drone_id, :drones, null: true, on_delete: :cascade
      String :stream_name, null: false
      String :operator, null: false
      Float :threshold, null: false
      DateTime :created_at, null: false

      index %i[drone_id stream_name]
    end
  end
end
