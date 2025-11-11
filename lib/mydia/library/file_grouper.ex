defmodule Mydia.Library.FileGrouper do
  @moduledoc """
  Groups matched media files hierarchically for organized display and processing.

  This module provides functionality to organize matched media files into a
  hierarchical structure suitable for display in the import workflow:

  - TV shows are grouped by series → seasons → episodes
  - Movies are kept in a flat list
  - Unmatched files are kept separately

  ## Example

      matched_files = [
        %{file: file1, match_result: %{title: "Show A", parsed_info: %{type: :tv_show, season: 1, episodes: [1]}}},
        %{file: file2, match_result: %{title: "Movie B", parsed_info: %{type: :movie}}},
        %{file: file3, match_result: nil}
      ]

      FileGrouper.group_files(matched_files)
      # Returns:
      # %{
      #   series: [
      #     %{
      #       title: "Show A",
      #       seasons: [
      #         %{season_number: 1, episodes: [%{file: file1, index: 0, ...}]}
      #       ]
      #     }
      #   ],
      #   movies: [%{file: file2, index: 1, ...}],
      #   ungrouped: [%{file: file3, index: 2, ...}]
      # }
  """

  @type matched_file :: %{
          file: map(),
          match_result: match_result() | nil,
          import_status: atom()
        }

  @type match_result :: %{
          title: String.t(),
          provider_id: String.t(),
          year: integer() | nil,
          parsed_info: parsed_info()
        }

  @type parsed_info :: %{
          type: :tv_show | :movie,
          season: integer() | nil,
          episodes: [integer()] | nil
        }

  @type episode :: %{
          file: map(),
          match_result: match_result(),
          index: integer()
        }

  @type season :: %{
          season_number: integer(),
          episodes: [episode()]
        }

  @type series :: %{
          title: String.t(),
          provider_id: String.t(),
          year: integer() | nil,
          seasons: [season()]
        }

  @type grouped_files :: %{
          series: [series()],
          movies: [matched_file()],
          ungrouped: [matched_file()]
        }

  @doc """
  Groups matched files hierarchically by type (series, movies, ungrouped).

  Takes a list of matched files and organizes them into a structure suitable
  for display and processing. Files are indexed for easy reference.

  TV shows are grouped by series and season, with episodes sorted within each season.
  Movies are kept in a flat list. Files without matches are placed in the ungrouped list.

  ## Parameters

    * `matched_files` - List of matched file maps, each containing:
      - `:file` - The file information
      - `:match_result` - The metadata match (or nil if no match)
      - `:import_status` - The import status

  ## Returns

  A map with three keys:
    * `:series` - List of series maps, each containing seasons and episodes
    * `:movies` - List of movie file maps with index added
    * `:ungrouped` - List of unmatched file maps with index added

  ## Examples

      iex> files = [
      ...>   %{file: %{path: "/tv/show.s01e01.mkv"}, match_result: %{title: "Show", provider_id: "123", year: 2020, parsed_info: %{type: :tv_show, season: 1, episodes: [1]}}},
      ...>   %{file: %{path: "/movies/movie.mkv"}, match_result: %{title: "Movie", provider_id: "456", year: 2021, parsed_info: %{type: :movie}}},
      ...>   %{file: %{path: "/unknown.mkv"}, match_result: nil}
      ...> ]
      iex> FileGrouper.group_files(files)
      %{
        series: [%{title: "Show", provider_id: "123", year: 2020, seasons: [...]}],
        movies: [%{file: %{path: "/movies/movie.mkv"}, index: 1, ...}],
        ungrouped: [%{file: %{path: "/unknown.mkv"}, index: 2, ...}]
      }
  """
  @spec group_files([matched_file()]) :: grouped_files()
  def group_files(matched_files) when is_list(matched_files) do
    matched_files
    |> Enum.with_index()
    |> Enum.reduce(%{series: %{}, movies: [], ungrouped: []}, &group_file/2)
    |> finalize_grouping()
  end

  @doc """
  Generates a unique key for a series based on title and provider ID.

  This key is used internally for grouping episodes of the same series together.

  ## Parameters

    * `match_or_series` - Either a match result map or a series map containing
      `:title` and `:provider_id` fields

  ## Returns

  A string in the format "title-provider_id"

  ## Examples

      iex> FileGrouper.series_key(%{title: "Breaking Bad", provider_id: "1396"})
      "Breaking Bad-1396"
  """
  @spec series_key(match_result() | series()) :: String.t()
  def series_key(%{title: title, provider_id: provider_id}) do
    "#{title}-#{provider_id}"
  end

  # Private functions

  # Group a single file into the accumulator
  defp group_file({matched_file, index}, acc) do
    case matched_file.match_result do
      nil ->
        # No match - add to ungrouped
        %{acc | ungrouped: acc.ungrouped ++ [Map.put(matched_file, :index, index)]}

      match when match.parsed_info.type == :tv_show ->
        # TV show episode - group by series and season
        group_tv_show_episode(matched_file, index, match, acc)

      match when match.parsed_info.type == :movie ->
        # Movie - add to movies list
        %{acc | movies: acc.movies ++ [Map.put(matched_file, :index, index)]}

      _other ->
        # Unknown type - add to ungrouped
        %{acc | ungrouped: acc.ungrouped ++ [Map.put(matched_file, :index, index)]}
    end
  end

  # Group a TV show episode into the series hierarchy
  defp group_tv_show_episode(matched_file, index, match, acc) do
    series_id = series_key(match)
    season_num = match.parsed_info.season || 0

    # Get or create series entry
    series_entry =
      Map.get(acc.series, series_id, %{
        title: match.title,
        provider_id: match.provider_id,
        year: match.year,
        seasons: %{}
      })

    # Get or create season entry
    season_entry =
      Map.get(series_entry.seasons, season_num, %{
        season_number: season_num,
        episodes: []
      })

    # Add episode to season
    episode_entry = Map.put(matched_file, :index, index)
    updated_season = %{season_entry | episodes: season_entry.episodes ++ [episode_entry]}
    updated_series = put_in(series_entry.seasons[season_num], updated_season)
    updated_series_map = Map.put(acc.series, series_id, updated_series)

    %{acc | series: updated_series_map}
  end

  # Convert series map to list and sort seasons
  defp finalize_grouping(grouped) do
    series_list =
      grouped.series
      |> Map.values()
      |> Enum.map(fn series ->
        seasons_list =
          series.seasons
          |> Map.values()
          |> Enum.sort_by(& &1.season_number)

        Map.put(series, :seasons, seasons_list)
      end)
      |> Enum.sort_by(& &1.title)

    %{
      series: series_list,
      movies: grouped.movies,
      ungrouped: grouped.ungrouped
    }
  end
end
