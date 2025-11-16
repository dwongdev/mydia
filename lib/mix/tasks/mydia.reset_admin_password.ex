defmodule Mix.Tasks.Mydia.ResetAdminPassword do
  @moduledoc """
  Resets the admin user's password to "admin".

  This task finds the admin user by username and resets their password.

  ## Examples

      mix mydia.reset_admin_password

  """
  use Mix.Task

  @shortdoc "Resets the admin user's password to 'admin'"

  @impl Mix.Task
  def run(_args) do
    # Start the application to load configuration
    Mix.Task.run("app.start")

    alias Mydia.Accounts

    case Accounts.get_user_by_username("admin") do
      nil ->
        Mix.shell().error("✗ Admin user not found. Please create an admin user first.")
        exit({:shutdown, 1})

      user ->
        case Accounts.update_password(user, "admin") do
          {:ok, _user} ->
            Mix.shell().info("✓ Admin password reset successfully to 'admin'")
            :ok

          {:error, changeset} ->
            Mix.shell().error("✗ Failed to reset password: #{inspect(changeset.errors)}")
            exit({:shutdown, 1})
        end
    end
  end
end
