defmodule Mydia.RemoteAccess.WebRTC.Session do
  @moduledoc """
  Manages a WebRTC PeerConnection for a remote access session.

  E2EE via the Noise protocol is mandatory:
  1. Client initiates Noise IK handshake on the `mydia-api` DataChannel
  2. After handshake completion, all messages are encrypted
  3. Both API and Media channels use the established cipher states
  4. Plaintext communication is not allowed
  """
  use GenServer
  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate}
  alias Mydia.RemoteAccess.{Relay, MessageEncoder}
  alias Mydia.RemoteAccess.WebRTC.NoiseSession
  alias Mydia.Library.MediaFile

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends an encrypted response to the API channel.

  This is called by async tasks to send responses through the GenServer,
  ensuring proper encryption state management.
  """
  def send_api_response(session_pid, response) do
    GenServer.cast(session_pid, {:send_api_response, response})
  end

  @doc """
  Sends an encrypted response to the media channel.
  """
  def send_media_response(session_pid, data) do
    GenServer.cast(session_pid, {:send_media_response, data})
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    relay_pid = Keyword.fetch!(opts, :relay_pid)
    provided_ice_servers = Keyword.get(opts, :ice_servers, [])

    Logger.info("Starting WebRTC Session: #{session_id}")

    # Subscribe to relay messages for this session
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:session:#{session_id}")

    # Use provided ICE servers if available, otherwise fall back to defaults
    ice_servers =
      if provided_ice_servers != [] do
        # Convert string keys to atoms for ExWebRTC compatibility
        Enum.map(provided_ice_servers, fn server ->
          server
          |> Enum.map(fn
            {"urls", v} -> {:urls, v}
            {"username", v} -> {:username, v}
            {"credential", v} -> {:credential, v}
            {k, v} when is_atom(k) -> {k, v}
            {k, v} -> {String.to_atom(k), v}
          end)
          |> Map.new()
        end)
      else
        # Default to STUN only - TURN credentials are provided by metadata-relay
        [%{urls: "stun:stun.l.google.com:19302"}]
      end

    Logger.info("WebRTC Session using #{length(ice_servers)} ICE servers")

    for server <- ice_servers do
      Logger.info(
        "  - #{server[:urls]}#{if server[:username], do: " (with credentials)", else: ""}"
      )
    end

    {:ok, pc} = PeerConnection.start_link(ice_servers: ice_servers)

    # Initialize Noise session for E2EE - mandatory
    case init_noise_session(session_id) do
      {:ok, noise_session} ->
        Logger.info("Noise E2EE initialized for session #{session_id}")

        state = %{
          session_id: session_id,
          relay_pid: relay_pid,
          pc: pc,
          data_channel: nil,
          media_channel: nil,
          device_id: nil,
          noise_session: noise_session
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("E2EE initialization failed for session #{session_id}: #{inspect(reason)}")
        {:stop, {:e2ee_required, reason}}
    end
  end

  defp init_noise_session(session_id) do
    with {:ok, keypair} <- Mydia.RemoteAccess.get_static_keypair(),
         {:ok, config} <- get_remote_access_config() do
      NoiseSession.new_responder(keypair, session_id, config.instance_id)
    end
  end

  defp get_remote_access_config do
    case Mydia.RemoteAccess.get_config() do
      nil -> {:error, :not_configured}
      config -> {:ok, config}
    end
  end

  @impl true
  def handle_info({:webrtc_signaling, "webrtc_offer", payload}, state) do
    Logger.info("Received WebRTC Offer for session #{state.session_id}")

    sdp = payload |> Jason.decode!()
    desc = SessionDescription.from_json(sdp)

    :ok = PeerConnection.set_remote_description(state.pc, desc)

    {:ok, answer} = PeerConnection.create_answer(state.pc)
    :ok = PeerConnection.set_local_description(state.pc, answer)

    answer_json = SessionDescription.to_json(answer)

    Relay.send_webrtc_message(
      state.relay_pid,
      state.session_id,
      "webrtc_answer",
      Jason.encode!(answer_json)
    )

    {:noreply, state}
  end

  def handle_info({:webrtc_signaling, "webrtc_candidate", payload}, state) do
    candidate_json = Jason.decode!(payload)
    Logger.info("Received ICE candidate: #{candidate_json["candidate"]}")

    # ExWebRTC.ICECandidate.from_json/1 requires usernameFragment key
    # Add it if missing (browser clients may not send it)
    candidate_json = Map.put_new(candidate_json, "usernameFragment", nil)

    candidate = ICECandidate.from_json(candidate_json)
    :ok = PeerConnection.add_ice_candidate(state.pc, candidate)
    Logger.info("ICE candidate added successfully")
    {:noreply, state}
  end

  # Handle PeerConnection messages
  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, state) do
    candidate_json = ICECandidate.to_json(candidate)
    Logger.info("Sending ICE candidate to client: #{candidate_json["candidate"]}")

    Relay.send_webrtc_message(
      state.relay_pid,
      state.session_id,
      "webrtc_candidate",
      Jason.encode!(candidate_json)
    )

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel, channel}}, state) do
    Logger.info(
      "Data channel received: label=#{channel.label}, id=#{channel.id}, ref=#{inspect(channel.ref)}, state=#{inspect(channel.ready_state)}"
    )

    new_state =
      case channel.label do
        "mydia-media" ->
          Logger.info("Storing media channel with ref=#{inspect(channel.ref)}")
          %{state | media_channel: channel}

        _ ->
          Logger.info("Storing API channel with ref=#{inspect(channel.ref)}")
          %{state | data_channel: channel}
      end

    Logger.info(
      "State after storing: data_channel=#{inspect(new_state.data_channel)}, media_channel=#{inspect(new_state.media_channel)}"
    )

    {:noreply, new_state}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, ref, new_state}}, state) do
    Logger.info("Data channel state change: ref=#{inspect(ref)}, state=#{inspect(new_state)}")
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:data, _channel_ref, data}}, state) do
    cond do
      # Handshake not complete - process as handshake message
      not NoiseSession.handshake_complete?(state.noise_session) ->
        new_state = handle_noise_handshake(data, state)
        {:noreply, new_state}

      # Handshake complete - all messages must be encrypted
      true ->
        case NoiseSession.decrypt(state.noise_session, data) do
          {:ok, noise_session, channel, plaintext} ->
            new_state = %{state | noise_session: noise_session}

            case channel do
              :media ->
                handle_media_message(plaintext, new_state)
                {:noreply, new_state}

              :api ->
                new_state = process_data(plaintext, new_state)
                {:noreply, new_state}
            end

          {:error, reason} ->
            Logger.warning("E2EE decryption failed: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  def handle_info({:ex_webrtc, _pc, {:connection_state_change, connection_state}}, state) do
    Logger.info("WebRTC Connection State: #{connection_state}")
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:ice_connection_state_change, ice_state}}, state) do
    Logger.info("WebRTC ICE Connection State: #{ice_state}")
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:ice_gathering_state_change, gathering_state}}, state) do
    Logger.info("WebRTC ICE Gathering State: #{gathering_state}")
    {:noreply, state}
  end

  def handle_info({:relay_message, _}, state), do: {:noreply, state}

  def handle_info({:ex_webrtc, _pc, msg}, state) do
    Logger.info("Unhandled ExWebRTC message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_api_response, response}, state) do
    new_state = send_data_to_channel(state, :api, Jason.encode!(response))
    {:noreply, new_state}
  end

  def handle_cast({:send_media_response, data}, state) do
    new_state = send_data_to_channel(state, :media, data)
    {:noreply, new_state}
  end

  # Helper to send data with E2EE encryption (mandatory)
  defp send_data_to_channel(state, channel, data) do
    channel_struct =
      case channel do
        :api -> state.data_channel
        :media -> state.media_channel
      end

    cond do
      channel_struct == nil ->
        Logger.error("Cannot send to #{channel} - channel is nil!")
        state

      not NoiseSession.handshake_complete?(state.noise_session) ->
        Logger.error("Cannot send to #{channel} - E2EE handshake not complete!")
        state

      true ->
        case NoiseSession.encrypt(state.noise_session, channel, data) do
          {:ok, noise_session, ciphertext} ->
            PeerConnection.send_data(state.pc, channel_struct.ref, ciphertext)
            %{state | noise_session: noise_session}

          {:error, reason} ->
            Logger.error("E2EE encryption failed: #{inspect(reason)}")
            state
        end
    end
  end

  defp handle_noise_handshake(data, state) do
    case NoiseSession.process_handshake(state.noise_session, data) do
      {:ok, noise_session, response} ->
        # Send handshake response if present
        if response do
          PeerConnection.send_data(state.pc, state.data_channel.ref, response)
        end

        Logger.info("Noise handshake progressed for session #{state.session_id}")
        %{state | noise_session: noise_session}

      {:error, reason} ->
        # E2EE is mandatory - handshake failure terminates the session
        Logger.error("Noise handshake failed for session #{state.session_id}: #{inspect(reason)}")
        # Close the peer connection
        PeerConnection.close(state.pc)
        state
    end
  end

  defp handle_media_message(data, _state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "stream_request"} = req} ->
        file_id = req["file_id"]
        request_id = req["request_id"]
        range_start = req["range_start"] || 0
        # optional
        range_end = req["range_end"]

        # Stream chunks back through GenServer for E2EE encryption
        session_pid = self()

        Task.start(fn ->
          stream_file_e2ee(file_id, request_id, range_start, range_end, session_pid)
        end)

      _ ->
        Logger.warning("Unknown media message")
    end
  end

  # File streaming - sends chunks back through GenServer for E2EE encryption
  defp stream_file_e2ee(file_id, request_id, range_start, range_end, session_pid) do
    case Mydia.Repo.get(MediaFile, file_id) |> Mydia.Repo.preload(:library_path) do
      nil ->
        send_media_response(session_pid, build_media_error(request_id, 404, "File not found"))

      file ->
        abs_path = MediaFile.absolute_path(file)

        if File.exists?(abs_path) do
          file_size = File.stat!(abs_path).size

          # Calculate effective range
          effective_end = range_end || file_size - 1
          effective_end = min(effective_end, file_size - 1)
          length = effective_end - range_start + 1

          # Send header
          header = %{
            type: "response_header",
            request_id: request_id,
            status: 206,
            headers: %{
              "Content-Type" => MIME.from_path(abs_path),
              "Content-Length" => to_string(length),
              "Content-Range" => "bytes #{range_start}-#{effective_end}/#{file_size}",
              "Accept-Ranges" => "bytes"
            }
          }

          send_media_response(session_pid, Jason.encode!(header))

          # Stream data
          # Smaller chunk size for E2EE to account for encryption overhead
          chunk_size = 14 * 1024

          File.open!(abs_path, [:read, :binary], fn io_device ->
            # Seek to start
            :file.position(io_device, range_start)

            stream_loop_e2ee(io_device, length, chunk_size, request_id, session_pid)
          end)
        else
          send_media_response(
            session_pid,
            build_media_error(request_id, 404, "File missing on disk")
          )
        end
    end
  end

  defp stream_loop_e2ee(_io, remaining, _chunk_size, _request_id, _session_pid)
       when remaining <= 0 do
    :ok
  end

  defp stream_loop_e2ee(io, remaining, chunk_size, request_id, session_pid) do
    bytes_to_read = min(remaining, chunk_size)

    case IO.binread(io, bytes_to_read) do
      data when is_binary(data) ->
        # Framing: [0x01 (Data)][req_id_len][req_id][payload]
        req_id_bytes = request_id
        req_id_len = byte_size(req_id_bytes)

        payload = <<0x01, req_id_len::8, req_id_bytes::binary, data::binary>>

        send_media_response(session_pid, payload)
        stream_loop_e2ee(io, remaining - byte_size(data), chunk_size, request_id, session_pid)

      :eof ->
        :ok

      {:error, reason} ->
        Logger.error("File read error: #{inspect(reason)}")
    end
  end

  defp build_media_error(request_id, status, _message) do
    resp = %{
      type: "response_header",
      request_id: request_id,
      status: status,
      headers: %{}
    }

    Jason.encode!(resp)
  end

  defp process_data(data, state) do
    Logger.info("Processing data: #{String.slice(data, 0, 200)}")

    Logger.info(
      "State: data_channel=#{inspect(state.data_channel)}, device_id=#{inspect(state.device_id)}"
    )

    case Jason.decode(data) do
      {:ok, %{"type" => "request"} = req} ->
        Logger.info(
          "Received request: method=#{req["method"]}, path=#{req["path"]}, id=#{req["id"]}"
        )

        if state.data_channel == nil do
          Logger.error("Cannot process request - data_channel is nil!")
          state
        else
          # Execute request in a Task, sends back through GenServer for E2EE encryption
          device_id = state.device_id
          session_pid = self()

          Task.start(fn ->
            response = execute_request(req, device_id)
            Logger.info("Sending response for #{req["id"]}: status=#{response[:status]}")
            send_api_response(session_pid, response)
          end)

          state
        end

      {:ok, %{"type" => "auth", "device_token" => token}} ->
        case Mydia.RemoteAccess.verify_device_token(token) do
          {:ok, device} ->
            Logger.info("Device authenticated via WebRTC: #{device.id}")
            resp = %{type: "auth_response", status: "ok", device_id: device.id}
            new_state = %{state | device_id: device.id}
            send_data_to_channel(new_state, :api, Jason.encode!(resp))

          {:error, _reason} ->
            Logger.warning("WebRTC Auth failed")
            resp = %{type: "auth_response", status: "error", message: "Invalid token"}
            send_data_to_channel(state, :api, Jason.encode!(resp))
        end

      {:ok,
       %{
         "type" => "claim_code",
         "code" => code,
         "device_name" => device_name,
         "platform" => platform
       }} ->
        device_attrs = %{device_name: device_name, platform: platform}

        case Mydia.RemoteAccess.Pairing.complete_pairing(code, device_attrs) do
          {:ok, device, media_token, access_token, device_token} ->
            Logger.info("Pairing successful for device #{device.id}")

            resp = %{
              type: "pairing_complete",
              device_id: device.id,
              media_token: media_token,
              access_token: access_token,
              device_token: device_token
            }

            new_state = %{state | device_id: device.id}
            send_data_to_channel(new_state, :api, Jason.encode!(resp))

          {:error, reason} ->
            Logger.warning("Pairing failed: #{inspect(reason)}")
            resp = %{type: "error", message: "Pairing failed: #{inspect(reason)}"}
            send_data_to_channel(state, :api, Jason.encode!(resp))
        end

      {:ok, other} ->
        Logger.debug("Received other message: #{inspect(other)}")
        state

      {:error, _} ->
        state
    end
  end

  defp execute_request(req, device_id) do
    method = req["method"]
    path = req["path"]
    headers = req["headers"] || %{}
    body = req["body"]
    request_id = req["id"]

    result =
      Mydia.RemoteAccess.RequestExecutor.execute(fn ->
        port = Application.get_env(:mydia, MydiaWeb.Endpoint)[:http][:port] || 4000
        url = "http://127.0.0.1:#{port}#{path}"

        req_headers = Map.to_list(headers) ++ [{"x-relay-device-id", device_id || ""}]

        Req.request(method: method, url: url, headers: req_headers, body: body)
      end)

    case result do
      {:ok, {:ok, resp}} ->
        %{
          type: "response",
          id: request_id,
          status: resp.status,
          headers: Map.new(resp.headers),
          body: MessageEncoder.encode_body(resp.body).body
        }

      {:ok, {:error, _}} ->
        %{type: "response", id: request_id, status: 500, body: "Internal Error"}

      {:error, _} ->
        %{type: "response", id: request_id, status: 504, body: "Timeout"}
    end
  end
end
