defmodule BotArmyVoiceCapture.TranscriptionTest do
  use ExUnit.Case, async: true

  @moduletag :core

  alias BotArmyVoiceCapture.{Transcription, TranscriptionSegment}

  describe "Transcription.from_whisper_result/2" do
    test "converts whisper result map to Transcription struct" do
      result = %{
        "text" => "Hello, turn on the lights",
        "language" => "en",
        "confidence" => 0.95,
        "duration_ms" => 3200,
        "segments" => [
          %{
            "start_ms" => 0,
            "end_ms" => 3200,
            "text" => "Hello, turn on the lights",
            "confidence" => 0.95
          }
        ]
      }

      t = Transcription.from_whisper_result(result, :g2_bridge)

      assert t.source == :g2_bridge
      assert t.text == "Hello, turn on the lights"
      assert t.language == "en"
      assert t.confidence == 0.95
      assert t.duration_ms == 3200
      assert length(t.segments) == 1
      assert byte_size(t.id) > 0
    end

    test "handles missing segments gracefully" do
      result = %{"text" => "Hi", "language" => "en"}
      t = Transcription.from_whisper_result(result, :mic)
      assert t.segments == []
    end
  end

  describe "Transcription.to_map/1" do
    test "serializes struct to map with string keys" do
      t = %Transcription{
        id: "test-id",
        source: :g2_bridge,
        text: "Hello",
        language: "en",
        confidence: 0.9,
        duration_ms: 1000,
        transcribed_at: "2026-05-25T10:00:00Z",
        segments: []
      }

      m = Transcription.to_map(t)
      assert m["id"] == "test-id"
      assert m["source"] == "g2_bridge"
      assert m["text"] == "Hello"
    end
  end

  describe "TranscriptionSegment" do
    test "from_map/1 creates segment from map" do
      map = %{"start_ms" => 100, "end_ms" => 500, "text" => "word", "confidence" => 0.8}
      seg = TranscriptionSegment.from_map(map)
      assert seg.start_ms == 100
      assert seg.end_ms == 500
    end

    test "to_map/1 serializes segment" do
      seg = %TranscriptionSegment{start_ms: 0, end_ms: 100, text: "hi", confidence: 0.9}
      m = TranscriptionSegment.to_map(seg)
      assert m["start_ms"] == 0
      assert m["text"] == "hi"
    end
  end
end
