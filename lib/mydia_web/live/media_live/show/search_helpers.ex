defmodule MydiaWeb.MediaLive.Show.SearchHelpers do
  @moduledoc """
  Search-related helper functions for the MediaLive.Show page.
  Handles manual search, filtering, sorting, and result processing.
  """

  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.QualityParser
  alias Mydia.Settings.QualityProfile

  def generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

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

    sorted_results =
      sort_search_results(filtered_results, socket.assigns.sort_by, quality_profile, media_type)

    socket
    |> Phoenix.Component.assign(:results_empty?, sorted_results == [])
    |> Phoenix.LiveView.stream(:search_results, sorted_results, reset: true)
  end

  def apply_search_sort(socket) do
    # Re-filter and re-sort from raw results
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    media_item = socket.assigns.media_item
    quality_profile = media_item.quality_profile
    media_type = get_media_type(media_item)

    sorted_results =
      sort_search_results(filtered_results, socket.assigns.sort_by, quality_profile, media_type)

    socket
    |> Phoenix.LiveView.stream(:search_results, sorted_results, reset: true)
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

  def sort_search_results(results, sort_by, quality_profile \\ nil, media_type \\ :movie)

  def sort_search_results(results, :quality, quality_profile, media_type) do
    # Sort by profile-based quality score if profile exists, then by seeders
    results
    |> Enum.sort_by(
      fn result ->
        {profile_score(result, quality_profile, media_type), result.seeders}
      end,
      :desc
    )
  end

  def sort_search_results(results, :seeders, _quality_profile, _media_type) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  def sort_search_results(results, :size, _quality_profile, _media_type) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  def sort_search_results(results, :date, _quality_profile, _media_type) do
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

  defp quality_score(%SearchResult{quality: nil}), do: 0

  defp quality_score(%SearchResult{quality: quality}) do
    QualityParser.quality_score(quality)
  end

  @doc """
  Calculate profile-based score for a search result.
  Returns the quality profile score (0-100) if a profile is set,
  otherwise falls back to the generic quality score.
  """
  def profile_score(%SearchResult{} = result, nil, _media_type) do
    # No profile set, use generic quality score (scaled to 0-100 for consistency)
    quality_score(result) / 20
  end

  def profile_score(%SearchResult{} = result, %QualityProfile{} = profile, media_type) do
    # Convert search result to media_attrs format for scoring
    media_attrs = search_result_to_media_attrs(result, media_type)

    # Ensure quality_standards has preferred_resolutions set from the qualities field
    # This is the fallback when the user hasn't explicitly set preferred_resolutions
    profile_with_resolution_fallback = ensure_preferred_resolutions(profile)

    score_result = QualityProfile.score_media_file(profile_with_resolution_fallback, media_attrs)
    score_result.score
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
