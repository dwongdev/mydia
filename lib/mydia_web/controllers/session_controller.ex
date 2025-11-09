defmodule MydiaWeb.SessionController do
  @moduledoc """
  Local authentication controller for development environments.

  Provides username/password login as a fallback when OIDC is not configured.
  Should only be used in development mode.
  """
  use MydiaWeb, :controller

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  @doc """
  Renders the login form.
  """
  def new(conn, _params) do
    if Application.get_env(:mydia, :env) == :prod do
      conn
      |> put_flash(:error, "Local authentication is not available in production")
      |> redirect(to: "/")
    else
      render(conn, :new,
        changeset: Accounts.change_user(%Mydia.Accounts.User{}),
        oidc_configured: oidc_configured?()
      )
    end
  end

  # Check if OIDC is configured
  defp oidc_configured? do
    Application.get_env(:ueberauth, Ueberauth) != nil
  end

  @doc """
  Handles local login with username and password.
  """
  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    if Application.get_env(:mydia, :env) == :prod do
      conn
      |> put_flash(:error, "Local authentication is not available in production")
      |> redirect(to: "/")
    else
      case Accounts.get_user_by_username(username) do
        nil ->
          conn
          |> put_flash(:error, "Invalid username or password")
          |> render(:new,
            changeset: Accounts.change_user(%Mydia.Accounts.User{}),
            oidc_configured: oidc_configured?()
          )

        user ->
          if Accounts.verify_password(user, password) do
            # Update last login timestamp
            Accounts.update_last_login(user)

            # Sign the JWT token and store in session
            {:ok, token, _claims} = Guardian.create_token(user)

            conn
            |> Guardian.Plug.sign_in(user)
            |> put_session(:guardian_token, token)
            |> put_flash(:info, "Successfully logged in!")
            |> redirect(to: "/")
          else
            conn
            |> put_flash(:error, "Invalid username or password")
            |> render(:new,
              changeset: Accounts.change_user(%Mydia.Accounts.User{}),
              oidc_configured: oidc_configured?()
            )
          end
      end
    end
  end
end
