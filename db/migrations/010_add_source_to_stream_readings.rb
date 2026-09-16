Sequel.migration do
  change do
    # Distinguishes FleetSimulator's fake ticks from readings a real drone
    # actually pushed via POST /api/drones/:slug/telemetry - lets the
    # simulator back off a stream once live data starts arriving for it,
    # and lets the UI badge which is which. Existing rows predate real
    # ingestion, so they backfill as 'simulated'.
    alter_table(:stream_readings) do
      add_column :source, String, null: false, default: 'simulated'
    end
  end
end
