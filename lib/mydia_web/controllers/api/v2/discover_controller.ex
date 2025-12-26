defmodule MydiaWeb.Api.V2.DiscoverController do
  @moduledoc """
  REST API controller for content discovery.

  Provides endpoints for personalized content recommendations including
  continue watching, recently added media, and next episodes to watch.
  """

  use MydiaWeb, :controller

  alias Mydia.{Media, Playback}
  alias Mydia.Auth.Guardian
  alias Mydia.Playback.Progress
  import Ecto.Query
  require Logger

  @doc """
  Gets in-progress content for the current user.

  Returns movies and episodes sorted by last watched time (most recent first).
  Only includes content with < 90% completion.

  GET /api/v2/discover/continue

  Returns:
    - 200: List of in-progress items with progress data
  """
  def continue_watching(conn, _params) do
    current_user = Guardian.Plug.current_resource(conn)

    # Get all in-progress items (< 90% completion) ordered by last_watched_at desc
    progress_items =
      from(p in Progress,
        where: p.user_id == ^current_user.id,
        where: p.completion_percentage < 90.0,
        order_by: [desc: p.last_watched_at],
        preload: [:media_item, :episode]
      )
      |> Mydia.Repo.all()

    # Serialize the results
    items =
      progress_items
      |> Enum.map(&serialize_continue_watching_item/1)
      |> Enum.reject(&is_nil/1)

    json(conn, %{data: items})
  end

  @doc """
  Gets recently added media items.

  Returns movies and TV shows added in the last 30 days, sorted by insertion date.

  GET /api/v2/discover/recent

  Query params:
    - days (optional): Number of days to look back (default: 30, max: 365)
    - limit (optional): Maximum number of items to return (default: 50, max: 200)

  Returns:
    - 200: List of recently added media items
  """
  def recent(conn, params) do
    current_user = Guardian.Plug.current_resource(conn)
    days = parse_days(params["days"])
    limit = parse_limit(params["limit"])

    # Calculate the cutoff date
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    # Query recently added media items
    recent_items =
      from(m in Media.MediaItem,
        where: m.inserted_at >= ^cutoff_date,
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [:media_files, episodes: :media_files]
      )
      |> Mydia.Repo.all()

    # Get progress for the current user for these items
    media_item_ids = Enum.map(recent_items, & &1.id)

    progress_map =
      from(p in Progress,
        where: p.user_id == ^current_user.id,
        where: p.media_item_id in ^media_item_ids,
        select: {p.media_item_id, p}
      )
      |> Mydia.Repo.all()
      |> Map.new()

    # Serialize the results
    items =
      recent_items
      |> Enum.map(fn item ->
        serialize_recent_item(item, Map.get(progress_map, item.id))
      end)

    json(conn, %{data: items})
  end

  @doc """
  Gets the next unwatched episode for each TV show with progress.

  Returns one episode per show - either the first unwatched episode
  or the episode currently in progress.

  GET /api/v2/discover/up_next

  Query params:
    - limit (optional): Maximum number of shows to return (default: 50, max: 200)

  Returns:
    - 200: List of next episodes to watch, one per show
  """
  def up_next(conn, params) do
    current_user = Guardian.Plug.current_resource(conn)
    limit = parse_limit(params["limit"])

    # Get all TV shows the user has started watching
    # Find shows where the user has progress on at least one episode
    shows_with_progress =
      from(p in Progress,
        join: e in Mydia.Media.Episode,
        on: p.episode_id == e.id,
        join: m in Media.MediaItem,
        on: e.media_item_id == m.id,
        where: p.user_id == ^current_user.id,
        where: not is_nil(p.episode_id),
        where: m.type == "tv_show",
        distinct: m.id,
        select: m.id,
        order_by: [desc: max(p.last_watched_at)],
        group_by: m.id,
        limit: ^limit
      )
      |> Mydia.Repo.all()

    # For each show, get the next episode to watch
    items =
      shows_with_progress
      |> Enum.map(fn media_item_id ->
        case Playback.get_next_episode(media_item_id, current_user.id) do
          {:continue, episode} ->
            progress = Playback.get_progress(current_user.id, episode_id: episode.id)
            serialize_up_next_item(episode, progress, :continue)

          {:next, episode} ->
            serialize_up_next_item(episode, nil, :next)

          {:start, episode} ->
            serialize_up_next_item(episode, nil, :start)

          :all_watched ->
            nil

          nil ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    json(conn, %{data: items})
  end

  ## Private Functions

  defp parse_days(nil), do: 30

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} when n > 0 and n <= 365 -> n
      _ -> 30
    end
  end

  defp parse_days(_), do: 30

  defp parse_limit(nil), do: 50

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 and n <= 200 -> n
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50

  defp serialize_continue_watching_item(%Progress{media_item_id: media_item_id} = progress)
       when not is_nil(media_item_id) do
    media_item = progress.media_item

    if is_nil(media_item) do
      nil
    else
      %{
        type: "movie",
        id: media_item.id,
        title: media_item.title,
        year: media_item.year,
        poster_url: get_metadata_field(media_item.metadata, "poster_path"),
        backdrop_url: get_metadata_field(media_item.metadata, "backdrop_path"),
        progress: %{
          position_seconds: progress.position_seconds,
          duration_seconds: progress.duration_seconds,
          completion_percentage: progress.completion_percentage,
          last_watched_at: progress.last_watched_at
        }
      }
    end
  end

  defp serialize_continue_watching_item(%Progress{episode_id: episode_id} = progress)
       when not is_nil(episode_id) do
    episode = progress.episode

    if is_nil(episode) do
      nil
    else
      # Need to load the media_item for the episode
      episode = Mydia.Repo.preload(episode, :media_item)
      media_item = episode.media_item

      if is_nil(media_item) do
        nil
      else
        %{
          type: "episode",
          id: episode.id,
          title: episode.title,
          season_number: episode.season_number,
          episode_number: episode.episode_number,
          still_url: get_metadata_field(episode.metadata, "still_path"),
          show: %{
            id: media_item.id,
            title: media_item.title,
            poster_url: get_metadata_field(media_item.metadata, "poster_path"),
            backdrop_url: get_metadata_field(media_item.metadata, "backdrop_path")
          },
          progress: %{
            position_seconds: progress.position_seconds,
            duration_seconds: progress.duration_seconds,
            completion_percentage: progress.completion_percentage,
            last_watched_at: progress.last_watched_at
          }
        }
      end
    end
  end

  defp serialize_continue_watching_item(_), do: nil

  defp serialize_recent_item(media_item, progress) do
    base = %{
      id: media_item.id,
      type: media_item.type,
      title: media_item.title,
      year: media_item.year,
      poster_url: get_metadata_field(media_item.metadata, "poster_path"),
      backdrop_url: get_metadata_field(media_item.metadata, "backdrop_path"),
      overview: get_metadata_field(media_item.metadata, "overview"),
      added_at: media_item.inserted_at
    }

    if media_item.type == "movie" do
      base
      |> Map.put(:has_file, length(media_item.media_files) > 0)
      |> Map.put(:progress, serialize_progress(progress))
    else
      # For TV shows, include episode count info
      total_episodes = count_total_episodes(media_item)
      available_episodes = count_available_episodes(media_item)

      base
      |> Map.put(:total_episodes, total_episodes)
      |> Map.put(:available_episodes, available_episodes)
    end
  end

  defp serialize_up_next_item(episode, progress, state) do
    episode = Mydia.Repo.preload(episode, :media_item)
    media_item = episode.media_item

    %{
      type: "episode",
      id: episode.id,
      title: episode.title,
      season_number: episode.season_number,
      episode_number: episode.episode_number,
      air_date: episode.air_date,
      still_url: get_metadata_field(episode.metadata, "still_path"),
      overview: get_metadata_field(episode.metadata, "overview"),
      state: state,
      show: %{
        id: media_item.id,
        title: media_item.title,
        poster_url: get_metadata_field(media_item.metadata, "poster_path"),
        backdrop_url: get_metadata_field(media_item.metadata, "backdrop_path")
      },
      progress: serialize_progress(progress)
    }
  end

  defp serialize_progress(nil) do
    %{
      position_seconds: 0,
      duration_seconds: nil,
      completion_percentage: 0.0,
      watched: false
    }
  end

  defp serialize_progress(progress) do
    %{
      position_seconds: progress.position_seconds,
      duration_seconds: progress.duration_seconds,
      completion_percentage: progress.completion_percentage,
      watched: progress.watched,
      last_watched_at: progress.last_watched_at
    }
  end

  defp get_metadata_field(metadata, field) when is_map(metadata) do
    Map.get(metadata, field)
  end

  defp get_metadata_field(_, _), do: nil

  defp count_total_episodes(media_item) do
    length(media_item.episodes)
  end

  defp count_available_episodes(media_item) do
    media_item.episodes
    |> Enum.count(fn episode -> length(episode.media_files) > 0 end)
  end
end
