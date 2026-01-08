defmodule MetadataRelayWeb.ClientTunnelSocket do
  @moduledoc """
  WebSocket socket for client tunnel connections.

  This socket handles connections from Flutter clients that need to
  communicate with Mydia instances through the relay (when direct
  connection isn't possible).

  ## Protocol

  All messages are JSON-encoded:

  - Connect: `{"type": "connect", "instance_id": "..."}`
  - Message: `{"type": "message", "payload": "base64"}`
  - Close: `{"type": "close"}`
  """

  @behaviour Phoenix.Socket.Transport
  require Logger

  alias MetadataRelay.Relay
  alias MetadataRelay.Relay.ConnectionRegistry
  alias MetadataRelay.Relay.ProtocolVersion

  # Session timeout: 5 minutes without activity
  @session_timeout 300_000

  @impl true
  def child_spec(_opts) do
    %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}, restart: :transient}
  end

  @impl true
  def connect(_state) do
    session_id = generate_session_id()
    Logger.info("Client tunnel socket connect: session_id=#{session_id}")

    {:ok,
     %{
       session_id: session_id,
       instance_id: nil,
       connected: false,
       timeout_timer: nil
     }}
  end

  @impl true
  def init(state) do
    # Subscribe to responses for this session
    Phoenix.PubSub.subscribe(MetadataRelay.PubSub, "relay:session:#{state.session_id}")

    # Start session timeout timer
    timer = Process.send_after(self(), :session_timeout, @session_timeout)
    {:ok, %{state | timeout_timer: timer}}
  end

  @impl true
  def handle_in({text, _opts}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _reason} ->
        Logger.warning("Invalid JSON received from client tunnel")
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:session_timeout, state) do
    Logger.info("Client tunnel session timeout: #{state.session_id}")
    {:stop, :session_timeout, state}
  end

  @impl true
  def handle_info({:relay_response, payload}, state) do
    # Forward response from instance to client
    state = reset_timeout(state)

    message =
      Jason.encode!(%{
        type: "message",
        payload: Base.encode64(payload)
      })

    {:push, {:text, message}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timeout_timer do
      Process.cancel_timer(state.timeout_timer)
    end

    :ok
  end

  # Message handlers

  defp handle_message(%{"type" => "connect", "instance_id" => instance_id}, state) do
    case Relay.get_connection_info(instance_id) do
      {:ok, info} ->
        if info.online do
          Logger.info(
            "Client connecting to instance #{instance_id} via relay, session: #{state.session_id}"
          )

          state = reset_timeout(state)

          # Notify the instance about the incoming connection
          # Instance needs to know: session_id and client public key (if available)
          # For now, we send a connection notification - handshake will happen via messages
          Phoenix.PubSub.broadcast(
            MetadataRelay.PubSub,
            "relay:instance:#{instance_id}",
            {:relay_connection, state.session_id, <<>>}
          )

          # Get instance protocol versions from ConnectionRegistry
          instance_versions = get_instance_versions(instance_id)

          response =
            Jason.encode!(%{
              type: "connected",
              session_id: state.session_id,
              instance_id: instance_id,
              public_key: info.public_key,
              direct_urls: info.direct_urls,
              relay_protocol: ProtocolVersion.preferred_version(),
              instance_versions: instance_versions
            })

          {:reply, :ok, {:text, response}, %{state | instance_id: instance_id, connected: true}}
        else
          response =
            Jason.encode!(%{
              type: "error",
              message: "Instance is offline"
            })

          {:reply, :error, {:text, response}, state}
        end

      {:error, :not_found} ->
        response =
          Jason.encode!(%{
            type: "error",
            message: "Instance not found"
          })

        {:reply, :error, {:text, response}, state}
    end
  end

  defp handle_message(
         %{"type" => "connect", "claim_code" => code},
         state
       ) do
    # Alternative connection via claim code
    Logger.info("Client connecting via claim code: #{code}")

    case Relay.redeem_claim(code) do
      {:ok, info} ->
        if info.online do
          Logger.info(
            "Client connecting via claim code to instance #{info.instance_id}, session: #{state.session_id}"
          )

          state = reset_timeout(state)

          # Notify the instance about the incoming connection
          Logger.debug("Broadcasting relay_connection to relay:instance:#{info.instance_id}")

          Phoenix.PubSub.broadcast(
            MetadataRelay.PubSub,
            "relay:instance:#{info.instance_id}",
            {:relay_connection, state.session_id, <<>>}
          )

          Logger.debug("Broadcast sent for session #{state.session_id}")

          # Get instance protocol versions from ConnectionRegistry
          instance_versions = get_instance_versions(info.instance_id)

          response =
            Jason.encode!(%{
              type: "connected",
              session_id: state.session_id,
              claim_id: info.claim_id,
              instance_id: info.instance_id,
              public_key: info.public_key,
              direct_urls: info.direct_urls,
              user_id: info.user_id,
              relay_protocol: ProtocolVersion.preferred_version(),
              instance_versions: instance_versions
            })

          {:reply, :ok, {:text, response},
           %{state | instance_id: info.instance_id, connected: true}}
        else
          response =
            Jason.encode!(%{
              type: "error",
              message: "Instance is offline"
            })

          {:reply, :error, {:text, response}, state}
        end

      {:error, reason} ->
        message =
          case reason do
            :not_found -> "Invalid claim code"
            :already_consumed -> "Claim code has already been used"
            :expired -> "Claim code has expired"
            _ -> "Failed to redeem claim code"
          end

        response = Jason.encode!(%{type: "error", message: message})
        {:reply, :error, {:text, response}, state}
    end
  end

  defp handle_message(%{"type" => "message", "payload" => payload_b64}, state)
       when state.connected do
    Logger.debug(
      "Received message from client, session: #{state.session_id}, connected: #{state.connected}"
    )

    case Base.decode64(payload_b64) do
      {:ok, payload} ->
        state = reset_timeout(state)

        Logger.debug(
          "Forwarding message to instance #{state.instance_id}, payload size: #{byte_size(payload)}"
        )

        # Forward message to instance via PubSub
        Phoenix.PubSub.broadcast(
          MetadataRelay.PubSub,
          "relay:instance:#{state.instance_id}",
          {:relay_message, state.session_id, payload}
        )

        Logger.debug("Message forwarded to relay:instance:#{state.instance_id}")

        {:ok, state}

      :error ->
        Logger.warning("Invalid base64 payload in client message")
        {:ok, state}
    end
  end

  defp handle_message(%{"type" => "ping"}, state) do
    # Heartbeat ping from client - respond with pong and reset timeout
    state = reset_timeout(state)
    response = Jason.encode!(%{type: "pong"})
    {:reply, :ok, {:text, response}, state}
  end

  defp handle_message(%{"type" => "close"}, state) do
    {:stop, :normal, state}
  end

  defp handle_message(msg, state) do
    Logger.debug("Unhandled client tunnel message: #{inspect(msg)}")
    {:ok, state}
  end

  defp reset_timeout(state) do
    if state.timeout_timer do
      Process.cancel_timer(state.timeout_timer)
    end

    timer = Process.send_after(self(), :session_timeout, @session_timeout)
    %{state | timeout_timer: timer}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  # Get protocol versions for an instance from ConnectionRegistry
  defp get_instance_versions(instance_id) do
    case ConnectionRegistry.lookup(instance_id) do
      {:ok, _pid, metadata} ->
        Map.get(metadata, :protocol_versions, %{})

      :not_found ->
        %{}
    end
  end
end
