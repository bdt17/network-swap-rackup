Sequel.migration do
  change do
    create_table(:stream_readings) do
      primary_key :id
      foreign_key :drone_id, :drones, null: false, on_delete: :cascade
      String :stream_name, null: false
      String :value, null: false
      DateTime :recorded_at, null: false

      index %i[drone_id stream_name recorded_at]
    end
  end
end
