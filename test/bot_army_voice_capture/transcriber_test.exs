defmodule BotArmyVoiceCapture.TranscriberTest do
  use ExUnit.Case, async: false

  @moduletag :handlers

  describe "health/0" do
    test "returns health status from transcriber" do
      result = BotArmyVoiceCapture.Transcriber.health()
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :model)
    end
  end
end
