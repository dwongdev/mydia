defmodule MetadataRelay.Pairing do
  @moduledoc """
  Context module for iroh-based P2P pairing.

  This module handles the simplified pairing flow:
  - Creating claim codes with node_addr (iroh EndpointAddr)
  - Looking up claim codes to get node_addr
  - Deleting claim codes after successful pairing
  - Cleanup of expired claims

  Unlike the full relay system, this doesn't require instance registration.
  The node_addr contains all the information needed to connect directly.
  """

  require Logger

  import Ecto.Query
  alias MetadataRelay.Repo
  alias MetadataRelay.Pairing.Claim

  @doc """
  Creates a new claim code for a node_addr.

  ## Parameters
  - `node_addr` - JSON string of iroh EndpointAddr
  - `opts` - Options:
    - `:ttl_seconds` - Custom TTL (default: 300)
    - `:code` - Custom code (default: auto-generated)

  Returns `{:ok, claim}` or `{:error, changeset}`.

  ## Example

      iex> create_claim('{"relay_url":"...","node_id":"..."}')
      {:ok, %Claim{code: "ABC123", node_addr: "...", expires_at: ~U[...]}}
  """
  def create_claim(node_addr, opts \\ []) do
    code = Keyword.get(opts, :code, Claim.generate_code())
    ttl = Keyword.get(opts, :ttl_seconds, 300)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      code: String.upcase(code),
      node_addr: node_addr,
      expires_at: expires_at
    }

    %Claim{}
    |> Claim.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Looks up a claim code and returns the node_addr if valid.

  ## Parameters
  - `code` - The claim code to look up

  Returns `{:ok, node_addr}` or `{:error, reason}`.

  ## Example

      iex> get_claim("ABC123")
      {:ok, '{"relay_url":"...","node_id":"..."}'}

      iex> get_claim("INVALID")
      {:error, :not_found}
  """
  def get_claim(code) do
    code = normalize_code(code)

    query = from(c in Claim, where: c.code == ^code)

    case Repo.one(query) do
      nil ->
        log_lookup_attempt(code, :not_found)
        {:error, :not_found}

      claim ->
        if Claim.expired?(claim) do
          log_lookup_attempt(code, :expired)
          {:error, :expired}
        else
          log_lookup_attempt(code, :success)
          {:ok, claim.node_addr}
        end
    end
  end

  @doc """
  Deletes a claim code.

  Called after successful pairing to clean up.

  ## Parameters
  - `code` - The claim code to delete

  Returns `:ok` or `{:error, :not_found}`.
  """
  def delete_claim(code) do
    code = normalize_code(code)

    query = from(c in Claim, where: c.code == ^code)

    case Repo.delete_all(query) do
      {0, _} ->
        Logger.debug("Claim delete attempted for non-existent code",
          code_prefix: String.slice(code, 0, 2)
        )

        {:error, :not_found}

      {1, _} ->
        Logger.info("Claim deleted",
          code_prefix: String.slice(code, 0, 2)
        )

        :ok
    end
  end

  @doc """
  Deletes expired claims.

  Used for periodic cleanup.

  ## Parameters
  - `max_age_seconds` - Maximum age in seconds beyond expiry (default: 3600 = 1 hour)

  Returns the number of deleted claims.
  """
  def cleanup_expired(max_age_seconds \\ 3600) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_age_seconds, :second)

    query = from(c in Claim, where: c.expires_at < ^cutoff)

    {count, _} = Repo.delete_all(query)

    if count > 0 do
      Logger.info("Cleaned up expired pairing claims", count: count)
    end

    count
  end

  # Normalizes a claim code by removing whitespace/dashes and uppercasing.
  defp normalize_code(code) when is_binary(code) do
    code
    |> String.upcase()
    |> String.replace(~r/[-\s]/, "")
  end

  defp normalize_code(code), do: code

  # Log lookup attempts for security monitoring
  # Only logs code prefix to avoid exposing full codes
  defp log_lookup_attempt(code, :success) do
    Logger.info("Pairing claim lookup successful",
      code_prefix: String.slice(code, 0, 2)
    )
  end

  defp log_lookup_attempt(code, reason) do
    Logger.warning("Pairing claim lookup failed",
      code_prefix: String.slice(code, 0, 2),
      reason: reason
    )
  end
end
