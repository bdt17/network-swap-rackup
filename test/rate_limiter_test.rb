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

  def test_old_attempts_outside_the_window_do_not_count
    key = %i[login old-ip]
    hits = RateLimiter.instance_variable_get(:@hits)
    hits[key] = Array.new(10) { Time.now - 200 } # older than the 180s window

    refute RateLimiter.exceeded?(:login, 'old-ip')
  end
end
