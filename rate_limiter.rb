# In-memory rate limiting for the login and two-factor-challenge endpoints,
# keyed by request IP - matches network-swap-app's own `rate_limit to: 10,
# within: 3.minutes` on its SessionsController. In-memory (not DB-backed) is
# consistent with everything else in this app (settings.sockets,
# FleetSimulator's tick gate) being single-instance-only by design; would
# need a shared store (Redis, Postgres) the moment this runs on more than
# one instance - see NEXT_STEPS.md.
module RateLimiter
  LIMITS = {
    login: { max: 10, within: 180 },
    two_factor: { max: 10, within: 180 }
  }.freeze

  @mutex = Mutex.new
  @hits = Hash.new { |h, k| h[k] = [] }

  # Records this attempt and returns true if the caller is already over the
  # limit (the attempt still counts, so a caller can't dodge the count by
  # retrying just under the window).
  def self.exceeded?(bucket, key)
    limit = LIMITS.fetch(bucket)
    now = Time.now

    @mutex.synchronize do
      timestamps = @hits[[bucket, key]]
      timestamps.reject! { |t| now - t > limit[:within] }
      over = timestamps.size >= limit[:max]
      timestamps << now
      over
    end
  end

  # Test-only: clears all recorded attempts so one test's logins don't count
  # against the next test's rate limit.
  def self.reset!
    @mutex.synchronize { @hits.clear }
  end
end
