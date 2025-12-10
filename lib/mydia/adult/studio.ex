defmodule Mydia.Adult.Studio do
  @moduledoc """
  Schema for adult content studios/production companies.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "studios" do
    field :name, :string
    field :sort_name, :string
    field :description, :string
    field :image_url, :string
    field :website, :string
    field :founded_year, :integer

    has_many :scenes, Mydia.Adult.Scene

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a studio.
  """
  def changeset(studio, attrs) do
    studio
    |> cast(attrs, [:name, :sort_name, :description, :image_url, :website, :founded_year])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
