defmodule Mydia.CollectionsFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the `Mydia.Collections` context.
  """

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections

  @doc """
  Generate a collection.
  """
  def collection_fixture(attrs \\ %{}) do
    # Create a user if not provided
    user =
      case Map.get(attrs, :user) || Map.get(attrs, :user_id) do
        nil -> user_fixture()
        %Mydia.Accounts.User{} = user -> user
        user_id when is_binary(user_id) -> Mydia.Repo.get!(Mydia.Accounts.User, user_id)
      end

    default_attrs = %{
      name: "Test Collection #{System.unique_integer([:positive])}",
      type: "manual",
      visibility: "private"
    }

    attrs =
      attrs
      |> Map.drop([:user, :user_id])
      |> Map.merge(default_attrs, fn _k, user_val, _default -> user_val end)

    {:ok, collection} = Collections.create_collection(user, attrs)
    collection
  end

  @doc """
  Generate a smart collection with rules.
  """
  def smart_collection_fixture(attrs \\ %{}) do
    user =
      case Map.get(attrs, :user) || Map.get(attrs, :user_id) do
        nil -> user_fixture()
        %Mydia.Accounts.User{} = user -> user
        user_id when is_binary(user_id) -> Mydia.Repo.get!(Mydia.Accounts.User, user_id)
      end

    default_rules = %{
      "match_type" => "all",
      "conditions" => [
        %{"field" => "type", "operator" => "eq", "value" => "movie"}
      ]
    }

    default_attrs = %{
      name: "Smart Collection #{System.unique_integer([:positive])}",
      type: "smart",
      visibility: "private",
      smart_rules: Jason.encode!(Map.get(attrs, :rules, default_rules))
    }

    attrs =
      attrs
      |> Map.drop([:user, :user_id, :rules])
      |> Map.merge(default_attrs, fn _k, user_val, _default -> user_val end)

    {:ok, collection} = Collections.create_collection(user, attrs)
    collection
  end

  @doc """
  Generate a collection item.
  """
  def collection_item_fixture(attrs \\ %{}) do
    collection =
      case Map.get(attrs, :collection) || Map.get(attrs, :collection_id) do
        nil -> collection_fixture()
        %Collections.Collection{} = collection -> collection
        collection_id -> Mydia.Repo.get!(Collections.Collection, collection_id)
      end

    media_item =
      case Map.get(attrs, :media_item) || Map.get(attrs, :media_item_id) do
        nil -> media_item_fixture()
        %Mydia.Media.MediaItem{} = item -> item
        media_item_id -> Mydia.Repo.get!(Mydia.Media.MediaItem, media_item_id)
      end

    {:ok, item} = Collections.add_item(collection, media_item.id)
    item
  end
end
