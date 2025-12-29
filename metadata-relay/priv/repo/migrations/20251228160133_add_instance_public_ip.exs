defmodule MetadataRelay.Repo.Migrations.AddInstancePublicIp do
  use Ecto.Migration

  def change do
    alter table(:relay_instances) do
      add :public_ip, :string
    end
  end
end
