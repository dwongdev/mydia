defmodule Mydia.Repo.Migrations.MigrateFavoritesToCollections do
  @moduledoc """
  Migrates existing user_favorites data to the new collections system.

  For each user with favorites:
  1. Creates a system "Favorites" collection (is_system: true)
  2. Copies user_favorites entries to collection_items

  The user_favorites table is kept for rollback safety.
  """
  use Ecto.Migration

  def up do
    # For each user that has favorites, create a Favorites collection
    # and migrate their favorites to collection_items
    execute("""
    INSERT INTO collections (id, name, type, visibility, is_system, position, user_id, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))) as id,
      'Favorites' as name,
      'manual' as type,
      'private' as visibility,
      1 as is_system,
      0 as position,
      user_id,
      datetime('now') as inserted_at,
      datetime('now') as updated_at
    FROM (SELECT DISTINCT user_id FROM user_favorites)
    """)

    # Now copy favorites to collection_items
    # We need to join with the newly created collections to get the collection_id
    execute("""
    INSERT INTO collection_items (id, collection_id, media_item_id, position, inserted_at)
    SELECT
      lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))) as id,
      c.id as collection_id,
      uf.media_item_id,
      ROW_NUMBER() OVER (PARTITION BY uf.user_id ORDER BY uf.inserted_at) - 1 as position,
      uf.inserted_at
    FROM user_favorites uf
    INNER JOIN collections c ON c.user_id = uf.user_id AND c.is_system = 1 AND c.name = 'Favorites'
    """)
  end

  def down do
    # Remove migrated collection items
    execute("""
    DELETE FROM collection_items
    WHERE collection_id IN (
      SELECT id FROM collections WHERE is_system = 1 AND name = 'Favorites'
    )
    """)

    # Remove system Favorites collections
    execute("DELETE FROM collections WHERE is_system = 1 AND name = 'Favorites'")
  end
end
