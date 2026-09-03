import Config

nats_host = System.get_env("NATS_HOST") || "localhost"
nats_port = String.to_integer(System.get_env("NATS_PORT") || "4223")

config :bot_army_library_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000

if config_env() != :test do
  config :bot_army_voice_capture, :http,
    enabled: System.get_env("BOT_ARMY_VOICE_CAPTURE_HTTP_ENABLED") in ~w(1 true yes),
    port: String.to_integer(System.get_env("BOT_ARMY_VOICE_CAPTURE_HTTP_PORT") || "39901"),
    ip: {0, 0, 0, 0},
    auth_token: System.get_env("BOT_ARMY_VOICE_CAPTURE_HTTP_TOKEN")
end
