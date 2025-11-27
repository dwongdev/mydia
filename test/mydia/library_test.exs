defmodule Mydia.LibraryTest do
  use Mydia.DataCase

  alias Mydia.Library

  import Mydia.SettingsFixtures

  describe "update_media_file_scan/2" do
    test "updates orphaned media file without validation errors" do
      library_path = library_path_fixture(%{type: "movies"})

      # Create an orphaned file (no media_item_id or episode_id)
      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "orphaned/file.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      assert is_nil(media_file.media_item_id)
      assert is_nil(media_file.episode_id)

      # Update using scan function should succeed
      {:ok, updated} =
        Library.update_media_file_scan(media_file, %{
          size: 2_000_000,
          verified_at: DateTime.utc_now()
        })

      assert updated.size == 2_000_000
      assert updated.verified_at != nil
    end

    test "regular update_media_file fails on orphaned files" do
      library_path = library_path_fixture(%{type: "movies"})

      # Create an orphaned file
      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "orphaned/file2.mp4",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      # Regular update should fail due to missing parent
      {:error, changeset} =
        Library.update_media_file(media_file, %{
          size: 2_000_000,
          verified_at: DateTime.utc_now()
        })

      assert %{media_item_id: ["either media_item_id or episode_id must be set"]} =
               errors_on(changeset)
    end
  end
end
