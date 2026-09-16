Sequel.migration do
  change do
    # Backs RateLimiter across multiple app instances - the old in-memory
    # @hits Hash only ever saw attempts that landed on that exact process,
    # so two instances behind a load balancer each independently allowed up
    # to the limit. One row per attempt, self-pruned lazily (a bucket+key's
    # stale rows are deleted on that same key's next check - same lazy
    # pruning the in-memory version already did, just DB-backed now).
    create_table(:rate_limit_hits) do
      primary_key :id
      String :bucket, null: false
      String :key, null: false
      DateTime :occurred_at, null: false

      index %i[bucket key occurred_at]
    end
  end
end
