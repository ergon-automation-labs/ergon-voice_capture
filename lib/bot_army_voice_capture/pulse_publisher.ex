defmodule BotArmyVoiceCapture.PulsePublisher do
  @moduledoc """
  Periodic health publisher for Voice Capture Bot.

  Two channels:
  1. `system.health.voice_capture` — lightweight liveness every 30s
  2. `bot.voice_capture.pulse` — richer metrics every 30 minutes
  """

  use GenServer
  require Logger

  @health_interval_ms 30 * 1000
  @publish_interval_ms 30 * 60 * 1000
  @service_name "voice_capture"
  @envelope_source "bot_army_voice_capture"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Voice Capture pulse publisher")
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    send(self(), :publish_health)
    send(self(), :publish_pulse)
    {:ok, %{started_at: started_at, transcription_count: 0}}
  end

  @impl true
  def handle_info(:publish_health, state) do
    Task.start(fn -> publish_system_health(state) end)
    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse(state) end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_transcription, _transcription}, state) do
    {:noreply, %{state | transcription_count: state.transcription_count + 1}}
  end

  defp publish_pulse(state) do
    signal = health_signal()

    pulse = %{
      service: @service_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      health: signal,
      metrics: %{
        transcription_count: state.transcription_count,
        uptime_seconds:
          DateTime.diff(
            DateTime.utc_now() |> DateTime.truncate(:second),
            state.started_at,
            :second
          )
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("bot.#{@service_name}.pulse", pulse) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published pulse: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
    end
  end

  defp publish_system_health(%{started_at: started_at} = _state) do
    tenant_id = System.get_env("BOT_ARMY_TENANT_ID") || BotArmyRuntime.Tenant.default_tenant_id()
    signal = health_signal()

    uptime_seconds =
      DateTime.diff(DateTime.utc_now() |> DateTime.truncate(:second), started_at, :second)

    case BotArmyRuntime.SynapseHealth.publish(
           source: @envelope_source,
           service: @service_name,
           tenant_id: tenant_id,
           health_signal: signal,
           uptime_seconds: max(uptime_seconds, 0)
         ) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published system.health: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish system.health: #{inspect(reason)}")
    end
  end

  defp health_signal do
    case BotArmyVoiceCapture.Transcriber.health() do
      %{status: :ready} -> :nominal
      %{status: :starting} -> :degraded
      %{status: :down} -> :critical
      _ -> :degraded
    end
  end
end
