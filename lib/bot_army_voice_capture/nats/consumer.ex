defmodule BotArmyVoiceCapture.NATS.Consumer do
  @moduledoc """
  NATS message consumer for Voice Capture Bot.

  Subscribes to request/reply on `voice.transcribe` for internal
  Bot Army consumers to request transcription services.

  All request/reply handlers return responses using Reply helpers:
  - BotArmyRuntime.NATS.Reply.ok(data) for success
  - BotArmyRuntime.NATS.Reply.error(message, code) for errors
  """

  use GenServer
  require Logger

  alias BotArmyVoiceCapture.{Transcriber, Transcription, Publisher}

  @reconnect_delay_ms 5_000
  @registry_heartbeat_ms 40_000
  @version Mix.Project.config()[:version]

  @subjects [
    %{
      subject: "voice.transcribe",
      type: :request_reply,
      description: "Transcribe audio (base64 PCM or WAV path)"
    },
    %{subject: "system.health.voice_capture", type: :publish, description: "Health pulse"}
  ]

  def subjects, do: @subjects

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[Consumer] Starting Voice Capture NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[Consumer] Connected to NATS, subscribing to topics")

        subscriptions =
          [
            "voice.transcribe"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[Consumer] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error("[Consumer] Failed to subscribe to #{subject}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        BotArmyRuntime.Registry.register("voice_capture", @subjects, @version)
        send(self(), :registry_heartbeat)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[Consumer] NATS connection not ready, will retry")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      Logger.debug("[Consumer] Received NATS message on subject: #{msg.topic}")

      if msg.reply_to do
        case msg.topic do
          "voice.transcribe" ->
            handle_transcribe(msg, state)

          _ ->
            Logger.debug("[Consumer] Unknown request/reply subject: #{msg.topic}")
        end
      else
        case BotArmyCore.NATS.Decoder.decode(msg.body) do
          {:ok, decoded} ->
            route_message(decoded, msg.topic)

          {:error, reason} ->
            Logger.warning(
              "[Consumer] Failed to decode message from #{msg.topic}: #{inspect(reason)}"
            )
        end
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      BotArmyRuntime.Registry.register("voice_capture", @subjects, @version)
    end

    Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[Consumer] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[Consumer] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Request/reply handlers
  # ============================================================================

  defp handle_transcribe(msg, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, %{"audio_base64" => b64} = payload} ->
        _format = Map.get(payload, "format", "pcm")
        sample_rate = Map.get(payload, "sample_rate", 16_000)
        source = Map.get(payload, "source", "g2_bridge") |> maybe_to_atom()

        case Base.decode64(b64) do
          {:ok, pcm_data} ->
            case Transcriber.transcribe_pcm(pcm_data, sample_rate: sample_rate) do
              {:ok, result} ->
                transcription = Transcription.from_whisper_result(result, source)
                Publisher.publish_transcription(transcription)
                reply = BotArmyRuntime.NATS.Reply.ok(Transcription.to_map(transcription))
                Gnat.pub(state.conn, msg.reply_to, reply)

              {:error, error} ->
                reply =
                  BotArmyRuntime.NATS.Reply.error(
                    "Transcription failed: #{inspect(error)}",
                    :transcription_failed
                  )

                Gnat.pub(state.conn, msg.reply_to, reply)
            end

          :error ->
            reply = BotArmyRuntime.NATS.Reply.error("Invalid base64 audio data", :invalid_base64)
            Gnat.pub(state.conn, msg.reply_to, reply)
        end

      {:ok, %{"audio_path" => path} = payload} ->
        source = Map.get(payload, "source", "g2_bridge") |> maybe_to_atom()

        case Transcriber.transcribe(path) do
          {:ok, result} ->
            transcription = Transcription.from_whisper_result(result, source)
            Publisher.publish_transcription(transcription)
            reply = BotArmyRuntime.NATS.Reply.ok(Transcription.to_map(transcription))
            Gnat.pub(state.conn, msg.reply_to, reply)

          {:error, error} ->
            reply =
              BotArmyRuntime.NATS.Reply.error(
                "Transcription failed: #{inspect(error)}",
                :transcription_failed
              )

            Gnat.pub(state.conn, msg.reply_to, reply)
        end

      {:ok, _} ->
        reply =
          BotArmyRuntime.NATS.Reply.error("Missing audio_base64 or audio_path", :missing_audio)

        Gnat.pub(state.conn, msg.reply_to, reply)

      {:error, reason} ->
        reply =
          BotArmyRuntime.NATS.Reply.error(
            "Failed to decode request: #{inspect(reason)}",
            :decode_error
          )

        Gnat.pub(state.conn, msg.reply_to, reply)
    end
  end

  defp route_message(_message, topic) do
    Logger.debug("[Consumer] Routing message from #{topic} (no handler)")
  end

  defp maybe_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> String.to_atom(str)
    end
  end

  defp maybe_to_atom(atom) when is_atom(atom), do: atom
end
