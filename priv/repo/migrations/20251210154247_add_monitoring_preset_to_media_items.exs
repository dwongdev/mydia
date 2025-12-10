defmodule Mydia.Repo.Migrations.AddMonitoringPresetToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :monitoring_preset, :string, default: "all"
    end
  end
end
