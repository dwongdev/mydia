defmodule MydiaWeb.Schema.Resolvers.PlaybackResolver do
  @moduledoc """
  Resolvers for playback-related GraphQL mutations.
  """

  alias Mydia.{Media, Playback}

  def update_movie_progress(_parent, args, %{context: context}) do
    %{movie_id: movie_id, position_seconds: position} = args
    duration = Map.get(args, :duration_seconds)

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        attrs = %{
          position_seconds: position,
          duration_seconds: duration
        }

        case Playback.save_progress(user.id, [media_item_id: movie_id], attrs) do
          {:ok, progress} ->
            formatted_progress = format_progress(progress)

            # Publish subscription event
            Absinthe.Subscription.publish(
              MydiaWeb.Endpoint,
              formatted_progress,
              progress_updated: movie_id
            )

            {:ok, formatted_progress}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  def update_episode_progress(_parent, args, %{context: context}) do
    %{episode_id: episode_id, position_seconds: position} = args
    duration = Map.get(args, :duration_seconds)

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        attrs = %{
          position_seconds: position,
          duration_seconds: duration
        }

        case Playback.save_progress(user.id, [episode_id: episode_id], attrs) do
          {:ok, progress} ->
            formatted_progress = format_progress(progress)

            # Publish subscription event
            Absinthe.Subscription.publish(
              MydiaWeb.Endpoint,
              formatted_progress,
              progress_updated: episode_id
            )

            {:ok, formatted_progress}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  def mark_movie_watched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.mark_watched(user.id, media_item_id: movie_id) do
          {:ok, _progress} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}

          {:error, :not_found} ->
            # Create watched progress if it doesn't exist
            case Playback.save_progress(user.id, [media_item_id: movie_id], %{
                   position_seconds: 0,
                   duration_seconds: 1,
                   watched: true
                 }) do
              {:ok, _} ->
                movie = Media.get_media_item!(movie_id)
                {:ok, Map.put(movie, :added_at, movie.inserted_at)}

              {:error, changeset} ->
                {:error, format_changeset_errors(changeset)}
            end
        end
    end
  end

  def mark_movie_unwatched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.delete_progress(user.id, media_item_id: movie_id) do
          {:ok, _} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}

          {:error, :not_found} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}
        end
    end
  end

  def mark_episode_watched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.mark_watched(user.id, episode_id: episode_id) do
          {:ok, _progress} ->
            {:ok, Media.get_episode!(episode_id)}

          {:error, :not_found} ->
            # Create watched progress if it doesn't exist
            case Playback.save_progress(user.id, [episode_id: episode_id], %{
                   position_seconds: 0,
                   duration_seconds: 1,
                   watched: true
                 }) do
              {:ok, _} ->
                {:ok, Media.get_episode!(episode_id)}

              {:error, changeset} ->
                {:error, format_changeset_errors(changeset)}
            end
        end
    end
  end

  def mark_episode_unwatched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.delete_progress(user.id, episode_id: episode_id) do
          {:ok, _} ->
            {:ok, Media.get_episode!(episode_id)}

          {:error, :not_found} ->
            {:ok, Media.get_episode!(episode_id)}
        end
    end
  end

  def mark_season_watched(_parent, %{show_id: show_id, season_number: season_number}, %{
        context: context
      }) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        # Get all episodes in the season
        episodes =
          Media.list_episodes(show_id)
          |> Enum.filter(&(&1.season_number == season_number))

        # Mark each episode as watched
        Enum.each(episodes, fn episode ->
          case Playback.mark_watched(user.id, episode_id: episode.id) do
            {:ok, _} ->
              :ok

            {:error, :not_found} ->
              Playback.save_progress(user.id, [episode_id: episode.id], %{
                position_seconds: 0,
                duration_seconds: 1,
                watched: true
              })
          end
        end)

        show = Media.get_media_item!(show_id)
        {:ok, Map.put(show, :added_at, show.inserted_at)}
    end
  end

  def toggle_favorite(_parent, %{media_item_id: media_item_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Media.toggle_favorite(user.id, media_item_id) do
          {:ok, :added} ->
            {:ok, %{is_favorite: true, media_item_id: media_item_id}}

          {:ok, :removed} ->
            {:ok, %{is_favorite: false, media_item_id: media_item_id}}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  # Private helper functions

  defp format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
