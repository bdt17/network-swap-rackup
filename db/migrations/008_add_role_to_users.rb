Sequel.migration do
  change do
    # Postgres backfills existing rows with the DEFAULT as part of the same
    # ALTER TABLE (no separate data migration needed) - so every account
    # created before roles existed keeps full access rather than being
    # silently downgraded.
    add_column :users, :role, String, null: false, default: 'admin'
  end
end
