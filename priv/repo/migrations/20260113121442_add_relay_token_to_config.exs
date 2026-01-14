defmodule Mydia.Repo.Migrations.AddRelayTokenToConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      add :relay_token, :text
    end
  end
end
