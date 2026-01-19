defmodule Mydia.RemoteAccess.ProtocolVersion do
  @moduledoc """
  Protocol version constants and negotiation for remote access.

  ## Version Layers

  The remote access protocol has multiple independent layers:

  - `relay_protocol` - Relay WebSocket message format
  - `encryption_protocol` - E2E encryption scheme (X25519 ECDH, ChaCha20-Poly1305)
  - `pairing_protocol` - Device pairing handshake (claim codes, key exchange)
  - `api_protocol` - Tunneled API request/response format

  ## Multi-Version Support

  Each layer advertises a list of supported versions. Components negotiate
  the highest mutually-supported major version during handshake.

  ## Version Format

  `{major}.{minor}` where:
  - Major = Incompatible change requiring negotiation
  - Minor = Backward-compatible addition
  """

  require Logger

  # Supported versions for each protocol layer
  # Add new versions to these lists when implementing breaking changes
  @relay_protocol_supported ["1.0"]
  @encryption_protocol_supported ["1.0"]
  @pairing_protocol_supported ["1.0"]
  @api_protocol_supported ["1.0"]

  @doc """
  Returns all supported versions for each protocol layer.

  ## Example

      iex> ProtocolVersion.supported_versions()
      %{
        "relay_protocol" => ["1.0"],
        "encryption_protocol" => ["1.0"],
        "pairing_protocol" => ["1.0"],
        "api_protocol" => ["1.0"]
      }
  """
  @spec supported_versions() :: %{String.t() => [String.t()]}
  def supported_versions do
    %{
      "relay_protocol" => @relay_protocol_supported,
      "encryption_protocol" => @encryption_protocol_supported,
      "pairing_protocol" => @pairing_protocol_supported,
      "api_protocol" => @api_protocol_supported
    }
  end

  @doc """
  Negotiates the best common version for a protocol layer.

  Finds the highest version that both sides support.

  ## Parameters

  - `layer` - Protocol layer name (e.g., "encryption_protocol")
  - `remote_versions` - Remote supported versions (list)

  ## Returns

  - `{:ok, version}` - The highest mutually supported version
  - `{:error, :no_compatible_version}` - No common major version found

  ## Examples

      iex> ProtocolVersion.negotiate("encryption_protocol", ["1.0", "2.0"])
      {:ok, "1.0"}

      iex> ProtocolVersion.negotiate("encryption_protocol", ["2.0"])
      {:error, :no_compatible_version}
  """
  @spec negotiate(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :no_compatible_version}
  def negotiate(layer, remote_versions) when is_list(remote_versions) do
    local = Map.get(supported_versions(), layer, [])
    common = find_common_major_versions(local, remote_versions)

    case common do
      [] ->
        Logger.warning(
          "No compatible version for #{layer}: local=#{inspect(local)}, remote=#{inspect(remote_versions)}"
        )

        {:error, :no_compatible_version}

      versions ->
        {:ok, Enum.max(versions)}
    end
  end

  @doc """
  Negotiates all protocol layers at once.

  ## Parameters

  - `remote_versions` - Map of layer names to supported version lists

  ## Returns

  - `{:ok, negotiated}` - Map of layer names to negotiated versions
  - `{:error, :incompatible, failed_layers}` - List of layers that failed
  """
  @spec negotiate_all(map()) :: {:ok, map()} | {:error, :incompatible, [String.t()]}
  def negotiate_all(remote_versions) when is_map(remote_versions) do
    layers = ["encryption_protocol", "pairing_protocol", "api_protocol"]

    results =
      Enum.map(layers, fn layer ->
        remote = Map.get(remote_versions, layer, [])
        {layer, negotiate(layer, remote)}
      end)

    failed = for {layer, {:error, _}} <- results, do: layer
    negotiated = for {layer, {:ok, version}} <- results, into: %{}, do: {layer, version}

    if failed == [] do
      {:ok, negotiated}
    else
      {:error, :incompatible, failed}
    end
  end

  @doc """
  Builds the "update required" error response.

  ## Parameters

  - `failed_layers` - List of layer names that failed negotiation
  """
  @spec update_required_response([String.t()]) :: map()
  def update_required_response(failed_layers) do
    incompatible_details =
      Enum.map(failed_layers, fn layer ->
        %{
          layer: layer,
          server_versions: Map.get(supported_versions(), layer, []),
          message: "#{layer} version incompatible"
        }
      end)

    %{
      type: "error",
      code: "update_required",
      message: "Client version is incompatible. Please update your app.",
      incompatible_layers: incompatible_details,
      update_url: Application.get_env(:mydia, :player_update_url, "")
    }
  end

  # Private functions

  defp find_common_major_versions(local, remote) do
    local_majors =
      local
      |> Enum.map(&major_version/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    remote
    |> Enum.filter(fn v ->
      case major_version(v) do
        nil -> false
        major -> MapSet.member?(local_majors, major)
      end
    end)
  end

  defp major_version(version_string) when is_binary(version_string) do
    case String.split(version_string, ".") do
      [major | _] ->
        case Integer.parse(major) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp major_version(_), do: nil
end
