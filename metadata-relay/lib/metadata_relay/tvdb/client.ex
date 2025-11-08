defmodule MetadataRelay.TVDB.Client do
  @moduledoc """
  HTTP client for TVDB API v4.

  This module provides a thin wrapper around the TVDB API using Req.
  It handles JWT authentication via the Auth GenServer and forwards
  requests to TVDB, returning the raw API responses.
  """

  alias MetadataRelay.TVDB.Auth

  @base_url "https://api4.thetvdb.com/v4"

  @doc """
  Creates a new Req client configured for TVDB API requests.

  The client automatically includes the JWT bearer token from the Auth GenServer.
  Returns `{:ok, client}` or `{:error, reason}` if authentication fails.
  """
  def new do
    case Auth.get_token() do
      {:ok, token} ->
        client =
          Req.new(
            base_url: @base_url,
            headers: [
              {"accept", "application/json"},
              {"content-type", "application/json"},
              {"authorization", "Bearer #{token}"}
            ]
          )

        {:ok, client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  GET request to TVDB API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  def get(path, opts \\ []) do
    with {:ok, client} <- new(),
         params <- Keyword.get(opts, :params, []),
         {:ok, %{status: status, body: body}} <- Req.get(client, url: path, params: params) do
      case status do
        s when s in 200..299 ->
          {:ok, body}

        401 ->
          # Token might be expired, try to refresh
          case Auth.refresh_token() do
            {:ok, _token} ->
              # Retry the request with new token
              get(path, opts)

            {:error, reason} ->
              {:error, {:authentication_failed, reason}}
          end

        _ ->
          {:error, {:http_error, status, body}}
      end
    else
      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport_error, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
