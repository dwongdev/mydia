defmodule Mydia.Repo.Migrations.CreateAdultTables do
  use Ecto.Migration

  def change do
    # Studios table
    create table(:studios, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :sort_name, :string
      add :description, :text
      add :image_url, :string
      add :website, :string
      add :founded_year, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:studios, [:name])
    create index(:studios, [:sort_name])

    # Scenes table
    create table(:scenes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :studio_id, references(:studios, type: :binary_id, on_delete: :nilify_all)
      add :release_date, :date
      add :description, :text
      add :performers, {:array, :string}, default: []
      add :tags, {:array, :string}, default: []
      add :cover_url, :string
      add :duration, :integer
      add :monitored, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:scenes, [:studio_id])
    create index(:scenes, [:title])
    create index(:scenes, [:release_date])

    # Adult files table
    create table(:adult_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scene_id, references(:scenes, type: :binary_id, on_delete: :nilify_all)
      add :library_path_id, references(:library_paths, type: :binary_id, on_delete: :nilify_all)
      add :path, :string, null: false
      add :relative_path, :string
      add :size, :bigint
      add :resolution, :string
      add :codec, :string
      add :audio_codec, :string
      add :bitrate, :integer
      add :duration, :integer
      add :hdr_format, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:adult_files, [:path])
    create index(:adult_files, [:scene_id])
    create index(:adult_files, [:library_path_id])
  end
end
