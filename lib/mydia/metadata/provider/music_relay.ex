defmodule Mydia.Metadata.Provider.MusicRelay do
  @moduledoc """
  Music metadata provider adapter for metadata-relay service.
  """

  @behaviour Mydia.Metadata.MusicProvider

  alias Mydia.Metadata.Provider.{Error, HTTP}

  @impl true
  def search_artist(config, query, _opts \\ []) do
    req = HTTP.new_request(config)
    params = [query: query, type: "artist"]

    case HTTP.get(req, "/music/search", params: params) do
      {:ok, %{status: 200, body: body}} ->
        artists = Map.get(body, "artists", [])
        {:ok, artists}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Search failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def search_release(config, query, _opts \\ []) do
    req = HTTP.new_request(config)
    params = [query: query, type: "release"]

    case HTTP.get(req, "/music/search", params: params) do
      {:ok, %{status: 200, body: body}} ->
        releases = Map.get(body, "releases", [])
        {:ok, releases}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Search failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_artist(config, mbid) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/music/artist/#{mbid}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Artist not found: #{mbid}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Get artist failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_release(config, mbid) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/music/release/#{mbid}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Release not found: #{mbid}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Get release failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_release_group(config, mbid) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/music/release-group/#{mbid}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Release group not found: #{mbid}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Get release group failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_recording(config, mbid) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/music/recording/#{mbid}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Recording not found: #{mbid}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Get recording failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_cover_art(config, release_mbid) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/music/cover/#{release_mbid}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Cover art not found: #{release_mbid}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Get cover art failed with status #{status}", %{body: body})}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
