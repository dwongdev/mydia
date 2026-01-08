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

  alias Mydia.Crypto
  alias Mydia.RemoteAccess.Relay
  alias Mydia.RemoteAccess.Pairing
  alias Mydia.RemoteAccess.ProtocolVersion

  # Crypto constants
  @nonce_size 12
  @mac_size 16

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

    Logger.info(
      "Tunnel generated server keypair: public_key_length=#{byte_size(server_public_key)}"
    )

    # State tracks: server keys, session key (after handshake), handshake completion, and device_id
    initial_state = %{
      server_public_key: server_public_key,
      server_private_key: server_private_key,
      session_key: nil,
      handshake_complete: false,
      device_id: nil
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

        # Decrypt if handshake is complete (encrypted messages won't be valid JSON)
        # Try JSON first, if fails and handshake complete, try decryption
        decoded_payload = maybe_decrypt_payload(payload, session_id, handshake_state)

        # Decode message from client via relay
        case decode_tunnel_message(decoded_payload) do
          {:ok, message_type, data} ->
            Logger.info(
              "Tunnel decoded message: type=#{message_type}, session=#{session_id}, handshake_complete=#{handshake_state.handshake_complete}"
            )

            # Process the message
            case handle_tunnel_message(message_type, data, handshake_state) do
              {:ok, response, new_state} ->
                # Log response details
                {response_type, response_info} =
                  case Jason.decode(response) do
                    {:ok, %{"type" => resp_type, "status" => status}} ->
                      {resp_type, "type=#{resp_type}, status=#{status}"}

                    {:ok, %{"type" => resp_type}} ->
                      {resp_type, "type=#{resp_type}"}

                    _ ->
                      {nil, "raw response"}
                  end

                Logger.info(
                  "Tunnel message handled successfully: session=#{session_id}, request_type=#{message_type}, response=#{response_info}"
                )

                # Encrypt response if handshake is complete and not a handshake message type
                final_response =
                  maybe_encrypt_response(response, response_type, session_id, new_state)

                # Send response back through relay
                send_to_relay(session_id, relay_pid, final_response)
                tunnel_loop(session_id, relay_pid, new_state)

              {:error, reason} ->
                Logger.error(
                  "Tunnel message processing failed: session=#{session_id}, type=#{message_type}, reason=#{inspect(reason)}"
                )

                Logger.error("Failed message data: #{inspect(data)}")

                send_error_to_client(
                  session_id,
                  relay_pid,
                  "message_processing_failed",
                  handshake_state
                )

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

        Logger.info(
          "Decoded message (flat format): type=#{type}, keys=#{inspect(Map.keys(data))}"
        )

        {:ok, type, data}

      {:ok, other} ->
        Logger.warning("Unexpected JSON structure: #{inspect(other)}")
        {:error, {:unexpected_structure, other}}

      {:error, reason} ->
        Logger.error(
          "JSON decode failed: #{inspect(reason)}, payload: #{String.slice(payload, 0, 100)}"
        )

        {:error, {:json_decode_failed, reason}}
    end
  end

  defp handle_tunnel_message(
         "pairing_handshake",
         %{"message" => client_message_b64} = data,
         state
       ) do
    Logger.info("Tunnel processing pairing_handshake message")

    # Negotiate protocol versions with client
    client_versions = Map.get(data, "protocol_versions", %{})

    case ProtocolVersion.negotiate_all(client_versions) do
      {:ok, _negotiated} ->
        do_pairing_handshake(client_message_b64, state)

      {:error, :incompatible, failed_layers} ->
        Logger.warning("Tunnel pairing_handshake: client protocol version mismatch")
        response = ProtocolVersion.update_required_response(failed_layers)
        {:ok, Jason.encode!(response), state}
    end
  end

  defp do_pairing_handshake(client_message_b64, state) do
    case Base.decode64(client_message_b64) do
      {:ok, client_public_key} ->
        Logger.info(
          "Tunnel pairing_handshake: client_public_key_length=#{byte_size(client_public_key)}"
        )

        # Derive session key from client's public key
        case Pairing.process_pairing_message(state.server_private_key, client_public_key) do
          {:ok, session_key} ->
            # Debug: Log session key fingerprint for troubleshooting cross-platform crypto
            session_key_hex = Base.encode16(session_key, case: :lower)

            Logger.info(
              "Tunnel pairing_handshake: session key derived, first_8_bytes=#{String.slice(session_key_hex, 0, 16)}"
            )

            Logger.info(
              "Tunnel pairing_handshake: session key derived successfully, handshake complete"
            )

            # Send back server's public key with protocol versions
            response = %{
              type: "pairing_handshake",
              message: Base.encode64(state.server_public_key),
              protocol_versions: ProtocolVersion.supported_versions()
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
              not is_map_key(data, "platform") or
              not is_map_key(data, "static_public_key") do
    Logger.error("claim_code message missing required keys. Got: #{inspect(Map.keys(data))}")
    Logger.error("Full data: #{inspect(data)}")
    {:error, {:missing_required_keys, Map.keys(data)}}
  end

  defp handle_tunnel_message(
         "claim_code",
         %{
           "code" => code,
           "device_name" => device_name,
           "platform" => platform,
           "static_public_key" => static_public_key_b64
         },
         state
       ) do
    Logger.info(
      "Tunnel processing claim_code: code=#{code}, device_name=#{device_name}, platform=#{platform}, handshake_complete=#{state.handshake_complete}"
    )

    unless state.handshake_complete do
      Logger.error("Tunnel claim_code REJECTED: handshake not complete")
      {:error, :handshake_incomplete}
    else
      # Decode the client's static public key
      case Base.decode64(static_public_key_b64) do
        {:ok, client_static_public_key} ->
          device_attrs = %{
            device_name: device_name,
            platform: platform
          }

          # Client provides its own static public key - no keypair generation on server
          case Pairing.complete_pairing(
                 code,
                 device_attrs,
                 client_static_public_key,
                 state.session_key
               ) do
            {:ok, device, media_token, device_token, _session_key} ->
              Logger.info(
                "Tunnel claim_code SUCCESS: device_id=#{device.id}, device_name=#{device_name}"
              )

              # Publish device connected event
              Mydia.RemoteAccess.publish_device_event(device, :connected)

              # Response includes device_token for reconnection authentication
              response = %{
                type: "pairing_complete",
                device_id: device.id,
                media_token: media_token,
                device_token: device_token
              }

              # Store device_id in state for authenticating subsequent requests
              new_state = %{state | device_id: device.id}
              {:ok, Jason.encode!(response), new_state}

            {:error, reason} ->
              Logger.error("Tunnel claim_code FAILED: code=#{code}, reason=#{inspect(reason)}")
              {:error, {:pairing_failed, reason}}
          end

        :error ->
          Logger.error("Tunnel claim_code: invalid base64 in static_public_key")
          {:error, :invalid_base64}
      end
    end
  end

  defp handle_tunnel_message("handshake_init", %{"message" => client_message_b64}, state) do
    Logger.info("Tunnel processing handshake_init (reconnection)")

    case Base.decode64(client_message_b64) do
      {:ok, client_public_key} ->
        Logger.info(
          "Tunnel handshake_init: client_public_key_length=#{byte_size(client_public_key)}"
        )

        # For reconnection, process the client's static public key
        case Pairing.process_client_message(state.server_private_key, client_public_key) do
          {:ok, session_key, device} ->
            Logger.info(
              "Tunnel handshake_init: found device_id=#{device.id}, completing reconnection"
            )

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
            Logger.error(
              "Tunnel handshake_init process_client_message FAILED: #{inspect(reason)}"
            )

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

    auth_info =
      if auth_header, do: "present (#{String.length(auth_header)} chars)", else: "MISSING"

    Logger.info(
      "Tunnel proxying request: method=#{method}, path=#{path}, id=#{request_id}, auth=#{auth_info}, device_id=#{state.device_id}, headers=#{inspect(Map.keys(headers))}"
    )

    if body do
      Logger.info("Request body size: #{String.length(body)} chars")
      Logger.info("Request body: #{body}")
    end

    # Execute the request using RequestExecutor for proper timeout handling
    # Pass device_id for authentication of tunneled requests
    result =
      Mydia.RemoteAccess.RequestExecutor.execute(
        fn -> execute_local_request(method, path, headers, body, state.device_id) end,
        timeout: 30_000
      )

    case result do
      {:ok, {:ok, status, response_headers, response_body}} ->
        # Encode the response body (handles binary content)
        encoded = Mydia.RemoteAccess.MessageEncoder.encode_body(response_body)

        # Log response details with extra info for auth failures
        body_preview =
          if status in [401, 403] do
            body_str =
              case response_body do
                body when is_binary(body) -> String.slice(body, 0, 200)
                body when is_map(body) -> inspect(body)
                body -> inspect(body)
              end

            ", body=#{body_str}"
          else
            ""
          end

        Logger.info(
          "Tunnel request completed: method=#{method}, path=#{path}, id=#{request_id}, status=#{status}#{body_preview}"
        )

        Logger.info(
          "Response body details: encoding=#{encoded.body_encoding}, body_size=#{if encoded.body, do: byte_size(encoded.body), else: 0}, body_preview=#{if encoded.body, do: String.slice(encoded.body, 0, 100), else: "nil"}"
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
  defp handle_tunnel_message(
         "request",
         %{"id" => request_id, "method" => method, "path" => path},
         state
       )
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

  # Handle key_exchange for reconnection with device_token authentication
  defp handle_tunnel_message(
         "key_exchange",
         %{"client_public_key" => client_public_key_b64, "device_token" => device_token} = data,
         state
       ) do
    Logger.info("Tunnel processing key_exchange (reconnection with device_token)")

    # Negotiate protocol versions with client
    client_versions = Map.get(data, "protocol_versions", %{})

    case ProtocolVersion.negotiate_all(client_versions) do
      {:ok, _negotiated} ->
        do_key_exchange(client_public_key_b64, device_token, state)

      {:error, :incompatible, failed_layers} ->
        Logger.warning("Tunnel key_exchange: client protocol version mismatch")
        response = ProtocolVersion.update_required_response(failed_layers)
        {:ok, Jason.encode!(response), state}
    end
  end

  defp do_key_exchange(client_public_key_b64, device_token, state) do
    with {:ok, client_public_key} <- Base.decode64(client_public_key_b64),
         {:ok, device} <- Mydia.RemoteAccess.verify_device_token(device_token),
         false <- Mydia.RemoteAccess.RemoteDevice.revoked?(device) do
      Logger.info("Tunnel key_exchange: verified device_id=#{device.id}")

      # Generate ephemeral X25519 keypair for this session
      {server_public_key, server_private_key} = :crypto.generate_key(:ecdh, :x25519)

      # Compute shared secret using X25519 ECDH
      shared_secret = :crypto.compute_key(:ecdh, client_public_key, server_private_key, :x25519)

      # Derive session key using HKDF
      session_key = derive_session_key(shared_secret)

      # Update device last_seen and generate new media token
      {:ok, updated_device} = Mydia.RemoteAccess.touch_device(device)
      media_token = Pairing.generate_media_token(updated_device)

      # Publish device connected event
      Mydia.RemoteAccess.publish_device_event(updated_device, :connected)

      response = %{
        type: "key_exchange_complete",
        server_public_key: Base.encode64(server_public_key),
        token: media_token,
        device_id: updated_device.id,
        protocol_versions: ProtocolVersion.supported_versions()
      }

      new_state = %{
        state
        | session_key: session_key,
          handshake_complete: true,
          device_id: updated_device.id
      }

      Logger.info("Tunnel key_exchange SUCCESS: device_id=#{updated_device.id}")
      {:ok, Jason.encode!(response), new_state}
    else
      :error ->
        Logger.error("Tunnel key_exchange: invalid base64 in client_public_key")
        {:error, :invalid_base64}

      {:error, :not_found} ->
        Logger.warning("Tunnel key_exchange: device not found for token")
        {:error, :device_not_found}

      true ->
        Logger.warning("Tunnel key_exchange: device has been revoked")
        {:error, :device_revoked}

      {:error, reason} ->
        Logger.error("Tunnel key_exchange FAILED: #{inspect(reason)}")
        {:error, {:key_exchange_failed, reason}}
    end
  end

  defp handle_tunnel_message(type, data, state) when is_binary(type) do
    Logger.warning(
      "Tunnel received unknown message type: type=#{type}, keys=#{inspect(Map.keys(data))}, handshake_complete=#{state.handshake_complete}"
    )

    {:ok, Jason.encode!(%{type: "error", message: "unknown_message_type"}), state}
  end

  # Derive a 32-byte session key from shared secret using HKDF-SHA256
  defp derive_session_key(shared_secret) do
    # Simple HKDF extract and expand
    # Extract: PRK = HMAC-SHA256(salt="", IKM=shared_secret)
    prk = :crypto.mac(:hmac, :sha256, "", shared_secret)
    # Expand: OKM = HMAC-SHA256(PRK, info || 0x01)
    :crypto.mac(:hmac, :sha256, prk, "mydia-session-key" <> <<1>>)
  end

  # Execute a local HTTP request (used to proxy API calls through the tunnel)
  defp execute_local_request(method, path, headers, body, device_id) do
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

    # Build request options - filter out existing auth headers since we'll use device auth
    req_headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Enum.reject(fn {k, _} -> k in ["host", "content-length", "authorization"] end)

    # Add internal headers to identify tunneled requests and authenticate via device
    # Include HMAC signature for defense-in-depth authentication
    timestamp = System.system_time(:second) |> Integer.to_string()
    signature = compute_relay_signature(device_id || "", timestamp)

    req_headers = [
      {"x-relay-tunnel", "true"},
      {"x-relay-device-id", device_id || ""},
      {"x-relay-timestamp", timestamp},
      {"x-relay-signature", signature}
      | req_headers
    ]

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

  defp send_error_to_client(session_id, relay_pid, error_message, handshake_state) do
    response = Jason.encode!(%{type: "error", message: error_message})
    final_response = maybe_encrypt_response(response, "error", session_id, handshake_state)
    send_to_relay(session_id, relay_pid, final_response)
  end

  # Attempts to decrypt the payload if handshake is complete.
  # If the payload is valid JSON (plaintext handshake message), returns it as-is.
  # If the payload is encrypted, decrypts it using the session key.
  # AAD format: "{session_id}:to-server" (messages from client to server)
  defp maybe_decrypt_payload(payload, _session_id, %{handshake_complete: false}) do
    # Before handshake, all messages are plaintext
    payload
  end

  defp maybe_decrypt_payload(payload, session_id, %{
         handshake_complete: true,
         session_key: session_key
       }) do
    # After handshake, ALL messages MUST be encrypted - no plaintext allowed
    # Log session key for debugging cross-platform crypto
    session_key_hex = Base.encode16(session_key, case: :lower)

    # Build AAD for client→server messages (we're the server receiving)
    aad = build_aad(session_id, :to_server)

    Logger.info(
      "Tunnel decrypting message: payload_size=#{byte_size(payload)}, session_key_first8=#{String.slice(session_key_hex, 0, 16)}, session_id=#{session_id}, aad=#{aad}"
    )

    case decrypt_payload(payload, session_key, aad) do
      {:ok, decrypted} ->
        Logger.info("Successfully decrypted message, decrypted_size=#{byte_size(decrypted)}")
        decrypted

      {:error, reason} ->
        Logger.error(
          "Failed to decrypt message: #{inspect(reason)} - session_key_first8=#{String.slice(session_key_hex, 0, 16)}"
        )

        # Return a payload that will fail JSON decode with a clear error
        ""
    end
  end

  # Encrypts the response if handshake is complete and message type is not a handshake type.
  # AAD format: "{session_id}:to-client" (messages from server to client)
  defp maybe_encrypt_response(response, response_type, session_id, %{
         handshake_complete: true,
         session_key: session_key
       })
       when not is_nil(session_key) do
    if handshake_message_type?(response_type) do
      # Handshake responses are always plaintext
      Logger.debug("Sending plaintext handshake response: #{response_type}")
      response
    else
      # All other responses are encrypted after handshake
      session_key_hex = Base.encode16(session_key, case: :lower)

      # Build AAD for server→client messages (we're the server sending)
      aad = build_aad(session_id, :to_client)

      Logger.info(
        "Tunnel encrypting response: type=#{response_type}, session_key_first8=#{String.slice(session_key_hex, 0, 16)}, session_id=#{session_id}, aad=#{aad}"
      )

      encrypt_message(response, session_key, aad)
    end
  end

  defp maybe_encrypt_response(response, _response_type, _session_id, _handshake_state) do
    # Before handshake or no session key, send plaintext
    response
  end

  # ============================================================================
  # End-to-End Encryption Functions
  # ============================================================================

  @doc false
  # Builds AAD (Additional Authenticated Data) for encryption/decryption.
  # Format: "{session_id}:{direction}"
  # This binds the ciphertext to a specific session and direction,
  # preventing cross-session and reflection attacks.
  defp build_aad(session_id, direction) when direction in [:to_client, :to_server] do
    direction_str = if direction == :to_client, do: "to-client", else: "to-server"
    "#{session_id}:#{direction_str}"
  end

  @doc false
  # Encrypts a JSON response using the session key.
  # Returns raw binary: nonce (12 bytes) || ciphertext || mac (16 bytes)
  # The caller (relay) will base64-encode this binary for transmission.
  # AAD (Additional Authenticated Data) binds the ciphertext to its context,
  # preventing cross-session replay attacks.
  #
  # AAD format: "{session_id}:{direction}"
  # - direction = "to-client" for server→client messages
  # - direction = "to-server" for client→server messages
  defp encrypt_message(json_response, session_key, aad)
       when is_binary(session_key) and is_binary(aad) do
    %{ciphertext: ciphertext, nonce: nonce, mac: mac} =
      Crypto.encrypt(json_response, session_key, aad)

    Logger.info(
      "encrypt_message: nonce_size=#{byte_size(nonce)}, ciphertext_size=#{byte_size(ciphertext)}, mac_size=#{byte_size(mac)}, plaintext_size=#{byte_size(json_response)}"
    )

    # Wire format: nonce || ciphertext || mac (return as binary, not base64)
    nonce <> ciphertext <> mac
  end

  @doc false
  # Decrypts an encrypted payload using the session key.
  # The payload can be either:
  # - Base64-encoded string (will be decoded first)
  # - Raw binary bytes (used directly)
  # Returns {:ok, plaintext} or {:error, reason}
  #
  # AAD format: "{session_id}:{direction}"
  # - direction = "to-client" for server→client messages
  # - direction = "to-server" for client→server messages
  # AAD must match what was used during encryption, or decryption will fail.
  defp decrypt_payload(payload, session_key, aad)
       when is_binary(session_key) and is_binary(aad) do
    # Try to detect if payload is base64-encoded or raw bytes.
    # Base64 strings contain only [A-Za-z0-9+/=] characters.
    # Raw encrypted data typically contains non-printable bytes.
    binary =
      case Base.decode64(payload) do
        {:ok, decoded} ->
          # Successfully decoded as base64
          decoded

        :error ->
          # Not valid base64 - assume it's already raw bytes
          # This happens when the relay has already decoded the base64
          Logger.debug("Payload is not base64, treating as raw bytes")
          payload
      end

    if byte_size(binary) > @nonce_size + @mac_size do
      <<nonce::binary-size(@nonce_size), ciphertext_with_mac::binary>> = binary
      ciphertext_len = byte_size(ciphertext_with_mac) - @mac_size

      <<ciphertext::binary-size(ciphertext_len), mac::binary-size(@mac_size)>> =
        ciphertext_with_mac

      Crypto.decrypt(ciphertext, nonce, mac, session_key, aad)
    else
      {:error, :payload_too_short}
    end
  end

  @doc false
  # Determines if a message type requires encryption/should be sent encrypted.
  # Handshake messages are always plaintext; all others are encrypted after handshake.
  defp handshake_message_type?(type)
       when type in ["pairing_handshake", "handshake_complete", "key_exchange_complete"] do
    true
  end

  defp handshake_message_type?(_type), do: false

  # ============================================================================
  # Internal Request Authentication
  # ============================================================================

  @doc false
  # Computes HMAC-SHA256 signature for relay tunnel requests.
  # Used for defense-in-depth authentication beyond localhost IP checks.
  defp compute_relay_signature(device_id, timestamp) do
    secret = Application.get_env(:mydia, :relay_tunnel_secret)
    message = "#{device_id}:#{timestamp}"
    :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode64()
  end
end
