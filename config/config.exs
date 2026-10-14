import Config
# Load .env for local development — never under :test. `.env` is gitignored and carries
# `NATS_PORT=4222`; `System.put_env/2` writes the VM's own env table, which is exactly
# what `Connection.pick_servers/2` reads (opts -> app config -> env -> default), so a
# shell-exported `NATS_PORT=42991` is overwritten *inside the VM* and cannot save a run.
# On 2026-10-13 a `mix test` in `bot_army_fitness` published a real
# `gossip.social.invite` into gtd's production log that way.
# docs/runbooks/KNOWN_ISSUE_DOTENV_IN_VM_OVERRIDES_THE_TEST_BROKER.md
if config_env() != :test and File.exists?(".env") do
  File.stream!(".env")
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

config :bot_army_voice_capture,
  whisper_model: System.get_env("WHISPER_MODEL") || "medium.en",
  sample_rate: 16_000,
  max_utterance_duration_ms: 15_000,
  default_source: :g2_bridge

config :logger, :console, metadata: [:source, :subject, :latency_ms, :reason, :bot_name]

if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
