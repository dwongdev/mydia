defmodule MydiaWeb.MediaLive.Show.SearchHelpers do
  @moduledoc """
  Search-related helper functions for the MediaLive.Show page.
  Handles manual search, filtering, sorting, and result processing.
  """

  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.SearchScorer

  def generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  @doc """
  Prepare results for streaming by adding position-based IDs to preserve sort order.
  LiveView streams may reorder items based on DOM IDs, so we include position.
  """
  def prepare_for_stream(sorted_results) do
    sorted_results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      # Add a position field that will be used in the DOM ID
      Map.put(result, :stream_position, index)
    end)
  end

  def generate_positioned_id(%{stream_position: pos} = result) do
    # Include position as a zero-padded prefix to ensure correct ordering
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{String.pad_leading(Integer.to_string(pos), 5, "0")}-#{hash}"
  end

  def generate_positioned_id(result), do: generate_result_id(result)

  def perform_search(query, min_seeders) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true
    ]

    Indexers.search_all(query, opts)
  end

  def apply_search_filters(socket) do
    # Re-filter from raw results without re-searching
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    media_item = socket.assigns.media_item
    quality_profile = media_item.quality_profile
    media_type = get_media_type(media_item)
    search_query = Map.get(socket.assigns, :manual_search_query)

    sorted_results =
      sort_search_results(
        filtered_results,
        socket.assigns.sort_by,
        quality_profile,
        media_type,
        search_query
      )

    prepared_results = prepare_for_stream(sorted_results)

    socket
    |> Phoenix.Component.assign(:results_empty?, sorted_results == [])
    |> Phoenix.LiveView.stream(:search_results, prepared_results, reset: true)
  end

  def apply_search_sort(socket) do
    # Re-filter and re-sort from raw results
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    media_item = socket.assigns.media_item
    quality_profile = media_item.quality_profile
    media_type = get_media_type(media_item)
    search_query = Map.get(socket.assigns, :manual_search_query)

    sorted_results =
      sort_search_results(
        filtered_results,
        socket.assigns.sort_by,
        quality_profile,
        media_type,
        search_query
      )

    prepared_results = prepare_for_stream(sorted_results)

    socket
    |> Phoenix.LiveView.stream(:search_results, prepared_results, reset: true)
  end

  def filter_search_results(results, assigns) do
    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
  end

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    Enum.filter(results, fn result -> result.seeders >= min_seeders end)
  end

  defp filter_by_seeders(results, _), do: results

  defp filter_by_quality(results, nil), do: results

  defp filter_by_quality(results, quality_filter) do
    Enum.filter(results, fn result ->
      case result.quality do
        %{resolution: resolution} when not is_nil(resolution) ->
          # Normalize 2160p to 4k and vice versa
          normalized_resolution = normalize_resolution(resolution)
          normalized_filter = normalize_resolution(quality_filter)
          normalized_resolution == normalized_filter

        _ ->
          false
      end
    end)
  end

  defp normalize_resolution("2160p"), do: "4k"
  defp normalize_resolution("4k"), do: "4k"
  defp normalize_resolution(res), do: String.downcase(res)

  @doc """
  Sort search results by the specified criteria.

  ## Options

  - `sort_by` - The sorting criteria (`:quality`, `:seeders`, `:size`, `:date`)
  - `quality_profile` - The quality profile to use for scoring (optional)
  - `media_type` - The media type for profile scoring (`:movie` or `:episode`)
  - `search_query` - The original search query for title relevance scoring (optional)
  """
  def sort_search_results(
        results,
        sort_by,
        quality_profile \\ nil,
        media_type \\ :movie,
        search_query \\ nil
      )

  def sort_search_results(results, :quality, nil, _media_type, _search_query) do
    # No quality profile - just sort by seeders (most available first)
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  def sort_search_results(results, :quality, quality_profile, media_type, search_query) do
    # Sort by combined score using the unified SearchScorer algorithm
    # This ensures seeded results rank higher than dead torrents
    opts = [
      quality_profile: quality_profile,
      media_type: media_type,
      search_query: search_query
    ]

    results
    |> Enum.sort_by(
      fn result ->
        combined_score = SearchScorer.score_result(result, opts)
        # Use seeders as tie-breaker
        {combined_score, result.seeders}
      end,
      :desc
    )
  end

  def sort_search_results(results, :seeders, _quality_profile, _media_type, _search_query) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  def sort_search_results(results, :size, _quality_profile, _media_type, _search_query) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  def sort_search_results(results, :date, _quality_profile, _media_type, _search_query) do
    Enum.sort_by(
      results,
      fn result ->
        case result.published_at do
          nil -> DateTime.from_unix!(0)
          dt -> dt
        end
      end,
      {:desc, DateTime}
    )
  end

  @doc """
  Calculate profile-based score for a search result.
  Returns the combined score using the unified SearchScorer algorithm.
  """
  def profile_score(%SearchResult{} = result, quality_profile, media_type) do
    opts = [quality_profile: quality_profile, media_type: media_type]
    SearchScorer.score_result(result, opts)
  end

  @doc """
  Calculate profile-based score with full breakdown for a search result.
  Returns the full score result including breakdown of individual components.

  Delegates to SearchScorer.score_result_with_breakdown/2 for the unified algorithm.

  Returns a map with:
  - `:score` - Overall combined score
  - `:breakdown` - Map with individual component scores and weights
  - `:violations` - List of constraint violations (if any)
  - `:detected` - Map of detected quality attributes from the result
  """
  def profile_score_breakdown(%SearchResult{} = result, quality_profile, media_type) do
    opts = [quality_profile: quality_profile, media_type: media_type]
    SearchScorer.score_result_with_breakdown(result, opts)
  end

  defp get_media_type(media_item) do
    case media_item.type do
      "movie" -> :movie
      "tv_show" -> :episode
      _ -> :movie
    end
  end

  # Helper functions for the search results template

  def get_search_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  def search_health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end
end
