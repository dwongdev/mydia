defmodule Mydia.LibraryTest do
  use Mydia.DataCase

  alias Mydia.Library

  import Mydia.SettingsFixtures

  describe "list_media_files/1 with library_path_type filter" do
    test "filters media files by library path type" do
      # Create library paths of different types
      movies_path = library_path_fixture(%{path: "/movies", type: "movies"})
      adult_path = library_path_fixture(%{path: "/adult", type: "adult"})

      # Create media files in each library
      {:ok, movies_file} =
        Library.create_scanned_media_file(%{
          relative_path: "movie.mp4",
          library_path_id: movies_path.id,
          size: 1_000_000
        })

      {:ok, adult_file} =
        Library.create_scanned_media_file(%{
          relative_path: "video.mp4",
          library_path_id: adult_path.id,
          size: 2_000_000
        })

      # Filter by adult type
      adult_files = Library.list_media_files(library_path_type: :adult)
      assert length(adult_files) == 1
      assert hd(adult_files).id == adult_file.id

      # Filter by movies type
      movie_files = Library.list_media_files(library_path_type: :movies)
      assert length(movie_files) == 1
      assert hd(movie_files).id == movies_file.id
    end

    test "returns empty list when no files match type" do
      # Create a library path of one type
      movies_path = library_path_fixture(%{path: "/movies2", type: "movies"})

      {:ok, _movies_file} =
        Library.create_scanned_media_file(%{
          relative_path: "movie2.mp4",
          library_path_id: movies_path.id,
          size: 1_000_000
        })

      # Query for a different type
      adult_files = Library.list_media_files(library_path_type: :adult)
      assert Enum.empty?(adult_files)
    end

    test "can combine library_path_type with preload" do
      adult_path = library_path_fixture(%{path: "/adult2", type: "adult"})

      {:ok, _adult_file} =
        Library.create_scanned_media_file(%{
          relative_path: "video2.mp4",
          library_path_id: adult_path.id,
          size: 2_000_000
        })

      files = Library.list_media_files(library_path_type: :adult, preload: [:library_path])
      assert length(files) == 1
      assert hd(files).library_path.type == :adult
    end
  end

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
