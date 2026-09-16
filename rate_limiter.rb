require_relative 'models'

# DB-backed (via RateLimitHit) rate limiting for the login,
# two-factor-challenge, and telemetry-ingestion endpoints, keyed by request
# IP (login/two_factor) or drone slug (telemetry) - matches network-swap-app's
# own `rate_limit to: 10, within: 3.minutes` on its SessionsController.
#
# DB-backed rather than an in-memory Hash specifically so this stays correct
# once this app runs on more than one instance (see NEXT_STEPS.md's former
# "single-instance only" gap) - an in-memory counter only ever sees attempts
# that landed on that exact process, so two instances behind a load balancer
# would each independently allow up to the limit. A per-process Mutex is
# still kept around the check+insert purely to narrow (not eliminate) a
# race between two concurrent requests on the *same* instance; it can't do
# anything about a simultaneous request on a different instance, which is
# an accepted, minor over-count risk at this app's scale - the same
# "good enough, not bulletproof" bar `client_ip` already documents.
module RateLimiter
  LIMITS = {
    login: { max: 10, within: 180 },
    two_factor: { max: 10, within: 180 },
    # Keyed by drone slug (not IP) in practice - the thing worth protecting
    # is a single drone's feed/the fleet-wide broadcast it triggers, not a
    # particular caller. Generous enough for a real drone reporting every
    # few seconds; tight enough that a misbehaving or compromised
    # credential can't flood the fleet broadcast unbounded.
    telemetry: { max: 60, within: 60 }
  }.freeze

  @mutex = Mutex.new

  # Records this attempt and returns true if the caller is already over the
  # limit (the attempt still counts, so a caller can't dodge the count by
  # retrying just under the window).
  def self.exceeded?(bucket, key)
    limit = LIMITS.fetch(bucket)
    bucket_s = bucket.to_s
    key_s = key.to_s
    now = Time.now

    @mutex.synchronize do
      RateLimitHit.where(bucket: bucket_s, key: key_s).where { occurred_at < (now - limit[:within]) }.delete
      over = RateLimitHit.where(bucket: bucket_s, key: key_s).count >= limit[:max]
      RateLimitHit.create(bucket: bucket_s, key: key_s, occurred_at: now)
      over
    end
  end

  # Test-only: clears all recorded attempts so one test's logins don't count
  # against the next test's rate limit.
  def self.reset!
    RateLimitHit.dataset.delete
  end
end
