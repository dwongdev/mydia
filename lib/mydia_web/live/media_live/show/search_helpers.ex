defmodule MydiaWeb.MediaLive.Show.SearchHelpers do
  @moduledoc """
  Search-related helper functions for the MediaLive.Show page.
  Handles manual search, filtering, sorting, and result processing.
  """

  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings.QualityProfile

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
    # Sort by profile-based quality score + title relevance, then by seeders
    results
    |> Enum.sort_by(
      fn result ->
        base_score = profile_score(result, quality_profile, media_type)
        title_bonus = title_relevance_bonus(result.title, search_query)
        # Title bonus contributes up to 20 points on top of the 0-100 profile score
        {base_score + title_bonus, result.seeders}
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

  # Calculate title relevance bonus (0-20 points)
  # Penalizes results with extra unrelated words in the title
  defp title_relevance_bonus(_title, nil), do: 0
  defp title_relevance_bonus(_title, ""), do: 0

  defp title_relevance_bonus(title, search_query) do
    query_words = normalize_to_words(search_query)
    title_words = normalize_to_words(title)

    if query_words == [] do
      0
    else
      # Count matched words
      matched_words =
        Enum.count(query_words, fn query_word ->
          Enum.any?(title_words, fn title_word ->
            title_word == query_word or
              String.starts_with?(title_word, query_word) or
              String.starts_with?(query_word, title_word)
          end)
        end)

      match_ratio = matched_words / length(query_words)

      # Check if title starts with the query (significant word match)
      significant_query = filter_common_words(query_words)
      significant_title = filter_common_words(title_words)

      starts_with_bonus =
        case {significant_query, significant_title} do
          {[first_q | _], [first_t | _]} when first_q == first_t -> 5
          _ -> 0
        end

      # Penalty for extra unrelated words (not in query, not quality/episode markers)
      extra_words =
        title_words
        |> Enum.reject(&Enum.member?(query_words, &1))
        |> Enum.reject(&quality_or_episode_word?/1)
        |> length()

      # More extra words = bigger penalty (max -10 points)
      extra_penalty = min(extra_words * 2, 10)

      # Base bonus (up to 15 points based on match ratio) + starts_with - penalty
      base_bonus = round(match_ratio * 15)
      max(0, base_bonus + starts_with_bonus - extra_penalty)
    end
  end

  defp normalize_to_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[._\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(&1 != ""))
  end

  defp filter_common_words(words) do
    common = ~w(the a an of and or in on at to for)
    Enum.reject(words, &Enum.member?(common, &1))
  end

  defp quality_or_episode_word?(word) do
    quality_words = ~w(
      2160p 1080p 720p 480p 4k uhd hd sd
      x264 x265 h264 h265 hevc avc av1
      bluray bdrip brrip webrip webdl web hdtv hdrip dvdrip
      remux proper repack
      dts atmos truehd dolby aac ac3 flac ddp ddp5
      hdr hdr10 dolbyvision dv
      nf amzn atvp
    )

    episode_pattern = ~r/^(s\d+e?\d*|e\d+|\d{3,4}p)$/i
    year_pattern = ~r/^(19|20)\d{2}$/

    Enum.member?(quality_words, word) or
      String.match?(word, episode_pattern) or
      String.match?(word, year_pattern)
  end

  @doc """
  Calculate profile-based score for a search result.
  Returns the quality profile score (0-100) if a profile is set,
  otherwise falls back to the generic quality score.
  """
  def profile_score(%SearchResult{} = result, nil, media_type) do
    # Use the same scoring logic as breakdown for consistency
    score_result = profile_score_breakdown(result, nil, media_type)
    score_result.score
  end

  def profile_score(%SearchResult{} = result, %QualityProfile{} = profile, media_type) do
    score_result = profile_score_breakdown(result, profile, media_type)
    score_result.score
  end

  @doc """
  Calculate profile-based score with full breakdown for a search result.
  Returns the full score result including breakdown of individual components.

  Returns a map with:
  - `:score` - Overall quality score (0.0 - 100.0)
  - `:breakdown` - Map with individual component scores and weights
  - `:violations` - List of constraint violations (if any)
  - `:detected` - Map of detected quality attributes from the result
  """
  def profile_score_breakdown(%SearchResult{} = result, nil, _media_type) do
    # No profile set - score is just seeders count (sorted by most seeders)
    %{
      score: result.seeders,
      breakdown: %{
        seeders: result.seeders
      },
      violations: if(result.seeders == 0, do: ["No seeders available"], else: []),
      detected: extract_detected_quality(result)
    }
  end

  def profile_score_breakdown(%SearchResult{} = result, %QualityProfile{} = profile, media_type) do
    # Convert search result to media_attrs format for scoring
    media_attrs = search_result_to_media_attrs(result, media_type)

    # Ensure quality_standards has preferred_resolutions set from the qualities field
    profile_with_resolution_fallback = ensure_preferred_resolutions(profile)

    score_result = QualityProfile.score_media_file(profile_with_resolution_fallback, media_attrs)

    # Add detected attributes for display
    Map.put(score_result, :detected, extract_detected_quality(result))
  end

  # Extract detected quality attributes from search result for display
  defp extract_detected_quality(%SearchResult{quality: nil}), do: %{}

  defp extract_detected_quality(%SearchResult{quality: quality} = result) do
    %{
      resolution: quality.resolution,
      source: quality.source,
      video_codec: normalize_codec(quality.codec),
      audio_codec: normalize_audio_codec(quality.audio),
      hdr: quality.hdr,
      size_mb: if(result.size, do: Float.round(result.size / (1024 * 1024), 1), else: nil)
    }
  end

  # Ensure preferred_resolutions in quality_standards falls back to the qualities field
  # Note: The scoring functions use atom keys, so we set atom keys here
  defp ensure_preferred_resolutions(%QualityProfile{quality_standards: nil} = profile) do
    # No quality_standards set, create one with qualities as preferred_resolutions
    case profile.qualities do
      nil -> profile
      [] -> profile
      qualities -> %{profile | quality_standards: %{preferred_resolutions: qualities}}
    end
  end

  defp ensure_preferred_resolutions(%QualityProfile{quality_standards: standards} = profile) do
    # Check if preferred_resolutions is already set (could be string or atom key from JSON)
    existing =
      Map.get(standards, :preferred_resolutions) || Map.get(standards, "preferred_resolutions")

    case existing do
      nil ->
        # Use qualities field as fallback - use atom key to match scoring functions
        case profile.qualities do
          nil ->
            profile

          [] ->
            profile

          qualities ->
            %{profile | quality_standards: Map.put(standards, :preferred_resolutions, qualities)}
        end

      [] ->
        # Empty list, use qualities field as fallback
        case profile.qualities do
          nil ->
            profile

          [] ->
            profile

          qualities ->
            %{profile | quality_standards: Map.put(standards, :preferred_resolutions, qualities)}
        end

      _resolutions ->
        # Already has preferred_resolutions, use as-is
        profile
    end
  end

  # Convert SearchResult to the media_attrs format expected by QualityProfile.score_media_file/2
  defp search_result_to_media_attrs(%SearchResult{quality: nil} = result, media_type) do
    # No quality info available
    file_size_mb = if result.size, do: result.size / (1024 * 1024), else: nil

    %{
      resolution: nil,
      source: nil,
      video_codec: nil,
      audio_codec: nil,
      file_size_mb: file_size_mb,
      media_type: media_type
    }
  end

  defp search_result_to_media_attrs(%SearchResult{quality: quality} = result, media_type) do
    # Map codec names to the format expected by quality profiles
    video_codec = normalize_codec(quality.codec)
    audio_codec = normalize_audio_codec(quality.audio)

    # Convert size from bytes to MB
    file_size_mb = if result.size, do: result.size / (1024 * 1024), else: nil

    base_attrs = %{
      resolution: quality.resolution,
      source: quality.source,
      video_codec: video_codec,
      audio_codec: audio_codec,
      file_size_mb: file_size_mb,
      media_type: media_type
    }

    # Add HDR format if present
    if quality.hdr do
      Map.put(base_attrs, :hdr_format, "hdr10")
    else
      base_attrs
    end
  end

  # Normalize video codec names to match quality profile format
  defp normalize_codec(nil), do: nil

  defp normalize_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> case do
      "x264" -> "h264"
      "x265" -> "h265"
      "h.264" -> "h264"
      "h.265" -> "h265"
      other -> other
    end
  end

  # Normalize audio codec names to match quality profile format
  defp normalize_audio_codec(nil), do: nil

  defp normalize_audio_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> case do
      "truehd" -> "truehd"
      "dolby truehd" -> "truehd"
      "dts-hd" -> "dts-hd"
      "dts-hd ma" -> "dts-hd"
      "atmos" -> "atmos"
      "dolby atmos" -> "atmos"
      "dd+" -> "eac3"
      "ddp" -> "eac3"
      "dd" -> "ac3"
      other -> other
    end
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
