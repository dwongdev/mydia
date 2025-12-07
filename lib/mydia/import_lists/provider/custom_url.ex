defmodule Mydia.ImportLists.Provider.CustomURL do
  @moduledoc """
  Custom URL provider for import lists.

  Fetches items from user-provided JSON endpoints. Supports flexible JSON formats:

  ## Supported Formats

  1. Array of objects with tmdb_id:
     ```json
     [
       {"tmdb_id": 123, "title": "Movie Name", "year": 2024},
       {"tmdb_id": 456, "title": "Another Movie"}
     ]
     ```

  2. Object with items/results array:
     ```json
     {"items": [{"tmdb_id": 123, "title": "..."}]}
     {"results": [{"tmdb_id": 123, "title": "..."}]}
     ```

  3. Radarr/Sonarr export format:
     ```json
     [{"tmdbId": 123, "title": "..."}, ...]
     ```

  Required fields: tmdb_id (or tmdbId)
  Optional fields: title, year, poster_path
  """

  @behaviour Mydia.ImportLists.Provider

  require Logger

  @impl true
  def supports?("custom_url"), do: true
  def supports?(_), do: false

  @impl true
  def fetch_items(%{type: "custom_url", config: config, media_type: media_type}) do
    url = get_in(config, ["list_url"])

    case url do
      nil ->
        {:error, "No URL configured"}

      url when is_binary(url) ->
        fetch_from_url(url, media_type)
    end
  end

  def fetch_items(_), do: {:error, "Invalid import list type for CustomURL provider"}

  ## Private Functions

  defp fetch_from_url(url, media_type) do
    Logger.info("[CustomURL] Fetching from URL", url: url)

    req =
      Req.new(
        url: url,
        headers: [
          {"accept", "application/json"},
          {"user-agent", "Mydia/1.0"}
        ],
        receive_timeout: 30_000
      )

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        parse_items(body, media_type)

      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        parse_items(items, media_type)

      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        parse_items(results, media_type)

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("[CustomURL] Unexpected response format", body: inspect(body))
        {:error, "Unexpected JSON format - expected array or object with items/results key"}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, "Request failed: #{inspect(reason)}"}

      {:error, error} ->
        {:error, "Request failed: #{inspect(error)}"}
    end
  end

  defp parse_items(items, media_type) do
    parsed =
      items
      |> Enum.map(&parse_item(&1, media_type))
      |> Enum.filter(&(&1 != nil))

    Logger.info("[CustomURL] Parsed #{length(parsed)} items from #{length(items)} entries")
    {:ok, parsed}
  end

  defp parse_item(item, media_type) when is_map(item) do
    # Try different field name conventions
    tmdb_id = get_tmdb_id(item)

    if tmdb_id do
      %{
        tmdb_id: tmdb_id,
        title: get_title(item),
        year: get_year(item),
        poster_path: get_poster_path(item),
        media_type: media_type
      }
    else
      Logger.debug("[CustomURL] Skipping item without tmdb_id", item: inspect(item))
      nil
    end
  end

  defp parse_item(_, _), do: nil

  # Support multiple field naming conventions for tmdb_id
  defp get_tmdb_id(item) do
    cond do
      is_integer(item["tmdb_id"]) -> item["tmdb_id"]
      is_integer(item["tmdbId"]) -> item["tmdbId"]
      is_integer(item["id"]) -> item["id"]
      is_binary(item["tmdb_id"]) -> parse_int(item["tmdb_id"])
      is_binary(item["tmdbId"]) -> parse_int(item["tmdbId"])
      is_binary(item["id"]) -> parse_int(item["id"])
      true -> nil
    end
  end

  defp get_title(item) do
    item["title"] || item["name"] || item["originalTitle"] || "Unknown"
  end

  defp get_year(item) do
    cond do
      is_integer(item["year"]) ->
        item["year"]

      is_binary(item["year"]) ->
        parse_int(item["year"])

      is_binary(item["release_date"]) and byte_size(item["release_date"]) >= 4 ->
        parse_int(String.slice(item["release_date"], 0, 4))

      is_binary(item["first_air_date"]) and byte_size(item["first_air_date"]) >= 4 ->
        parse_int(String.slice(item["first_air_date"], 0, 4))

      is_binary(item["releaseDate"]) and byte_size(item["releaseDate"]) >= 4 ->
        parse_int(String.slice(item["releaseDate"], 0, 4))

      true ->
        nil
    end
  end

  defp get_poster_path(item) do
    item["poster_path"] || item["posterPath"] || item["poster"]
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
