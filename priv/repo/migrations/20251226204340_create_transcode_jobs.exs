defmodule Mydia.Repo.Migrations.CreateTranscodeJobs do
  use Ecto.Migration

  def change do
    create table(:transcode_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id, references(:media_files, type: :binary_id, on_delete: :delete_all),
        null: false

      add :resolution, :string, null: false
      add :status, :string, null: false
      add :progress, :float
      add :output_path, :string
      add :file_size, :integer
      add :error, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :last_accessed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transcode_jobs, [:media_file_id, :resolution])
    create index(:transcode_jobs, [:status])
    create index(:transcode_jobs, [:media_file_id])
  end
end
