defmodule MydiaWeb.Schema.Resolvers.CollectionResolver do
  @moduledoc """
  Resolvers for collection-related GraphQL queries.
  """

  alias Mydia.Collections

  @tmdb_image_base "https://image.tmdb.org/t/p/original"

  def list_collections(_parent, args, %{context: %{current_user: user}}) do
    first = Map.get(args, :first, 50)

    collections =
      Collections.list_collections(user)
      |> Enum.reject(& &1.is_system)
      |> Enum.take(first)
      |> Enum.map(&build_collection/1)

    {:ok, collections}
  end

  def list_collections(_parent, _args, _info), do: {:ok, []}

  def collection(_parent, %{id: id}, %{context: %{current_user: user}}) do
    collection = Collections.get_collection!(user, id)
    {:ok, build_collection(collection)}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection(_parent, _args, _info), do: {:error, "Not authenticated"}

  def collection_items(_parent, %{collection_id: id} = args, %{context: %{current_user: user}}) do
    first = Map.get(args, :first, 50)
    collection = Collections.get_collection!(user, id)
    items = Collections.list_collection_items(collection, limit: first)

    result =
      items
      |> Enum.map(&build_recently_added_item/1)

    {:ok, result}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection_items(_parent, _args, _info), do: {:ok, []}

  # Private helpers

  defp build_collection(collection) do
    item_count = Collections.item_count(collection)
    posters = Collections.poster_paths(collection, 4)

    %{
      id: collection.id,
      name: collection.name,
      description: collection.description,
      type: collection.type,
      visibility: collection.visibility,
      item_count: item_count,
      poster_paths: Enum.map(posters, &build_image_url/1)
    }
  end

  defp build_recently_added_item(media_item) do
    %{
      id: media_item.id,
      type: String.to_atom(media_item.type),
      title: media_item.title,
      year: media_item.year,
      artwork: build_artwork(media_item),
      added_at: media_item.inserted_at
    }
  end

  defp build_artwork(%{metadata: nil}), do: nil

  defp build_artwork(%{metadata: metadata}) do
    poster_path = get_metadata_field(metadata, :poster_path)
    backdrop_path = get_metadata_field(metadata, :backdrop_path)

    %{
      poster_url: build_image_url(poster_path),
      backdrop_url: build_image_url(backdrop_path),
      thumbnail_url: nil
    }
  end

  defp build_artwork(_), do: nil

  defp get_metadata_field(nil, _field), do: nil

  defp get_metadata_field(metadata, field) when is_struct(metadata) do
    Map.get(metadata, field)
  end

  defp get_metadata_field(metadata, field) when is_map(metadata) do
    Map.get(metadata, field) || Map.get(metadata, to_string(field))
  end

  defp get_metadata_field(_metadata, _field), do: nil

  defp build_image_url(nil), do: nil
  defp build_image_url(""), do: nil
  defp build_image_url("/" <> _ = path), do: @tmdb_image_base <> path
  defp build_image_url(path), do: @tmdb_image_base <> "/" <> path
end
