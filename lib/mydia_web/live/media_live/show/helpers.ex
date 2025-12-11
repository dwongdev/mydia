defmodule MydiaWeb.MediaLive.Show.Helpers do
  @moduledoc """
  General helper functions for the MediaLive.Show page.
  Handles metadata extraction, episode status, download management, and UI helpers.
  """

  alias Mydia.Media
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Library
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Metadata.Structs.Video

  require Logger

  def has_media_files?(media_item) do
    # Check if media item has any files (movie files or episode files)
    movie_files = length(media_item.media_files || []) > 0

    episode_files =
      case media_item.type do
        "tv_show" ->
          media_item.episodes
          |> Enum.any?(fn episode -> length(episode.media_files || []) > 0 end)

        _ ->
          false
      end

    movie_files || episode_files
  end

  def get_poster_url(media_item) do
    case media_item.metadata do
      %MediaMetadata{poster_path: path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/w500#{path}"

      _ ->
        "/images/no-poster.svg"
    end
  end

  def get_backdrop_url(media_item) do
    case media_item.metadata do
      %MediaMetadata{backdrop_path: path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/original#{path}"

      _ ->
        nil
    end
  end

  def get_media_path(media_item) do
    # For movies, check media_files directly
    # For TV shows, check episode media_files
    first_file =
      case media_item.media_files do
        [file | _] ->
          file

        _ ->
          # Try to get from episodes for TV shows
          media_item
          |> Map.get(:episodes, [])
          |> Enum.flat_map(&Map.get(&1, :media_files, []))
          |> List.first()
      end

    case first_file do
      %{library_path: %{path: lib_path}, relative_path: rel_path}
      when is_binary(lib_path) and is_binary(rel_path) ->
        # For TV shows, go up one level to show series folder (not season folder)
        folder = Path.dirname(rel_path)

        folder =
          if media_item.type == "tv_show" do
            Path.dirname(folder)
          else
            folder
          end

        Path.join(lib_path, folder)

      %{relative_path: rel_path} when is_binary(rel_path) ->
        folder = Path.dirname(rel_path)

        if media_item.type == "tv_show" do
          Path.dirname(folder)
        else
          folder
        end

      _ ->
        nil
    end
  end

  def get_overview(media_item) do
    case media_item.metadata do
      %MediaMetadata{overview: overview} when is_binary(overview) and overview != "" ->
        overview

      _ ->
        "No overview available."
    end
  end

  def get_rating(media_item) do
    case media_item.metadata do
      %MediaMetadata{vote_average: rating} when is_number(rating) ->
        Float.round(rating, 1)

      _ ->
        nil
    end
  end

  def get_runtime(media_item) do
    case media_item.metadata do
      %MediaMetadata{runtime: runtime} when is_integer(runtime) and runtime > 0 ->
        hours = div(runtime, 60)
        minutes = rem(runtime, 60)

        cond do
          hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
          hours > 0 -> "#{hours}h"
          true -> "#{minutes}m"
        end

      _ ->
        nil
    end
  end

  def get_genres(media_item) do
    case media_item.metadata do
      %MediaMetadata{genres: genres} when is_list(genres) ->
        Enum.map(genres, fn
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  def get_cast(media_item, limit \\ 6) do
    case media_item.metadata do
      %MediaMetadata{cast: cast} when is_list(cast) ->
        cast
        |> Enum.take(limit)
        |> Enum.map(fn actor ->
          %{
            name: actor.name,
            character: actor.character,
            profile_path: actor.profile_path
          }
        end)

      _ ->
        []
    end
  end

  def get_crew(media_item) do
    case media_item.metadata do
      %MediaMetadata{crew: crew} when is_list(crew) ->
        # Get key crew members (directors, writers, producers)
        crew
        |> Enum.filter(fn member ->
          member.job in ["Director", "Writer", "Screenplay", "Executive Producer", "Producer"]
        end)
        |> Enum.uniq_by(fn member -> {member.name, member.job} end)
        |> Enum.take(6)
        |> Enum.map(fn member ->
          %{name: member.name, job: member.job}
        end)

      _ ->
        []
    end
  end

  def get_first_trailer(media_item) do
    case media_item.metadata do
      %MediaMetadata{videos: [%Video{} = video | _]} ->
        video

      _ ->
        nil
    end
  end

  def get_trailer_embed_url(media_item) do
    case get_first_trailer(media_item) do
      %Video{} = video -> Video.youtube_embed_url(video)
      _ -> nil
    end
  end

  def get_profile_image_url(nil), do: nil

  def get_profile_image_url(path) when is_binary(path) do
    "https://image.tmdb.org/t/p/w185#{path}"
  end

  def group_episodes_by_season(episodes) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.sort_by(fn {season, _} -> season end, :desc)
  end

  def get_episode_quality_badge(episode) do
    case episode.media_files do
      [] ->
        nil

      files ->
        files
        |> Enum.map(& &1.resolution)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(:desc)
        |> List.first()
    end
  end

  # Episode status helpers - delegates to EpisodeStatus module
  def get_episode_status(episode) do
    EpisodeStatus.get_episode_status_with_downloads(episode)
  end

  def episode_status_color(status) do
    EpisodeStatus.status_color(status)
  end

  def episode_status_icon(status) do
    EpisodeStatus.status_icon(status)
  end

  def episode_status_details(episode) do
    EpisodeStatus.status_details(episode)
  end

  @doc """
  Returns an enhanced tooltip for episode status that includes filenames for quick reference.
  """
  def episode_status_tooltip(episode) do
    base_status = EpisodeStatus.status_details(episode)

    case episode.media_files do
      [_ | _] = files ->
        filenames =
          files
          |> Enum.map(fn file ->
            absolute_path = Mydia.Library.MediaFile.absolute_path(file)
            basename = Path.basename(absolute_path)
            resolution = file.resolution || "?"
            "• #{basename} (#{resolution})"
          end)
          |> Enum.join("\n")

        "#{base_status}\n\nFiles:\n#{filenames}"

      _ ->
        base_status
    end
  end

  def get_download_status(downloads_with_status) do
    active_downloads =
      downloads_with_status
      |> Enum.filter(fn d -> d.status in ["downloading", "seeding", "checking", "paused"] end)

    case active_downloads do
      [] -> nil
      [download | _] -> download
    end
  end

  # Auto search helper functions

  def can_auto_search?(%Media.MediaItem{} = media_item, _downloads_with_status) do
    # Always allow auto search for supported media types
    # Users should be able to re-search even if files exist or downloads are in history
    media_item.type in ["movie", "tv_show"]
  end

  def has_active_download?(downloads_with_status) do
    Enum.any?(downloads_with_status, fn d ->
      d.status in ["downloading", "checking"]
    end)
  end

  def episode_in_season?(episode_id, season_num) do
    episode = Media.get_episode!(episode_id)
    episode.season_number == season_num
  end

  # Helper to get all media files for episodes in a specific season
  def get_season_media_files(media_item, season_number) do
    media_item.episodes
    |> Enum.filter(&(&1.season_number == season_number))
    |> Enum.flat_map(& &1.media_files)
  end

  # File metadata refresh helper
  def refresh_files(media_files) do
    Logger.info("Starting file metadata refresh", file_count: length(media_files))

    results =
      Enum.map(media_files, fn file ->
        case Library.refresh_file_metadata(file) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))

    Logger.info("Completed file metadata refresh",
      success: success_count,
      errors: error_count
    )

    {:ok, success_count, error_count}
  end

  # Get button text based on watch state
  def next_episode_button_text(:continue), do: "Continue Watching"
  def next_episode_button_text(:next), do: "Play Next Episode"
  def next_episode_button_text(:start), do: "Start Watching"
  def next_episode_button_text(_), do: "Play"

  # Get episode thumbnail from metadata
  def get_episode_thumbnail(episode) do
    case episode.metadata do
      %{"still_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/w300#{path}"

      _ ->
        # Use a placeholder or the series poster
        nil
    end
  end

  # Check if playback feature is enabled
  def playback_enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:playback_enabled, false)
  end

  # Check if subtitle feature is enabled
  def subtitle_feature_enabled? do
    Mydia.Subtitles.FeatureFlags.enabled?()
  end

  def download_for_media?(download, media_item) do
    download.media_item_id == media_item.id or
      (download.episode_id &&
         Enum.any?(media_item.episodes, fn ep -> ep.id == download.episode_id end))
  end

  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def parse_int(value) when is_integer(value), do: value

  def parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  def parse_int(_), do: 0

  # Parse optional integer (returns nil if not present or invalid)
  def parse_optional_int(nil), do: nil
  def parse_optional_int(""), do: nil
  def parse_optional_int(value) when is_integer(value), do: value

  def parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  def parse_optional_int(_), do: nil

  # Parse optional float (returns nil if not present or invalid)
  def parse_optional_float(nil), do: nil
  def parse_optional_float(""), do: nil
  def parse_optional_float(value) when is_float(value), do: value

  def parse_optional_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  def parse_optional_float(_), do: nil
end
