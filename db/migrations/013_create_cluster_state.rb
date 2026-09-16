Sequel.migration do
  # Explicit up/down (not `change`) because this migration also seeds two
  # known rows - `change` can't auto-reverse a data insert the way it can a
  # column/table definition.
  up do
    create_table(:cluster_state) do
      String :key, primary_key: true
      String :value, null: false
      DateTime :updated_at, null: false
    end

    # A tiny shared key-value table coordinating state across multiple app
    # instances (see NEXT_STEPS.md's former "single-instance only" gap):
    # - fleet_last_changed_at: a timestamp marker every instance polls (via
    #   App.relay_remote_broadcasts!, on every incoming request) to know
    #   when to push a fresh WebSocket broadcast to its own locally-
    #   connected sockets, even when the mutation that changed it happened
    #   on a *different* instance.
    # - simulator_next_tick_at: claimed atomically (a single conditional
    #   UPDATE, not a lock) so exactly one instance runs each simulator
    #   tick, not one per running instance.
    # Both rows are seeded here so runtime code never has to distinguish
    # "row missing" from "not due yet."
    now = Time.now.utc
    from(:cluster_state).insert(key: 'fleet_last_changed_at', value: now.iso8601, updated_at: now)
    from(:cluster_state).insert(key: 'simulator_next_tick_at', value: now.iso8601, updated_at: now)
  end

  down do
    drop_table(:cluster_state)
  end
end
