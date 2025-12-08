defmodule MetadataRelay.Music.Client do
  @moduledoc """
  HTTP client for MusicBrainz API and Cover Art Archive.
  """

  @mb_base_url "https://musicbrainz.org/ws/2"
  @caa_base_url "https://coverartarchive.org"
  @user_agent "MetadataRelay/1.0 ( https://github.com/mydia-org/mydia )"

  @doc """
  GET request to MusicBrainz API.
  """
  def get_mb(path, opts \\ []) do
    client =
      Req.new(
        base_url: @mb_base_url,
        headers: [
          {"user-agent", @user_agent},
          {"accept", "application/json"}
        ]
      )

    params = Keyword.get(opts, :params, []) |> Keyword.put(:fmt, "json")

    case Req.get(client, url: path, params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  GET request to Cover Art Archive.
  Returns the raw image binary.
  """
  def get_caa(path) do
    client =
      Req.new(
        base_url: @caa_base_url,
        headers: [
          {"user-agent", @user_agent}
        ]
      )

    case Req.get(client, url: path) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
