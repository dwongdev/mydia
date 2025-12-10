defmodule Mydia.Adult.AdultFile do
  @moduledoc """
  Schema for adult content files (video files on disk).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "adult_files" do
    field :path, :string
    field :relative_path, :string
    field :size, :integer
    field :resolution, :string
    field :codec, :string
    field :audio_codec, :string
    field :bitrate, :integer
    field :duration, :integer
    field :hdr_format, :string

    belongs_to :scene, Mydia.Adult.Scene
    belongs_to :library_path, Mydia.Settings.LibraryPath

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an adult file.
  """
  def changeset(adult_file, attrs) do
    adult_file
    |> cast(attrs, [
      :path,
      :relative_path,
      :size,
      :resolution,
      :codec,
      :audio_codec,
      :bitrate,
      :duration,
      :hdr_format,
      :scene_id,
      :library_path_id
    ])
    |> validate_required([:path])
    |> unique_constraint(:path)
    |> foreign_key_constraint(:scene_id)
    |> foreign_key_constraint(:library_path_id)
  end
end
