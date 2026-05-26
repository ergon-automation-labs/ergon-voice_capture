defmodule BotArmyVoiceCapture.Http.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @moduletag :http

  alias BotArmyVoiceCapture.Http.Router

  @opts Router.init([])

  describe "GET /health" do
    test "returns 200 ok" do
      conn = conn(:get, "/health") |> Router.call(@opts)
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "POST /v1/transcribe with JSON" do
    test "returns 400 when audio_base64 is missing" do
      conn =
        conn(:post, "/v1/transcribe", %{"format" => "pcm"})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert %{"error" => %{"type" => "missing_audio"}} = body
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = conn(:get, "/unknown") |> Router.call(@opts)
      assert conn.status == 404
    end
  end
end
