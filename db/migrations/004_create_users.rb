Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :email, null: false
      String :password_digest, null: false
      String :otp_secret
      TrueClass :otp_enabled, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :email, unique: true
    end
  end
end
