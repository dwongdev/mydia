defmodule Mydia.RemoteAccess.Relay.WebSocket do
  @moduledoc """
  WebSockex process that maintains the actual WebSocket connection to the relay service.
  This module is managed by the Relay GenServer and forwards all messages to the parent.
  """

  use WebSockex
  require Logger

  @doc """
  Starts the WebSocket connection.

  ## Options
  - `:url` - The WebSocket URL to connect to (required)
  - `:parent` - The parent process to notify of events (required)
  """
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    parent = Keyword.fetch!(opts, :parent)

    state = %{
      parent: parent,
      url: url
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.debug("Relay.WebSocket connected to #{state.url}")
    send(state.parent, {:ws_connected, self()})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    send(state.parent, {:ws_frame, self(), {:text, msg}})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:ping, _}, state) do
    {:reply, :pong, state}
  end

  @impl WebSockex
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.debug("Relay.WebSocket disconnected: #{inspect(reason)}")
    send(state.parent, {:ws_disconnected, self(), reason})
    # Don't auto-reconnect - let the parent GenServer handle it
    {:ok, state}
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.debug("Relay.WebSocket terminating: #{inspect(reason)}")
    send(state.parent, {:ws_disconnected, self(), reason})
    :ok
  end
end
