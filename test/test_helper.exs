ExUnit.start(exclude: [:integration])

# Stub Transcriber for unit tests (not integration)
unless System.get_env("VOICE_CAPTURE_ENABLE_WHISPER") in ~w(1 true yes) do
  defmodule BotArmyVoiceCapture.Transcriber do
    @moduledoc false
    def transcribe(_audio_path, _opts \\ []), do: {:ok, mock_result()}
    def transcribe_pcm(_pcm_data, _opts \\ []), do: {:ok, mock_result()}
    def health, do: %{status: :ready, model: "test"}

    defp mock_result do
      %{
        "text" => "test transcription",
        "language" => "en",
        "confidence" => 0.95,
        "duration_ms" => 1000,
        "segments" => []
      }
    end
  end
end
