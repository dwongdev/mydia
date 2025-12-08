defmodule MetadataRelay.Test.TVDBHelpers do
  @moduledoc """
  Test helpers for TVDB module testing.

  Provides utilities for creating mock HTTP adapters and test JWT tokens.
  """

  @doc """
  Creates a valid test JWT token with the specified expiration time.

  The token is properly formatted as a base64-encoded JWT with header.payload.signature structure.
  """
  def create_test_token(expires_in_seconds \\ 30 * 24 * 60 * 60) do
    # JWT Header (base64url encoded)
    header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)

    # JWT Payload with expiration
    exp = DateTime.utc_now() |> DateTime.add(expires_in_seconds, :second) |> DateTime.to_unix()
    payload = Base.url_encode64(~s({"exp":#{exp},"sub":"test"}), padding: false)

    # Signature (fake but properly formatted)
    signature = Base.url_encode64("test_signature", padding: false)

    "#{header}.#{payload}.#{signature}"
  end

  @doc """
  Creates an expired test JWT token.
  """
  def create_expired_token do
    create_test_token(-3600)
  end

  @doc """
  Creates a mock HTTP adapter that returns the specified response.

  ## Examples

      adapter = mock_adapter(200, %{"data" => %{"token" => "test"}})
  """
  def mock_adapter(status, body) do
    fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end
  end

  @doc """
  Creates a mock HTTP adapter for successful TVDB authentication.
  """
  def mock_auth_success(token \\ nil) do
    token = token || create_test_token()
    mock_adapter(200, %{"data" => %{"token" => token}})
  end

  @doc """
  Creates a mock HTTP adapter for TVDB authentication failure.
  """
  def mock_auth_failure(status \\ 401, message \\ "Unauthorized") do
    mock_adapter(status, %{"error" => message})
  end

  @doc """
  Creates a mock HTTP adapter that returns different responses based on URL.

  ## Examples

      adapter = mock_adapter_with_routes(%{
        "/v4/login" => {200, %{"data" => %{"token" => "test"}}},
        "/v4/search" => {200, %{"data" => [%{"id" => 1, "name" => "Test"}]}}
      })
  """
  def mock_adapter_with_routes(routes) do
    fn request ->
      url = request.url |> URI.to_string()

      # Find matching route
      {status, body} =
        Enum.find_value(routes, {404, %{"error" => "Not found"}}, fn {pattern, response} ->
          if String.contains?(url, pattern), do: response
        end)

      {request, Req.Response.new(status: status, body: body)}
    end
  end

  @doc """
  Creates a mock HTTP adapter that simulates network errors.
  """
  def mock_network_error(reason \\ :econnrefused) do
    fn _request ->
      {:error, %Req.TransportError{reason: reason}}
    end
  end

  @doc """
  Sets up the TVDB HTTP adapter for testing.

  Should be called in test setup and cleaned up with `clear_tvdb_adapter/0`.
  """
  def set_tvdb_adapter(adapter) do
    # Wrap the adapter to also disable Req's retry mechanism for faster tests
    wrapped_adapter = fn request ->
      # Remove retry step from request options to speed up tests
      request = %{request | options: Map.put(request.options, :retry, false)}
      adapter.(request)
    end

    Application.put_env(:metadata_relay, :tvdb_http_adapter, wrapped_adapter)
  end

  @doc """
  Clears the TVDB HTTP adapter after testing.
  """
  def clear_tvdb_adapter do
    Application.delete_env(:metadata_relay, :tvdb_http_adapter)
  end

  @doc """
  Runs a function with a temporary TVDB HTTP adapter.

  Automatically cleans up the adapter after the function completes.
  """
  def with_tvdb_adapter(adapter, fun) do
    set_tvdb_adapter(adapter)

    try do
      fun.()
    after
      clear_tvdb_adapter()
    end
  end
end
