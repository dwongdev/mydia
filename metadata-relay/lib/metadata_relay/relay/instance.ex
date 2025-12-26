defmodule MetadataRelay.Relay.Instance do
  @moduledoc """
  Schema for relay instances - Mydia servers that register with the relay.

  Each instance registers with:
  - A unique instance_id (UUID)
  - A Noise protocol public key for E2E encryption
  - Direct URLs where the instance can be reached

  The relay tracks online status and maintains WebSocket connections
  for NAT traversal when direct connections aren't possible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "relay_instances" do
    field :instance_id, :string
    field :public_key, :binary
    field :direct_urls, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime
    field :online, :boolean, default: false

    has_many :claims, MetadataRelay.Relay.Claim

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new instance registration.
  """
  def create_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:instance_id, :public_key, :direct_urls])
    |> validate_required([:instance_id, :public_key])
    |> validate_length(:instance_id, min: 1, max: 255)
    |> validate_public_key()
    |> unique_constraint(:instance_id)
  end

  @doc """
  Changeset for updating instance presence (heartbeat).
  """
  def heartbeat_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:direct_urls, :last_seen_at, :online])
  end

  @doc """
  Changeset for updating online status.
  """
  def online_changeset(instance, online) when is_boolean(online) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    instance
    |> change(online: online, last_seen_at: now)
  end

  defp validate_public_key(changeset) do
    case get_change(changeset, :public_key) do
      nil ->
        changeset

      key when is_binary(key) and byte_size(key) == 32 ->
        changeset

      _key ->
        add_error(changeset, :public_key, "must be a 32-byte Curve25519 public key")
    end
  end
end
