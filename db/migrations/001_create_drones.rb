Sequel.migration do
  change do
    create_table(:drones) do
      primary_key :id
      String :slug, null: false
      String :name
      Float :lat
      Float :lon
      Integer :battery
      String :status, null: false, default: 'UNKNOWN'
      String :firmware_version, null: false, default: 'v1.0.0'
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :slug, unique: true
    end
  end
end
