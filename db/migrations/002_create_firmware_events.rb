Sequel.migration do
  change do
    create_table(:firmware_events) do
      primary_key :id
      foreign_key :drone_id, :drones, null: false, on_delete: :cascade
      String :from_version
      String :to_version, null: false
      DateTime :flashed_at, null: false

      index :drone_id
    end
  end
end
