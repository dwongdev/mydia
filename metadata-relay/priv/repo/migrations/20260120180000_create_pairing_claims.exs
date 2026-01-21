defmodule MetadataRelay.Repo.Migrations.CreatePairingClaims do
  use Ecto.Migration

  @moduledoc """
  Creates the pairing_claims table for iroh-based P2P pairing.

  This is a simplified pairing flow where:
  1. Server posts its node_addr (iroh EndpointAddr) and receives a claim code
  2. Client looks up the claim code to get the node_addr
  3. Client dials the server directly using the node_addr
  4. Server deletes the claim code after successful pairing

  No instance registration is required - just the node_addr.
  """

  def change do
    create table(:pairing_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :node_addr, :text, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pairing_claims, [:code])
    create index(:pairing_claims, [:expires_at])
  end
end
