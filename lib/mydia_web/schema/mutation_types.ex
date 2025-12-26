defmodule MydiaWeb.Schema.MutationTypes do
  @moduledoc """
  GraphQL mutation type definitions.
  """

  use Absinthe.Schema.Notation

  alias MydiaWeb.Schema.Resolvers.PlaybackResolver
  alias MydiaWeb.Schema.Resolvers.RemoteAccessResolver
  alias MydiaWeb.Schema.Resolvers.ApiKeyResolver

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

  object :api_key_mutations do
    @desc "Create a new API key for the current user"
    field :create_api_key, :create_api_key_result do
      arg(:name, non_null(:string))
      arg(:permissions, list_of(non_null(:string)))
      arg(:expires_at, :datetime)
      resolve(&ApiKeyResolver.create_api_key/3)
    end

    @desc "Revoke an API key"
    field :revoke_api_key, :api_key do
      arg(:id, non_null(:id))
      resolve(&ApiKeyResolver.revoke_api_key/3)
    end

    @desc "Delete an API key"
    field :delete_api_key, :boolean do
      arg(:id, non_null(:id))
      resolve(&ApiKeyResolver.delete_api_key/3)
    end
  end

  object :auth_mutations do
    @desc "Login with username/password and device information"
    field :login, :login_result do
      arg(:input, non_null(:login_input))
      resolve(&MydiaWeb.Schema.Resolvers.AuthResolver.login/3)
    end
  end

  object :device_mutations do
    @desc "Revoke a device"
    field :revoke_device, :revoke_device_result do
      arg(:id, non_null(:id))
      resolve(&MydiaWeb.Schema.Resolvers.DeviceResolver.revoke_device/3)
    end
  end
end
