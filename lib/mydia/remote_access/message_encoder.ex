defmodule Mydia.RemoteAccess.MessageEncoder do
  @moduledoc """
  Binary content encoding for control plane messages.

  Provides encoding/decoding of message bodies with automatic detection
  of binary vs UTF-8 content. This enables future transmission of binary
  data (thumbnails, encrypted blobs) through the relay control plane.

  ## Encoding Format

  Messages include a `body_encoding` field:
  - `"raw"` - Body is UTF-8 text (default, most common)
  - `"base64"` - Body is base64-encoded binary data

  ## Usage

      # Encoding (automatically detects content type)
      text_result = MessageEncoder.encode_body("Hello, world!")
      # => %{body: "Hello, world!", body_encoding: "raw"}

      binary_result = MessageEncoder.encode_body(<<0, 1, 2, 255>>)
      # => %{body: "AAEC/w==", body_encoding: "base64"}

      # Decoding (handles both formats)
      MessageEncoder.decode_body(%{"body" => "Hello", "body_encoding" => "raw"})
      # => "Hello"

      MessageEncoder.decode_body(%{"body" => "AAEC/w==", "body_encoding" => "base64"})
      # => <<0, 1, 2, 255>>

      # Backwards compatible - assumes raw if no encoding specified
      MessageEncoder.decode_body(%{"body" => "Legacy message"})
      # => "Legacy message"
  """

  @doc """
  Encodes a response body, detecting binary content.

  Returns a map with `body` and `body_encoding` fields.
  UTF-8 valid strings are encoded as "raw", binary data as "base64".

  ## Parameters

  - `body` - The body content to encode (binary or nil)

  ## Returns

  A map with:
  - `body` - The encoded body (string or nil)
  - `body_encoding` - Either "raw" or "base64"

  ## Examples

      iex> MessageEncoder.encode_body("Hello")
      %{body: "Hello", body_encoding: "raw"}

      iex> MessageEncoder.encode_body(<<0, 255>>)
      %{body: "AP8=", body_encoding: "base64"}

      iex> MessageEncoder.encode_body(nil)
      %{body: nil, body_encoding: "raw"}
  """
  @spec encode_body(binary() | map() | nil) :: %{
          body: String.t() | nil,
          body_encoding: String.t()
        }
  def encode_body(body) when is_binary(body) do
    if String.valid?(body) do
      %{body: body, body_encoding: "raw"}
    else
      %{body: Base.encode64(body), body_encoding: "base64"}
    end
  end

  def encode_body(body) when is_map(body) do
    # Req returns JSON responses as maps - encode as JSON string
    %{body: Jason.encode!(body), body_encoding: "raw"}
  end

  def encode_body(nil), do: %{body: nil, body_encoding: "raw"}

  @doc """
  Decodes a message body based on the encoding field.

  Handles both "raw" and "base64" encodings, and is backwards compatible
  with messages that don't include a `body_encoding` field (assumes "raw").

  ## Parameters

  - `message` - A map with "body" and optionally "body_encoding" fields

  ## Returns

  The decoded body as a binary.

  ## Examples

      iex> MessageEncoder.decode_body(%{"body" => "Hello", "body_encoding" => "raw"})
      "Hello"

      iex> MessageEncoder.decode_body(%{"body" => "AP8=", "body_encoding" => "base64"})
      <<0, 255>>

      iex> MessageEncoder.decode_body(%{"body" => "Legacy"})
      "Legacy"

      iex> MessageEncoder.decode_body(%{"body" => nil, "body_encoding" => "raw"})
      nil
  """
  @spec decode_body(map()) :: binary() | nil
  def decode_body(%{"body" => body, "body_encoding" => "base64"}) when is_binary(body) do
    Base.decode64!(body)
  end

  def decode_body(%{"body" => body, "body_encoding" => "raw"}) do
    body
  end

  def decode_body(%{"body" => body}) do
    # Legacy: assume raw if no encoding specified
    body
  end

  def decode_body(%{body: body, body_encoding: "base64"}) when is_binary(body) do
    Base.decode64!(body)
  end

  def decode_body(%{body: body, body_encoding: "raw"}) do
    body
  end

  def decode_body(%{body: body}) do
    body
  end
end
