defmodule Mydia.RemoteAccess.MessageEncoderTest do
  use ExUnit.Case, async: true

  alias Mydia.RemoteAccess.MessageEncoder

  describe "encode_body/1" do
    test "encodes UTF-8 string as raw" do
      result = MessageEncoder.encode_body("Hello, world!")
      assert result == %{body: "Hello, world!", body_encoding: "raw"}
    end

    test "encodes UTF-8 string with unicode as raw" do
      result = MessageEncoder.encode_body("Hello, 世界! 🌍")
      assert result == %{body: "Hello, 世界! 🌍", body_encoding: "raw"}
    end

    test "encodes binary data as base64" do
      binary = <<0, 1, 2, 255>>
      result = MessageEncoder.encode_body(binary)
      assert result == %{body: "AAEC/w==", body_encoding: "base64"}
    end

    test "encodes nil as nil with raw encoding" do
      result = MessageEncoder.encode_body(nil)
      assert result == %{body: nil, body_encoding: "raw"}
    end

    test "encodes empty string as raw" do
      result = MessageEncoder.encode_body("")
      assert result == %{body: "", body_encoding: "raw"}
    end

    test "encodes invalid UTF-8 binary as base64" do
      # Create a binary with invalid UTF-8 byte sequence (0xFF is never valid in UTF-8)
      binary = <<104, 101, 108, 108, 111, 255, 119, 111, 114, 108, 100>>
      result = MessageEncoder.encode_body(binary)
      assert result.body_encoding == "base64"
      assert Base.decode64!(result.body) == binary
    end

    test "encodes null bytes in UTF-8 string as raw" do
      # Null bytes are valid in Elixir strings (just not in C-style strings)
      binary = "hello\0world"
      result = MessageEncoder.encode_body(binary)
      assert result.body_encoding == "raw"
      assert result.body == binary
    end

    test "encodes map as JSON string with raw encoding" do
      # Req returns JSON responses as maps - should encode as JSON
      body = %{"error" => "Unauthorized", "message" => "Invalid token"}
      result = MessageEncoder.encode_body(body)
      assert result.body_encoding == "raw"
      assert result.body == ~s({"error":"Unauthorized","message":"Invalid token"})
    end
  end

  describe "decode_body/1 with string keys" do
    test "decodes raw encoding" do
      result = MessageEncoder.decode_body(%{"body" => "Hello", "body_encoding" => "raw"})
      assert result == "Hello"
    end

    test "decodes base64 encoding" do
      result = MessageEncoder.decode_body(%{"body" => "AAEC/w==", "body_encoding" => "base64"})
      assert result == <<0, 1, 2, 255>>
    end

    test "decodes nil body" do
      result = MessageEncoder.decode_body(%{"body" => nil, "body_encoding" => "raw"})
      assert result == nil
    end

    test "handles legacy messages without encoding field (assumes raw)" do
      result = MessageEncoder.decode_body(%{"body" => "Legacy message"})
      assert result == "Legacy message"
    end
  end

  describe "decode_body/1 with atom keys" do
    test "decodes raw encoding with atom keys" do
      result = MessageEncoder.decode_body(%{body: "Hello", body_encoding: "raw"})
      assert result == "Hello"
    end

    test "decodes base64 encoding with atom keys" do
      result = MessageEncoder.decode_body(%{body: "AAEC/w==", body_encoding: "base64"})
      assert result == <<0, 1, 2, 255>>
    end

    test "handles messages without encoding field with atom keys (assumes raw)" do
      result = MessageEncoder.decode_body(%{body: "Legacy message"})
      assert result == "Legacy message"
    end
  end

  describe "round-trip encoding/decoding" do
    test "UTF-8 text survives round-trip" do
      original = "Hello, 世界! 🌍"
      encoded = MessageEncoder.encode_body(original)
      decoded = MessageEncoder.decode_body(encoded)
      assert decoded == original
    end

    test "binary data survives round-trip" do
      original = <<0, 1, 2, 128, 255>>
      encoded = MessageEncoder.encode_body(original)
      decoded = MessageEncoder.decode_body(encoded)
      assert decoded == original
    end

    test "nil survives round-trip" do
      encoded = MessageEncoder.encode_body(nil)
      decoded = MessageEncoder.decode_body(encoded)
      assert decoded == nil
    end
  end
end
