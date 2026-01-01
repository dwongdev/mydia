defmodule MydiaWeb.PlayerDevSocket do
  @moduledoc """
  WebSocket proxy for Flutter dev server hot reload.

  Forwards WebSocket connections from the browser to the Flutter dev server,
  enabling hot reload to work through the Phoenix proxy.
  """

  @behaviour Phoenix.Socket.Transport

  require Logger

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(state) do
    {:ok, state}
  end

  @impl true
  def init(state) do
    # Get the path from params
    path = Map.get(state, :path_info, []) |> Enum.join("/")
    ws_path = if path == "", do: "$dwdsSseHandler", else: path

    # Start WebSocket client to Flutter dev server
    url = "ws://player:3000/#{ws_path}"

    case WebSockex.start_link(url, __MODULE__.Client, %{parent: self()}, async: true) do
      {:ok, client_pid} ->
        Logger.debug("Started Flutter dev WebSocket proxy to #{url}")
        {:ok, Map.put(state, :client_pid, client_pid)}

      {:error, reason} ->
        Logger.error("Failed to connect to Flutter dev WebSocket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def handle_in({text, _opts}, %{client_pid: pid} = state) when is_pid(pid) do
    WebSockex.send_frame(pid, {:text, text})
    {:ok, state}
  end

  def handle_in(_msg, state), do: {:ok, state}

  @impl true
  def handle_info({:flutter_ws, {:text, text}}, state) do
    {:push, {:text, text}, state}
  end

  def handle_info({:flutter_ws, :connected}, state) do
    Logger.debug("Flutter dev WebSocket connected")
    {:ok, state}
  end

  def handle_info({:flutter_ws, {:closed, _reason}}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{client_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # WebSockex client that forwards messages to the parent socket
  defmodule Client do
    use WebSockex

    @impl true
    def handle_connect(_conn, %{parent: parent} = state) do
      send(parent, {:flutter_ws, :connected})
      {:ok, state}
    end

    @impl true
    def handle_frame({:text, msg}, %{parent: parent} = state) do
      send(parent, {:flutter_ws, {:text, msg}})
      {:ok, state}
    end

    @impl true
    def handle_frame(_frame, state), do: {:ok, state}

    @impl true
    def handle_disconnect(_reason, %{parent: parent} = state) do
      send(parent, {:flutter_ws, {:closed, :disconnected}})
      {:ok, state}
    end

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
