defmodule Mydia.RemoteAccess.DirectUrls do
  @moduledoc """
  Detects network interfaces and builds sslip.io URLs for direct access.

  This module automatically discovers local network IP addresses and generates
  publicly accessible URLs using sslip.io for direct device-to-server connections.
  """

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

    # Combine all URLs, filtering out nils
    urls = [external_url | additional_urls] ++ local_urls

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

  # Private helpers

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
  defp valid_ip?({127, _, _, _}), do: false  # Loopback
  defp valid_ip?({169, 254, _, _}), do: false  # Link-local
  defp valid_ip?({172, 17, _, _}), do: false  # Docker bridge
  defp valid_ip?({a, b, c, d})
    when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d),
    do: true
  defp valid_ip?(_), do: false
end
