defmodule Mydia.RemoteAccess.Config do
  @moduledoc """
  Schema for remote access instance configuration.
  Stores the instance identity for remote access.

  Note: The relay URL is read from the METADATA_RELAY_URL environment variable
  at runtime via `Mydia.Metadata.metadata_relay_url/0`, not stored in the database.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "remote_access_config" do
    field :instance_id, :string
    field :static_public_key, :binary
    field :static_private_key_encrypted, :binary
    field :enabled, :boolean, default: false
    field :direct_urls, {:array, :string}, default: []
    field :cert_fingerprint, :string
    # Port overrides for public IP URLs (overrides env var if set)
    field :public_port, :integer
    field :public_https_port, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating remote access configuration.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :instance_id,
      :static_public_key,
      :static_private_key_encrypted,
      :enabled,
      :direct_urls,
      :cert_fingerprint,
      :public_port,
      :public_https_port
    ])
    |> validate_required([
      :instance_id,
      :static_public_key,
      :static_private_key_encrypted
    ])
    |> validate_length(:instance_id, min: 1, max: 255)
    |> validate_number(:public_port, greater_than: 0, less_than: 65536)
    |> validate_number(:public_https_port, greater_than: 0, less_than: 65536)
    |> unique_constraint(:instance_id)
  end

  @doc """
  Changeset for toggling remote access enabled state.
  """
  def toggle_enabled_changeset(config, enabled) when is_boolean(enabled) do
    change(config, enabled: enabled)
  end

  @doc """
  Changeset for updating direct URLs.
  """
  def update_direct_urls_changeset(config, direct_urls) do
    change(config, direct_urls: direct_urls)
  end

  @doc """
  Changeset for updating public port.
  """
  def update_public_port_changeset(config, public_port) do
    config
    |> change(public_port: public_port)
    |> validate_number(:public_port, greater_than: 0, less_than: 65536)
  end

  @doc """
  Changeset for updating public HTTPS port.
  """
  def update_public_https_port_changeset(config, public_https_port) do
    config
    |> change(public_https_port: public_https_port)
    |> validate_number(:public_https_port, greater_than: 0, less_than: 65536)
  end

  @doc """
  Changeset for updating both public ports.
  """
  def update_public_ports_changeset(config, attrs) do
    config
    |> cast(attrs, [:public_port, :public_https_port])
    |> validate_number(:public_port, greater_than: 0, less_than: 65536)
    |> validate_number(:public_https_port, greater_than: 0, less_than: 65536)
  end
end
