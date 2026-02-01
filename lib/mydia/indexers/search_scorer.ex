defmodule Mydia.Indexers.SearchScorer do
  @moduledoc """
  Unified search result scoring module.

  This module provides a single source of truth for scoring search results,
  used by both manual UI searches and automatic background searches.

  ## Scoring Algorithm

  Combined Score = (quality_score * 0.6 + seeder_score + title_bonus) * zero_seeder_penalty

  Where:
  - quality_score: 0-100 (from QualityProfile.score_media_file/2 or fallback)
  - seeder_score: log10(seeders + 1) * 10 (max ~30 pts)
  - title_bonus: title_relevance_bonus / 2 (0-10 pts)
  - zero_seeder_penalty: 0.7 if seeders == 0, else 1.0

  ## Usage

      # Score a single result
      SearchScorer.score_result(result, quality_profile: profile, media_type: :movie, search_query: "...")

      # Get full breakdown
      SearchScorer.score_result_with_breakdown(result, quality_profile: profile, media_type: :movie, search_query: "...")
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings.QualityProfile

  @type score_opts :: [
          quality_profile: QualityProfile.t() | nil,
          media_type: :movie | :episode,
          search_query: String.t() | nil
        ]

  @type score_breakdown :: %{
          score: float(),
          breakdown: map(),
          violations: [String.t()],
          detected: map()
        }

  @doc """
  Calculate the combined score for a search result.

  Returns a float score that can be used for sorting results.

  ## Options

  - `:quality_profile` - The quality profile to use for scoring (optional)
  - `:media_type` - Either `:movie` or `:episode` (default: `:movie`)
  - `:search_query` - The original search query for title relevance scoring (optional)
  """
  @spec score_result(SearchResult.t(), score_opts()) :: float()
  def score_result(%SearchResult{} = result, opts \\ []) do
    breakdown = score_result_with_breakdown(result, opts)
    breakdown.score
  end

  @doc """
  Calculate the combined score with full breakdown for a search result.

  Returns a map with:
  - `:score` - Overall combined score
  - `:breakdown` - Map with individual component scores
  - `:violations` - List of constraint violations (if any)
  - `:detected` - Map of detected quality attributes from the result
  """
  @spec score_result_with_breakdown(SearchResult.t(), score_opts()) :: score_breakdown()
  def score_result_with_breakdown(%SearchResult{} = result, opts \\ []) do
    quality_profile = Keyword.get(opts, :quality_profile)
    media_type = Keyword.get(opts, :media_type, :movie)
    search_query = Keyword.get(opts, :search_query)

    # Calculate individual component scores
    {quality_score, quality_breakdown, violations} =
      score_quality(result, quality_profile, media_type)

    seeder_score = score_seeders(result.seeders)
    title_bonus = score_title_match(result.title, search_query)

    # Zero-seeder penalty: reduce score by 30% for dead torrents
    zero_seeder_penalty = if result.seeders == 0, do: 0.7, else: 1.0

    # Combined score: quality (60%) + seeders (30%) + title (10%)
    combined_score = (quality_score * 0.6 + seeder_score + title_bonus) * zero_seeder_penalty

    # Build full breakdown
    breakdown =
      quality_breakdown
      |> Map.put(:quality_score, Float.round(quality_score, 1))
      |> Map.put(:seeder_score, Float.round(seeder_score, 1))
      |> Map.put(:title_bonus, Float.round(title_bonus, 1))
      |> Map.put(:zero_seeder_penalty, zero_seeder_penalty)

    # Add violation for zero seeders
    violations =
      if result.seeders == 0 do
        violations ++ ["No seeders (30% penalty applied)"]
      else
        violations
      end

    %{
      score: Float.round(combined_score, 1),
      breakdown: breakdown,
      violations: violations,
      detected: extract_detected_quality(result)
    }
  end

  @doc """
  Calculate quality score for a search result.

  If a quality profile is provided, uses QualityProfile.score_media_file/2.
  Otherwise, returns a fallback score based on seeders.

  Returns {score, breakdown, violations} tuple.
  """
  @spec score_quality(SearchResult.t(), QualityProfile.t() | nil, :movie | :episode) ::
          {float(), map(), [String.t()]}
  def score_quality(%SearchResult{} = result, nil, _media_type) do
    # No profile set - use seeders as the primary quality indicator.
    # Without a quality profile, users haven't expressed quality preferences,
    # so we prioritize availability (more seeders = more reliable download).
    quality_score = min(result.seeders * 1.0, 100.0)

    {quality_score, %{raw_quality_score: quality_score}, []}
  end

  def score_quality(%SearchResult{} = result, %QualityProfile{} = profile, media_type) do
    # Convert search result to media_attrs format for scoring
    media_attrs = search_result_to_media_attrs(result, media_type)

    # Ensure quality_standards has preferred_resolutions set from the qualities field
    profile_with_resolution_fallback = ensure_preferred_resolutions(profile)

    score_result = QualityProfile.score_media_file(profile_with_resolution_fallback, media_attrs)

    {score_result.score, score_result.breakdown, score_result.violations}
  end

  @doc """
  Calculate seeder score using logarithmic scale.

  0 seeders = 0, 10 seeders = 10, 100 seeders = 20, 1000 seeders = 30

  Returns a score in the range 0-30.
  """
  @spec score_seeders(non_neg_integer()) :: float()
  def score_seeders(seeders) when seeders <= 0, do: 0.0

  def score_seeders(seeders) do
    :math.log10(seeders + 1) * 10
  end

  @doc """
  Calculate title relevance bonus.

  Scores how well the result title matches the search query.
  Returns a score in the range 0-10.
  """
  @spec score_title_match(String.t(), String.t() | nil) :: float()
  def score_title_match(_title, nil), do: 0.0
  def score_title_match(_title, ""), do: 0.0

  def score_title_match(title, search_query) do
    # Calculate raw title relevance bonus (0-20 scale) and divide by 2 for 0-10 range
    raw_bonus = calculate_title_relevance_bonus(title, search_query)
    raw_bonus / 2
  end

  # Private functions

  # Calculate title relevance bonus (0-20 points)
  # Penalizes results with extra unrelated words in the title
  defp calculate_title_relevance_bonus(title, search_query) do
    query_words = normalize_to_words(search_query)
    title_words = normalize_to_words(title)

    if query_words == [] do
      0.0
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
          {[first_q | _], [first_t | _]} when first_q == first_t -> 5.0
          _ -> 0.0
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
      base_bonus = match_ratio * 15

      max(0.0, base_bonus + starts_with_bonus - extra_penalty)
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

    # Add HDR format if present - use actual format, not hardcoded hdr10
    if quality.hdr do
      hdr_format = normalize_hdr_format(quality.hdr_format)
      Map.put(base_attrs, :hdr_format, hdr_format)
    else
      base_attrs
    end
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
      # TrueHD Atmos is the highest tier - map to "atmos"
      "truehd atmos" -> "atmos"
      "atmos" -> "atmos"
      "dolby atmos" -> "atmos"
      # TrueHD without Atmos
      "truehd" -> "truehd"
      "dolby truehd" -> "truehd"
      # DTS variants
      "dts:x" -> "dts-hd"
      "dts-hd ma" -> "dts-hd"
      "dts-hd" -> "dts-hd"
      # Dolby Digital variants
      "dd+" -> "eac3"
      "ddp" -> "eac3"
      "dd" -> "ac3"
      other -> other
    end
  end

  # Normalize HDR format names to match quality profile format
  # QualityParser returns: "DV", "HDR10+", "HDR10"
  # QualityProfile expects: "dolby_vision", "hdr10+", "hdr10"
  defp normalize_hdr_format(nil), do: "hdr10"

  defp normalize_hdr_format(format) when is_binary(format) do
    format
    |> String.downcase()
    |> case do
      "dv" -> "dolby_vision"
      "dolby vision" -> "dolby_vision"
      "dolbyvision" -> "dolby_vision"
      "hdr10+" -> "hdr10+"
      "hdr10plus" -> "hdr10+"
      "hdr10" -> "hdr10"
      "hdr" -> "hdr10"
      other -> other
    end
  end
end
