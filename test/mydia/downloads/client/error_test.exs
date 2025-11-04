defmodule Mydia.Downloads.Client.ErrorTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Error

  describe "new/3" do
    test "creates error with type and message" do
      error = Error.new(:connection_failed, "Connection refused")

      assert %Error{
               type: :connection_failed,
               message: "Connection refused",
               details: nil
             } = error
    end

    test "creates error with details" do
      details = %{status: 400, body: "Bad request"}
      error = Error.new(:api_error, "Request failed", details)

      assert %Error{
               type: :api_error,
               message: "Request failed",
               details: ^details
             } = error
    end
  end

  describe "error type helpers" do
    test "connection_failed/2 creates connection error" do
      error = Error.connection_failed("Connection refused")

      assert %Error{type: :connection_failed, message: "Connection refused"} = error
    end

    test "authentication_failed/2 creates auth error" do
      error = Error.authentication_failed("Invalid credentials")

      assert %Error{type: :authentication_failed, message: "Invalid credentials"} = error
    end

    test "timeout/2 creates timeout error" do
      error = Error.timeout("Request timed out")

      assert %Error{type: :timeout, message: "Request timed out"} = error
    end

    test "not_found/2 creates not found error" do
      error = Error.not_found("Torrent not found")

      assert %Error{type: :not_found, message: "Torrent not found"} = error
    end

    test "invalid_torrent/2 creates invalid torrent error" do
      error = Error.invalid_torrent("Invalid magnet link")

      assert %Error{type: :invalid_torrent, message: "Invalid magnet link"} = error
    end

    test "duplicate_torrent/2 creates duplicate error" do
      error = Error.duplicate_torrent("Torrent already exists")

      assert %Error{type: :duplicate_torrent, message: "Torrent already exists"} = error
    end

    test "insufficient_space/2 creates disk space error" do
      error = Error.insufficient_space("Not enough space")

      assert %Error{type: :insufficient_space, message: "Not enough space"} = error
    end

    test "invalid_config/2 creates config error" do
      error = Error.invalid_config("Missing host")

      assert %Error{type: :invalid_config, message: "Missing host"} = error
    end

    test "api_error/2 creates API error" do
      error = Error.api_error("Bad request", %{status: 400})

      assert %Error{
               type: :api_error,
               message: "Bad request",
               details: %{status: 400}
             } = error
    end

    test "network_error/2 creates network error" do
      error = Error.network_error("DNS failed")

      assert %Error{type: :network_error, message: "DNS failed"} = error
    end

    test "parse_error/2 creates parse error" do
      error = Error.parse_error("Invalid JSON")

      assert %Error{type: :parse_error, message: "Invalid JSON"} = error
    end

    test "unknown/2 creates unknown error" do
      error = Error.unknown("Unexpected error")

      assert %Error{type: :unknown, message: "Unexpected error"} = error
    end
  end

  describe "from_req_error/1" do
    test "converts connection refused transport error" do
      req_error = %Req.TransportError{reason: :econnrefused}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :connection_failed,
               message: "Connection refused"
             } = error
    end

    test "converts timeout transport error" do
      req_error = %Req.TransportError{reason: :timeout}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :timeout,
               message: "Request timed out"
             } = error
    end

    test "converts DNS resolution error" do
      req_error = %Req.TransportError{reason: :nxdomain}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :network_error,
               message: "DNS resolution failed"
             } = error
    end

    test "converts generic transport error" do
      req_error = %Req.TransportError{reason: :some_other_reason}
      error = Error.from_req_error(req_error)

      assert %Error{
               type: :connection_failed,
               message: "Transport error: :some_other_reason"
             } = error
    end

    test "converts 401 response to authentication error" do
      response = %Req.Response{status: 401, body: "Unauthorized"}
      error = Error.from_req_error(response)

      assert %Error{
               type: :authentication_failed,
               message: "Authentication failed (401)",
               details: %{status: 401}
             } = error
    end

    test "converts 403 response to authentication error" do
      response = %Req.Response{status: 403, body: "Forbidden"}
      error = Error.from_req_error(response)

      assert %Error{
               type: :authentication_failed,
               message: "Access forbidden (403)",
               details: %{status: 403}
             } = error
    end

    test "converts 404 response to not found error" do
      response = %Req.Response{status: 404, body: "Not found"}
      error = Error.from_req_error(response)

      assert %Error{
               type: :not_found,
               message: "Resource not found (404)",
               details: %{status: 404}
             } = error
    end

    test "converts 500 response to API error" do
      response = %Req.Response{status: 500, body: "Internal error"}
      error = Error.from_req_error(response)

      assert %Error{
               type: :api_error,
               message: "HTTP 500",
               details: %{status: 500, body: "Internal error"}
             } = error
    end

    test "converts unknown error types" do
      unknown_error = %{some: "error"}
      error = Error.from_req_error(unknown_error)

      assert %Error{
               type: :unknown,
               message: message
             } = error

      assert message =~ "Unexpected error"
    end
  end

  describe "message/1" do
    test "formats error message with type label" do
      error = Error.connection_failed("Connection refused")
      message = Error.message(error)

      assert message == "Connection failed: Connection refused"
    end

    test "formats multi-word error types" do
      error = Error.authentication_failed("Invalid credentials")
      message = Error.message(error)

      assert message == "Authentication failed: Invalid credentials"
    end

    test "formats error with underscores in type" do
      error = Error.invalid_config("Missing host")
      message = Error.message(error)

      assert message == "Invalid config: Missing host"
    end
  end

  describe "exception/1" do
    test "creates exception from keyword list with all fields" do
      error =
        Error.exception(
          type: :connection_failed,
          message: "Connection refused",
          details: %{host: "localhost"}
        )

      assert %Error{
               type: :connection_failed,
               message: "Connection refused",
               details: %{host: "localhost"}
             } = error
    end

    test "creates exception with default values" do
      error = Error.exception(message: "Custom message")

      assert %Error{
               type: :unknown,
               message: "Custom message",
               details: nil
             } = error
    end

    test "creates exception from binary message" do
      error = Error.exception("Simple error message")

      assert %Error{
               type: :unknown,
               message: "Simple error message",
               details: nil
             } = error
    end
  end
end
