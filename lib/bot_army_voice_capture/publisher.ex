defmodule BotArmyVoiceCapture.Publisher do
  @moduledoc """
  NATS publisher for voice transcription events.

  Publishes to:
  - voice.transcription.raw (every transcription)
  - voice.transcription.{source} (source-scoped)
  - voice.status (health heartbeat)
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def publish_transcription(%BotArmyVoiceCapture.Transcription{} = transcription) do
    GenServer.cast(__MODULE__, {:publish_transcription, transcription})
  end

  def publish_transcription_async(transcription_map, source) when is_map(transcription_map) do
    GenServer.cast(__MODULE__, {:publish_raw, transcription_map, source})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:publish_transcription, transcription}, state) do
    payload = BotArmyVoiceCapture.Transcription.to_map(transcription)
    source = transcription.source

    publish("voice.transcription.raw", payload)
    publish("voice.transcription.#{source}", payload)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:publish_raw, payload, source}, state) do
    publish("voice.transcription.raw", payload)
    publish("voice.transcription.#{source}", payload)
    {:noreply, state}
  end

  defp publish(subject, payload) do
    case BotArmyRuntime.NATS.Publisher.publish(subject, payload) do
      {:ok, _} ->
        Logger.debug("[Publisher] Published to #{subject}")

      {:error, reason} ->
        Logger.warning("[Publisher] Failed to publish to #{subject}: #{inspect(reason)}")
    end
  end
end
