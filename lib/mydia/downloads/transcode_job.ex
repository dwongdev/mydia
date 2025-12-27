defmodule Mydia.Downloads.TranscodeJob do
  @moduledoc """
  Schema for tracking transcode jobs and cached transcoded files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transcode_jobs" do
    field :resolution, :string
    field :status, :string
    field :progress, :float
    field :output_path, :string
    field :file_size, :integer
    field :error, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_accessed_at, :utc_datetime

    belongs_to :media_file, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending transcoding ready failed)
  @valid_resolutions ~w(1080p 720p 480p)

  @doc """
  Changeset for creating or updating a transcode job.
  """
  def changeset(transcode_job, attrs) do
    transcode_job
    |> cast(attrs, [
      :media_file_id,
      :resolution,
      :status,
      :progress,
      :output_path,
      :file_size,
      :error,
      :started_at,
      :completed_at,
      :last_accessed_at
    ])
    |> validate_required([:media_file_id, :resolution, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:resolution, @valid_resolutions)
    |> validate_number(:progress, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:file_size, greater_than: 0)
    |> foreign_key_constraint(:media_file_id)
    |> unique_constraint([:media_file_id, :resolution],
      message: "transcode job already exists for this file and resolution"
    )
  end
end
