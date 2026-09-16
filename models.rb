require 'bcrypt'
require 'digest'
require_relative 'db'

class Drone < Sequel::Model
  plugin :timestamps, update_on_create: true
  one_to_many :firmware_events, order: :flashed_at
  one_to_many :command_events
  one_to_many :stream_readings, order: Sequel.desc(:recorded_at)

  STATUSES = %w[ACTIVE PATROL_AZ1 PATROL_AZ2 CHARGING OFFLINE MAINTENANCE].freeze

  def validate
    super
    errors.add(:slug, 'cannot be empty') if slug.nil? || slug.strip.empty?
    errors.add(:status, "must be one of #{STATUSES.join(', ')}") if status && !STATUSES.include?(status)
    errors.add(:battery, 'must be between 0 and 100') if battery && !(0..100).cover?(battery)
  end

  # The latest reading per named stream (e.g. "camera" => "OK"), keyed by
  # stream name so the frontend/history page can label each one.
  def latest_streams
    StreamReading.latest_for(id)
  end

  # Shape expected by the frontend's WebSocket handler: { lat:, lon:, battery:, status:, firmware: { version: }, streams: {}, stream_sources: {}, stream_ages_s: {} }
  # stream_sources/stream_ages_s are parallel name=>value maps (not nested
  # inside streams) so existing plain-string consumers of `streams` (alert
  # thresholds, CSV export) don't need to change shape. stream_ages_s (age
  # in whole seconds as of this broadcast) lets the live client-side alerts
  # panel flag a stale live feed without needing its own clock/timers.
  def to_fleet_json
    streams = latest_streams
    now = Time.now
    {
      lat: lat,
      lon: lon,
      battery: battery,
      status: status,
      firmware: { version: firmware_version },
      streams: streams.transform_values { |r| r[:value] },
      stream_sources: streams.transform_values { |r| r[:source] },
      stream_ages_s: streams.transform_values { |r| (now - r[:recorded_at]).round },
      has_token: !token_digest.nil?
    }
  end

  def self.fleet_hash
    all.each_with_object({}) { |d, h| h[d.slug] = d.to_fleet_json }
  end

  # A per-drone telemetry credential - deliberately separate from
  # DRONE_API_TOKEN, which also satisfies admin_access? (full fleet
  # management). This only ever authorizes posting telemetry for *this*
  # drone; app.rb never lets it near admin_access?/require_admin!.
  # SHA-256 (not bcrypt) matches BackupCode's own choice for the same
  # reason: a high-entropy generated token, not a human-memorized
  # password, so bcrypt's deliberate slowness buys nothing here.
  def self.hash_token(token)
    Digest::SHA256.hexdigest(token.to_s.strip)
  end

  def telemetry_token_valid?(provided)
    return false if token_digest.nil? || provided.to_s.strip.empty?

    self.class.hash_token(provided) == token_digest
  end
end

class FirmwareEvent < Sequel::Model
  many_to_one :drone

  MAX_FILE_SIZE = 8 * 1024 * 1024 # 8MB - generous for real embedded firmware images
  ALLOWED_EXTENSIONS = %w[.bin .hex].freeze
  KEEP_BLOBS_PER_DRONE = 10

  # The full from/to-version audit trail is kept forever (it's tiny, just
  # text); only the actual uploaded bytes are pruned, so a demo/small-scale
  # app doesn't accumulate unbounded binary storage from repeated flashes.
  # Mirrors StreamReading's self-limiting-on-write pattern.
  def self.prune_blobs!(drone_id)
    keep_ids = where(drone_id: drone_id)
               .exclude(data: nil)
               .reverse_order(:flashed_at)
               .limit(KEEP_BLOBS_PER_DRONE)
               .select_map(:id)
    return if keep_ids.empty?

    where(drone_id: drone_id).exclude(id: keep_ids).exclude(data: nil)
                              .update(data: nil, filename: nil, content_type: nil)
  end
end

class CommandEvent < Sequel::Model
  many_to_one :drone
end

# A named, ongoing telemetry channel per drone (e.g. "camera", "link_signal") -
# distinct from the drone's core state (lat/lon/battery/status), which lives
# directly on the drones table. Self-limiting like AssistantFeedback in the
# sibling app: each write prunes older rows for that (drone, stream) pair
# down to MAX_PER_STREAM, so this never needs a cron job to stay bounded.
class StreamReading < Sequel::Model
  many_to_one :drone

  MAX_PER_STREAM = 20

  # A 'live' stream (unlike a 'simulated' one, which the simulator keeps
  # fresh forever) has no guaranteed reporting cadence - a real drone could
  # stop sending for any reason. If its latest reading is older than this,
  # the fleet alerts panel flags the feed as stale rather than silently
  # keeping showing a last-known value with no indication it's gone quiet.
  LIVE_STALE_SECONDS = Integer(ENV['LIVE_STREAM_STALE_SECONDS'] || 120)

  # Ingestion limits for POST /api/drones/:slug/telemetry - generous enough
  # for a real sensor payload, tight enough that one bad client can't wedge
  # the fleet-wide broadcast or blow up storage with garbage stream names.
  MAX_STREAMS_PER_INGEST = 25
  MAX_NAME_LENGTH = 40
  MAX_VALUE_LENGTH = 100
  NAME_PATTERN = /\A[a-zA-Z0-9_.\-]{1,40}\z/

  def self.record!(drone, stream_name, value, source: 'simulated')
    create(drone_id: drone.id, stream_name: stream_name.to_s, value: value.to_s,
           source: source, recorded_at: Time.now)
    prune!(drone.id, stream_name)
  end

  def self.prune!(drone_id, stream_name)
    keep_ids = where(drone_id: drone_id, stream_name: stream_name)
               .reverse_order(:recorded_at)
               .limit(MAX_PER_STREAM)
               .select_map(:id)
    return if keep_ids.empty?

    where(drone_id: drone_id, stream_name: stream_name).exclude(id: keep_ids).delete
  end

  # => { "camera" => { value:, recorded_at:, source: }, "link_signal" => {...}, ... }
  def self.latest_for(drone_id)
    where(drone_id: drone_id)
      .reverse_order(:recorded_at)
      .all
      .group_by(&:stream_name)
      .transform_values { |rows| { value: rows.first.value, recorded_at: rows.first.recorded_at, source: rows.first.source } }
  end

  # Has a *live* (not simulated) reading landed for this drone+stream inside
  # the last `within` seconds? FleetSimulator checks this before faking a
  # tick for a stream so it doesn't fight a real drone that's actively
  # reporting - and resumes on its own once the real feed goes quiet.
  def self.live?(drone_id, stream_name, within:)
    where(drone_id: drone_id, stream_name: stream_name, source: 'live')
      .where { recorded_at > (Time.now - within) }
      .any?
  end

  # Oldest-first (chart-reading order), values parsed to Float by stripping
  # any non-numeric unit suffix (e.g. "-62dBm" => -62.0, "34°C" => 34.0).
  # => [{ value: 34.0, recorded_at: }, ...]
  def self.numeric_history_for(drone_id, stream_name)
    where(drone_id: drone_id, stream_name: stream_name)
      .order(:recorded_at)
      .all
      .map { |r| { value: r.value.to_s[/-?\d+(\.\d+)?/].to_f, recorded_at: r.recorded_at } }
  end
end

class User < Sequel::Model
  plugin :timestamps, update_on_create: true
  one_to_many :sessions
  one_to_many :backup_codes

  ROLES = %w[admin viewer].freeze

  def validate
    super
    errors.add(:email, 'cannot be empty') if email.nil? || email.strip.empty?
    errors.add(:password_digest, 'cannot be empty') if password_digest.nil? || password_digest.empty?
    errors.add(:role, "must be one of #{ROLES.join(', ')}") if role && !ROLES.include?(role)
  end

  def admin?
    role == 'admin'
  end

  # Assigning `password=` (rather than password_digest directly) is how
  # every caller - bin/create_user, the future admin-facing user management
  # this app doesn't have yet - sets a password, so it's never stored plain.
  def password=(plain)
    self.password_digest = BCrypt::Password.create(plain)
  end

  def authenticate(plain)
    return false if password_digest.to_s.empty?

    BCrypt::Password.new(password_digest) == plain
  rescue BCrypt::Errors::InvalidHash
    false
  end
end

class Session < Sequel::Model
  many_to_one :user
end

class BackupCode < Sequel::Model
  many_to_one :user

  def self.hash_code(code)
    Digest::SHA256.hexdigest(code.to_s.strip.downcase)
  end
end
