defmodule Mydia.RemoteAccess.StunClient do
  @moduledoc """
  A minimal STUN client for detecting public IP addresses.

  Implements RFC 5389 (STUN - Session Traversal Utilities for NAT) binding request
  to discover the public IP address by querying STUN servers.

  STUN is more reliable than HTTP-based IP detection services because:
  - It works over UDP, which is faster and has lower overhead
  - STUN servers are specifically designed for this purpose
  - Many reliable public STUN servers are available (Google, Twilio, etc.)
  - It's the same mechanism used by WebRTC for ICE candidate gathering

  ## Usage

      case StunClient.detect_public_ip() do
        {:ok, "203.0.113.42"} -> # Got the public IP
        {:error, reason} -> # All STUN servers failed
      end

  """

  require Logger

  # STUN magic cookie (RFC 5389)
  @magic_cookie 0x2112A442

  # STUN message types
  @binding_request 0x0001
  @binding_response 0x0101

  # STUN attribute types
  @attr_mapped_address 0x0001
  @attr_xor_mapped_address 0x0020

  # Default STUN port
  @default_port 3478

  # Timeout for STUN requests (2 seconds per server)
  @request_timeout_ms 2_000

  # Public STUN servers to try (in order of preference)
  @stun_servers [
    {"stun.l.google.com", 19302},
    {"stun1.l.google.com", 19302},
    {"stun.cloudflare.com", 3478},
    {"stun.twilio.com", 3478},
    {"stun.stunprotocol.org", 3478}
  ]

  @doc """
  Detects the public IP address using STUN binding requests.

  Tries multiple STUN servers in order until one succeeds.
  Returns `{:ok, ip_string}` on success, or `{:error, reason}` if all servers fail.

  ## Examples

      iex> StunClient.detect_public_ip()
      {:ok, "203.0.113.42"}

      iex> StunClient.detect_public_ip()
      {:error, :all_servers_failed}

  """
  @spec detect_public_ip() :: {:ok, String.t()} | {:error, atom()}
  def detect_public_ip do
    detect_public_ip(@stun_servers)
  end

  @doc """
  Detects public IP using a custom list of STUN servers.

  Each server should be a tuple of `{host, port}` or just `host` (uses default port 3478).

  ## Examples

      iex> StunClient.detect_public_ip([{"stun.l.google.com", 19302}])
      {:ok, "203.0.113.42"}

  """
  @spec detect_public_ip(list()) :: {:ok, String.t()} | {:error, atom()}
  def detect_public_ip(servers) when is_list(servers) do
    Enum.reduce_while(servers, {:error, :all_servers_failed}, fn server, _acc ->
      {host, port} = normalize_server(server)

      case query_stun_server(host, port) do
        {:ok, ip} ->
          Logger.debug("STUN: detected public IP #{ip} from #{host}:#{port}")
          {:halt, {:ok, ip}}

        {:error, reason} ->
          Logger.debug("STUN: failed to query #{host}:#{port} - #{inspect(reason)}")
          {:cont, {:error, :all_servers_failed}}
      end
    end)
  end

  @doc """
  Queries a single STUN server for the public IP.

  Sends a STUN binding request and parses the XOR-MAPPED-ADDRESS or
  MAPPED-ADDRESS attribute from the response.

  ## Examples

      iex> StunClient.query_stun_server("stun.l.google.com", 19302)
      {:ok, "203.0.113.42"}

  """
  @spec query_stun_server(String.t() | charlist(), integer()) ::
          {:ok, String.t()} | {:error, atom()}
  def query_stun_server(host, port \\ @default_port) do
    host = if is_binary(host), do: String.to_charlist(host), else: host

    # Resolve hostname to IP address
    case :inet.getaddr(host, :inet) do
      {:ok, server_ip} ->
        do_stun_query(server_ip, port)

      {:error, reason} ->
        {:error, {:dns_error, reason}}
    end
  end

  # Private implementation

  defp normalize_server({host, port}) when is_integer(port), do: {host, port}
  defp normalize_server(host) when is_binary(host), do: {host, @default_port}
  defp normalize_server(host) when is_list(host), do: {host, @default_port}

  defp do_stun_query(server_ip, port) do
    # Open a UDP socket
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          # Build and send binding request
          transaction_id = :crypto.strong_rand_bytes(12)
          request = build_binding_request(transaction_id)

          case :gen_udp.send(socket, server_ip, port, request) do
            :ok ->
              # Wait for response
              case :gen_udp.recv(socket, 0, @request_timeout_ms) do
                {:ok, {_addr, _port, response}} ->
                  parse_binding_response(response, transaction_id)

                {:error, :timeout} ->
                  {:error, :timeout}

                {:error, reason} ->
                  {:error, {:recv_error, reason}}
              end

            {:error, reason} ->
              {:error, {:send_error, reason}}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, {:socket_error, reason}}
    end
  end

  # Build a STUN binding request message
  # Format: 2-byte type, 2-byte length, 4-byte magic cookie, 12-byte transaction ID
  defp build_binding_request(transaction_id) when byte_size(transaction_id) == 12 do
    <<
      @binding_request::16,
      0::16,
      @magic_cookie::32,
      transaction_id::binary-size(12)
    >>
  end

  # Parse STUN binding response and extract the mapped address
  defp parse_binding_response(
         <<@binding_response::16, length::16, @magic_cookie::32, transaction_id::binary-size(12),
           attributes::binary>>,
         expected_transaction_id
       ) do
    # Verify transaction ID matches
    if transaction_id == expected_transaction_id do
      # Parse attributes to find XOR-MAPPED-ADDRESS or MAPPED-ADDRESS
      parse_attributes(attributes, length)
    else
      {:error, :transaction_id_mismatch}
    end
  end

  defp parse_binding_response(_, _), do: {:error, :invalid_response}

  # Parse STUN attributes looking for mapped address
  defp parse_attributes(<<>>, _remaining), do: {:error, :no_mapped_address}
  defp parse_attributes(_, remaining) when remaining <= 0, do: {:error, :no_mapped_address}

  defp parse_attributes(
         <<type::16, attr_length::16, value::binary-size(attr_length), rest::binary>>,
         remaining
       ) do
    # Calculate padding (attributes are aligned to 4-byte boundaries)
    padding = rem(4 - rem(attr_length, 4), 4)
    rest = skip_padding(rest, padding)

    case type do
      @attr_xor_mapped_address ->
        parse_xor_mapped_address(value)

      @attr_mapped_address ->
        parse_mapped_address(value)

      _ ->
        # Skip unknown attribute and continue
        bytes_consumed = 4 + attr_length + padding
        parse_attributes(rest, remaining - bytes_consumed)
    end
  end

  defp parse_attributes(_, _), do: {:error, :malformed_attributes}

  # Skip padding bytes
  defp skip_padding(data, 0), do: data
  defp skip_padding(<<_padding::binary-size(1), rest::binary>>, 1), do: rest
  defp skip_padding(<<_padding::binary-size(2), rest::binary>>, 2), do: rest
  defp skip_padding(<<_padding::binary-size(3), rest::binary>>, 3), do: rest
  defp skip_padding(data, _), do: data

  # Parse XOR-MAPPED-ADDRESS attribute (RFC 5389)
  # Format: 1 byte reserved, 1 byte family, 2 bytes x-port, 4 bytes x-address
  defp parse_xor_mapped_address(<<0, 0x01, xor_port::16, xor_addr::32>>) do
    # XOR with magic cookie to get real values
    port = Bitwise.bxor(xor_port, Bitwise.bsr(@magic_cookie, 16))
    addr = Bitwise.bxor(xor_addr, @magic_cookie)

    # Convert to IP string
    a = Bitwise.band(Bitwise.bsr(addr, 24), 0xFF)
    b = Bitwise.band(Bitwise.bsr(addr, 16), 0xFF)
    c = Bitwise.band(Bitwise.bsr(addr, 8), 0xFF)
    d = Bitwise.band(addr, 0xFF)

    Logger.debug("STUN: XOR-MAPPED-ADDRESS #{a}.#{b}.#{c}.#{d}:#{port}")
    {:ok, "#{a}.#{b}.#{c}.#{d}"}
  end

  # IPv6 XOR-MAPPED-ADDRESS (not supported yet)
  defp parse_xor_mapped_address(<<0, 0x02, _rest::binary>>) do
    {:error, :ipv6_not_supported}
  end

  defp parse_xor_mapped_address(_), do: {:error, :invalid_xor_mapped_address}

  # Parse MAPPED-ADDRESS attribute (legacy, RFC 3489)
  # Format: 1 byte reserved, 1 byte family, 2 bytes port, 4 bytes address
  defp parse_mapped_address(<<0, 0x01, _port::16, a, b, c, d>>) do
    {:ok, "#{a}.#{b}.#{c}.#{d}"}
  end

  defp parse_mapped_address(<<0, 0x02, _rest::binary>>) do
    {:error, :ipv6_not_supported}
  end

  defp parse_mapped_address(_), do: {:error, :invalid_mapped_address}
end
