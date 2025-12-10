defmodule Mydia.Library.AdultScannerTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.AdultScanner
  alias Mydia.Adult

  describe "parse_filename/1" do
    test "parses 'Studio - Scene Title (2023).mp4' format" do
      result = AdultScanner.parse_filename("Vixen - Beautiful Scene (2023).mp4")

      assert result.studio == "Vixen"
      assert result.title == "Beautiful Scene"
      assert result.year == 2023
      assert result.performers == []
    end

    test "parses 'Studio - Title' format without year" do
      result = AdultScanner.parse_filename("Blacked - Amazing Scene.mp4")

      assert result.studio == "Blacked"
      assert result.title == "Amazing Scene"
      assert result.year == nil
      assert result.performers == []
    end

    test "parses 'Studio - Performer1, Performer2 - Title' format" do
      result = AdultScanner.parse_filename("Tushy - Jane Doe, John Smith - Scene Title.mkv")

      assert result.studio == "Tushy"
      assert result.title == "Scene Title"
      assert result.performers == ["Jane Doe", "John Smith"]
    end

    test "parses 'Studio - Performer1 & Performer2 - Title' format with ampersand" do
      result = AdultScanner.parse_filename("Studio - Alice & Bob - Great Scene.mp4")

      assert result.studio == "Studio"
      assert result.title == "Great Scene"
      assert result.performers == ["Alice", "Bob"]
    end

    test "parses dotted format 'Studio.Scene.Title.XXX.1080p.mp4'" do
      result = AdultScanner.parse_filename("Brazzers.Amazing.Scene.Title.XXX.1080p.x264.mp4")

      assert result.studio == "Brazzers"
      assert result.title == "Amazing Scene Title"
      assert result.year == nil
      assert result.performers == []
    end

    test "filters out quality indicators in dotted format" do
      result = AdultScanner.parse_filename("Studio.Scene.Title.720p.HEVC.mp4")

      assert result.studio == "Studio"
      assert result.title == "Scene Title"
    end

    test "handles plain filename with year" do
      result = AdultScanner.parse_filename("Just A Title (2022).mp4")

      assert result.studio == nil
      assert result.title == "Just A Title"
      assert result.year == 2022
    end

    test "handles plain filename without structure" do
      result = AdultScanner.parse_filename("random_video_file.mp4")

      assert result.studio == nil
      assert result.title == "random_video_file"
      assert result.year == nil
      assert result.performers == []
    end

    test "handles empty performers in structured format" do
      result = AdultScanner.parse_filename("Studio - - Title.mp4")

      # This should fall back since the middle part is empty
      assert result.title != nil
    end

    test "trims whitespace from parsed values" do
      result = AdultScanner.parse_filename("  Studio  -  Scene Title  .mp4")

      assert result.studio == "Studio"
      assert result.title == "Scene Title"
    end

    test "handles files with complex extensions" do
      result = AdultScanner.parse_filename("Studio - Scene.final.cut.mp4")

      assert result.studio == "Studio"
      assert result.title == "Scene.final.cut"
    end
  end

  describe "process_scan_result/2" do
    setup do
      # Create a library path for adult content
      {:ok, library_path} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/test_adult_lib_#{:rand.uniform(100_000)}",
          type: :adult,
          monitored: true
        })

      on_exit(fn ->
        Mydia.Settings.delete_library_path(library_path)
      end)

      %{library_path: library_path}
    end

    test "handles empty scan result", %{library_path: library_path} do
      scan_result = %{
        files: [],
        total_count: 0,
        total_size: 0,
        errors: []
      }

      result = AdultScanner.process_scan_result(library_path, scan_result)

      assert result.new_files == 0
      assert result.modified_files == 0
      assert result.deleted_files == 0
    end

    test "reports correct change counts", %{library_path: library_path} do
      # First, create some existing files
      {:ok, studio} = Adult.create_studio(%{name: "Test Studio"})
      {:ok, scene} = Adult.create_scene(%{title: "Test Scene", studio_id: studio.id})

      {:ok, _existing_file} =
        Adult.create_adult_file(%{
          path: "#{library_path.path}/existing.mp4",
          relative_path: "existing.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      # Scan result with only new files (existing file is "deleted" since not in scan)
      scan_result = %{
        files: [],
        total_count: 0,
        total_size: 0,
        errors: []
      }

      result = AdultScanner.process_scan_result(library_path, scan_result)

      # The existing file should be marked for deletion since it's not in scan
      assert result.deleted_files == 1
    end
  end

  describe "studio matching" do
    setup do
      {:ok, studio} = Adult.create_studio(%{name: "Existing Studio"})
      %{studio: studio}
    end

    test "finds existing studio by name", %{studio: _studio} do
      studios = Adult.list_studios()
      assert Enum.any?(studios, fn s -> s.name == "Existing Studio" end)
    end

    test "studio lookup is case-sensitive" do
      # Create studio with specific casing
      {:ok, _} = Adult.create_studio(%{name: "Case Test Studio"})

      # Lookup with exact case should work
      assert Adult.get_studio_by_name("Case Test Studio") != nil

      # Lookup with different case should not find it (current implementation)
      assert Adult.get_studio_by_name("CASE TEST STUDIO") == nil
    end
  end

  describe "scene creation" do
    setup do
      {:ok, studio} = Adult.create_studio(%{name: "Scene Test Studio"})
      %{studio: studio}
    end

    test "creates scene with performers array", %{studio: studio} do
      {:ok, scene} =
        Adult.create_scene(%{
          title: "Scene with Performers",
          studio_id: studio.id,
          performers: ["Performer One", "Performer Two"]
        })

      assert scene.performers == ["Performer One", "Performer Two"]
    end

    test "creates scene with empty performers by default", %{studio: studio} do
      {:ok, scene} =
        Adult.create_scene(%{
          title: "Scene without Performers",
          studio_id: studio.id
        })

      assert scene.performers == []
    end

    test "creates scene with tags", %{studio: studio} do
      {:ok, scene} =
        Adult.create_scene(%{
          title: "Tagged Scene",
          studio_id: studio.id,
          tags: ["tag1", "tag2", "tag3"]
        })

      assert scene.tags == ["tag1", "tag2", "tag3"]
    end
  end

  describe "extensions_for_library_type/1" do
    alias Mydia.Library.Scanner

    test "returns video and image extensions for :adult type" do
      extensions = Scanner.extensions_for_library_type(:adult)

      # Video extensions
      assert ".mkv" in extensions
      assert ".mp4" in extensions
      assert ".avi" in extensions

      # Image extensions
      assert ".jpg" in extensions
      assert ".jpeg" in extensions
      assert ".png" in extensions
    end
  end
end
