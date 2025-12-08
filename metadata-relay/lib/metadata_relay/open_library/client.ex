defmodule MetadataRelay.OpenLibrary.Client do
  @moduledoc """
  HTTP client for Open Library API.
  """

  @base_url "https://openlibrary.org"

  @doc """
  Creates a new Req client configured for Open Library API requests.
  """
  def new do
    Req.new(
      base_url: @base_url,
      headers: [
        {"accept", "application/json"},
        {"user-agent", "MetadataRelay/1.0 (https://github.com/my-org/metadata-relay)"}
      ]
    )
  end

  @doc """
  GET request to Open Library API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  def get(path, opts \\ []) do
    client = new()
    params = Keyword.get(opts, :params, [])

    case Req.get(client, url: path, params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
