Sequel.migration do
  change do
    # A per-drone manifest of streams it's expected to report - closes two
    # gaps that only applied to a stream *after* it had reported at least
    # once: stale-feed detection (Phase 10) couldn't flag a stream that was
    # supposed to show up and never did, and ingested numeric streams had
    # no real unit for their history chart (StreamReading itself stores no
    # unit - just a value string like "42.7C"). Distinct from AlertRule
    # (Phase 14), which is a threshold check on a value, not a presence/
    # labeling manifest.
    create_table(:stream_specs) do
      primary_key :id
      foreign_key :drone_id, :drones, null: false, on_delete: :cascade
      String :stream_name, null: false
      String :unit
      DateTime :created_at, null: false

      index %i[drone_id stream_name], unique: true
    end
  end
end
