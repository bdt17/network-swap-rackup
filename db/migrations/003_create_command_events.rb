Sequel.migration do
  change do
    create_table(:command_events) do
      primary_key :id
      foreign_key :drone_id, :drones, null: true, on_delete: :set_null
      String :raw_payload, text: true
      DateTime :received_at, null: false

      index :drone_id
    end
  end
end
