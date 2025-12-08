defmodule Mydia.MediaServer.Client.Plex do
  @moduledoc """
  Plex media server adapter.
  """

  @behaviour Mydia.MediaServer.Client

  require Logger

  @impl true
  def test_connection(%{url: nil}), do: {:error, "URL is required"}
  def test_connection(%{url: ""}), do: {:error, "URL is required"}
  def test_connection(%{token: nil}), do: {:error, "Token is required"}
  def test_connection(%{token: ""}), do: {:error, "Token is required"}

  def test_connection(config) do
    # Plex identity endpoint: /identity
    # Headers: X-Plex-Token

    url = build_url(config, "/identity")

    case Req.get(url, headers: headers(config)) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "Connection failed: HTTP #{status}"}
      {:error, exception} -> {:error, "Connection failed: #{Exception.message(exception)}"}
    end
  end

  @impl true
  def update_library(config, opts \\ []) do
    path = opts[:path]

    # If path is provided, we scan that specific location
    # Endpoint: /library/sections/all/refresh?path=...
    # If no path, we scan all libraries
    # Endpoint: /library/sections/all/refresh

    url = build_url(config, "/library/sections/all/refresh")

    params =
      if path do
        [path: path]
      else
        []
      end

    Logger.info("Triggering Plex library scan", server: config.name, path: path)

    case Req.get(url, headers: headers(config), params: params) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "Scan failed: HTTP #{status}"}
      {:error, exception} -> {:error, "Scan failed: #{Exception.message(exception)}"}
    end
  end

  defp build_url(config, path) do
    base = String.trim_trailing(config.url, "/")
    "#{base}#{path}"
  end

  defp headers(config) do
    [
      {"X-Plex-Token", config.token},
      {"Accept", "application/json"}
    ]
  end
end
