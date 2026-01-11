defmodule MetadataRelay.TurnServer do
  @moduledoc """
  Integrated STUN/TURN server using the processone/stun library.

  This module provides a native TURN server that eliminates the need for
  external Coturn deployments. It uses time-limited credentials with
  HMAC-SHA1 authentication (RFC 5389 Long-Term Credential Mechanism).

  ## Configuration

  The TURN server is configured via environment variables:

  - `TURN_ENABLED` - Set to "true" to enable the integrated TURN server
  - `TURN_SECRET` - Shared secret for credential generation (required)
  - `TURN_REALM` - Authentication realm (default: "metadata-relay")
  - `TURN_MIN_PORT` - Minimum port for relay allocations (default: 49152)
  - `TURN_MAX_PORT` - Maximum port for relay allocations (default: 65535)
  - `TURN_LISTEN_IP` - IP to listen on (default: "0.0.0.0")
  - `TURN_PORT` - Port for STUN/TURN listener (default: 3478)
  - `TURN_PUBLIC_IP` - Public IP to advertise for relay addresses (required for TURN)

  ## Authentication

  Uses time-limited credentials compatible with WebRTC:
  - Username format: `{timestamp}:{user_identifier}`
  - Password: HMAC-SHA1(secret, username) base64-encoded
  - Credentials are validated by recalculating the HMAC

  ## Example

      # Start with default configuration
      {:ok, pid} = MetadataRelay.TurnServer.start_link([])

      # Or with custom options
      {:ok, pid} = MetadataRelay.TurnServer.start_link(
        port: 3478,
        secret: "my-secret",
        realm: "my-realm"
      )
  """

  use GenServer
  require Logger

  @default_port 3478
  @default_realm "metadata-relay"
  @default_min_port 49152
  @default_max_port 65535

  defstruct [
    :port,
    :secret,
    :realm,
    :min_port,
    :max_port,
    :listen_ip,
    :public_ip,
    :max_rate,
    :listener_started
  ]

  @doc """
  Starts the TURN server.

  ## Options

  - `:port` - STUN/TURN listener port (default: 3478)
  - `:secret` - Shared secret for authentication (required)
  - `:realm` - Authentication realm (default: "metadata-relay")
  - `:min_port` - Minimum relay allocation port (default: 49152)
  - `:max_port` - Maximum relay allocation port (default: 65535)
  - `:listen_ip` - IP address to listen on (default: {0, 0, 0, 0})
  - `:public_ip` - Public IP for relay addresses (required for TURN)
  - `:max_rate` - Max bitrate in bytes/second (default: 1,000,000 = ~8 Mbps)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns whether the TURN server is enabled based on configuration.
  """
  def enabled? do
    System.get_env("TURN_ENABLED") == "true"
  end

  @doc """
  Returns the current TURN server configuration.
  """
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  catch
    :exit, _ -> nil
  end

  @doc """
  Validates a time-limited credential.

  Returns `{:ok, username}` if valid, `{:error, reason}` otherwise.
  """
  def validate_credential(username, password) do
    GenServer.call(__MODULE__, {:validate_credential, username, password})
  catch
    :exit, _ -> {:error, :not_running}
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    # Ensure the stun application is started
    case Application.ensure_all_started(:stun) do
      {:ok, _} ->
        Logger.info("STUN application started successfully")

      {:error, reason} ->
        Logger.error("Failed to start STUN application: #{inspect(reason)}")
        {:stop, {:stun_app_error, reason}}
    end

    config = build_config(opts)

    case config do
      {:ok, state} ->
        # Start the listener after a short delay to ensure everything is ready
        Process.send_after(self(), :start_listener, 100)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:start_listener, state) do
    case start_turn_listener(state) do
      :ok ->
        Logger.info(
          "TURN server started on #{format_ip(state.listen_ip)}:#{state.port} " <>
            "(relay ports: #{state.min_port}-#{state.max_port})"
        )

        {:noreply, %{state | listener_started: true}}

      {:error, reason} ->
        Logger.error("Failed to start TURN listener: #{inspect(reason)}")
        # Retry after a delay
        Process.send_after(self(), :start_listener, 5000)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("TurnServer received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    config = %{
      port: state.port,
      realm: state.realm,
      min_port: state.min_port,
      max_port: state.max_port,
      listen_ip: state.listen_ip,
      public_ip: state.public_ip,
      max_rate: state.max_rate,
      listener_started: state.listener_started
    }

    {:reply, config, state}
  end

  def handle_call({:validate_credential, username, password}, _from, state) do
    result = do_validate_credential(username, password, state.secret)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listener_started do
      Logger.info("Stopping TURN listener")
      :stun_listener.del_listener(state.listen_ip, state.port, :udp)
    end

    :ok
  end

  # Private functions

  defp build_config(opts) do
    secret = Keyword.get(opts, :secret) || System.get_env("TURN_SECRET")

    if is_nil(secret) or secret == "" do
      {:error, :missing_secret}
    else
      listen_ip = parse_ip(Keyword.get(opts, :listen_ip) || System.get_env("TURN_LISTEN_IP") || "0.0.0.0")
      public_ip = parse_ip(Keyword.get(opts, :public_ip) || System.get_env("TURN_PUBLIC_IP"))
      max_rate = Keyword.get(opts, :max_rate) || parse_int(System.get_env("TURN_MAX_RATE"), 1_000_000)

      state = %__MODULE__{
        port: Keyword.get(opts, :port) || parse_int(System.get_env("TURN_PORT"), @default_port),
        secret: secret,
        realm: Keyword.get(opts, :realm) || System.get_env("TURN_REALM") || @default_realm,
        min_port: Keyword.get(opts, :min_port) || parse_int(System.get_env("TURN_MIN_PORT"), @default_min_port),
        max_port: Keyword.get(opts, :max_port) || parse_int(System.get_env("TURN_MAX_PORT"), @default_max_port),
        listen_ip: listen_ip,
        public_ip: public_ip,
        max_rate: max_rate,
        listener_started: false
      }

      {:ok, state}
    end
  end

  defp start_turn_listener(state) do
    # Build options for the STUN/TURN listener
    # The auth_fun callback is called by the stun library to validate credentials
    auth_fun = build_auth_fun(state.secret)

    opts =
      [
        use_turn: true,
        auth_type: :user,
        auth_realm: state.realm,
        auth_fun: auth_fun,
        turn_min_port: state.min_port,
        turn_max_port: state.max_port,
        server_name: "metadata-relay",
        shaper: state.max_rate
      ]
      |> maybe_add_turn_ip(state.public_ip)

    # Add the UDP listener
    case :stun_listener.add_listener(state.listen_ip, state.port, :udp, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_turn_ip(opts, nil), do: opts

  defp maybe_add_turn_ip(opts, public_ip) when is_tuple(public_ip) do
    case tuple_size(public_ip) do
      4 -> Keyword.put(opts, :turn_ipv4_address, public_ip)
      8 -> Keyword.put(opts, :turn_ipv6_address, public_ip)
    end
  end

  @doc false
  # Build the authentication function for the STUN library.
  # This function is called by the stun library to get the password for a user.
  # For time-limited credentials, we recalculate the expected password from the username.
  defp build_auth_fun(secret) do
    fn username, _realm ->
      # Username format: "{timestamp}:{identifier}"
      # Password is HMAC-SHA1(secret, username) base64-encoded
      case validate_username_timestamp(username) do
        :ok ->
          # Return the expected password
          calculate_credential(secret, username)

        {:error, _reason} ->
          # Return empty binary to fail authentication
          <<>>
      end
    end
  end

  defp do_validate_credential(username, password, secret) do
    case validate_username_timestamp(username) do
      :ok ->
        expected_password = calculate_credential(secret, username)

        if secure_compare(password, expected_password) do
          {:ok, username}
        else
          {:error, :invalid_password}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_username_timestamp(username) when is_binary(username) do
    case String.split(username, ":", parts: 2) do
      [timestamp_str, _identifier] ->
        case Integer.parse(timestamp_str) do
          {timestamp, ""} ->
            now = System.os_time(:second)

            if timestamp > now do
              :ok
            else
              {:error, :expired}
            end

          _ ->
            {:error, :invalid_timestamp}
        end

      _ ->
        {:error, :invalid_username_format}
    end
  end

  defp validate_username_timestamp(_), do: {:error, :invalid_username}

  defp calculate_credential(secret, username) do
    :crypto.mac(:hmac, :sha, secret, username)
    |> Base.encode64()
  end

  # Constant-time comparison to prevent timing attacks
  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp secure_compare(a, b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    result =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

    result == 0
  end

  defp parse_ip(nil), do: nil
  defp parse_ip(""), do: nil

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end

  defp parse_ip(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(_), do: "unknown"
end
