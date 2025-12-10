defmodule Mydia.AdultTest do
  use Mydia.DataCase, async: true

  alias Mydia.Adult

  describe "studios" do
    test "list_studios/0 returns all studios" do
      {:ok, studio1} = Adult.create_studio(%{name: "Studio One"})
      {:ok, studio2} = Adult.create_studio(%{name: "Studio Two"})

      studios = Adult.list_studios()
      assert length(studios) >= 2
      assert Enum.any?(studios, &(&1.id == studio1.id))
      assert Enum.any?(studios, &(&1.id == studio2.id))
    end

    test "list_studios/1 filters by search" do
      {:ok, _studio1} = Adult.create_studio(%{name: "Matching Studio"})
      {:ok, _studio2} = Adult.create_studio(%{name: "Other Name"})

      studios = Adult.list_studios(search: "Matching")
      assert length(studios) == 1
      assert hd(studios).name == "Matching Studio"
    end

    test "get_studio!/1 returns the studio with given id" do
      {:ok, studio} = Adult.create_studio(%{name: "Test Studio"})
      retrieved = Adult.get_studio!(studio.id)
      assert retrieved.id == studio.id
      assert retrieved.name == "Test Studio"
    end

    test "get_studio_by_name/1 returns the studio with given name" do
      {:ok, studio} = Adult.create_studio(%{name: "Unique Studio Name"})
      retrieved = Adult.get_studio_by_name("Unique Studio Name")
      assert retrieved.id == studio.id
    end

    test "get_studio_by_name/1 returns nil for non-existent studio" do
      assert Adult.get_studio_by_name("Non Existent") == nil
    end

    test "create_studio/1 with valid data creates a studio" do
      attrs = %{name: "New Studio", website: "https://example.com", founded_year: 2020}
      assert {:ok, studio} = Adult.create_studio(attrs)
      assert studio.name == "New Studio"
      assert studio.website == "https://example.com"
      assert studio.founded_year == 2020
    end

    test "create_studio/1 with invalid data returns error changeset" do
      assert {:error, changeset} = Adult.create_studio(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_studio/1 enforces unique name constraint" do
      {:ok, _} = Adult.create_studio(%{name: "Duplicate Name"})
      {:error, changeset} = Adult.create_studio(%{name: "Duplicate Name"})
      assert %{name: _} = errors_on(changeset)
    end

    test "update_studio/2 with valid data updates the studio" do
      {:ok, studio} = Adult.create_studio(%{name: "Original Name"})
      assert {:ok, updated} = Adult.update_studio(studio, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end

    test "delete_studio/1 deletes the studio" do
      {:ok, studio} = Adult.create_studio(%{name: "To Delete"})
      assert {:ok, _} = Adult.delete_studio(studio)
      assert_raise Ecto.NoResultsError, fn -> Adult.get_studio!(studio.id) end
    end

    test "change_studio/1 returns a studio changeset" do
      {:ok, studio} = Adult.create_studio(%{name: "Test"})
      assert %Ecto.Changeset{} = Adult.change_studio(studio)
    end
  end

  describe "scenes" do
    setup do
      {:ok, studio} = Adult.create_studio(%{name: "Test Studio for Scenes"})
      %{studio: studio}
    end

    test "list_scenes/0 returns all scenes", %{studio: studio} do
      {:ok, scene1} = Adult.create_scene(%{title: "Scene One", studio_id: studio.id})
      {:ok, scene2} = Adult.create_scene(%{title: "Scene Two", studio_id: studio.id})

      scenes = Adult.list_scenes()
      assert length(scenes) >= 2
      assert Enum.any?(scenes, &(&1.id == scene1.id))
      assert Enum.any?(scenes, &(&1.id == scene2.id))
    end

    test "list_scenes/1 filters by studio_id", %{studio: studio} do
      {:ok, other_studio} = Adult.create_studio(%{name: "Other Studio"})
      {:ok, scene1} = Adult.create_scene(%{title: "Studio Scene", studio_id: studio.id})
      {:ok, _scene2} = Adult.create_scene(%{title: "Other Scene", studio_id: other_studio.id})

      scenes = Adult.list_scenes(studio_id: studio.id)
      assert length(scenes) == 1
      assert hd(scenes).id == scene1.id
    end

    test "list_scenes/1 filters by search", %{studio: studio} do
      {:ok, _scene1} = Adult.create_scene(%{title: "Matching Scene", studio_id: studio.id})
      {:ok, _scene2} = Adult.create_scene(%{title: "Other Title", studio_id: studio.id})

      scenes = Adult.list_scenes(search: "Matching")
      assert length(scenes) == 1
      assert hd(scenes).title == "Matching Scene"
    end

    test "list_scenes/1 filters by monitored status", %{studio: studio} do
      {:ok, _scene1} =
        Adult.create_scene(%{title: "Monitored", studio_id: studio.id, monitored: true})

      {:ok, _scene2} =
        Adult.create_scene(%{title: "Not Monitored", studio_id: studio.id, monitored: false})

      monitored_scenes = Adult.list_scenes(monitored: true)
      assert Enum.all?(monitored_scenes, & &1.monitored)
    end

    test "count_scenes/0 returns count of all scenes", %{studio: studio} do
      initial_count = Adult.count_scenes()
      {:ok, _} = Adult.create_scene(%{title: "New Scene", studio_id: studio.id})
      assert Adult.count_scenes() == initial_count + 1
    end

    test "get_scene!/1 returns the scene with given id", %{studio: studio} do
      {:ok, scene} = Adult.create_scene(%{title: "Test Scene", studio_id: studio.id})
      retrieved = Adult.get_scene!(scene.id)
      assert retrieved.id == scene.id
      assert retrieved.title == "Test Scene"
    end

    test "create_scene/1 with valid data creates a scene", %{studio: studio} do
      attrs = %{
        title: "New Scene",
        studio_id: studio.id,
        performers: ["Performer A", "Performer B"],
        tags: ["tag1", "tag2"],
        release_date: ~D[2023-06-15]
      }

      assert {:ok, scene} = Adult.create_scene(attrs)
      assert scene.title == "New Scene"
      assert scene.studio_id == studio.id
      assert scene.performers == ["Performer A", "Performer B"]
      assert scene.tags == ["tag1", "tag2"]
      assert scene.release_date == ~D[2023-06-15]
    end

    test "create_scene/1 with invalid data returns error changeset" do
      assert {:error, changeset} = Adult.create_scene(%{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "update_scene/2 with valid data updates the scene", %{studio: studio} do
      {:ok, scene} = Adult.create_scene(%{title: "Original", studio_id: studio.id})
      assert {:ok, updated} = Adult.update_scene(scene, %{title: "Updated"})
      assert updated.title == "Updated"
    end

    test "delete_scene/1 deletes the scene", %{studio: studio} do
      {:ok, scene} = Adult.create_scene(%{title: "To Delete", studio_id: studio.id})
      assert {:ok, _} = Adult.delete_scene(scene)
      assert_raise Ecto.NoResultsError, fn -> Adult.get_scene!(scene.id) end
    end
  end

  describe "adult_files" do
    setup do
      {:ok, studio} = Adult.create_studio(%{name: "File Test Studio"})
      {:ok, scene} = Adult.create_scene(%{title: "File Test Scene", studio_id: studio.id})

      {:ok, library_path} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/adult_test_#{:rand.uniform(100_000)}",
          type: :adult,
          monitored: true
        })

      %{studio: studio, scene: scene, library_path: library_path}
    end

    test "list_adult_files/0 returns all adult files", %{scene: scene, library_path: library_path} do
      {:ok, file1} =
        Adult.create_adult_file(%{
          path: "/path/to/file1.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      {:ok, file2} =
        Adult.create_adult_file(%{
          path: "/path/to/file2.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      files = Adult.list_adult_files()
      assert length(files) >= 2
      assert Enum.any?(files, &(&1.id == file1.id))
      assert Enum.any?(files, &(&1.id == file2.id))
    end

    test "list_adult_files/1 filters by scene_id", %{
      studio: studio,
      scene: scene,
      library_path: library_path
    } do
      {:ok, other_scene} = Adult.create_scene(%{title: "Other Scene", studio_id: studio.id})

      {:ok, file1} =
        Adult.create_adult_file(%{
          path: "/path/to/scene_file.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      {:ok, _file2} =
        Adult.create_adult_file(%{
          path: "/path/to/other_file.mp4",
          scene_id: other_scene.id,
          library_path_id: library_path.id
        })

      files = Adult.list_adult_files(scene_id: scene.id)
      assert length(files) == 1
      assert hd(files).id == file1.id
    end

    test "list_adult_files/1 filters by library_path_id", %{
      scene: scene,
      library_path: library_path
    } do
      {:ok, other_path} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/other_adult_#{:rand.uniform(100_000)}",
          type: :adult,
          monitored: true
        })

      {:ok, file1} =
        Adult.create_adult_file(%{
          path: "/path/file_in_lib.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      {:ok, _file2} =
        Adult.create_adult_file(%{
          path: "/path/file_in_other.mp4",
          scene_id: scene.id,
          library_path_id: other_path.id
        })

      files = Adult.list_adult_files(library_path_id: library_path.id)
      assert length(files) == 1
      assert hd(files).id == file1.id
    end

    test "get_adult_file!/1 returns the adult file with given id", %{
      scene: scene,
      library_path: library_path
    } do
      {:ok, file} =
        Adult.create_adult_file(%{
          path: "/path/to/test.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      retrieved = Adult.get_adult_file!(file.id)
      assert retrieved.id == file.id
    end

    test "get_adult_file_by_path/1 returns the adult file with given path", %{
      scene: scene,
      library_path: library_path
    } do
      path = "/unique/path/to/file_#{:rand.uniform(100_000)}.mp4"

      {:ok, file} =
        Adult.create_adult_file(%{
          path: path,
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      retrieved = Adult.get_adult_file_by_path(path)
      assert retrieved.id == file.id
    end

    test "get_adult_file_by_path/1 returns nil for non-existent path" do
      assert Adult.get_adult_file_by_path("/nonexistent/path.mp4") == nil
    end

    test "create_adult_file/1 with valid data creates an adult file", %{
      scene: scene,
      library_path: library_path
    } do
      attrs = %{
        path: "/path/to/new_file.mp4",
        relative_path: "new_file.mp4",
        scene_id: scene.id,
        library_path_id: library_path.id,
        size: 1024 * 1024 * 500,
        resolution: "1080p",
        codec: "H.264",
        audio_codec: "AAC",
        bitrate: 8_000_000,
        duration: 3600
      }

      assert {:ok, file} = Adult.create_adult_file(attrs)
      assert file.path == "/path/to/new_file.mp4"
      assert file.resolution == "1080p"
      assert file.codec == "H.264"
    end

    test "create_adult_file/1 with invalid data returns error changeset" do
      assert {:error, changeset} = Adult.create_adult_file(%{})
      assert %{path: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_adult_file/1 enforces unique path constraint", %{
      scene: scene,
      library_path: library_path
    } do
      path = "/duplicate/path_#{:rand.uniform(100_000)}.mp4"

      {:ok, _} =
        Adult.create_adult_file(%{
          path: path,
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      {:error, changeset} =
        Adult.create_adult_file(%{
          path: path,
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      assert %{path: _} = errors_on(changeset)
    end

    test "update_adult_file/2 with valid data updates the adult file", %{
      scene: scene,
      library_path: library_path
    } do
      {:ok, file} =
        Adult.create_adult_file(%{
          path: "/path/to/update.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      assert {:ok, updated} = Adult.update_adult_file(file, %{resolution: "4K", codec: "HEVC"})
      assert updated.resolution == "4K"
      assert updated.codec == "HEVC"
    end

    test "delete_adult_file/1 deletes the adult file", %{scene: scene, library_path: library_path} do
      {:ok, file} =
        Adult.create_adult_file(%{
          path: "/path/to/delete.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      assert {:ok, _} = Adult.delete_adult_file(file)
      assert_raise Ecto.NoResultsError, fn -> Adult.get_adult_file!(file.id) end
    end

    test "delete_missing_adult_files/2 removes files not in the list", %{
      scene: scene,
      library_path: library_path
    } do
      {:ok, file1} =
        Adult.create_adult_file(%{
          path: "/keep/this.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      {:ok, file2} =
        Adult.create_adult_file(%{
          path: "/delete/this.mp4",
          scene_id: scene.id,
          library_path_id: library_path.id
        })

      # Keep file1, delete file2
      {deleted_count, _} = Adult.delete_missing_adult_files(library_path.id, ["/keep/this.mp4"])

      assert deleted_count == 1
      assert Adult.get_adult_file_by_path("/keep/this.mp4") != nil
      assert Adult.get_adult_file_by_path("/delete/this.mp4") == nil
    end
  end
end
