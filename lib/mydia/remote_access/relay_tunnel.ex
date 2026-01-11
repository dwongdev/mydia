defmodule Mydia.RemoteAccess.RelayTunnel do
  @moduledoc """
  Handles relay-tunneled connections from clients.

  This module subscribes to relay connection events and creates a WebRTC session
  using Mydia.RemoteAccess.WebRTC.Supervisor.
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the relay tunnel manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to relay connection events
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:connections")
    Logger.info("RelayTunnel manager started and subscribed to relay connections")
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_info(
        {:relay_connection, session_id, _client_public_key, ice_servers, relay_pid},
        state
      ) do
    Logger.info(
      "Starting WebRTC session for #{session_id} with #{length(ice_servers)} ICE servers"
    )

    # Start a WebRTC session for this connection
    case Mydia.RemoteAccess.WebRTC.Supervisor.start_session(
           session_id: session_id,
           relay_pid: relay_pid,
           ice_servers: ice_servers
         ) do
      {:ok, _pid} ->
        Logger.info("WebRTC session started successfully")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to start WebRTC session: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Handle old format for backwards compatibility (without ice_servers)
  @impl true
  def handle_info({:relay_connection, session_id, client_public_key, relay_pid}, state) do
    handle_info({:relay_connection, session_id, client_public_key, [], relay_pid}, state)
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
