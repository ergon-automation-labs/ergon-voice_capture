defmodule BotArmyVoiceCapture.Application do
  @moduledoc """
  Voice Capture Bot application supervisor.

  Manages the Whisper inference pipeline and HTTP endpoint for
  G2 companion app STT requests.

  Children (production):
  - Transcriber (Erlang Port to whisper_server.py)
  - Publisher (NATS event publisher)
  - NATS Consumer (voice.transcribe request/reply)
  - PulsePublisher (health heartbeats)
  - Bandit HTTP server (conditional, for G2 companion app)

  Children (test):
  - Only Transcriber is started when VOICE_CAPTURE_ENABLE_WHISPER=1
  - Other services are gated by @env
  """

  use Application

  @env Mix.env()
  @dialyzer {:nowarn_function,
             [maybe_add_publisher: 1, maybe_add_consumer: 1, maybe_add_pulse_publisher: 1]}

  @impl true
  def start(_type, _args) do
    # Note: BotArmyRuntime.Telemetry and BotArmyRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_transcriber()
      |> maybe_add_publisher()
      |> maybe_add_consumer()
      |> maybe_add_pulse_publisher()
      |> maybe_add_http()

    opts = [strategy: :one_for_one, name: BotArmyVoiceCapture.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_transcriber(children) do
    # Skip Transcriber in test unless explicitly enabled (requires Python/MLX)
    if @env == :test and System.get_env("VOICE_CAPTURE_ENABLE_WHISPER") not in ~w(1 true yes) do
      children
    else
      [{BotArmyVoiceCapture.Transcriber, []} | children]
    end
  end

  defp maybe_add_publisher(children) do
    # dialyzer:ignore
    if @env == :test do
      children
    else
      [{BotArmyVoiceCapture.Publisher, []} | children]
    end
  end

  defp maybe_add_consumer(children) do
    # dialyzer:ignore
    if @env == :test do
      children
    else
      [{BotArmyVoiceCapture.NATS.Consumer, []} | children]
    end
  end

  defp maybe_add_pulse_publisher(children) do
    # dialyzer:ignore
    if @env == :test do
      children
    else
      [{BotArmyVoiceCapture.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_http(children) do
    cfg = Application.get_env(:bot_army_voice_capture, :http, [])

    if Keyword.get(cfg, :enabled, false) do
      port = Keyword.fetch!(cfg, :port)
      ip = Keyword.get(cfg, :ip, {0, 0, 0, 0})

      bandit =
        {Bandit, plug: BotArmyVoiceCapture.Http.Router, scheme: :http, port: port, ip: ip}

      children ++ [bandit]
    else
      children
    end
  end
end
