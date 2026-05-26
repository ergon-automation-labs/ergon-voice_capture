import Config

config :bot_army_library_runtime, :nats_disabled, true

config :bot_army_voice_capture, :http,
  enabled: false,
  port: 39901,
  ip: {127, 0, 0, 1},
  auth_token: nil

config :bot_army_voice_capture,
  whisper_model: "medium.en",
  sample_rate: 16_000

config :logger, level: :warning
