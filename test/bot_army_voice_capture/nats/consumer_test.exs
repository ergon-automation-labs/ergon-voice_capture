defmodule BotArmyVoiceCapture.NATS.ConsumerTest do
  use ExUnit.Case, async: false

  @moduletag :nats

  describe "subject definitions" do
    test "voice.transcribe is registered as request_reply" do
      subjects = BotArmyVoiceCapture.NATS.Consumer.subjects()
      transcribe = Enum.find(subjects, &(&1.subject == "voice.transcribe"))
      assert transcribe != nil
      assert transcribe.type == :request_reply
    end

    test "health subject is registered" do
      subjects = BotArmyVoiceCapture.NATS.Consumer.subjects()
      health = Enum.find(subjects, &(&1.subject == "system.health.voice_capture"))
      assert health != nil
    end
  end
end
