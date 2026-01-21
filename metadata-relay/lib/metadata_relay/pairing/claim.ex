defmodule MetadataRelay.Pairing.Claim do
  @moduledoc """
  Schema for iroh-based P2P pairing claim codes.

  This is a simplified pairing flow:
  1. Mydia server gets its node_addr (iroh EndpointAddr JSON)
  2. Server POSTs node_addr to relay, receives claim code
  3. User enters code in Flutter app
  4. App GETs the code, receives node_addr
  5. App dials server directly using node_addr
  6. Server DELETEs the claim code after successful pairing

  Codes are:
  - 6 alphanumeric characters (case-insensitive, no ambiguous chars)
  - Valid for 5 minutes by default
  - Single-use (deleted after pairing)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Default expiration: 5 minutes
  @default_ttl_seconds 300

  schema "pairing_claims" do
    field(:code, :string)
    field(:node_addr, :string)
    field(:expires_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new pairing claim.
  """
  def create_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:code, :node_addr, :expires_at])
    |> validate_required([:code, :node_addr])
    |> validate_length(:code, min: 6, max: 8)
    |> validate_format(:code, ~r/^[A-Z0-9]+$/i, message: "must be alphanumeric")
    |> validate_node_addr()
    |> put_default_expiration()
    |> unique_constraint(:code)
  end

  @doc """
  Checks if a claim has expired.
  """
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if a claim is valid (not expired).
  """
  def valid?(claim) do
    not expired?(claim)
  end

  @doc """
  Generates a cryptographically secure random claim code.

  Uses `:crypto.strong_rand_bytes/1` for secure random number generation.
  Default length is 6 characters providing ~31 bits of entropy.
  Excludes ambiguous characters (0, O, I, 1, L).
  """
  def generate_code(length \\ 6) do
    # Alphabet without ambiguous characters: 0/O, 1/I/L
    alphabet = ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    char_count = length(alphabet)

    :crypto.strong_rand_bytes(length)
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(alphabet, rem(byte, char_count)) end)
    |> List.to_string()
  end

  defp put_default_expiration(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(@default_ttl_seconds, :second)
          |> DateTime.truncate(:second)

        put_change(changeset, :expires_at, expires_at)

      _ ->
        changeset
    end
  end

  # Validates that node_addr is valid JSON
  defp validate_node_addr(changeset) do
    validate_change(changeset, :node_addr, fn :node_addr, value ->
      case Jason.decode(value) do
        {:ok, _} -> []
        {:error, _} -> [node_addr: "must be valid JSON"]
      end
    end)
  end
end
