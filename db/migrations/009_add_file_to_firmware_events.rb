Sequel.migration do
  change do
    alter_table(:firmware_events) do
      add_column :filename, String
      add_column :content_type, String
      add_column :data, File # bytea on Postgres, BLOB on sqlite - portable across both
    end
  end
end
