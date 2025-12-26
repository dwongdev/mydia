defmodule Mydia.Media.UserFavorite do
  @moduledoc """
  Schema for user favorites (movies and TV shows).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_favorites" do
    belongs_to :user, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating user favorites.
  """
  def changeset(user_favorite, attrs) do
    user_favorite
    |> cast(attrs, [:user_id, :media_item_id])
    |> validate_required([:user_id, :media_item_id])
    |> unique_constraint([:user_id, :media_item_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:media_item_id)
  end
end
