defmodule Mydia.RemoteAccess.DirectUrls do
  @moduledoc """
  Detects network interfaces and builds sslip.io URLs for direct access.

  This module automatically discovers local network IP addresses and generates
  publicly accessible URLs using sslip.io for direct device-to-server connections.

  Also supports detecting the instance's public IP address using external services,
  which is useful when running behind NAT/Docker where the relay can't see the
  real public IP.
  """

  require Logger

  # Public IP detection services (tried in order)
  @public_ip_services [
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com"
  ]

  # Cache TTL for public IP (5 minutes)
  @public_ip_cache_ttl_ms 5 * 60 * 1000

  # Timeout for public IP detection requests (3 seconds)
  @public_ip_timeout_ms 3_000

  @doc """
  Detects all available direct URLs for the instance.

  Returns a list of URLs that clients can use to connect directly to this instance.
  This includes:
  - Auto-detected LAN URLs using sslip.io
  - Manual external URL override (if configured)
  - Additional direct URLs (if configured)

  ## Configuration

  Reads from Application config `:mydia, :direct_urls`:
  - `:external_port` - Port to use in generated URLs (default: 4000)
  - `:external_url` - Manual external URL override
  - `:additional_direct_urls` - List of additional URLs

  ## Examples

      iex> DirectUrls.detect_all()
      ["https://192-168-1-100.sslip.io:4000", "https://example.com:443"]

  """
  def detect_all do
    config = Application.get_env(:mydia, :direct_urls, [])

    # Get all URL sources
    local_urls = detect_local_urls()
    external_url = Keyword.get(config, :external_url)
    additional_urls = Keyword.get(config, :additional_direct_urls, [])

    # Get public IP URL (returns nil on failure)
    public_url =
      case detect_public_url() do
        {:ok, url} -> url
        {:error, _} -> nil
      end

    # Combine all URLs, filtering out nils
    # Order: external_url first (user-configured), then public_url, then additional, then local
    urls = [external_url, public_url | additional_urls] ++ local_urls

    urls
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Detects local network URLs using network interface detection.

  Scans all network interfaces using `:inet.getifaddrs/0` and builds
  sslip.io URLs for each valid IP address found.

  Filters out:
  - Loopback addresses (127.x.x.x)
  - Link-local addresses (169.254.x.x)
  - Docker bridge addresses (172.17.x.x)
  - IPv6 addresses (currently not supported)

  ## Examples

      iex> DirectUrls.detect_local_urls()
      ["https://192-168-1-100.sslip.io:4000"]

  """
  def detect_local_urls do
    config = Application.get_env(:mydia, :direct_urls, [])
    port = Keyword.get(config, :external_port, 4000)

    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> extract_ip_addresses()
        |> Enum.filter(&valid_ip?/1)
        |> Enum.map(&build_sslip_url(&1, port))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Builds an sslip.io URL from an IP tuple.

  Converts an IP address tuple (e.g., {192, 168, 1, 100}) into an sslip.io
  URL format: https://{a}-{b}-{c}-{d}.sslip.io:{port}

  ## Examples

      iex> DirectUrls.build_sslip_url({192, 168, 1, 100}, 4000)
      "https://192-168-1-100.sslip.io:4000"

  """
  def build_sslip_url({a, b, c, d}, port) when is_integer(port) do
    "https://#{a}-#{b}-#{c}-#{d}.sslip.io:#{port}"
  end

  @doc """
  Detects the public IP address of this instance using external services.

  Makes HTTP requests to external "what's my IP" services to determine the
  public IP address. Results are cached to avoid repeated requests.

  Returns `{:ok, ip_string}` on success, or `{:error, reason}` on failure.

  ## Configuration

  Reads from Application config `:mydia, :direct_urls`:
  - `:public_ip_enabled` - Enable/disable public IP detection (default: true)

  ## Examples

      iex> DirectUrls.detect_public_ip()
      {:ok, "203.0.113.42"}

      iex> DirectUrls.detect_public_ip()
      {:error, :all_services_failed}

  """
  def detect_public_ip do
    config = Application.get_env(:mydia, :direct_urls, [])
    enabled = Keyword.get(config, :public_ip_enabled, true)

    if enabled do
      detect_public_ip_cached()
    else
      {:error, :disabled}
    end
  end

  @doc """
  Detects the public IP and returns an sslip.io URL if successful.

  Uses the configured `public_port` for the URL. The port is determined by
  `get_public_port/0` which checks sources in this order:
  1. Environment variable (PUBLIC_PORT)
  2. Database setting (remote_access_config.public_port)
  3. external_port from config

  Returns `{:ok, url}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> DirectUrls.detect_public_url()
      {:ok, "https://203-0-113-42.sslip.io:4443"}

  """
  def detect_public_url do
    port = get_public_port()

    case detect_public_ip() do
      {:ok, ip_string} ->
        case parse_ip_string(ip_string) do
          {:ok, ip_tuple} ->
            {:ok, build_sslip_url(ip_tuple, port)}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets the public port configuration.

  Checks sources in order of precedence:
  1. Environment variable (PUBLIC_PORT) - highest priority
  2. Database setting (remote_access_config.public_port)
  3. external_port from config - fallback

  Returns the port as an integer.
  """
  def get_public_port do
    env_config = Application.get_env(:mydia, :direct_urls, [])

    # Environment variable takes precedence
    case Keyword.get(env_config, :public_port) do
      port when is_integer(port) ->
        port

      _ ->
        # Try database config
        case get_db_public_port() do
          port when is_integer(port) ->
            port

          _ ->
            # Fall back to external_port
            Keyword.get(env_config, :external_port, 4000)
        end
    end
  end

  # Gets the public_port from database config
  # Returns nil if not set or database unavailable
  defp get_db_public_port do
    case Mydia.RemoteAccess.get_config() do
      %{public_port: port} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    # Database might not be available during startup
    _ -> nil
  end

  @doc """
  Clears the cached public IP, forcing a fresh detection on next call.

  Useful for testing or when the network configuration has changed.
  """
  def clear_public_ip_cache do
    :persistent_term.erase({__MODULE__, :public_ip_cache})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Private helpers

  defp detect_public_ip_cached do
    case get_cached_public_ip() do
      {:ok, _ip} = cached ->
        cached

      :miss ->
        result = detect_public_ip_from_services()

        case result do
          {:ok, ip} ->
            cache_public_ip(ip)
            result

          {:error, _} ->
            result
        end
    end
  end

  defp get_cached_public_ip do
    case :persistent_term.get({__MODULE__, :public_ip_cache}, nil) do
      nil ->
        :miss

      {ip, cached_at} ->
        if System.monotonic_time(:millisecond) - cached_at < @public_ip_cache_ttl_ms do
          {:ok, ip}
        else
          :miss
        end
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_public_ip(ip) do
    :persistent_term.put(
      {__MODULE__, :public_ip_cache},
      {ip, System.monotonic_time(:millisecond)}
    )
  end

  defp detect_public_ip_from_services do
    Enum.reduce_while(@public_ip_services, {:error, :all_services_failed}, fn service_url, _acc ->
      case fetch_public_ip(service_url) do
        {:ok, ip} ->
          Logger.debug("Detected public IP #{ip} from #{service_url}")
          {:halt, {:ok, ip}}

        {:error, reason} ->
          Logger.debug("Failed to get public IP from #{service_url}: #{inspect(reason)}")
          {:cont, {:error, :all_services_failed}}
      end
    end)
  end

  defp fetch_public_ip(service_url) do
    case Req.get(service_url, receive_timeout: @public_ip_timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        ip = String.trim(body)

        if valid_ip_string?(ip) do
          {:ok, ip}
        else
          {:error, :invalid_ip_format}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_ip_string?(ip) when is_binary(ip) do
    case parse_ip_string(ip) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp parse_ip_string(ip) when is_binary(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, {a, b, c, d} = tuple}
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
        {:ok, tuple}

      {:ok, _ipv6} ->
        {:error, :ipv6_not_supported}

      {:error, _} ->
        {:error, :invalid_format}
    end
  end

  # Extracts IPv4 addresses from getifaddrs output
  defp extract_ip_addresses(interfaces) do
    interfaces
    |> Enum.flat_map(fn {_iface, properties} ->
      properties
      |> Enum.filter(fn {key, _value} -> key == :addr end)
      |> Enum.map(fn {:addr, addr} -> addr end)
      |> Enum.filter(&is_ipv4?/1)
    end)
  end

  # Checks if address is IPv4 (4-tuple)
  defp is_ipv4?(addr) when is_tuple(addr) and tuple_size(addr) == 4, do: true
  defp is_ipv4?(_), do: false

  # Validates that an IP address is suitable for public access
  # Loopback
  defp valid_ip?({127, _, _, _}), do: false
  # Link-local
  defp valid_ip?({169, 254, _, _}), do: false
  # Docker bridge
  defp valid_ip?({172, 17, _, _}), do: false

  defp valid_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d),
       do: true

  defp valid_ip?(_), do: false
end
