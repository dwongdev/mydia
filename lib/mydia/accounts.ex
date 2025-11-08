defmodule Mydia.Accounts do
  @moduledoc """
  The Accounts context handles users and API keys.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.{User, ApiKey}

  ## Users

  @doc """
  Returns the list of users.

  ## Options
    - `:role` - Filter by role
    - `:preload` - List of associations to preload
  """
  def list_users(opts \\ []) do
    User
    |> apply_user_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single user.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the user does not exist.
  """
  def get_user!(id, opts \\ []) do
    User
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a user by username.
  """
  def get_user_by_username(username, opts \\ []) do
    User
    |> where([u], u.username == ^username)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email, opts \\ []) do
    User
    |> where([u], u.email == ^email)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a user by OIDC subject and issuer.
  """
  def get_user_by_oidc(oidc_sub, oidc_issuer, opts \\ []) do
    User
    |> where([u], u.oidc_sub == ^oidc_sub and u.oidc_issuer == ^oidc_issuer)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a user with local authentication.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Checks if at least one admin user exists in the system.
  """
  def admin_exists? do
    User
    |> where([u], u.role == "admin")
    |> Repo.exists?()
  end

  @doc """
  Creates or updates a user from OIDC claims.

  If this is the first user in the system (no admin exists) and it's a new user,
  automatically promotes them to admin role regardless of OIDC claims.
  This ensures that production deployments with OIDC-only auth have an initial admin.
  """
  def upsert_user_from_oidc(oidc_sub, oidc_issuer, attrs) do
    require Logger

    case get_user_by_oidc(oidc_sub, oidc_issuer) do
      nil ->
        # New user - check if we need to auto-promote to admin
        attrs_with_oidc = Map.merge(attrs, %{oidc_sub: oidc_sub, oidc_issuer: oidc_issuer})

        final_attrs =
          if admin_exists?() do
            # Admin exists - use role from OIDC claims
            attrs_with_oidc
          else
            # No admin exists - promote this first user to admin
            Logger.info(
              "Auto-promoting first OIDC user to admin (email: #{attrs[:email] || "unknown"})"
            )

            Map.put(attrs_with_oidc, :role, "admin")
          end

        %User{}
        |> User.oidc_changeset(final_attrs)
        |> Repo.insert()

      user ->
        # Existing user - update with OIDC claims (never auto-promote existing users)
        user
        |> User.oidc_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates user's last login timestamp.
  """
  def update_last_login(%User{} = user) do
    user
    |> User.login_changeset()
    |> Repo.update()
  end

  @doc """
  Deletes a user.
  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.
  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @doc """
  Verifies a user's password.
  """
  def verify_password(%User{password_hash: password_hash}, password)
      when is_binary(password_hash) do
    Bcrypt.verify_pass(password, password_hash)
  end

  def verify_password(_user, _password), do: false

  ## API Keys

  @doc """
  Returns the list of API keys for a user.

  ## Options
    - `:preload` - List of associations to preload
  """
  def list_api_keys(user_id, opts \\ []) do
    ApiKey
    |> where([k], k.user_id == ^user_id)
    |> maybe_preload(opts[:preload])
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single API key.

  Raises `Ecto.NoResultsError` if the API key does not exist.
  """
  def get_api_key!(id) do
    Repo.get!(ApiKey, id)
  end

  @doc """
  Verifies an API key and returns the associated user.
  """
  def verify_api_key(key) when is_binary(key) do
    # Find all API keys and verify against them
    # This is not ideal for performance but works for small numbers of keys
    # For production, consider using a more efficient lookup mechanism
    ApiKey
    |> preload(:user)
    |> Repo.all()
    |> Enum.find(fn api_key ->
      not_expired?(api_key) and Argon2.verify_pass(key, api_key.key_hash)
    end)
    |> case do
      nil ->
        {:error, :invalid_key}

      api_key ->
        # Update last used timestamp
        update_api_key_last_used(api_key)
        {:ok, api_key.user}
    end
  end

  def verify_api_key(_key), do: {:error, :invalid_key}

  @doc """
  Creates an API key for a user.
  Returns {:ok, api_key, plain_key} where plain_key is the unhashed key to show to the user.
  """
  def create_api_key(user_id, attrs \\ %{}) do
    # Generate a random API key
    plain_key = generate_api_key()

    attrs_with_key =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:key, plain_key)

    case %ApiKey{}
         |> ApiKey.changeset(attrs_with_key)
         |> Repo.insert() do
      {:ok, api_key} ->
        {:ok, api_key, plain_key}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes an API key.
  """
  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  ## Private Functions

  defp apply_user_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:role, role}, query ->
        where(query, [u], u.role == ^role)

      _other, query ->
        query
    end)
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  defp not_expired?(%ApiKey{expires_at: nil}), do: true

  defp not_expired?(%ApiKey{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  defp update_api_key_last_used(api_key) do
    api_key
    |> ApiKey.used_changeset()
    |> Repo.update()
  end

  # Generate a random API key (32 bytes = 256 bits of entropy)
  defp generate_api_key do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
