defmodule Mydia.Indexers.ReleaseRanker do
  @moduledoc """
  Ranks and filters torrent search results based on configurable criteria.

  This module provides a pluggable ranking system for selecting the best
  torrent releases from search results. It uses the unified `SearchScorer`
  algorithm to ensure consistent scoring between automatic and manual searches.

  ## Usage

      # Get the best result
      ReleaseRanker.select_best_result(results, min_seeders: 10)

      # Rank all results with scores
      ReleaseRanker.rank_all(results, preferred_qualities: ["1080p", "720p"])

      # Filter by criteria
      ReleaseRanker.filter_acceptable(results, size_range: {500, 10_000})

  ## Scoring Algorithm

  Scoring is handled by `SearchScorer` with the following formula:

      Combined Score = (quality_score * 0.6 + seeder_score + title_bonus) * zero_seeder_penalty

  Where:
  - `quality_score`: 0-100 based on QualityProfile scoring
  - `seeder_score`: log10(seeders + 1) * 10 (max ~30 pts)
  - `title_bonus`: title relevance bonus / 2 (0-10 pts)
  - `zero_seeder_penalty`: 0.7 if seeders == 0, else 1.0

  ## Options

  - `:min_seeders` - Minimum seeder count (default: 0 for Usenet compatibility)
  - `:min_ratio` - Minimum seeder ratio as percentage (default: nil)
  - `:size_range` - `{min_mb, max_mb}` tuple where either can be nil (default: `nil` = no filtering)
  - `:preferred_qualities` - List of resolutions in preference order (for sorting)
  - `:blocked_tags` - List of strings to filter out from titles
  - `:search_query` - Original search query to score title relevance
  - `:quality_profile` - QualityProfile struct for scoring (recommended)
  - `:media_type` - Either `:movie` or `:episode` (default: `:movie`)
  """

  require Logger

  alias Mydia.Indexers.{SearchResult, SearchScorer}
  alias Mydia.Indexers.Structs.{RankedResult, ScoreBreakdown}
  alias Mydia.Settings.QualityProfile

  @type ranked_result :: RankedResult.t()
  @type score_breakdown :: ScoreBreakdown.t()

  @type ranking_options :: [
          min_seeders: non_neg_integer(),
          min_ratio: float() | nil,
          size_range: {non_neg_integer(), non_neg_integer()},
          preferred_qualities: [String.t()],
          blocked_tags: [String.t()],
          search_query: String.t() | nil,
          quality_profile: QualityProfile.t() | nil,
          media_type: :movie | :episode
        ]

  @default_min_seeders 0

  @doc """
  Selects the best result from a list based on ranking criteria.

  Returns the result with the highest score along with its score breakdown.
  Returns `nil` if no results pass the filtering criteria.

  ## Examples

      iex> ReleaseRanker.select_best_result(results, min_seeders: 10)
      %{result: %SearchResult{...}, score: 850.5, breakdown: %{...}}

      iex> ReleaseRanker.select_best_result([], [])
      nil
  """
  @spec select_best_result([SearchResult.t()], ranking_options()) :: ranked_result() | nil
  def select_best_result(results, opts \\ []) do
    results
    |> rank_all(opts)
    |> List.first()
  end

  @doc """
  Ranks all results by score in descending order.

  Returns a list of maps containing the result, total score, and score breakdown.
  Results that don't meet filtering criteria are excluded.

  ## Examples

      iex> ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      [
        %{result: %SearchResult{...}, score: 850.5, breakdown: %{quality: 480, seeders: 200, ...}},
        %{result: %SearchResult{...}, score: 720.3, breakdown: %{quality: 400, seeders: 180, ...}}
      ]
  """
  @spec rank_all([SearchResult.t()], ranking_options()) :: [ranked_result()]
  def rank_all(results, opts \\ []) do
    preferred_qualities = Keyword.get(opts, :preferred_qualities)

    Logger.info(
      "[ReleaseRanker] rank_all called with opts: preferred_qualities=#{inspect(preferred_qualities)}, " <>
        "min_seeders=#{inspect(Keyword.get(opts, :min_seeders))}, " <>
        "size_range=#{inspect(Keyword.get(opts, :size_range))}"
    )

    ranked =
      results
      |> filter_acceptable(opts)
      |> Enum.map(fn result ->
        breakdown = calculate_score_breakdown(result, opts)
        RankedResult.new(%{result: result, score: breakdown.total, breakdown: breakdown})
      end)
      |> sort_by_score_and_preferences(preferred_qualities)

    # Log the top 5 results after sorting
    top_5 = Enum.take(ranked, 5)

    Logger.info("[ReleaseRanker] Top 5 results after sorting by preferences:")

    Enum.each(top_5, fn %{result: result, score: score} ->
      resolution = if result.quality, do: result.quality.resolution, else: "unknown"
      quality_idx = quality_preference_index(result, preferred_qualities)

      Logger.info(
        "  - [idx=#{quality_idx}] #{resolution} | score=#{Float.round(score, 1)} | #{String.slice(result.title, 0, 60)}"
      )
    end)

    ranked
  end

  @doc """
  Filters results to only those meeting minimum criteria.

  Removes results that:
  - Have fewer than `:min_seeders` seeders
  - Have seeder ratio below `:min_ratio` (if specified)
  - Fall outside the `:size_range` (in MB)
  - Contain any `:blocked_tags` in their title

  ## Examples

      iex> ReleaseRanker.filter_acceptable(results, min_seeders: 10, blocked_tags: ["CAM"])
      [%SearchResult{...}, ...]

      iex> ReleaseRanker.filter_acceptable(results, min_ratio: 0.15)
      [%SearchResult{...}, ...]
  """
  @spec filter_acceptable([SearchResult.t()], ranking_options()) :: [SearchResult.t()]
  def filter_acceptable(results, opts \\ []) do
    min_seeders = Keyword.get(opts, :min_seeders, @default_min_seeders)
    min_ratio = Keyword.get(opts, :min_ratio)
    size_range = Keyword.get(opts, :size_range)
    blocked_tags = Keyword.get(opts, :blocked_tags, [])

    Enum.filter(results, fn result ->
      cond do
        not meets_seeder_minimum?(result, min_seeders) ->
          Logger.info(
            "[ReleaseRanker] Filtered out (seeders #{result.seeders} < #{min_seeders}): #{result.title}"
          )

          false

        min_ratio != nil and not meets_ratio_minimum?(result, min_ratio) ->
          total = result.seeders + result.leechers
          ratio = if total > 0, do: Float.round(result.seeders / total * 100, 1), else: 0.0

          Logger.info(
            "[ReleaseRanker] Filtered out (ratio #{ratio}% < #{Float.round(min_ratio * 100, 1)}%): #{result.title}"
          )

          false

        size_range != nil and not within_size_range?(result, size_range) ->
          {min_mb, max_mb} = size_range
          size_mb = Float.round(bytes_to_mb(result.size), 1)
          range_str = format_size_range(min_mb, max_mb)

          Logger.info(
            "[ReleaseRanker] Filtered out (size #{size_mb} MB not in #{range_str}): #{result.title}"
          )

          false

        not not_blocked?(result, blocked_tags) ->
          Logger.info("[ReleaseRanker] Filtered out (blocked tag): #{result.title}")
          false

        true ->
          true
      end
    end)
  end

  ## Private Functions - Filtering

  defp meets_seeder_minimum?(%SearchResult{seeders: seeders}, min_seeders) do
    seeders >= min_seeders
  end

  defp meets_ratio_minimum?(_result, nil), do: true

  defp meets_ratio_minimum?(%SearchResult{seeders: seeders, leechers: leechers}, min_ratio) do
    total_peers = seeders + leechers

    if total_peers == 0 do
      # No peers at all - allow it
      true
    else
      seeder_ratio = seeders / total_peers
      seeder_ratio >= min_ratio
    end
  end

  # nil size_range disables size filtering
  defp within_size_range?(_result, nil), do: true

  # Handle partial ranges where min or max might be nil
  defp within_size_range?(%SearchResult{size: size_bytes}, {min_mb, max_mb}) do
    size_mb = bytes_to_mb(size_bytes)

    above_min = min_mb == nil or size_mb >= min_mb
    below_max = max_mb == nil or size_mb <= max_mb

    above_min and below_max
  end

  defp format_size_range(nil, nil), do: "any"
  defp format_size_range(min, nil), do: "#{min}+ MB"
  defp format_size_range(nil, max), do: "0-#{max} MB"
  defp format_size_range(min, max), do: "#{min}-#{max} MB"

  defp not_blocked?(%SearchResult{title: title}, blocked_tags) do
    title_lower = String.downcase(title)

    not Enum.any?(blocked_tags, fn tag ->
      String.contains?(title_lower, String.downcase(tag))
    end)
  end

  ## Scoring Functions

  @doc """
  Calculates the full score breakdown for a single search result.

  Used by both automatic searches and manual UI searches for consistent scoring.
  Returns a `ScoreBreakdown` struct with individual component scores and total.

  This function always uses the unified SearchScorer algorithm to ensure
  consistent scoring between manual and automatic searches.

  ## Options

  Same as `rank_all/2`:
  - `:quality_profile` - QualityProfile struct for scoring (optional, but recommended)
  - `:media_type` - Either `:movie` or `:episode` (default: `:movie`)
  - `:search_query` - Original search query to score title relevance
  - `:preferred_qualities` - List of resolutions in preference order (used for sorting)
  """
  @spec calculate_score_breakdown(SearchResult.t(), ranking_options()) :: ScoreBreakdown.t()
  def calculate_score_breakdown(%SearchResult{} = result, opts) do
    quality_profile = Keyword.get(opts, :quality_profile)
    media_type = Keyword.get(opts, :media_type, :movie)
    search_query = Keyword.get(opts, :search_query)

    scorer_opts = [
      quality_profile: quality_profile,
      media_type: media_type,
      search_query: search_query
    ]

    score_result = SearchScorer.score_result_with_breakdown(result, scorer_opts)

    # Extract individual components for the breakdown struct
    breakdown = score_result.breakdown
    quality_score = Map.get(breakdown, :quality_score, 0.0)
    seeder_score = Map.get(breakdown, :seeder_score, 0.0)
    title_bonus = Map.get(breakdown, :title_bonus, 0.0)

    size_mb = bytes_to_mb(result.size)
    total_peers = result.seeders + result.leechers
    seeder_ratio = if total_peers > 0, do: result.seeders / total_peers, else: 0.0

    Logger.info("""
    [ReleaseRanker] Score breakdown for: #{result.title}
      Raw values:
        - Size: #{Float.round(size_mb, 1)} MB
        - Seeders: #{result.seeders}, Leechers: #{result.leechers}
        - Seeder ratio: #{Float.round(seeder_ratio * 100, 1)}%
        - Quality: #{inspect(result.quality)}
      Component scores:
        - Quality:  #{Float.round(quality_score, 2)} (60% weight in combined score)
        - Seeders:  #{Float.round(seeder_score, 2)} (30% weight in combined score)
        - Title:    #{Float.round(title_bonus, 2)} (10% weight in combined score)
        - Zero-seeder penalty: #{Map.get(breakdown, :zero_seeder_penalty, 1.0)}
      TOTAL: #{Float.round(score_result.score, 2)}
    """)

    # Map to ScoreBreakdown struct
    ScoreBreakdown.new(%{
      quality: round_score(quality_score),
      seeders: round_score(seeder_score),
      size: 0.0,
      age: 0.0,
      title_match: round_score(title_bonus * 100),
      tag_bonus: 0.0,
      total: round_score(score_result.score)
    })
  end

  ## Private Functions - Sorting

  defp sort_by_score_and_preferences(ranked_results, nil) do
    Enum.sort_by(ranked_results, & &1.score, :desc)
  end

  defp sort_by_score_and_preferences(ranked_results, preferred_qualities) do
    ranked_results
    |> Enum.sort_by(fn %{result: result, score: score} ->
      quality_index = quality_preference_index(result, preferred_qualities)
      # Sort by: quality preference (lower index = higher priority), then score
      {quality_index, -score}
    end)
  end

  defp quality_preference_index(%SearchResult{quality: nil}, _preferred_qualities) do
    999
  end

  defp quality_preference_index(_result, nil) do
    # No preferred qualities set, return 0 so all results sort by score only
    0
  end

  defp quality_preference_index(_result, []) do
    # Empty preferred qualities list, return 0 so all results sort by score only
    0
  end

  defp quality_preference_index(%SearchResult{quality: quality}, preferred_qualities) do
    case quality.resolution do
      nil ->
        999

      resolution ->
        case Enum.find_index(preferred_qualities, &(&1 == resolution)) do
          nil -> 999
          index -> index
        end
    end
  end

  @doc """
  Scores all results and returns detailed information about each, including rejection reasons.

  Unlike `rank_all/2`, this function includes ALL results (even those filtered out)
  and provides the reason why each was rejected (if applicable).

  Returns a list of maps containing:
  - `:title` - The release title
  - `:score` - The calculated score (0 if rejected before scoring)
  - `:seeders` - Seeder count
  - `:size_mb` - Size in megabytes
  - `:resolution` - Detected resolution (if available)
  - `:status` - Either `:accepted` or `:rejected`
  - `:rejection_reason` - Why it was rejected (nil if accepted)

  Results are sorted by score descending.

  ## Examples

      iex> ReleaseRanker.score_all_with_reasons(results, min_seeders: 10)
      [
        %{title: "Movie.2024.1080p", score: 75.5, status: :accepted, ...},
        %{title: "Movie.2024.CAM", score: 0, status: :rejected, rejection_reason: "blocked_tag: CAM", ...}
      ]
  """
  @spec score_all_with_reasons([SearchResult.t()], ranking_options()) :: [map()]
  def score_all_with_reasons(results, opts \\ []) do
    min_seeders = Keyword.get(opts, :min_seeders, @default_min_seeders)
    min_ratio = Keyword.get(opts, :min_ratio)
    size_range = Keyword.get(opts, :size_range)
    blocked_tags = Keyword.get(opts, :blocked_tags, [])

    results
    |> Enum.map(fn result ->
      size_mb = bytes_to_mb(result.size)
      resolution = if result.quality, do: result.quality.resolution, else: nil

      base_info = %{
        title: result.title,
        seeders: result.seeders,
        size_mb: Float.round(size_mb, 1),
        resolution: resolution
      }

      # Check rejection reasons in order
      rejection = get_rejection_reason(result, min_seeders, min_ratio, size_range, blocked_tags)

      case rejection do
        nil ->
          # Not rejected, calculate score
          breakdown = calculate_score_breakdown(result, opts)

          Map.merge(base_info, %{
            score: breakdown.total,
            status: :accepted,
            rejection_reason: nil,
            breakdown: %{
              quality: breakdown.quality,
              seeders: breakdown.seeders,
              title_match: breakdown.title_match
            }
          })

        reason ->
          Map.merge(base_info, %{
            score: 0.0,
            status: :rejected,
            rejection_reason: reason,
            breakdown: nil
          })
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  # Returns rejection reason string or nil if acceptable
  defp get_rejection_reason(result, min_seeders, min_ratio, size_range, blocked_tags) do
    cond do
      not meets_seeder_minimum?(result, min_seeders) ->
        "low_seeders: #{result.seeders} < #{min_seeders}"

      min_ratio != nil and not meets_ratio_minimum?(result, min_ratio) ->
        total = result.seeders + result.leechers
        ratio = if total > 0, do: Float.round(result.seeders / total * 100, 1), else: 0.0
        "low_ratio: #{ratio}% < #{Float.round(min_ratio * 100, 1)}%"

      size_range != nil and not within_size_range?(result, size_range) ->
        {min_mb, max_mb} = size_range
        size_mb = Float.round(bytes_to_mb(result.size), 1)
        "size_out_of_range: #{size_mb} MB not in #{min_mb}-#{max_mb} MB"

      blocked_tag = find_blocked_tag(result, blocked_tags) ->
        "blocked_tag: #{blocked_tag}"

      true ->
        nil
    end
  end

  # Find which blocked tag matched (if any)
  defp find_blocked_tag(%SearchResult{title: title}, blocked_tags) do
    title_lower = String.downcase(title)

    Enum.find(blocked_tags, fn tag ->
      String.contains?(title_lower, String.downcase(tag))
    end)
  end

  ## Private Functions - Helpers

  defp bytes_to_mb(bytes) when is_integer(bytes) do
    bytes / (1024 * 1024)
  end

  defp round_score(value) when is_float(value), do: Float.round(value, 2)
  defp round_score(value) when is_integer(value), do: value * 1.0
end
