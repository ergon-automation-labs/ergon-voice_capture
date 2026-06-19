defmodule BotArmyVoiceCapture.Http.Router do
  @moduledoc """
  HTTP surface for STT transcription requests.

  Accepts audio from G2 companion apps and returns transcriptions.

  ## Routes

  - `POST /v1/transcribe` — Transcribe audio (binary PCM/WAV or JSON with base64)
  - `GET /health` — Liveness check

  ## Enabling

  Set `BOT_ARMY_VOICE_CAPTURE_HTTP_ENABLED=true` and optionally
  `BOT_ARMY_VOICE_CAPTURE_HTTP_PORT` (default 39901).

  ## Auth (optional)

  Set `BOT_ARMY_VOICE_CAPTURE_HTTP_TOKEN`; clients must send `Authorization: Bearer <token>`.
  """

  use Plug.Router
  require Logger

  plug(:verify_token)
  plug(Plug.Logger)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [{:json, json_decoder: Jason}],
    pass: ["application/json"],
    length: 25_000_000
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/v1/transcribe" do
    source = get_source(conn)
    content_type = Plug.Conn.get_req_header(conn, "content-type") |> List.first() || ""

    result =
      cond do
        String.starts_with?(content_type, "application/json") ->
          handle_json_request(conn, source)

        true ->
          handle_binary_request(conn, source, content_type)
      end

    send_response(conn, result)
  end

  match _ do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      404,
      Jason.encode!(%{"error" => %{"type" => "not_found", "message" => "Not found"}})
    )
  end

  defp handle_json_request(conn, source) do
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}

    case body do
      %{"audio_base64" => b64} when is_binary(b64) ->
        _format = Map.get(body, "format", "pcm")
        sample_rate = Map.get(body, "sample_rate", 16_000)

        case Base.decode64(b64) do
          {:ok, pcm_data} ->
            transcribe_pcm(pcm_data, sample_rate, source)

          :error ->
            {:error, :invalid_base64}
        end

      _ ->
        {:error, :missing_audio_base64}
    end
  end

  defp handle_binary_request(conn, source, content_type) do
    # For binary content types, Plug.Parsers passes through — read body directly
    case Plug.Conn.read_body(conn, length: 25_000_000, read_length: 1_048_576) do
      {:ok, body, _conn2} when byte_size(body) > 0 ->
        if String.contains?(content_type, "wav") or binary_starts_with_wav?(body) do
          transcribe_wav_binary(body, source)
        else
          transcribe_pcm(body, 16_000, source)
        end

      _ ->
        {:error, :empty_body}
    end
  end

  defp transcribe_pcm(pcm_data, sample_rate, source) do
    case BotArmyVoiceCapture.Transcriber.transcribe_pcm(pcm_data, sample_rate: sample_rate) do
      {:ok, result} ->
        transcription = BotArmyVoiceCapture.Transcription.from_whisper_result(result, source)
        BotArmyVoiceCapture.Publisher.publish_transcription(transcription)
        {:ok, BotArmyVoiceCapture.Transcription.to_map(transcription)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transcribe_wav_binary(wav_data, source) do
    tmp_path =
      Path.join(System.tmp_dir!(), "voice_capture_#{:erlang.unique_integer([:positive])}.wav")

    case File.write(tmp_path, wav_data) do
      :ok ->
        try do
          case BotArmyVoiceCapture.Transcriber.transcribe(tmp_path) do
            {:ok, result} ->
              transcription =
                BotArmyVoiceCapture.Transcription.from_whisper_result(result, source)

              BotArmyVoiceCapture.Publisher.publish_transcription(transcription)
              {:ok, BotArmyVoiceCapture.Transcription.to_map(transcription)}

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.rm(tmp_path)
        end

      {:error, reason} ->
        {:error, {:tmp_write_failed, reason}}
    end
  end

  defp get_source(conn) do
    case Plug.Conn.get_req_header(conn, "x-source") do
      [source] when is_binary(source) and source != "" ->
        String.to_atom(String.trim(source))

      _ ->
        :g2_bridge
    end
  end

  defp binary_starts_with_wav?(<<0x52, 0x49, 0x46, 0x46, _::binary>>), do: true
  defp binary_starts_with_wav?(_), do: false

  defp send_response(conn, {:ok, data}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(data))
  end

  defp send_response(conn, {:error, :invalid_base64}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      400,
      Jason.encode!(%{
        "error" => %{
          "type" => "invalid_base64",
          "message" => "Could not decode base64 audio data"
        }
      })
    )
  end

  defp send_response(conn, {:error, :missing_audio_base64}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      400,
      Jason.encode!(%{
        "error" => %{
          "type" => "missing_audio",
          "message" => "Request must include audio_base64 field or binary audio body"
        }
      })
    )
  end

  defp send_response(conn, {:error, :empty_body}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      400,
      Jason.encode!(%{"error" => %{"type" => "empty_body", "message" => "Request body is empty"}})
    )
  end

  defp send_response(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      500,
      Jason.encode!(%{"error" => %{"type" => "transcription_failed", "message" => reason}})
    )
  end

  defp send_response(conn, {:error, %{"message" => msg, "code" => code}}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(500, Jason.encode!(%{"error" => %{"type" => code, "message" => msg}}))
  end

  defp send_response(conn, {:error, reason}) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(
      500,
      Jason.encode!(%{"error" => %{"type" => "internal_error", "message" => inspect(reason)}})
    )
  end

  defp verify_token(conn, _opts) do
    cfg = Application.get_env(:bot_army_voice_capture, :http, [])
    expected = Keyword.get(cfg, :auth_token)

    if is_binary(expected) and expected != "" do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when token == expected ->
          conn

        _ ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(
            401,
            Jason.encode!(%{
              "error" => %{
                "type" => "unauthorized",
                "message" => "Invalid or missing bearer token"
              }
            })
          )
          |> halt()
      end
    else
      conn
    end
  end
end
