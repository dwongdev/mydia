defmodule MydiaWeb.Schema.Resolvers.ApiKeyResolver do
  @moduledoc """
  GraphQL resolvers for API key management.
  """

  alias Mydia.Accounts

  @doc """
  Lists all API keys for the current user.
  """
  def list_api_keys(_parent, _args, %{context: %{current_user: user}}) do
    api_keys = Accounts.list_api_keys(user.id)
    {:ok, api_keys}
  end

  def list_api_keys(_parent, _args, _context) do
    {:error, :unauthorized}
  end

  @doc """
  Creates a new API key for the current user.
  """
  def create_api_key(_parent, %{name: name} = args, %{context: %{current_user: user}}) do
    attrs = %{
      name: name,
      permissions: Map.get(args, :permissions, ["read", "write"]),
      expires_at: Map.get(args, :expires_at)
    }

    case Accounts.create_api_key(user.id, attrs) do
      {:ok, api_key, plain_key} ->
        {:ok, %{api_key: api_key, key: plain_key}}

      {:error, changeset} ->
        {:error, message: "Failed to create API key", details: changeset}
    end
  end

  def create_api_key(_parent, _args, _context) do
    {:error, :unauthorized}
  end

  @doc """
  Revokes an API key.
  """
  def revoke_api_key(_parent, %{id: id}, %{context: %{current_user: user}}) do
    case Accounts.get_api_key!(id) do
      nil ->
        {:error, :not_found}

      api_key ->
        # Ensure the API key belongs to the current user
        if api_key.user_id == user.id do
          case Accounts.revoke_api_key(api_key) do
            {:ok, updated_key} ->
              {:ok, updated_key}

            {:error, changeset} ->
              {:error, message: "Failed to revoke API key", details: changeset}
          end
        else
          {:error, :forbidden}
        end
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  def revoke_api_key(_parent, _args, _context) do
    {:error, :unauthorized}
  end

  @doc """
  Deletes an API key.
  """
  def delete_api_key(_parent, %{id: id}, %{context: %{current_user: user}}) do
    case Accounts.get_api_key!(id) do
      nil ->
        {:error, :not_found}

      api_key ->
        # Ensure the API key belongs to the current user
        if api_key.user_id == user.id do
          case Accounts.delete_api_key(api_key) do
            {:ok, _deleted} ->
              {:ok, true}

            {:error, changeset} ->
              {:error, message: "Failed to delete API key", details: changeset}
          end
        else
          {:error, :forbidden}
        end
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  def delete_api_key(_parent, _args, _context) do
    {:error, :unauthorized}
  end
end
