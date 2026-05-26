defmodule BotArmyVoiceCapture.Transcription do
  @moduledoc """
  Transcription result from Whisper inference.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          source: atom(),
          text: String.t(),
          language: String.t(),
          confidence: float(),
          duration_ms: integer(),
          transcribed_at: String.t(),
          segments: [BotArmyVoiceCapture.TranscriptionSegment.t()]
        }

  defstruct [
    :id,
    :source,
    :text,
    :language,
    :confidence,
    :duration_ms,
    :transcribed_at,
    segments: []
  ]

  def from_whisper_result(result, source) do
    %__MODULE__{
      id: UUID.uuid4(),
      source: source,
      text: Map.get(result, "text", ""),
      language: Map.get(result, "language", "en"),
      confidence: Map.get(result, "confidence", 0.0),
      duration_ms: Map.get(result, "duration_ms", 0),
      transcribed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      segments:
        Enum.map(
          Map.get(result, "segments", []),
          &BotArmyVoiceCapture.TranscriptionSegment.from_map/1
        )
    }
  end

  def to_map(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "source" => to_string(t.source),
      "text" => t.text,
      "language" => t.language,
      "confidence" => t.confidence,
      "duration_ms" => t.duration_ms,
      "transcribed_at" => t.transcribed_at,
      "segments" => Enum.map(t.segments, &BotArmyVoiceCapture.TranscriptionSegment.to_map/1)
    }
  end
end

defmodule BotArmyVoiceCapture.TranscriptionSegment do
  @moduledoc """
  Individual segment within a transcription.
  """

  @type t :: %__MODULE__{
          start_ms: integer(),
          end_ms: integer(),
          text: String.t(),
          confidence: float()
        }

  defstruct [:start_ms, :end_ms, :text, :confidence]

  def from_map(map) when is_map(map) do
    %__MODULE__{
      start_ms: Map.get(map, "start_ms", 0),
      end_ms: Map.get(map, "end_ms", 0),
      text: Map.get(map, "text", ""),
      confidence: Map.get(map, "confidence", 0.0)
    }
  end

  def to_map(%__MODULE__{} = seg) do
    %{
      "start_ms" => seg.start_ms,
      "end_ms" => seg.end_ms,
      "text" => seg.text,
      "confidence" => seg.confidence
    }
  end
end
