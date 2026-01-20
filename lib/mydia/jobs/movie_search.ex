defmodule Mydia.Jobs.MovieSearch do
  @moduledoc """
  Background job for searching and downloading movie releases.

  This job searches indexers for movie releases and initiates downloads
  for the best matches. Supports both background execution for all monitored
  movies and UI-triggered searches for specific movies.

  ## Execution Modes

  - `"all_monitored"` - Search all monitored movies without files (scheduled)
  - `"specific"` - Search a single movie by ID (UI-triggered)

  ## Examples

      # Queue a search for all monitored movies
      %{mode: "all_monitored"}
      |> MovieSearch.new()
      |> Oban.insert()

      # Queue a search for a specific movie
      %{mode: "specific", media_item_id: 123}
      |> MovieSearch.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Repo, Media, Indexers, Downloads, Events, Search}
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Media.MediaItem
  alias Phoenix.PubSub

  # Get min_seeders from config (defaults to 0 for Usenet compatibility)
  defp get_min_seeders do
    Application.get_env(:mydia, :auto_search, [])[:min_seeders] || 0
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_monitored"} = args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting automatic search for all monitored movies")

    movies = load_monitored_movies_without_files()
    total_count = length(movies)

    Logger.info("Found #{total_count} monitored movies without files")

    if total_count == 0 do
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("No movies to search", duration_ms: duration)

      :ok
    else
      results = Enum.map(movies, &search_movie(&1, args))

      successful = Enum.count(results, &(&1 == :ok))
      failed = Enum.count(results, &match?({:error, _}, &1))
      no_results = Enum.count(results, &(&1 == :no_results))
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Automatic movie search completed",
        duration_ms: duration,
        total: total_count,
        successful: successful,
        failed: failed,
        no_results: no_results
      )

      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "specific", "media_item_id" => media_item_id} = args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting search for specific movie", media_item_id: media_item_id)

    result =
      try do
        media_item = Media.get_media_item!(media_item_id)

        case media_item do
          %MediaItem{type: "movie"} = movie ->
            search_movie_with_stats(movie, args)

          %MediaItem{type: type} ->
            Logger.error("Invalid media type for movie search",
              media_item_id: media_item_id,
              type: type
            )

            {:error, :invalid_type}
        end
      rescue
        Ecto.NoResultsError ->
          Logger.error("Media item not found", media_item_id: media_item_id)
          {:error, :not_found}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, stats} ->
        Logger.info("Movie search completed",
          duration_ms: duration,
          media_item_id: media_item_id,
          stats: stats
        )

        # Broadcast search completion for UI feedback
        broadcast_search_completed(media_item_id, stats)

        :ok

      {:no_results, stats} ->
        Logger.info("Movie search completed with no results",
          duration_ms: duration,
          media_item_id: media_item_id,
          stats: stats
        )

        # Broadcast search completion for UI feedback
        broadcast_search_completed(media_item_id, stats)

        :ok

      {:error, reason} ->
        Logger.error("Movie search failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        # Broadcast failure for UI feedback
        broadcast_search_completed(media_item_id, %{
          indexers_searched: 0,
          results_found: 0,
          downloads_initiated: 0,
          error: inspect(reason)
        })

        {:error, reason}
    end
  end

  ## Private Functions

  defp broadcast_search_completed(media_item_id, stats) do
    PubSub.broadcast(
      Mydia.PubSub,
      "downloads",
      {:search_completed, media_item_id, stats}
    )
  end

  defp search_movie_with_stats(%MediaItem{} = movie, args) do
    query = build_search_query(movie)
    indexers_count = count_enabled_indexers()

    Logger.info("Searching for movie",
      media_item_id: movie.id,
      title: movie.title,
      year: movie.year,
      query: query,
      indexers_count: indexers_count
    )

    min_seeders = get_min_seeders()

    case Indexers.search_all(query, min_seeders: min_seeders) do
      {:ok, []} ->
        Logger.warning("No results found for movie",
          media_item_id: movie.id,
          title: movie.title,
          query: query
        )

        # Log search event for no results
        Events.search_no_results(movie, %{
          "query" => query,
          "indexers_searched" => indexers_count
        })

        {:no_results,
         %{
           indexers_searched: indexers_count,
           results_found: 0,
           downloads_initiated: 0
         }}

      {:ok, results} ->
        Logger.info("Found #{length(results)} results for movie",
          media_item_id: movie.id,
          title: movie.title
        )

        {status, downloads_initiated} =
          process_search_results_with_count(movie, results, args, query)

        stats = %{
          indexers_searched: indexers_count,
          results_found: length(results),
          downloads_initiated: downloads_initiated
        }

        case status do
          :ok -> {:ok, stats}
          :no_results -> {:no_results, stats}
        end
    end
  end

  defp process_search_results_with_count(movie, results, args, query) do
    ranking_opts = build_ranking_options(movie, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning("No suitable results after ranking for movie",
          media_item_id: movie.id,
          title: movie.title,
          total_results: length(results)
        )

        # Log search event for all results filtered out
        Events.search_filtered_out(movie, %{
          "query" => query,
          "results_count" => length(results),
          "filter_stats" => build_filter_stats(results, ranking_opts)
        })

        {:no_results, 0}

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best result for movie",
          media_item_id: movie.id,
          title: movie.title,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown
        )

        # Log search completed event - search found and selected a result
        Events.search_completed(movie, %{
          "query" => query,
          "results_count" => length(results),
          "selected_release" => best_result.title,
          "score" => score,
          "breakdown" => stringify_keys(breakdown)
        })

        case initiate_download(movie, best_result) do
          :ok ->
            {:ok, 1}

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(movie, reason, %{
              "query" => query,
              "results_count" => length(results),
              "selected_release" => best_result.title,
              "score" => score
            })

            {:no_results, 0}
        end
    end
  end

  defp count_enabled_indexers do
    # Count enabled indexers from Settings
    indexers = Mydia.Settings.list_indexer_configs()
    enabled_count = Enum.count(indexers, & &1.enabled)

    # Also count Cardigann indexers if feature is enabled
    cardigann_count =
      if Application.get_env(:mydia, :features, [])[:cardigann_indexers] do
        Mydia.Indexers.list_cardigann_definitions()
        |> Enum.count(& &1.enabled)
      else
        0
      end

    enabled_count + cardigann_count
  end

  defp load_monitored_movies_without_files do
    movies =
      MediaItem
      |> where([m], m.type == "movie")
      |> where([m], m.monitored == true)
      |> join(:left, [m], mf in assoc(m, :media_files))
      |> group_by([m], m.id)
      |> having([m, mf], count(mf.id) == 0)
      |> Repo.all()

    filter_movies_in_backoff(movies)
  end

  defp filter_movies_in_backoff(movies) do
    {eligible, in_backoff} =
      Enum.split_with(movies, fn movie ->
        Search.eligible?("movie", movie.id)
      end)

    if in_backoff != [] do
      Logger.info("Skipping #{length(in_backoff)} movies in backoff")
    end

    eligible
  end

  defp search_movie(%MediaItem{} = movie, args) do
    query = build_search_query(movie)

    Logger.info("Searching for movie",
      media_item_id: movie.id,
      title: movie.title,
      year: movie.year,
      query: query
    )

    min_seeders = get_min_seeders()

    case Indexers.search_all(query, min_seeders: min_seeders) do
      {:ok, []} ->
        Logger.warning("No results found for movie",
          media_item_id: movie.id,
          title: movie.title,
          query: query
        )

        # Record backoff for no results
        record_movie_backoff(movie, "no_results")

        # Log search event for no results
        Events.search_no_results(movie, %{
          "query" => query,
          "indexers_searched" => count_enabled_indexers()
        })

        :no_results

      {:ok, results} ->
        Logger.info("Found #{length(results)} results for movie",
          media_item_id: movie.id,
          title: movie.title
        )

        process_search_results(movie, results, args, query)
    end
  end

  defp build_search_query(%MediaItem{title: title, year: nil}) do
    title
  end

  defp build_search_query(%MediaItem{title: title, year: year}) do
    "#{title} #{year}"
  end

  defp process_search_results(movie, results, args, query) do
    ranking_opts = build_ranking_options(movie, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning("No suitable results after ranking for movie",
          media_item_id: movie.id,
          title: movie.title,
          total_results: length(results)
        )

        # Record backoff for all results filtered out
        record_movie_backoff(movie, "all_filtered")

        # Log search event for all results filtered out
        Events.search_filtered_out(movie, %{
          "query" => query,
          "results_count" => length(results),
          "filter_stats" => build_filter_stats(results, ranking_opts)
        })

        :no_results

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best result for movie",
          media_item_id: movie.id,
          title: movie.title,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown
        )

        # Log search completed event - search found and selected a result
        Events.search_completed(movie, %{
          "query" => query,
          "results_count" => length(results),
          "selected_release" => best_result.title,
          "score" => score,
          "breakdown" => stringify_keys(breakdown)
        })

        case initiate_download(movie, best_result) do
          :ok ->
            # Reset backoff on successful download initiation
            reset_movie_backoff(movie)
            :ok

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(movie, reason, %{
              "query" => query,
              "results_count" => length(results),
              "selected_release" => best_result.title,
              "score" => score
            })

            :no_results
        end
    end
  end

  defp build_ranking_options(movie, args) do
    # Start with base options
    # Include search_query for title relevance scoring and media_type for unified scoring
    base_opts = [
      min_seeders: Map.get(args, "min_seeders", get_min_seeders()),
      size_range: Map.get(args, "size_range", {500, 20_000}),
      search_query: build_search_query(movie),
      media_type: :movie
    ]

    # Add quality profile for unified scoring via SearchScorer
    opts_with_quality =
      case load_quality_profile(movie) do
        nil ->
          base_opts

        quality_profile ->
          base_opts
          |> Keyword.put(:quality_profile, quality_profile)
          |> Keyword.merge(build_quality_options(quality_profile))
      end

    # Add any custom blocked/preferred tags from args
    opts_with_quality
    |> maybe_add_option(:blocked_tags, Map.get(args, "blocked_tags"))
    |> maybe_add_option(:preferred_tags, Map.get(args, "preferred_tags"))
  end

  defp load_quality_profile(%MediaItem{quality_profile_id: nil}), do: nil

  defp load_quality_profile(%MediaItem{} = movie) do
    movie
    |> Repo.preload(:quality_profile)
    |> Map.get(:quality_profile)
  end

  defp build_quality_options(quality_profile) do
    # Extract preferred qualities from quality profile
    # The :qualities field contains the list of allowed resolutions in preference order
    quality_opts =
      case Map.get(quality_profile, :qualities) do
        nil -> []
        qualities when is_list(qualities) -> [preferred_qualities: qualities]
        _ -> []
      end

    # Extract min_ratio from rules if present
    rules_opts =
      case Map.get(quality_profile, :rules) do
        %{"min_ratio" => min_ratio} when is_number(min_ratio) ->
          [min_ratio: min_ratio]

        _ ->
          []
      end

    Keyword.merge(quality_opts, rules_opts)
  end

  defp maybe_add_option(opts, _key, nil), do: opts
  defp maybe_add_option(opts, _key, []), do: opts
  defp maybe_add_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp initiate_download(movie, result) do
    case Downloads.initiate_download(result, media_item_id: movie.id) do
      {:ok, download} ->
        Logger.info("Successfully initiated download for movie",
          media_item_id: movie.id,
          title: movie.title,
          download_id: download.id,
          result_title: result.title
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to initiate download for movie",
          media_item_id: movie.id,
          title: movie.title,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions - Backoff Helpers

  defp record_movie_backoff(%MediaItem{} = movie, reason) do
    case Search.record_failure("movie", movie.id, reason) do
      {:ok, backoff} ->
        Logger.info("Applied search backoff for movie",
          media_item_id: movie.id,
          title: movie.title,
          failure_count: backoff.failure_count,
          next_eligible_at: backoff.next_eligible_at,
          reason: reason
        )

        # Emit backoff event
        Events.search_backoff_applied(
          movie,
          reason,
          Search.get_backoff_info("movie", movie.id)
        )

      {:error, changeset} ->
        Logger.error("Failed to record search backoff for movie",
          media_item_id: movie.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp reset_movie_backoff(%MediaItem{} = movie) do
    case Search.get_backoff("movie", movie.id) do
      nil ->
        :ok

      backoff ->
        previous_count = backoff.failure_count
        Search.reset_backoff("movie", movie.id)

        Logger.info("Reset search backoff for movie",
          media_item_id: movie.id,
          title: movie.title,
          previous_failure_count: previous_count
        )

        # Emit backoff reset event
        Events.search_backoff_reset(movie, previous_count)
    end
  end

  ## Private Functions - Event Helpers

  # Build a map of filter statistics for rejected results
  defp build_filter_stats(results, ranking_opts) do
    min_seeders = Keyword.get(ranking_opts, :min_seeders, get_min_seeders())

    low_seeders = Enum.count(results, fn r -> (r[:seeders] || 0) < min_seeders end)

    %{
      "total_results" => length(results),
      "low_seeders" => low_seeders,
      "below_quality_threshold" => length(results) - low_seeders
    }
  end

  # Convert a map with atom keys to string keys for JSON serialization
  defp stringify_keys(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
