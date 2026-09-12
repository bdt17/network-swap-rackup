require_relative 'test_helper'

class AuthTest < Minitest::Test
  include DroneTestHelpers

  def fresh_session
    Rack::Test::Session.new(Rack::MockSession.new(App))
  end

  def test_login_with_correct_password_succeeds
    session = fresh_session
    session.post '/login', email: TEST_EMAIL, password: TEST_PASSWORD

    assert_equal 302, session.last_response.status
    assert_includes session.last_response.location, '/'

    session.get '/'
    assert_equal 200, session.last_response.status
  end

  def test_login_with_wrong_password_fails
    session = fresh_session
    session.post '/login', email: TEST_EMAIL, password: 'wrong'

    assert_equal 401, session.last_response.status
    assert_includes session.last_response.body, 'Invalid email or password'
  end

  def test_logout_clears_the_session
    post '/logout'
    assert_equal 302, last_response.status

    get '/'
    assert_equal 302, last_response.status
    assert_includes last_response.location, '/login'
  end

  def test_two_factor_enrollment_and_challenge_flow
    # Enroll.
    post '/security/two-factor/enroll'
    assert_equal 200, last_response.status
    secret = last_response.body[/name="secret" value="([A-Z0-9]+)"/, 1]
    refute_nil secret

    code = ROTP::TOTP.new(secret).now
    post '/security/two-factor/confirm', secret: secret, code: code

    assert_equal 200, last_response.status
    assert_includes last_response.body, '2FA enabled'

    user = User.first(email: TEST_EMAIL)
    assert user.otp_enabled
    assert_equal 10, BackupCode.where(user_id: user.id).count

    # Now log out and log back in - should be routed through the challenge.
    post '/logout'
    session = fresh_session
    session.post '/login', email: TEST_EMAIL, password: TEST_PASSWORD
    assert_includes session.last_response.location, '/two-factor-challenge'

    session.get '/two-factor-challenge'
    assert_equal 200, session.last_response.status

    session.post '/two-factor-challenge', code: ROTP::TOTP.new(secret).now
    assert_includes session.last_response.location, '/'

    session.get '/'
    assert_equal 200, session.last_response.status
  end

  def test_two_factor_challenge_rejects_wrong_code
    post '/security/two-factor/enroll'
    secret = last_response.body[/name="secret" value="([A-Z0-9]+)"/, 1]
    post '/security/two-factor/confirm', secret: secret, code: ROTP::TOTP.new(secret).now
    post '/logout'

    session = fresh_session
    session.post '/login', email: TEST_EMAIL, password: TEST_PASSWORD
    session.post '/two-factor-challenge', code: '000000'

    assert_equal 401, session.last_response.status
    assert_includes session.last_response.body, 'Invalid code'
  end

  def test_backup_code_works_once
    post '/security/two-factor/enroll'
    secret = last_response.body[/name="secret" value="([A-Z0-9]+)"/, 1]
    post '/security/two-factor/confirm', secret: secret, code: ROTP::TOTP.new(secret).now

    # We only stored a digest of each backup code - re-deriving a plaintext
    # code from it isn't possible, so pull one from the confirm page instead
    # (the same place a real user would see it: shown once, never again).
    codes = last_response.body.scan(/<div class="codes">(.*?)<\/div>/m).flatten.first.to_s.split('<br>')
    refute_empty codes
    plain_code = codes.first

    post '/logout'
    session = fresh_session
    session.post '/login', email: TEST_EMAIL, password: TEST_PASSWORD
    session.post '/two-factor-challenge', code: plain_code
    assert_includes session.last_response.location, '/'

    # Using the same backup code again must fail.
    post '/logout'
    session2 = fresh_session
    session2.post '/login', email: TEST_EMAIL, password: TEST_PASSWORD
    session2.post '/two-factor-challenge', code: plain_code
    assert_equal 401, session2.last_response.status
  end

  def test_disable_two_factor_requires_correct_password
    post '/security/two-factor/enroll'
    secret = last_response.body[/name="secret" value="([A-Z0-9]+)"/, 1]
    post '/security/two-factor/confirm', secret: secret, code: ROTP::TOTP.new(secret).now

    post '/security/two-factor/disable', password: 'wrong'
    assert_equal 401, last_response.status
    assert User.first(email: TEST_EMAIL).otp_enabled

    post '/security/two-factor/disable', password: TEST_PASSWORD
    assert_equal 302, last_response.status
    refute User.first(email: TEST_EMAIL).otp_enabled
  end
end
