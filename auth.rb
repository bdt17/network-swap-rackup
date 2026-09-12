require 'securerandom'
require 'rotp'
require 'rqrcode'
require_relative 'models'

# Login + two-factor auth for the dashboard, mirroring the pattern already
# proven in network-swap-app (the sibling Rails app): bcrypt-hashed
# passwords, a DB-backed session token in a cookie (not Rack's own signed
# cookie session - that's used only for the short-lived "password verified,
# waiting on a TOTP code" pending state below), TOTP via an authenticator
# app, and one-time hashed backup codes.
class App < Sinatra::Base
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(32) }

  PENDING_MFA_TTL = 600 # seconds
  SESSION_COOKIE = 'drone_session'
  PUBLIC_PATHS = ['/login', '/two-factor-challenge', '/health'].freeze

  helpers do
    def current_user
      return @current_user if defined?(@current_user)

      token = request.cookies[SESSION_COOKIE]
      row = token && Session.first(token: token)
      row&.update(last_active_at: Time.now)
      @current_user = row&.user
    end

    def sign_in!(user)
      token = SecureRandom.hex(32)
      Session.create(user_id: user.id, token: token, created_at: Time.now, last_active_at: Time.now)
      response.set_cookie(SESSION_COOKIE, value: token, httponly: true, secure: request.secure?,
                                           same_site: :lax, path: '/')
      @current_user = user
    end

    def sign_out!
      token = request.cookies[SESSION_COOKIE]
      Session.where(token: token).delete if token
      response.delete_cookie(SESSION_COOKIE, path: '/')
    end

    def require_login!
      redirect '/login' unless current_user
    end

    # A configured DRONE_API_TOKEN bypasses login entirely, for
    # scripts/curl hitting the mutating endpoints without a browser session.
    def valid_api_token?
      configured = ENV['DRONE_API_TOKEN']
      return false if configured.to_s.empty?

      provided = request.env['HTTP_X_DRONE_TOKEN'] || params['token']
      provided == configured
    end

    def pending_mfa_user
      return nil unless session[:pending_user_id]
      return nil if session[:pending_expires_at].to_i < Time.now.to_i

      User[session[:pending_user_id]]
    end

    def clear_pending_mfa!
      session.delete(:pending_user_id)
      session.delete(:pending_expires_at)
    end

    def valid_totp_or_backup_code?(user, code)
      code = code.to_s.strip
      return false if code.empty?
      return true if user.otp_secret && ROTP::TOTP.new(user.otp_secret).verify(code, drift_behind: 30, drift_ahead: 30)

      backup = BackupCode.first(user_id: user.id, code_digest: BackupCode.hash_code(code), used_at: nil)
      return false unless backup

      backup.update(used_at: Time.now)
      true
    end

    def auth_page(title, body_html)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>#{h(title)}</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body{font-family:"Courier New",monospace;background:linear-gradient(45deg,#0a0a0a,#1a0033,#000066,#330066);color:#00ffcc;margin:0;padding:20px;min-height:100vh;display:flex;align-items:center;justify-content:center}
        .auth-card{background:rgba(0,255,204,.08);border:2px solid #00ffcc;border-radius:15px;padding:30px;max-width:380px;width:100%;box-shadow:0 10px 30px rgba(0,255,204,.3)}
        h1{font-size:1.6em;text-align:center;text-shadow:0 0 15px #00ffcc;margin-top:0}
        label{display:block;margin:14px 0 4px;font-size:.9em}
        input[type=email],input[type=password],input[type=text]{width:100%;box-sizing:border-box;background:#000;color:#00ffcc;border:1px solid #00ffcc;border-radius:5px;padding:10px;font-family:inherit}
        button,.btn{width:100%;margin-top:18px;background:#00ffcc;color:#000;border:none;padding:12px;border-radius:5px;cursor:pointer;font-weight:bold;font-family:inherit;font-size:1em}
        button:hover,.btn:hover{background:#00ccaa}
        .error-msg{color:#ff4444;text-align:center;margin-top:10px}
        .muted{color:#888;font-size:.85em;text-align:center;margin-top:14px}
        a{color:#00ffcc}
        .codes{font-size:1.2em;line-height:1.8;text-align:center;letter-spacing:1px}
        </style>
        </head>
        <body>
        <div class="auth-card">#{body_html}</div>
        </body>
        </html>
      HTML
    end

    def login_page(error: nil)
      auth_page('🛰️ Cyberpunk Drone C2 — Sign in', <<~HTML)
        <h1>🛰️ DRONE C2</h1>
        <form method="post" action="/login">
          <label>Email</label>
          <input type="email" name="email" required autofocus>
          <label>Password</label>
          <input type="password" name="password" required>
          <button type="submit">Sign in</button>
        </form>
        #{error ? "<div class=\"error-msg\">#{h(error)}</div>" : ''}
      HTML
    end

    def two_factor_page(error: nil)
      auth_page('Two-factor code', <<~HTML)
        <h1>🔒 Two-factor code</h1>
        <form method="post" action="/two-factor-challenge">
          <label>Authenticator code or backup code</label>
          <input type="text" name="code" required autofocus>
          <button type="submit">Verify</button>
        </form>
        #{error ? "<div class=\"error-msg\">#{h(error)}</div>" : ''}
        <div class="muted">Lost access? Ask an admin to run bin/disable_mfa.</div>
      HTML
    end

    def two_factor_setup_page(secret, error: nil)
      totp = ROTP::TOTP.new(secret, issuer: 'Cyberpunk Drone C2')
      uri = totp.provisioning_uri(current_user.email)
      qr_svg = RQRCode::QRCode.new(uri).as_svg(module_size: 4, standalone: true, use_path: true)

      auth_page('Enable two-factor auth', <<~HTML)
        <h1>🔒 Enable 2FA</h1>
        <div class="muted">Scan with your authenticator app, then enter a code to confirm.</div>
        <div style="background:#fff;padding:10px;border-radius:8px;margin-top:14px">#{qr_svg}</div>
        <form method="post" action="/security/two-factor/confirm">
          <input type="hidden" name="secret" value="#{h(secret)}">
          <label>6-digit code</label>
          <input type="text" name="code" required autofocus>
          <button type="submit">Confirm &amp; enable</button>
        </form>
        #{error ? "<div class=\"error-msg\">#{h(error)}</div>" : ''}
      HTML
    end

    def backup_codes_page(codes)
      auth_page('Your backup codes', <<~HTML)
        <h1>✅ 2FA enabled</h1>
        <div class="muted">Save these 10 backup codes somewhere safe — each works once if you lose your authenticator. They won't be shown again.</div>
        <div class="codes">#{codes.map { |c| h(c) }.join('<br>')}</div>
        <a class="btn" href="/" style="display:block;text-align:center;text-decoration:none;box-sizing:border-box">Done</a>
      HTML
    end

    def two_factor_status_page
      auth_page('Security', <<~HTML)
        <h1>🔒 Security</h1>
        <div class="muted">Signed in as #{h(current_user.email)}</div>
        #{if current_user.otp_enabled
            '<form method="post" action="/security/two-factor/disable" style="margin-top:20px">' \
              '<label>Password (to disable 2FA)</label>' \
              '<input type="password" name="password" required>' \
              '<button type="submit">Disable two-factor auth</button></form>'
          else
            '<form method="post" action="/security/two-factor/enroll" style="margin-top:20px">' \
              '<button type="submit">Enable two-factor auth</button></form>'
          end}
        <a href="/" style="display:block;text-align:center;margin-top:14px">&larr; Back to fleet</a>
      HTML
    end
  end

  before do
    next if PUBLIC_PATHS.include?(request.path_info)
    next if valid_api_token?

    require_login!
  end

  get '/login' do
    redirect '/' if current_user
    content_type :html
    login_page
  end

  post '/login' do
    user = User.first(email: params['email'].to_s.strip.downcase)
    unless user&.authenticate(params['password'].to_s)
      content_type :html
      halt 401, login_page(error: 'Invalid email or password')
    end

    if user.otp_enabled
      session[:pending_user_id] = user.id
      session[:pending_expires_at] = Time.now.to_i + PENDING_MFA_TTL
      redirect '/two-factor-challenge'
    else
      sign_in!(user)
      redirect '/'
    end
  end

  get '/two-factor-challenge' do
    redirect '/login' unless pending_mfa_user

    content_type :html
    two_factor_page
  end

  post '/two-factor-challenge' do
    user = pending_mfa_user
    redirect '/login' unless user

    if valid_totp_or_backup_code?(user, params['code'])
      clear_pending_mfa!
      sign_in!(user)
      redirect '/'
    else
      content_type :html
      halt 401, two_factor_page(error: 'Invalid code')
    end
  end

  post '/logout' do
    sign_out!
    redirect '/login'
  end

  get '/security/two-factor' do
    content_type :html
    two_factor_status_page
  end

  post '/security/two-factor/enroll' do
    secret = ROTP::Base32.random
    content_type :html
    two_factor_setup_page(secret)
  end

  post '/security/two-factor/confirm' do
    secret = params['secret'].to_s
    unless ROTP::TOTP.new(secret).verify(params['code'].to_s.strip, drift_behind: 30, drift_ahead: 30)
      content_type :html
      halt 401, two_factor_setup_page(secret, error: 'Invalid code, try again')
    end

    current_user.update(otp_secret: secret, otp_enabled: true)

    codes = Array.new(10) { SecureRandom.hex(4) }
    BackupCode.where(user_id: current_user.id).delete
    codes.each { |c| BackupCode.create(user_id: current_user.id, code_digest: BackupCode.hash_code(c), created_at: Time.now) }

    content_type :html
    backup_codes_page(codes)
  end

  post '/security/two-factor/disable' do
    halt 401, 'Wrong password' unless current_user.authenticate(params['password'].to_s)

    current_user.update(otp_secret: nil, otp_enabled: false)
    BackupCode.where(user_id: current_user.id).delete
    redirect '/security/two-factor'
  end
end
