require_relative 'test_helper'
require_relative '../rate_limiter'

class RateLimiterTest < Minitest::Test
  def setup
    RateLimiter.reset!
  end

  def test_allows_up_to_the_limit_then_blocks
    9.times { refute RateLimiter.exceeded?(:login, '1.2.3.4') }
    refute RateLimiter.exceeded?(:login, '1.2.3.4') # 10th attempt: still allowed, now at the limit
    assert RateLimiter.exceeded?(:login, '1.2.3.4') # 11th: over it
  end

  def test_buckets_are_independent_per_key
    10.times { RateLimiter.exceeded?(:login, 'ip-a') }
    assert RateLimiter.exceeded?(:login, 'ip-a')
    refute RateLimiter.exceeded?(:login, 'ip-b')
  end

  def test_buckets_are_independent_per_type
    10.times { RateLimiter.exceeded?(:login, 'shared-ip') }
    refute RateLimiter.exceeded?(:two_factor, 'shared-ip')
  end

  def test_telemetry_bucket_has_its_own_higher_limit
    59.times { refute RateLimiter.exceeded?(:telemetry, 'drone-001') }
    refute RateLimiter.exceeded?(:telemetry, 'drone-001') # 60th: still allowed, now at the limit
    assert RateLimiter.exceeded?(:telemetry, 'drone-001') # 61st: over it

    # A different drone's own bucket is untouched.
    refute RateLimiter.exceeded?(:telemetry, 'drone-002')
  end

  def test_old_attempts_outside_the_window_do_not_count
    10.times do
      RateLimitHit.create(bucket: 'login', key: 'old-ip', occurred_at: Time.now - 200) # older than the 180s window
    end

    refute RateLimiter.exceeded?(:login, 'old-ip')
  end

  def test_a_different_processs_hits_still_count_towards_the_same_limit
    # Simulates another instance's attempts by writing rows directly,
    # bypassing this process's own RateLimiter.exceeded? entirely - the
    # whole point of moving this to the DB is that it's still seen here.
    10.times { RateLimitHit.create(bucket: 'login', key: 'shared-ip', occurred_at: Time.now) }

    assert RateLimiter.exceeded?(:login, 'shared-ip')
  end
end
