Sequel.migration do
  change do
    create_table(:backup_codes) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :code_digest, null: false
      DateTime :used_at
      DateTime :created_at, null: false

      index :user_id
    end
  end
end
