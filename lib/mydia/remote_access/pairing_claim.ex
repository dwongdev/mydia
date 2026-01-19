defmodule Mydia.RemoteAccess.PairingClaim do
  @moduledoc """
  Schema for device pairing claim codes.
  Represents a short-lived code that a user can generate to pair a new device.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Characters to use for claim codes - excludes ambiguous characters
  @code_chars "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 8
  @expiry_minutes 5

  schema "pairing_claims" do
    field :code, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User
    belongs_to :device, Mydia.RemoteAccess.RemoteDevice

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new pairing claim.
  Generates a random code and sets expiration time.
  """
  def create_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:user_id])
    |> validate_required([:user_id])
    |> put_code()
    |> put_expiration()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:code)
  end

  @doc """
  Changeset for creating a claim with a pre-generated code from the relay.
  Used when the relay service generates the code.
  """
  def changeset_with_code(claim, attrs) do
    claim
    |> cast(attrs, [:user_id, :code, :expires_at])
    |> validate_required([:user_id, :code, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:code)
  end

  @doc """
  Changeset for consuming a claim (marking it as used).
  """
  def consume_changeset(claim, device_id) do
    claim
    |> change(used_at: DateTime.utc_now() |> DateTime.truncate(:second), device_id: device_id)
    |> foreign_key_constraint(:device_id)
  end

  @doc """
  Returns true if the claim is valid (not expired and not used).
  """
  def valid?(%__MODULE__{used_at: nil, expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  def valid?(%__MODULE__{}), do: false

  @doc """
  Returns true if the claim has been used.
  """
  def used?(%__MODULE__{used_at: nil}), do: false
  def used?(%__MODULE__{used_at: _}), do: true

  @doc """
  Returns true if the claim has expired.
  """
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  @doc """
  Generates a random claim code.
  """
  def generate_code do
    @code_length
    |> generate_code_string()
    |> format_code()
  end

  # Generate a cryptographically random string of the specified length using allowed characters
  defp generate_code_string(length) do
    chars = String.graphemes(@code_chars)
    count = length(chars)

    # Generate cryptographically secure random bytes
    random_bytes = :crypto.strong_rand_bytes(length)

    random_bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      # Use modulo to map byte value to character index
      Enum.at(chars, rem(byte, count))
    end)
    |> Enum.join()
  end

  # Format code by inserting a dash in the middle for readability
  # e.g., "ABCD1234" -> "ABCD-1234"
  defp format_code(code) do
    half = div(String.length(code), 2)
    {first, second} = String.split_at(code, half)
    "#{first}-#{second}"
  end

  # Put a generated code into the changeset
  defp put_code(changeset) do
    put_change(changeset, :code, generate_code())
  end

  # Put expiration timestamp into the changeset
  defp put_expiration(changeset) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@expiry_minutes * 60, :second)
      |> DateTime.truncate(:second)

    put_change(changeset, :expires_at, expires_at)
  end
end
