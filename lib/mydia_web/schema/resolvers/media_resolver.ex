defmodule MydiaWeb.Schema.Resolvers.MediaResolver do
  @moduledoc """
  Resolvers for media-related GraphQL fields.
  """

  alias Mydia.{Media, Library, Playback}

  @tmdb_image_base "https://image.tmdb.org/t/p/original"

  # Movie and TVShow field resolvers

  def resolve_overview(parent, _args, _info) do
    {:ok, get_metadata_field(parent, :overview)}
  end

  def resolve_runtime(parent, _args, _info) do
    {:ok, get_metadata_field(parent, :runtime)}
  end

  def resolve_genres(parent, _args, _info) do
    {:ok, get_metadata_field(parent, :genres) || []}
  end

  def resolve_content_rating(_parent, _args, _info) do
    # Content rating isn't stored in our current metadata
    {:ok, nil}
  end

  def resolve_rating(parent, _args, _info) do
    {:ok, get_metadata_field(parent, :vote_average)}
  end

  def resolve_status(parent, _args, _info) do
    {:ok, get_metadata_field(parent, :status)}
  end

  def resolve_category(%{category: category}, _args, _info) when is_binary(category) do
    {:ok, String.to_existing_atom(category)}
  end

  def resolve_category(%{category: category}, _args, _info) when is_atom(category) do
    {:ok, category}
  end

  def resolve_category(_parent, _args, _info), do: {:ok, nil}

  def resolve_artwork(%{metadata: metadata} = _parent, _args, _info) do
    poster_path = get_in_metadata(metadata, :poster_path)
    backdrop_path = get_in_metadata(metadata, :backdrop_path)

    artwork = %{
      poster_url: build_image_url(poster_path),
      backdrop_url: build_image_url(backdrop_path),
      thumbnail_url: nil
    }

    {:ok, artwork}
  end

  def resolve_artwork(_parent, _args, _info), do: {:ok, nil}

  # Movie-specific resolvers

  def resolve_movie_files(%{id: media_item_id}, _args, _info) do
    files = Library.get_media_files_for_item(media_item_id)
    {:ok, files}
  end

  def resolve_progress(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, nil}

      user ->
        case Playback.get_progress(user.id, media_item_id: media_item_id) do
          nil ->
            {:ok, nil}

          progress ->
            {:ok, format_progress(progress)}
        end
    end
  end

  # TV Show-specific resolvers

  def resolve_seasons(%{id: media_item_id}, _args, _info) do
    # Get all episodes and group by season
    episodes = Media.list_episodes(media_item_id)

    seasons =
      episodes
      |> Enum.group_by(& &1.season_number)
      |> Enum.map(fn {season_number, season_episodes} ->
        # Check if any episode has files
        has_files =
          Enum.any?(season_episodes, fn ep ->
            files = Library.get_media_files_for_episode(ep.id)
            length(files) > 0
          end)

        # Count aired episodes (air_date is in the past)
        today = Date.utc_today()

        aired_count =
          Enum.count(season_episodes, fn ep ->
            ep.air_date != nil and Date.compare(ep.air_date, today) != :gt
          end)

        %{
          season_number: season_number,
          episode_count: length(season_episodes),
          aired_episode_count: aired_count,
          has_files: has_files,
          # Store episodes for nested resolution
          _episodes: season_episodes,
          _media_item_id: media_item_id
        }
      end)
      |> Enum.sort_by(& &1.season_number)

    {:ok, seasons}
  end

  def resolve_season_count(%{id: media_item_id}, _args, _info) do
    episodes = Media.list_episodes(media_item_id)

    season_count =
      episodes
      |> Enum.map(& &1.season_number)
      |> Enum.uniq()
      |> length()

    {:ok, season_count}
  end

  def resolve_episode_count(%{id: media_item_id}, _args, _info) do
    episodes = Media.list_episodes(media_item_id)
    {:ok, length(episodes)}
  end

  def resolve_next_episode(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        # Return first episode if no user
        case Media.list_episodes(media_item_id) do
          [] -> {:ok, nil}
          [first | _] -> {:ok, first}
        end

      user ->
        case Playback.get_next_episode(media_item_id, user.id) do
          nil -> {:ok, nil}
          :all_watched -> {:ok, nil}
          {_state, episode} -> {:ok, episode}
        end
    end
  end

  # Season resolver for episodes
  def resolve_season_episodes(%{_episodes: episodes}, _args, _info) when is_list(episodes) do
    sorted = Enum.sort_by(episodes, & &1.episode_number)
    {:ok, sorted}
  end

  def resolve_season_episodes(
        %{season_number: season_number, _media_item_id: media_item_id},
        _args,
        _info
      ) do
    episodes =
      Media.list_episodes(media_item_id)
      |> Enum.filter(&(&1.season_number == season_number))
      |> Enum.sort_by(& &1.episode_number)

    {:ok, episodes}
  end

  # Episode-specific resolvers

  def resolve_episode_overview(%{metadata: metadata}, _args, _info) do
    {:ok, get_in_metadata(metadata, :overview)}
  end

  def resolve_episode_overview(_episode, _args, _info), do: {:ok, nil}

  def resolve_episode_runtime(%{metadata: metadata}, _args, _info) do
    {:ok, get_in_metadata(metadata, :runtime)}
  end

  def resolve_episode_runtime(_episode, _args, _info), do: {:ok, nil}

  def resolve_episode_thumbnail(%{metadata: metadata}, _args, _info) do
    still_path = get_in_metadata(metadata, :still_path)
    {:ok, build_image_url(still_path)}
  end

  def resolve_episode_thumbnail(_episode, _args, _info), do: {:ok, nil}

  def resolve_episode_files(%{id: episode_id}, _args, _info) do
    files = Library.get_media_files_for_episode(episode_id)
    {:ok, files}
  end

  def resolve_episode_progress(%{id: episode_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, nil}

      user ->
        case Playback.get_progress(user.id, episode_id: episode_id) do
          nil ->
            {:ok, nil}

          progress ->
            {:ok, format_progress(progress)}
        end
    end
  end

  def resolve_has_file(%{id: episode_id}, _args, _info) do
    files = Library.get_media_files_for_episode(episode_id)
    {:ok, length(files) > 0}
  end

  def resolve_parent_show(%{media_item_id: media_item_id}, _args, _info)
      when not is_nil(media_item_id) do
    show = Media.get_media_item!(media_item_id)
    {:ok, Map.put(show, :added_at, show.inserted_at)}
  rescue
    Ecto.NoResultsError -> {:ok, nil}
  end

  def resolve_parent_show(_episode, _args, _info), do: {:ok, nil}

  # Helper functions

  defp get_metadata_field(%{metadata: nil}, _field), do: nil

  defp get_metadata_field(%{metadata: metadata}, field) do
    get_in_metadata(metadata, field)
  end

  defp get_metadata_field(_parent, _field), do: nil

  defp get_in_metadata(nil, _field), do: nil

  defp get_in_metadata(metadata, field) when is_struct(metadata) do
    Map.get(metadata, field)
  end

  defp get_in_metadata(metadata, field) when is_map(metadata) do
    Map.get(metadata, field) || Map.get(metadata, to_string(field))
  end

  defp get_in_metadata(_metadata, _field), do: nil

  defp build_image_url(nil), do: nil
  defp build_image_url(""), do: nil
  defp build_image_url("/" <> _ = path), do: @tmdb_image_base <> path
  defp build_image_url(path), do: @tmdb_image_base <> "/" <> path

  defp format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end

  # Favorites resolver

  def resolve_is_favorite(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, false}

      user ->
        {:ok, Media.is_favorite?(user.id, media_item_id)}
    end
  end
end
