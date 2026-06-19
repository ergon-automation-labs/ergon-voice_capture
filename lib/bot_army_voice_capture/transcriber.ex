defmodule BotArmyVoiceCapture.Transcriber do
  @dialyzer {:nowarn_function, [open_python_port: 1]}

  @moduledoc """
  GenServer managing a Python Whisper inference process via Erlang Port.

  Communicates with whisper_server.py using line-delimited JSON over stdin/stdout.
  The Python process is stateless — it loads the model at startup and handles
  transcription commands. If the port exits, this GenServer restarts it with
  exponential backoff.
  """

  use GenServer
  require Logger

  @default_timeout_ms 30_000
  @backoff_min_ms 1_000
  @backoff_max_ms 60_000
  @ready_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def transcribe(audio_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    GenServer.call(__MODULE__, {:transcribe, audio_path}, timeout)
  end

  def transcribe_pcm(pcm_data, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    sample_rate = Keyword.get(opts, :sample_rate, 16_000)
    GenServer.call(__MODULE__, {:transcribe_pcm, pcm_data, sample_rate}, timeout)
  end

  def health do
    GenServer.call(__MODULE__, :health, 5_000)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    model =
      Keyword.get(
        opts,
        :model,
        Application.get_env(:bot_army_voice_capture, :whisper_model, "medium.en")
      )

    state = %{
      port: nil,
      model: model,
      backoff: @backoff_min_ms,
      pending: nil,
      buffer: "",
      health: :starting,
      ready_timer: nil
    }

    {:ok, state, {:continue, :open_port}}
  end

  @impl true
  def handle_continue(:open_port, state) do
    case open_python_port(state.model) do
      {:ok, port} ->
        # Wait for ready signal from Python process
        ready_ref = Process.send_after(self(), :ready_timeout, @ready_timeout_ms)
        {:noreply, %{state | port: port, backoff: @backoff_min_ms, ready_timer: ready_ref}}

      {:error, reason} ->
        Logger.error("[Transcriber] Failed to open Python port: #{inspect(reason)}")
        schedule_restart(state.backoff)
        {:noreply, %{state | health: :down, backoff: min(state.backoff * 2, @backoff_max_ms)}}
    end
  end

  @impl true
  def handle_call({:transcribe, audio_path}, from, state) do
    case state.health do
      :ready ->
        send_command(state.port, %{"command" => "transcribe", "audio_path" => audio_path})
        {:noreply, %{state | pending: from}}

      status ->
        {:reply, {:error, "Transcriber not ready: #{status}"}, state}
    end
  end

  @impl true
  def handle_call({:transcribe_pcm, pcm_data, sample_rate}, from, state) do
    case state.health do
      :ready ->
        # Encode binary data as base64 for JSON transport
        encoded = Base.encode64(pcm_data)

        send_command(state.port, %{
          "command" => "transcribe_pcm",
          "data" => encoded,
          "sample_rate" => sample_rate
        })

        {:noreply, %{state | pending: from}}

      status ->
        {:reply, {:error, "Transcriber not ready: #{status}"}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, %{status: state.health, model: state.model}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_port_line(state, line)
  end

  @impl true
  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> partial}}
  end

  @impl true
  def handle_info(:ready_timeout, state) do
    if state.health == :starting do
      Logger.warning("[Transcriber] Ready timeout — Python process did not signal ready")
      {:noreply, %{state | health: :down}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:restart_port, state) do
    {:noreply, state, {:continue, :open_port}}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("[Transcriber] Python port exited: #{inspect(reason)}")

    # Reply to pending caller if any
    state = reply_pending(state, {:error, "Python process exited: #{inspect(reason)}"})
    schedule_restart(state.backoff)

    {:noreply,
     %{
       state
       | port: nil,
         health: :down,
         pending: nil,
         backoff: min(state.backoff * 2, @backoff_max_ms)
     }}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp open_python_port(model) do
    priv_dir = :code.priv_dir(:bot_army_voice_capture)
    script = Path.join([priv_dir, "python", "whisper_server.py"])
    python = System.find_executable("python3") || System.find_executable("python")

    cond do
      is_nil(python) ->
        {:error, :python_not_found}

      true ->
        args = [script, "--model", model]

        port =
          Port.open({:spawn_executable, python}, [
            {:args, args},
            :binary,
            :exit_status,
            {:line, 4096},
            :use_stdio,
            :stderr_to_std_err
          ])

        {:ok, port}
    end
  end

  defp send_command(port, command) do
    json = Jason.encode!(command)
    Port.command(port, json <> "\n")
  end

  defp handle_port_line(state, line) do
    # If we have buffered data, prepend it
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(full_line) do
      {:ok, %{"type" => "ready"} = msg} ->
        model = Map.get(msg, "model", state.model)
        Logger.info("[Transcriber] Whisper server ready (model: #{model})")

        # Cancel ready timeout timer
        if state.ready_timer, do: Process.cancel_timer(state.ready_timer)
        {:noreply, %{state | health: :ready, model: model, ready_timer: nil}}

      {:ok, %{"type" => "pong"}} ->
        # Pong response, no action needed
        {:noreply, state}

      {:ok, %{"type" => "result"} = result} ->
        state = reply_pending(state, {:ok, result})
        {:noreply, %{state | pending: nil}}

      {:ok, %{"type" => "error"} = error} ->
        state = reply_pending(state, {:error, error})
        {:noreply, %{state | pending: nil}}

      {:ok, other} ->
        Logger.debug("[Transcriber] Unexpected port message: #{inspect(other)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Transcriber] Failed to decode port line: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp reply_pending(state, reply) do
    if state.pending do
      GenServer.reply(state.pending, reply)
    end

    state
  end

  defp schedule_restart(delay_ms) do
    Logger.info("[Transcriber] Restarting port in #{delay_ms}ms")
    Process.send_after(self(), :restart_port, delay_ms)
  end
end
