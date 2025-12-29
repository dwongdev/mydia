defmodule Mydia.Collections.CollectionItem do
  @moduledoc """
  Schema for items within a manual collection.

  This join table links media items to collections and supports:
  - Position-based ordering for manual collections
  - Unique constraint preventing duplicate items in the same collection
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "collection_items" do
    field :position, :integer, default: 0

    belongs_to :collection, Mydia.Collections.Collection
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for creating or updating a collection item.
  """
  def changeset(collection_item, attrs) do
    collection_item
    |> cast(attrs, [:position])
    |> validate_required([])
    |> unique_constraint([:collection_id, :media_item_id])
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:media_item_id)
  end
end
