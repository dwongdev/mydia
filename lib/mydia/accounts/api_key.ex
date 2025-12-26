defmodule Mydia.Accounts.ApiKey do
  @moduledoc """
  Schema for API keys used for programmatic access.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :permissions, {:array, :string}
    field :key, :string, virtual: true
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for creating an API key.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:user_id, :name, :key, :key_prefix, :permissions, :expires_at])
    |> validate_required([:user_id, :name, :key, :key_prefix])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_permissions()
    |> hash_key()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:key_hash)
  end

  @doc """
  Changeset for updating last used timestamp.
  """
  def used_changeset(api_key) do
    # SQLite doesn't support microseconds, so truncate to seconds
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(api_key, last_used_at: now)
  end

  @doc """
  Changeset for revoking an API key.
  """
  def revoke_changeset(api_key) do
    # SQLite doesn't support microseconds, so truncate to seconds
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(api_key, revoked_at: now)
  end

  @doc """
  Returns true if the API key has been revoked.
  """
  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{revoked_at: _}), do: true

  # Valid permissions for API keys
  @valid_permissions ["read", "write", "admin"]

  # Validate permissions field
  defp validate_permissions(changeset) do
    case get_change(changeset, :permissions) do
      nil ->
        changeset

      permissions when is_list(permissions) ->
        invalid = Enum.reject(permissions, &(&1 in @valid_permissions))

        if Enum.empty?(invalid) do
          changeset
        else
          add_error(changeset, :permissions, "contains invalid permissions: #{inspect(invalid)}")
        end

      _other ->
        add_error(changeset, :permissions, "must be a list")
    end
  end

  # Hash the API key if it's present
  defp hash_key(changeset) do
    case get_change(changeset, :key) do
      nil ->
        changeset

      key ->
        changeset
        |> put_change(:key_hash, hash_api_key(key))
        |> delete_change(:key)
    end
  end

  # Use Argon2 for hashing API keys
  defp hash_api_key(key) do
    Argon2.hash_pwd_salt(key)
  end
end
