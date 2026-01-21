defmodule Mydia.RemoteAccess.Relay do
  @moduledoc """
  DEPRECATED: The WebSocket-based relay has been replaced by P2P.

  This module provides backwards compatibility stubs for the old Relay API.
  All functionality now goes through the P2P system - see Mydia.P2p.
  """

  alias Mydia.RemoteAccess

  @doc """
  Starts the relay connection.

  Returns an error since the relay system requires remote access to be configured
  and enabled.
  """
  def start_link(opts \\ []) do
    _name = Keyword.get(opts, :name)

    case RemoteAccess.get_config() do
      nil ->
        {:error, :remote_access_not_configured}

      %{enabled: false} ->
        {:error, :remote_access_disabled}

      %{enabled: true} ->
        # In the new system, P2P handles connectivity
        # This is a compatibility stub
        {:error, :use_p2p}
    end
  end

  @doc """
  Gets the status of a relay connection.

  Returns `{:error, :not_running}` since the WebSocket relay is deprecated.
  """
  def status(_name \\ nil) do
    {:error, :not_running}
  end

  @doc """
  Pings the relay connection.

  Returns `{:error, :not_running}` since the WebSocket relay is deprecated.
  """
  def ping(_name \\ nil) do
    {:error, :not_running}
  end

  @doc """
  Updates the direct URLs for the relay.

  Delegates to RemoteAccess.update_direct_urls/3.
  """
  def update_direct_urls(urls, name \\ nil)

  def update_direct_urls(urls, _name) when is_list(urls) do
    # Use a placeholder fingerprint since we can't get the real one without the relay
    case RemoteAccess.update_direct_urls(urls, "", false) do
      {:ok, _config} -> :ok
      error -> error
    end
  end

  @doc """
  Sends a message through the relay.

  Returns `{:error, :not_running}` since the WebSocket relay is deprecated.
  """
  def send_relay_message(_target_id, _message, _name \\ nil) do
    {:error, :not_running}
  end

  @doc """
  Triggers a reconnection attempt.

  Returns `:ok` but doesn't actually reconnect since the WebSocket relay is deprecated.
  """
  def reconnect(_name \\ nil) do
    :ok
  end
end
