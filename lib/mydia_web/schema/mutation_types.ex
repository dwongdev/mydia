defmodule MydiaWeb.Schema.MutationTypes do
  @moduledoc """
  GraphQL mutation type definitions.
  """

  use Absinthe.Schema.Notation

  alias MydiaWeb.Schema.Resolvers.PlaybackResolver
  alias MydiaWeb.Schema.Resolvers.RemoteAccessResolver

  object :playback_mutations do
    @desc "Update playback progress for a movie"
    field :update_movie_progress, :progress do
      arg(:movie_id, non_null(:id))
      arg(:position_seconds, non_null(:integer))
      arg(:duration_seconds, :integer)
      resolve(&PlaybackResolver.update_movie_progress/3)
    end

    @desc "Update playback progress for an episode"
    field :update_episode_progress, :progress do
      arg(:episode_id, non_null(:id))
      arg(:position_seconds, non_null(:integer))
      arg(:duration_seconds, :integer)
      resolve(&PlaybackResolver.update_episode_progress/3)
    end

    @desc "Mark a movie as watched"
    field :mark_movie_watched, :movie do
      arg(:movie_id, non_null(:id))
      resolve(&PlaybackResolver.mark_movie_watched/3)
    end

    @desc "Mark a movie as unwatched"
    field :mark_movie_unwatched, :movie do
      arg(:movie_id, non_null(:id))
      resolve(&PlaybackResolver.mark_movie_unwatched/3)
    end

    @desc "Mark an episode as watched"
    field :mark_episode_watched, :episode do
      arg(:episode_id, non_null(:id))
      resolve(&PlaybackResolver.mark_episode_watched/3)
    end

    @desc "Mark an episode as unwatched"
    field :mark_episode_unwatched, :episode do
      arg(:episode_id, non_null(:id))
      resolve(&PlaybackResolver.mark_episode_unwatched/3)
    end

    @desc "Mark all episodes in a season as watched"
    field :mark_season_watched, :tv_show do
      arg(:show_id, non_null(:id))
      arg(:season_number, non_null(:integer))
      resolve(&PlaybackResolver.mark_season_watched/3)
    end

    @desc "Toggle favorite status for a media item"
    field :toggle_favorite, :toggle_favorite_result do
      arg(:media_item_id, non_null(:id))
      resolve(&PlaybackResolver.toggle_favorite/3)
    end
  end

  object :remote_access_mutations do
    @desc "Refresh a media access token before it expires"
    field :refresh_media_token, :media_token do
      arg(:token, non_null(:string))
      resolve(&RemoteAccessResolver.refresh_media_token/3)
    end
  end
end
