Sequel.migration do
  change do
    # Lets a single drone authenticate its own telemetry posts without the
    # fleet-wide DRONE_API_TOKEN, which also satisfies admin_access? (full
    # command/firmware/fleet-management rights) - a leaked per-drone token
    # should only ever be able to post telemetry for that one drone.
    # Nullable/no default: existing drones simply have no scoped credential
    # until an admin issues one via POST /api/drones/:slug/rotate_token.
    alter_table(:drones) do
      add_column :token_digest, String
    end
  end
end
