defmodule Mydia.RemoteAccess.RelayTunnel do
  @moduledoc """
  Handles relay-tunneled connections from clients.

  This module subscribes to relay connection events and creates a bridge
  between the relay WebSocket and the DeviceChannel, allowing clients to
  connect through the relay when direct connections fail.

  ## Architecture

  ```
  Client <-> Relay <-> RelayTunnel <-> DeviceChannel
  ```

  The tunnel:
  1. Subscribes to relay:connections PubSub topic
  2. Receives incoming connection events with session_id and client public key
  3. Creates a process to handle the tunneled connection
  4. Forwards messages bidirectionally between relay and DeviceChannel
  """

  use GenServer
  require Logger

  alias Mydia.RemoteAccess.Relay
  alias Mydia.RemoteAccess.Pairing

  # Client API

  @doc """
  Starts the relay tunnel supervisor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to relay connection events
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:connections")
    Logger.info("RelayTunnel supervisor started and subscribed to relay connections")
    {:ok, %{tunnels: %{}}}
  end

  @impl true
  def handle_info({:relay_connection, session_id, client_public_key, relay_pid}, state) do
    # Check for duplicate connection to same session
    existing_tunnel = Map.get(state.tunnels, session_id)

    if existing_tunnel && Process.alive?(existing_tunnel) do
      Logger.warning(
        "DUPLICATE relay connection detected: session_id=#{session_id}, existing_tunnel=#{inspect(existing_tunnel)}, new_relay_pid=#{inspect(relay_pid)} - IGNORING new connection"
      )

      # Don't spawn a new task - keep using the existing one
      {:noreply, state}
    else
      Logger.info(
        "Received relay connection request: session_id=#{session_id}, relay_pid=#{inspect(relay_pid)}"
      )

      Logger.debug("Client public key length: #{byte_size(client_public_key)}")

      # Start a tunnel process for this connection
      {:ok, tunnel_pid} =
        Task.start_link(fn ->
          handle_tunnel(session_id, client_public_key, relay_pid)
        end)

      tunnels = Map.put(state.tunnels, session_id, tunnel_pid)
      {:noreply, %{state | tunnels: tunnels}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp handle_tunnel(session_id, _client_public_key, relay_pid) do
    Logger.info(
      "Starting tunnel handler: session=#{session_id}, relay_pid=#{inspect(relay_pid)}, relay_alive=#{Process.alive?(relay_pid)}"
    )

    # Subscribe to messages for this specific session
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:session:#{session_id}")
    Logger.info("Tunnel subscribed to relay:session:#{session_id}")

    # Initialize pairing by generating server keypair
    {:ok, server_public_key, server_private_key} = Pairing.start_pairing_handshake()
    Logger.info("Tunnel generated server keypair: public_key_length=#{byte_size(server_public_key)}")

    # State tracks: server keys, session key (after handshake), and handshake completion
    initial_state = %{
      server_public_key: server_public_key,
      server_private_key: server_private_key,
      session_key: nil,
      handshake_complete: false
    }

    # Run the tunnel message loop
    tunnel_loop(session_id, relay_pid, initial_state)
  end

  defp tunnel_loop(session_id, relay_pid, handshake_state) do
    Logger.info(
      "Tunnel loop waiting: session=#{session_id}, handshake_complete=#{handshake_state.handshake_complete}"
    )

    receive do
      {:relay_message, payload} ->
        Logger.info(
          "Tunnel processing message for session #{session_id}, payload_size=#{byte_size(payload)}"
        )

        # Decode message from client via relay
        case decode_tunnel_message(payload) do
          {:ok, message_type, data} ->
            Logger.info(
              "Tunnel decoded message: type=#{message_type}, session=#{session_id}, handshake_complete=#{handshake_state.handshake_complete}"
            )

            # Process the message
            case handle_tunnel_message(message_type, data, handshake_state) do
              {:ok, response, new_state} ->
                # Log response details
                response_info =
                  case Jason.decode(response) do
                    {:ok, %{"type" => resp_type, "status" => status}} ->
                      "type=#{resp_type}, status=#{status}"

                    {:ok, %{"type" => resp_type}} ->
                      "type=#{resp_type}"

                    _ ->
                      "raw response"
                  end

                Logger.info(
                  "Tunnel message handled successfully: session=#{session_id}, request_type=#{message_type}, response=#{response_info}"
                )

                # Send response back through relay
                send_to_relay(session_id, relay_pid, response)
                tunnel_loop(session_id, relay_pid, new_state)

              {:error, reason} ->
                Logger.error(
                  "Tunnel message processing failed: session=#{session_id}, type=#{message_type}, reason=#{inspect(reason)}"
                )

                Logger.error("Failed message data: #{inspect(data)}")
                send_error_to_client(session_id, relay_pid, "message_processing_failed")
                tunnel_loop(session_id, relay_pid, handshake_state)

              :close ->
                Logger.info("Closing tunnel session: #{session_id}")
                :ok
            end

          {:error, reason} ->
            Logger.warning(
              "Failed to decode tunnel message: session=#{session_id}, reason=#{inspect(reason)}"
            )

            tunnel_loop(session_id, relay_pid, handshake_state)
        end

      {:DOWN, _ref, :process, ^relay_pid, reason} ->
        Logger.info("Relay connection closed for session #{session_id}: #{inspect(reason)}")
        :ok
    after
      # 5 minute timeout for tunnel inactivity
      300_000 ->
        Logger.info("Tunnel session timeout: #{session_id}")
        :ok
    end
  end

  defp decode_tunnel_message(payload) do
    Logger.info("Decoding tunnel message, payload preview: #{String.slice(payload, 0, 200)}")

    case Jason.decode(payload) do
      {:ok, %{"type" => type, "data" => data}} ->
        Logger.info("Decoded message (nested format): type=#{type}")
        {:ok, type, data}

      {:ok, %{"type" => type} = message} ->
        # Support flat message format where fields are at the top level
        # (e.g., {"type": "request", "id": "...", "method": "POST", ...})
        # Extract all fields except "type" as the data
        data = Map.delete(message, "type")
        Logger.info("Decoded message (flat format): type=#{type}, keys=#{inspect(Map.keys(data))}")
        {:ok, type, data}

      {:ok, other} ->
        Logger.warning("Unexpected JSON structure: #{inspect(other)}")
        {:error, {:unexpected_structure, other}}

      {:error, reason} ->
        Logger.error("JSON decode failed: #{inspect(reason)}, payload: #{String.slice(payload, 0, 100)}")
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp handle_tunnel_message("pairing_handshake", %{"message" => client_message_b64}, state) do
    Logger.info("Tunnel processing pairing_handshake message")

    case Base.decode64(client_message_b64) do
      {:ok, client_public_key} ->
        Logger.info("Tunnel pairing_handshake: client_public_key_length=#{byte_size(client_public_key)}")

        # Derive session key from client's public key
        case Pairing.process_pairing_message(state.server_private_key, client_public_key) do
          {:ok, session_key} ->
            Logger.info("Tunnel pairing_handshake: session key derived successfully, handshake complete")

            # Send back server's public key
            response = %{
              type: "pairing_handshake",
              message: Base.encode64(state.server_public_key)
            }

            new_state = %{state | session_key: session_key, handshake_complete: true}
            {:ok, Jason.encode!(response), new_state}

          {:error, reason} ->
            Logger.error("Tunnel pairing_handshake failed: #{inspect(reason)}")
            {:error, {:handshake_failed, reason}}
        end

      :error ->
        Logger.error("Tunnel pairing_handshake: invalid base64 in client message")
        {:error, :invalid_base64}
    end
  end

  defp handle_tunnel_message("claim_code", data, _state)
       when not is_map_key(data, "code") or
              not is_map_key(data, "device_name") or
              not is_map_key(data, "platform") do
    Logger.error("claim_code message missing required keys. Got: #{inspect(Map.keys(data))}")
    Logger.error("Full data: #{inspect(data)}")
    {:error, {:missing_required_keys, Map.keys(data)}}
  end

  defp handle_tunnel_message(
         "claim_code",
         %{"code" => code, "device_name" => device_name, "platform" => platform},
         state
       ) do
    Logger.info(
      "Tunnel processing claim_code: code=#{code}, device_name=#{device_name}, platform=#{platform}, handshake_complete=#{state.handshake_complete}"
    )

    unless state.handshake_complete do
      Logger.error("Tunnel claim_code REJECTED: handshake not complete")
      {:error, :handshake_incomplete}
    else
      device_attrs = %{
        device_name: device_name,
        platform: platform
      }

      case Pairing.complete_pairing(code, device_attrs, state.session_key) do
        {:ok, device, media_token, {device_public_key, device_private_key}, _session_key} ->
          Logger.info(
            "Tunnel claim_code SUCCESS: device_id=#{device.id}, device_name=#{device_name}"
          )

          # Publish device connected event
          Mydia.RemoteAccess.publish_device_event(device, :connected)

          response = %{
            type: "pairing_complete",
            device_id: device.id,
            media_token: media_token,
            device_public_key: Base.encode64(device_public_key),
            device_private_key: Base.encode64(device_private_key)
          }

          {:ok, Jason.encode!(response), state}

        {:error, reason} ->
          Logger.error("Tunnel claim_code FAILED: code=#{code}, reason=#{inspect(reason)}")
          {:error, {:pairing_failed, reason}}
      end
    end
  end

  defp handle_tunnel_message("handshake_init", %{"message" => client_message_b64}, state) do
    Logger.info("Tunnel processing handshake_init (reconnection)")

    case Base.decode64(client_message_b64) do
      {:ok, client_public_key} ->
        Logger.info("Tunnel handshake_init: client_public_key_length=#{byte_size(client_public_key)}")

        # For reconnection, process the client's static public key
        case Pairing.process_client_message(state.server_private_key, client_public_key) do
          {:ok, session_key, device} ->
            Logger.info("Tunnel handshake_init: found device_id=#{device.id}, completing reconnection")

            case Pairing.complete_reconnection(device, session_key) do
              {:ok, updated_device, token, _session_key} ->
                Logger.info(
                  "Tunnel handshake_init SUCCESS: device_id=#{updated_device.id}, handshake complete"
                )

                # Publish device connected event
                Mydia.RemoteAccess.publish_device_event(updated_device, :connected)

                # Send back server's public key for the client to derive the same session key
                response = %{
                  type: "handshake_complete",
                  message: Base.encode64(state.server_public_key),
                  token: token,
                  device_id: updated_device.id
                }

                new_state = %{state | session_key: session_key, handshake_complete: true}
                {:ok, Jason.encode!(response), new_state}

              {:error, reason} ->
                Logger.error("Tunnel handshake_init reconnection FAILED: #{inspect(reason)}")
                {:error, {:reconnection_failed, reason}}
            end

          {:error, reason} ->
            Logger.error("Tunnel handshake_init process_client_message FAILED: #{inspect(reason)}")
            {:error, {:handshake_failed, reason}}
        end

      :error ->
        Logger.error("Tunnel handshake_init: invalid base64 in client message")
        {:error, :invalid_base64}
    end
  end

  defp handle_tunnel_message("close", _data, _state) do
    :close
  end

  # Handle GraphQL/API requests proxied through the relay tunnel
  defp handle_tunnel_message(
         "request",
         %{"id" => request_id, "method" => method, "path" => path} = data,
         state
       )
       when state.handshake_complete do
    body = data["body"]
    headers = data["headers"] || %{}

    # Log incoming request details
    auth_header = headers["authorization"] || headers["Authorization"]
    auth_info = if auth_header, do: "present (#{String.length(auth_header)} chars)", else: "MISSING"

    Logger.info(
      "Tunnel proxying request: method=#{method}, path=#{path}, id=#{request_id}, auth=#{auth_info}, headers=#{inspect(Map.keys(headers))}"
    )

    if body do
      Logger.info("Request body size: #{String.length(body)} chars")
    end

    # Execute the request using RequestExecutor for proper timeout handling
    result =
      Mydia.RemoteAccess.RequestExecutor.execute(
        fn -> execute_local_request(method, path, headers, body) end,
        timeout: 30_000
      )

    case result do
      {:ok, {:ok, status, response_headers, response_body}} ->
        # Encode the response body (handles binary content)
        encoded = Mydia.RemoteAccess.MessageEncoder.encode_body(response_body)

        # Log response details with extra info for auth failures
        body_preview =
          if status in [401, 403] do
            ", body=#{inspect(String.slice(to_string(response_body), 0, 200))}"
          else
            ""
          end

        Logger.info(
          "Tunnel request completed: method=#{method}, path=#{path}, id=#{request_id}, status=#{status}#{body_preview}"
        )

        response = %{
          type: "response",
          id: request_id,
          status: status,
          headers: response_headers,
          body: encoded.body,
          body_encoding: encoded.body_encoding
        }

        {:ok, Jason.encode!(response), state}

      {:ok, {:error, reason}} ->
        Logger.error(
          "Tunnel request execution failed: method=#{method}, path=#{path}, id=#{request_id}, reason=#{inspect(reason)}"
        )

        response = %{
          type: "response",
          id: request_id,
          status: 502,
          headers: %{},
          body: Jason.encode!(%{error: "Request failed: #{inspect(reason)}"}),
          body_encoding: "raw"
        }

        {:ok, Jason.encode!(response), state}

      {:error, :timeout} ->
        Logger.warning(
          "Tunnel request timed out: method=#{method}, path=#{path}, id=#{request_id}"
        )

        response = %{
          type: "response",
          id: request_id,
          status: 504,
          headers: %{},
          body: Jason.encode!(%{error: "Request timeout"}),
          body_encoding: "raw"
        }

        {:ok, Jason.encode!(response), state}

      {:error, reason} ->
        Logger.error(
          "Tunnel request executor error: method=#{method}, path=#{path}, id=#{request_id}, reason=#{inspect(reason)}"
        )

        response = %{
          type: "response",
          id: request_id,
          status: 500,
          headers: %{},
          body: Jason.encode!(%{error: "Internal error"}),
          body_encoding: "raw"
        }

        {:ok, Jason.encode!(response), state}
    end
  end

  # Reject requests before handshake is complete
  defp handle_tunnel_message("request", %{"id" => request_id, "method" => method, "path" => path}, state)
       when not state.handshake_complete do
    Logger.warning(
      "Tunnel request REJECTED: handshake not complete, method=#{method}, path=#{path}, id=#{request_id}"
    )

    response = %{
      type: "response",
      id: request_id,
      status: 401,
      headers: %{},
      body: Jason.encode!(%{error: "Handshake required"}),
      body_encoding: "raw"
    }

    {:ok, Jason.encode!(response), state}
  end

  defp handle_tunnel_message("request", %{"id" => request_id}, state)
       when not state.handshake_complete do
    Logger.warning(
      "Tunnel request REJECTED: handshake not complete, id=#{request_id} (missing method/path)"
    )

    response = %{
      type: "response",
      id: request_id,
      status: 401,
      headers: %{},
      body: Jason.encode!(%{error: "Handshake required"}),
      body_encoding: "raw"
    }

    {:ok, Jason.encode!(response), state}
  end

  # Handle ping messages for keep-alive
  defp handle_tunnel_message("ping", _data, state) do
    Logger.info("Tunnel received ping, sending pong")
    response = %{type: "pong"}
    {:ok, Jason.encode!(response), state}
  end

  defp handle_tunnel_message(type, data, state) do
    Logger.warning(
      "Tunnel received unknown message type: type=#{type}, keys=#{inspect(Map.keys(data))}, handshake_complete=#{state.handshake_complete}"
    )

    {:ok, Jason.encode!(%{type: "error", message: "unknown_message_type"}), state}
  end

  # Execute a local HTTP request (used to proxy API calls through the tunnel)
  defp execute_local_request(method, path, headers, body) do
    # Build the local URL (requests go to the local Phoenix endpoint)
    port = Application.get_env(:mydia, MydiaWeb.Endpoint)[:http][:port] || 4000
    url = "http://127.0.0.1:#{port}#{path}"

    # Convert method string to atom
    method_atom =
      case String.upcase(method) do
        "GET" -> :get
        "POST" -> :post
        "PUT" -> :put
        "PATCH" -> :patch
        "DELETE" -> :delete
        "HEAD" -> :head
        "OPTIONS" -> :options
        _ -> :get
      end

    # Build request options
    req_headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Enum.reject(fn {k, _} -> k in ["host", "content-length"] end)

    # Add internal header to identify tunneled requests
    req_headers = [{"x-relay-tunnel", "true"} | req_headers]

    # Build the request
    request =
      Req.new(
        method: method_atom,
        url: url,
        headers: req_headers,
        # Don't follow redirects - let client handle them
        redirect: false,
        # Short connect timeout since we're hitting localhost
        connect_options: [timeout: 5_000],
        # Overall timeout
        receive_timeout: 25_000
      )

    # Add body for non-GET requests
    request =
      if body && method_atom not in [:get, :head] do
        Req.merge(request, body: body)
      else
        request
      end

    # Execute the request
    case Req.request(request) do
      {:ok, response} ->
        response_headers =
          response.headers
          |> Enum.map(fn {k, v} -> {k, Enum.join(List.wrap(v), ", ")} end)
          |> Map.new()

        {:ok, response.status, response_headers, response.body}

      {:error, exception} ->
        Logger.error("Local request failed: #{inspect(exception)}")
        {:error, exception}
    end
  end

  defp send_to_relay(session_id, relay_pid, response) when is_binary(response) do
    # Parse response to get summary info
    response_summary =
      case Jason.decode(response) do
        {:ok, %{"type" => type, "status" => status}} ->
          "type=#{type}, status=#{status}"

        {:ok, %{"type" => type}} ->
          "type=#{type}"

        _ ->
          "binary"
      end

    Logger.info(
      "Tunnel sending response to relay: session=#{session_id}, #{response_summary}, size=#{byte_size(response)}"
    )

    Relay.send_relay_message(relay_pid, session_id, response)
  end

  defp send_error_to_client(session_id, relay_pid, error_message) do
    response = Jason.encode!(%{type: "error", message: error_message})
    send_to_relay(session_id, relay_pid, response)
  end
end
