require_relative 'test_helper'

class AlertRuleTest < Minitest::Test
  include DroneTestHelpers

  def test_triggered_for_each_operator
    assert AlertRule.new(operator: 'gt', threshold: 10).triggered?('15')
    refute AlertRule.new(operator: 'gt', threshold: 10).triggered?('5')
    assert AlertRule.new(operator: 'gte', threshold: 10).triggered?('10')
    refute AlertRule.new(operator: 'lt', threshold: 10).triggered?('10')
    assert AlertRule.new(operator: 'lte', threshold: 10).triggered?('10')
  end

  def test_triggered_parses_a_unit_suffix
    assert AlertRule.new(operator: 'gt', threshold: 60).triggered?('75C')
  end

  def test_triggered_is_false_for_a_non_numeric_value_not_zero
    refute AlertRule.new(operator: 'gt', threshold: -1).triggered?('OK')
  end

  def test_validate_rejects_unknown_operator
    rule = AlertRule.new(stream_name: 'x', operator: 'nonsense', threshold: 1)
    refute rule.valid?
  end

  def test_validate_rejects_missing_threshold
    rule = AlertRule.new(stream_name: 'x', operator: 'gt', threshold: nil)
    refute rule.valid?
  end

  def test_for_drone_includes_global_and_own_scoped_rules
    d1 = Drone.first(slug: 'drone-001')
    d2 = Drone.first(slug: 'drone-002')
    global = AlertRule.create(stream_name: 'a', operator: 'gt', threshold: 1, created_at: Time.now)
    scoped_to_d1 = AlertRule.create(drone_id: d1.id, stream_name: 'b', operator: 'gt', threshold: 1,
                                     created_at: Time.now)
    AlertRule.create(drone_id: d2.id, stream_name: 'c', operator: 'gt', threshold: 1, created_at: Time.now)

    ids = AlertRule.for_drone(d1).select_map(:id)
    assert_includes ids, global.id
    assert_includes ids, scoped_to_d1.id
    assert_equal 2, ids.size
  end
end
