defmodule Mydia.Settings.MediaServerConfig do
  @moduledoc """
  Schema for media server configurations (Plex, Jellyfin).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @server_types [:plex, :jellyfin]

  schema "media_server_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @server_types
    field :enabled, :boolean, default: true
    field :url, :string
    field :token, :string
    field :connection_settings, Mydia.Settings.JsonMapType

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a media server config.
  """
  def changeset(media_server_config, attrs) do
    media_server_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :url,
      :token,
      :connection_settings,
      :updated_by_id
    ])
    |> validate_required([:name, :type, :url])
    |> validate_inclusion(:type, @server_types)
    |> unique_constraint(:name)
  end
end
