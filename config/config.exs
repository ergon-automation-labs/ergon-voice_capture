import Config

if File.exists?(".env") do
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
