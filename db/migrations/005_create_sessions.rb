Sequel.migration do
  change do
    create_table(:sessions) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :token, null: false
      DateTime :created_at, null: false
      DateTime :last_active_at, null: false

      index :token, unique: true
    end
  end
end
