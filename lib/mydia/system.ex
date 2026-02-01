defmodule Mydia.System do
  @moduledoc """
  System information helpers for application version, environment, etc.
  """

  # Capture the environment at compile time so it's available in releases
  @env Mix.env()

  # Capture build commit at compile time (set via BUILD_COMMIT env var during Docker builds)
  @build_commit System.get_env("BUILD_COMMIT")

  @doc """
  Get the application version from mix.exs.

  For development/master branch builds, appends an asterisk and short commit hash
  (e.g., "0.7.4*abc1234") to distinguish from stable releases.
  """
  def app_version do
    base_version =
      case Application.spec(:mydia, :vsn) do
        nil -> "unknown"
        vsn -> to_string(vsn)
      end

    case @build_commit do
      nil -> base_version
      "" -> base_version
      commit -> "#{base_version}*#{String.slice(commit, 0, 7)}"
    end
  end

  @doc """
  Get the full build commit hash, if available.

  Returns nil for stable releases built from tags.
  """
  def build_commit do
    case @build_commit do
      nil -> nil
      "" -> nil
      commit -> commit
    end
  end

  @doc """
  Check if running in development mode.
  """
  def dev_mode? do
    @env == :dev
  end
end
