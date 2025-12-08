defmodule MetadataRelay.OpenSubtitles.Auth do
  @moduledoc """
  GenServer that manages OpenSubtitles.com JWT authentication tokens.

  This module handles:
  - Initial authentication with OpenSubtitles API v1
  - Token caching in GenServer state
  - Automatic token refresh before expiration
  - Graceful error handling for authentication failures

  The GenServer is supervised and will automatically restart on failure.

  Authentication requires:
  - OPENSUBTITLES_API_KEY environment variable (application identification)
  - OPENSUBTITLES_USERNAME environment variable (user account)
  - OPENSUBTITLES_PASSWORD environment variable (user account)
  """

  use GenServer
  require Logger

  @auth_url "https://api.opensubtitles.com/api/v1/login"
  # Refresh token 1 hour before expiration (tokens typically last 24 hours)
  @refresh_before_expiry :timer.hours(1)

  ## Client API

  @doc """
  Starts the OpenSubtitles Auth GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current valid JWT token.

  Returns `{:ok, token}` if authenticated, or `{:error, reason}` if authentication failed
  or OpenSubtitles is not configured.
  """
  def get_token do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_configured}

      _pid ->
        GenServer.call(__MODULE__, :get_token)
    end
  end

  @doc """
  Forces a token refresh.

  Useful for testing or recovering from authentication errors.
  """
  def refresh_token do
    GenServer.call(__MODULE__, :refresh_token)
  end

  @doc """
  Checks if OpenSubtitles is configured and available.

  Returns `true` if the Auth GenServer is running (credentials are configured),
  `false` otherwise.
  """
  def configured? do
    Process.whereis(__MODULE__) != nil
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Attempt initial authentication on startup
    case authenticate() do
      {:ok, token, expires_at} ->
        schedule_refresh(expires_at)
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to authenticate with OpenSubtitles: #{inspect(reason)}")
        # Return error and let supervisor handle restart
        {:stop, {:authentication_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_token, _from, %{token: token} = state) do
    {:reply, {:ok, token}, state}
  end

  @impl true
  def handle_call(:refresh_token, _from, _state) do
    case authenticate() do
      {:ok, token, expires_at} ->
        schedule_refresh(expires_at)
        {:reply, {:ok, token}, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to refresh OpenSubtitles token: #{inspect(reason)}")
        {:reply, {:error, reason}, %{token: nil, expires_at: nil}}
    end
  end

  @impl true
  def handle_info(:refresh_token, _state) do
    case authenticate() do
      {:ok, token, expires_at} ->
        Logger.info("Successfully refreshed OpenSubtitles token")
        schedule_refresh(expires_at)
        {:noreply, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to refresh OpenSubtitles token: #{inspect(reason)}")
        # Keep old state and retry in 5 minutes
        Process.send_after(self(), :refresh_token, :timer.minutes(5))
        {:noreply, %{token: nil, expires_at: nil}}
    end
  end

  ## Private Functions

  defp authenticate do
    api_key = get_api_key()
    username = get_username()
    password = get_password()

    body = %{
      username: username,
      password: password
    }

    headers = [
      {"Api-Key", api_key},
      {"Content-Type", "application/json"},
      {"User-Agent", "metadata-relay v#{MetadataRelay.version()}"}
    ]

    case Req.post(@auth_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: %{"token" => token, "user" => _user}}} ->
        # Parse JWT to get expiration time
        expires_at = parse_token_expiry(token)

        Logger.info(
          "Successfully authenticated with OpenSubtitles, token expires at #{expires_at}"
        )

        {:ok, token, expires_at}

      {:ok, %{status: 401, body: body}} ->
        Logger.error("OpenSubtitles authentication failed with 401: #{inspect(body)}")
        {:error, {:authentication_failed, body}}

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "OpenSubtitles authentication failed with status #{status}: #{inspect(body)}"
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("OpenSubtitles authentication request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_api_key do
    case System.get_env("OPENSUBTITLES_API_KEY") do
      nil ->
        raise RuntimeError, """
        OPENSUBTITLES_API_KEY environment variable is not set.
        Please set it to your OpenSubtitles API key.
        """

      key ->
        key
    end
  end

  defp get_username do
    case System.get_env("OPENSUBTITLES_USERNAME") do
      nil ->
        raise RuntimeError, """
        OPENSUBTITLES_USERNAME environment variable is not set.
        Please set it to your OpenSubtitles username.
        """

      username ->
        username
    end
  end

  defp get_password do
    case System.get_env("OPENSUBTITLES_PASSWORD") do
      nil ->
        raise RuntimeError, """
        OPENSUBTITLES_PASSWORD environment variable is not set.
        Please set it to your OpenSubtitles password.
        """

      password ->
        password
    end
  end

  defp parse_token_expiry(token) do
    # JWT tokens are base64 encoded with format: header.payload.signature
    # We need to decode the payload to get the expiration time
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, decoded} ->
            case Jason.decode(decoded) do
              {:ok, %{"exp" => exp}} ->
                # exp is Unix timestamp in seconds
                DateTime.from_unix!(exp)

              _ ->
                # If we can't parse expiration, assume 24 hours from now
                DateTime.utc_now() |> DateTime.add(24, :hour)
            end

          _ ->
            DateTime.utc_now() |> DateTime.add(24, :hour)
        end

      _ ->
        DateTime.utc_now() |> DateTime.add(24, :hour)
    end
  end

  defp schedule_refresh(expires_at) do
    # Calculate when to refresh (1 hour before expiration)
    refresh_at = DateTime.add(expires_at, -@refresh_before_expiry, :millisecond)
    now = DateTime.utc_now()

    delay =
      case DateTime.diff(refresh_at, now, :millisecond) do
        diff when diff > 0 -> diff
        # If already expired or very close, refresh in 1 minute
        _ -> :timer.minutes(1)
      end

    Process.send_after(self(), :refresh_token, delay)
  end
end
