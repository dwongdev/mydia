defmodule MetadataRelay.Relay.ProtocolVersion do
  @moduledoc """
  Protocol version constants and negotiation for the relay service.

  The relay only validates the `relay_protocol` version since it doesn't
  participate in E2E encryption or API content - it just forwards messages.

  ## Multi-Version Support

  The relay advertises a list of supported versions. Components negotiate
  the highest mutually-supported major version during handshake.
  """

  require Logger

  # Supported versions for relay protocol
  @relay_protocol_supported ["1.0"]

  @doc """
  Returns the list of supported relay protocol versions.

  ## Example

      iex> ProtocolVersion.supported_versions()
      ["1.0"]
  """
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @relay_protocol_supported

  @doc """
  Returns the preferred (highest) relay protocol version.

  Used in responses to indicate the relay's current version.
  """
  @spec preferred_version() :: String.t()
  def preferred_version, do: Enum.max(@relay_protocol_supported)

  @doc """
  Negotiates the best common relay protocol version.

  ## Parameters

  - `remote_versions` - Remote supported versions (list)

  ## Returns

  - `{:ok, version}` - The highest mutually supported version
  - `{:error, :no_compatible_version}` - No common major version found

  ## Examples

      iex> ProtocolVersion.negotiate(["1.0", "2.0"])
      {:ok, "1.0"}

      iex> ProtocolVersion.negotiate(["2.0"])
      {:error, :no_compatible_version}
  """
  @spec negotiate([String.t()]) :: {:ok, String.t()} | {:error, :no_compatible_version}
  def negotiate(remote_versions) when is_list(remote_versions) do
    common = find_common_major_versions(@relay_protocol_supported, remote_versions)

    case common do
      [] ->
        Logger.warning(
          "No compatible relay protocol version: local=#{inspect(@relay_protocol_supported)}, remote=#{inspect(remote_versions)}"
        )

        {:error, :no_compatible_version}

      versions ->
        {:ok, Enum.max(versions)}
    end
  end

  @doc """
  Builds an error response for version incompatibility.
  """
  @spec version_error_response() :: map()
  def version_error_response do
    %{
      type: "error",
      code: "version_incompatible",
      message: "Relay protocol version mismatch",
      supported_versions: @relay_protocol_supported
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
