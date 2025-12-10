defmodule Mydia.Adult.Scene do
  @moduledoc """
  Schema for adult content scenes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scenes" do
    field :title, :string
    field :release_date, :date
    field :description, :string
    field :performers, {:array, :string}, default: []
    field :tags, {:array, :string}, default: []
    field :cover_url, :string
    field :duration, :integer
    field :monitored, :boolean, default: true

    belongs_to :studio, Mydia.Adult.Studio
    has_many :adult_files, Mydia.Adult.AdultFile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a scene.
  """
  def changeset(scene, attrs) do
    scene
    |> cast(attrs, [
      :title,
      :studio_id,
      :release_date,
      :description,
      :performers,
      :tags,
      :cover_url,
      :duration,
      :monitored
    ])
    |> validate_required([:title])
    |> foreign_key_constraint(:studio_id)
  end
end
