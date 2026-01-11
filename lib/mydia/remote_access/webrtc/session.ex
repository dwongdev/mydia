defmodule Mydia.RemoteAccess.WebRTC.Session do
  @moduledoc """
  Manages a WebRTC PeerConnection for a remote access session.
  """
  use GenServer
  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate}
  alias Mydia.RemoteAccess.{Relay, MessageEncoder}
  alias Mydia.Library.MediaFile

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
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
        # Default to STUN only
        default_servers = [%{urls: "stun:stun.l.google.com:19302"}]

        # If we have a local TURN server (e.g. dev environment), add it
        if Application.get_env(:mydia, :dev_routes) do
          [
            %{urls: "turn:localhost:3478", username: "mydia", credential: "mydia"}
            | default_servers
          ]
        else
          default_servers
        end
      end

    Logger.info("WebRTC Session using #{length(ice_servers)} ICE servers")

    for server <- ice_servers do
      Logger.info(
        "  - #{server[:urls]}#{if server[:username], do: " (with credentials)", else: ""}"
      )
    end

    {:ok, pc} = PeerConnection.start_link(ice_servers: ice_servers)

    state = %{
      session_id: session_id,
      relay_pid: relay_pid,
      pc: pc,
      data_channel: nil,
      media_channel: nil,
      device_id: nil
    }

    {:ok, state}
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

  def handle_info({:ex_webrtc, _pc, {:data, channel_ref, data}}, state) do
    # Determine if this is the media channel (compare by ref, not id)
    is_media = state.media_channel && state.media_channel.ref == channel_ref

    if is_media do
      handle_media_message(data, state)
      {:noreply, state}
    else
      new_state = process_data(data, state)
      {:noreply, new_state}
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

  defp handle_media_message(data, state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "stream_request"} = req} ->
        file_id = req["file_id"]
        request_id = req["request_id"]
        range_start = req["range_start"] || 0
        # optional
        range_end = req["range_end"]

        # We spawn a task to stream the file to avoid blocking the GenServer
        # We pass the PC and Channel to the task to send data directly
        pc = state.pc
        channel = state.media_channel

        Task.start(fn ->
          stream_file(file_id, request_id, range_start, range_end, pc, channel)
        end)

      _ ->
        Logger.warning("Unknown media message")
    end
  end

  defp stream_file(file_id, request_id, range_start, range_end, pc, channel) do
    case Mydia.Repo.get(MediaFile, file_id) |> Mydia.Repo.preload(:library_path) do
      nil ->
        send_media_error(pc, channel, request_id, 404, "File not found")

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

          PeerConnection.send_data(pc, channel.ref, Jason.encode!(header))

          # Stream data
          # Chunk size 16KB is safe for SCTP/WebRTC (max message size varies but 16KB is standard safe limit)
          chunk_size = 16 * 1024

          File.open!(abs_path, [:read, :binary], fn io_device ->
            # Seek to start
            :file.position(io_device, range_start)

            stream_loop(io_device, length, chunk_size, pc, channel, request_id)
          end)
        else
          send_media_error(pc, channel, request_id, 404, "File missing on disk")
        end
    end
  end

  defp stream_loop(_io, remaining, _chunk_size, _pc, _channel, _request_id) when remaining <= 0 do
    :ok
  end

  defp stream_loop(io, remaining, chunk_size, pc, channel, request_id) do
    bytes_to_read = min(remaining, chunk_size)

    case IO.binread(io, bytes_to_read) do
      data when is_binary(data) ->
        # Framing: [0x01 (Data)][req_id_len][req_id][payload]
        req_id_bytes = request_id
        req_id_len = byte_size(req_id_bytes)

        payload = <<0x01, req_id_len::8, req_id_bytes::binary, data::binary>>

        PeerConnection.send_data(pc, channel.ref, payload)
        stream_loop(io, remaining - byte_size(data), chunk_size, pc, channel, request_id)

      :eof ->
        :ok

      {:error, reason} ->
        Logger.error("File read error: #{inspect(reason)}")
    end
  end

  defp send_media_error(pc, channel, request_id, status, message) do
    Logger.warning("Media error: #{message}")

    resp = %{
      type: "response_header",
      request_id: request_id,
      status: status,
      headers: %{}
    }

    PeerConnection.send_data(pc, channel.ref, Jason.encode!(resp))
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
          # Execute request (readonly state access for now)
          # Note: calling send_data from Task requires pc and channel
          pc = state.pc
          channel = state.data_channel
          device_id = state.device_id

          Task.start(fn ->
            response = execute_request(req, device_id)
            Logger.info("Sending response for #{req["id"]}: status=#{response[:status]}")
            PeerConnection.send_data(pc, channel.ref, Jason.encode!(response))
          end)

          state
        end

      {:ok, %{"type" => "auth", "device_token" => token}} ->
        case Mydia.RemoteAccess.verify_device_token(token) do
          {:ok, device} ->
            Logger.info("Device authenticated via WebRTC: #{device.id}")
            resp = %{type: "auth_response", status: "ok", device_id: device.id}
            PeerConnection.send_data(state.pc, state.data_channel.ref, Jason.encode!(resp))
            %{state | device_id: device.id}

          {:error, _reason} ->
            Logger.warning("WebRTC Auth failed")
            resp = %{type: "auth_response", status: "error", message: "Invalid token"}
            PeerConnection.send_data(state.pc, state.data_channel.ref, Jason.encode!(resp))
            state
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

            PeerConnection.send_data(state.pc, state.data_channel.ref, Jason.encode!(resp))
            %{state | device_id: device.id}

          {:error, reason} ->
            Logger.warning("Pairing failed: #{inspect(reason)}")
            resp = %{type: "error", message: "Pairing failed: #{inspect(reason)}"}
            PeerConnection.send_data(state.pc, state.data_channel.ref, Jason.encode!(resp))
            state
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
