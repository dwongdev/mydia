defmodule Mydia.Repo.Migrations.AddPublicHttpsPortToRemoteAccessConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      add :public_https_port, :integer
    end
  end
end
