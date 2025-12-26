defmodule Mydia.RemoteAccess.Config do
  @moduledoc """
  Schema for remote access instance configuration.
  Stores the instance identity and relay service configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "remote_access_config" do
    field :instance_id, :string
    field :static_public_key, :binary
    field :static_private_key_encrypted, :binary
    field :relay_url, :string
    field :enabled, :boolean, default: false
    field :direct_urls, :string

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
      :relay_url,
      :enabled,
      :direct_urls
    ])
    |> validate_required([
      :instance_id,
      :static_public_key,
      :static_private_key_encrypted,
      :relay_url
    ])
    |> validate_length(:instance_id, min: 1, max: 255)
    |> validate_format(:relay_url, ~r/^https?:\/\/.+/, message: "must be a valid URL")
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
end
