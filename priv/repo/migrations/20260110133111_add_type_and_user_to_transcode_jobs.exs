defmodule Mydia.Repo.Migrations.AddTypeAndUserToTranscodeJobs do
  use Ecto.Migration

  def change do
    alter table(:transcode_jobs) do
      add :type, :string, default: "download", null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    # Drop the old unique index that was strictly for downloads
    drop_if_exists unique_index(:transcode_jobs, [:media_file_id, :resolution])

    # Create a new partial unique index for downloads only
    create unique_index(:transcode_jobs, [:media_file_id, :resolution],
             where: "type = 'download'"
           )

    # Add index for type for faster filtering
    create index(:transcode_jobs, [:type])
  end
end
