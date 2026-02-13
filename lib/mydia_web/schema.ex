defmodule MydiaWeb.Schema do
  @moduledoc """
  GraphQL schema for the Mydia player API.

  Provides a unified GraphQL interface for the Flutter player client to:
  - Browse libraries (movies, TV shows)
  - Get playback information
  - Track playback progress
  - Discover content (continue watching, recently added, up next)

  This schema works with the existing data model:
  - MediaItem (movies and TV shows)
  - Episode (TV episodes)
  - MediaFile (video files)
  - Progress (playback tracking)
  """

  use Absinthe.Schema

  import_types(Absinthe.Type.Custom)
  import_types(MydiaWeb.Schema.EnumTypes)
  import_types(MydiaWeb.Schema.CommonTypes)
  import_types(MydiaWeb.Schema.MediaTypes)
  import_types(MydiaWeb.Schema.QueryTypes)
  import_types(MydiaWeb.Schema.MutationTypes)
  import_types(MydiaWeb.Schema.SubscriptionTypes)

  query do
    import_fields(:browse_queries)
    import_fields(:discovery_queries)
    import_fields(:search_queries)
    import_fields(:api_key_queries)
    import_fields(:device_queries)
    import_fields(:remote_access_queries)
    import_fields(:streaming_queries)
    import_fields(:collection_queries)
  end

  mutation do
    import_fields(:playback_mutations)
    import_fields(:remote_access_mutations)
    import_fields(:api_key_mutations)
    import_fields(:auth_mutations)
    import_fields(:device_mutations)
    import_fields(:streaming_mutations)
    import_fields(:download_mutations)
  end

  subscription do
    import_fields(:playback_subscriptions)
    import_fields(:device_subscriptions)
  end
end
