defmodule MydiaWeb.Schema.CommonTypes do
  @moduledoc """
  Common GraphQL types shared across the schema.
  """

  use Absinthe.Schema.Notation

  @desc "Artwork URLs for a media item"
  object :artwork do
    field :poster_url, :string, description: "Poster image URL"
    field :backdrop_url, :string, description: "Backdrop/fanart image URL"
    field :thumbnail_url, :string, description: "Thumbnail image URL"
  end

  @desc "A playable video file"
  object :media_file do
    field :id, non_null(:id), description: "File ID"
    field :resolution, :string, description: "Video resolution (e.g., 1080p)"
    field :codec, :string, description: "Video codec (e.g., hevc, h264)"
    field :audio_codec, :string, description: "Audio codec (e.g., dts, aac)"
    field :hdr_format, :string, description: "HDR format if applicable (e.g., dolby_vision)"
    field :size, :integer, description: "File size in bytes"
    field :bitrate, :integer, description: "Bitrate in bits per second"

    @desc "Whether this file can be direct played (no transcoding needed)"
    field :direct_play_supported, :boolean do
      resolve(fn _file, _args, _info ->
        # TODO: Implement based on client capabilities
        {:ok, true}
      end)
    end

    @desc "Streaming URL for this file"
    field :stream_url, :string do
      resolve(fn file, _args, _info ->
        {:ok, "/api/v1/stream/file/#{file.id}"}
      end)
    end

    @desc "Direct play URL (no transcoding)"
    field :direct_play_url, :string do
      resolve(fn file, _args, _info ->
        {:ok, "/api/v1/stream/file/#{file.id}?strategy=DIRECT_PLAY"}
      end)
    end
  end

  @desc "User playback progress on a media item or episode"
  object :progress do
    field :position_seconds, non_null(:integer), description: "Current position in seconds"
    field :duration_seconds, :integer, description: "Total duration in seconds"
    field :percentage, :float, description: "Completion percentage (0-100)"
    field :watched, non_null(:boolean), description: "Whether marked as watched"
    field :last_watched_at, :datetime, description: "Last watched timestamp"
  end

  @desc "Input for sorting lists"
  input_object :sort_input do
    field :field, :sort_field, default_value: :title
    field :direction, :sort_direction, default_value: :asc
  end

  @desc "Pagination info for cursor-based pagination"
  object :page_info do
    field :has_next_page, non_null(:boolean)
    field :has_previous_page, non_null(:boolean)
    field :start_cursor, :string
    field :end_cursor, :string
  end

  @desc "Search result with relevance score"
  object :search_result do
    field :id, non_null(:id)
    field :type, non_null(:media_type)
    field :title, non_null(:string)
    field :year, :integer
    field :artwork, :artwork
    field :score, :float, description: "Relevance score"
  end

  @desc "Search results container"
  object :search_results do
    field :results, non_null(list_of(non_null(:search_result)))
    field :total_count, non_null(:integer)
  end

  @desc "A library path for organizing media"
  object :library_path do
    interface(:node)

    field :id, non_null(:id)

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :path, non_null(:string), description: "Filesystem path"
    field :type, non_null(:library_type), description: "Type of content in this library"
    field :monitored, non_null(:boolean), description: "Whether this path is actively monitored"
    field :scan_interval, :integer, description: "Scan interval in seconds"
    field :last_scan_at, :datetime, description: "Last scan timestamp"
    field :auto_organize, non_null(:boolean), description: "Whether auto-organization is enabled"
    field :auto_import, non_null(:boolean), description: "Whether auto-import is enabled"
  end

  @desc "Result of toggling favorite status"
  object :toggle_favorite_result do
    field :is_favorite, non_null(:boolean), description: "New favorite status"
    field :media_item_id, non_null(:id), description: "ID of the media item"
  end

  @desc "Media access token for direct media requests"
  object :media_token do
    field :token, non_null(:string), description: "JWT token for media access"
    field :expires_at, non_null(:datetime), description: "Token expiration timestamp"

    field :permissions, non_null(list_of(non_null(:string))),
      description: "List of granted permissions"
  end
end
