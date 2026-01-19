defmodule MydiaWeb.Schema.Resolvers.AuthResolver do
  @moduledoc """
  GraphQL resolvers for authentication operations.
  """

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.Config

  @doc """
  Login with username/password and device information.

  This resolver:
  1. Validates credentials
  2. Creates a JWT token
  3. Returns user info and token

  Note: This does NOT create a device record - that's handled by the remote access flow.
  For direct mode login, we just authenticate and return a token.
  """
  def login(_parent, %{input: input}, _resolution) do
    # Check if local auth is enabled
    config = Config.get()

    if not config.auth.local_enabled do
      {:error, "Local authentication is disabled"}
    else
      # Try to find user by username or email
      user =
        case Accounts.get_user_by_username(input.username) do
          nil -> Accounts.get_user_by_email(input.username)
          user -> user
        end

      case user do
        nil ->
          # Don't reveal whether username exists
          {:error, "Invalid username or password"}

        user ->
          if Accounts.verify_password(user, input.password) do
            # Update last login timestamp
            Accounts.update_last_login(user)

            # Create JWT token
            case Guardian.create_token(user) do
              {:ok, token, claims} ->
                # Get token expiration (default is 30 days for Guardian)
                expires_in = Map.get(claims, "exp", 0) - Map.get(claims, "iat", 0)

                {:ok,
                 %{
                   token: token,
                   user: user,
                   expires_in: expires_in
                 }}

              {:error, reason} ->
                {:error, "Failed to create authentication token: #{inspect(reason)}"}
            end
          else
            {:error, "Invalid username or password"}
          end
      end
    end
  end
end
