defmodule Mydia.Content.TypeRegistryTest do
  use ExUnit.Case, async: false

  alias Mydia.Content.TypeRegistry

  @test_config_path "test/fixtures/content_types_test.yml"

  setup do
    # Stop the registry if it's running (from application startup)
    if Process.whereis(TypeRegistry) do
      Agent.stop(TypeRegistry)
      # Wait for process to fully stop
      :timer.sleep(50)
    end

    on_exit(fn ->
      # Cleanup after each test
      if Process.whereis(TypeRegistry) do
        Agent.stop(TypeRegistry)
      end
    end)

    :ok
  end

  describe "start_link/1" do
    test "loads and validates configuration from default path" do
      # Use the actual config file
      assert {:ok, pid} = TypeRegistry.start_link()
      assert Process.alive?(pid)

      # Verify we can query types
      assert {:ok, _definition} = TypeRegistry.get_type(:movie)

      # Cleanup
      Agent.stop(TypeRegistry)
    end

    test "raises error if config file not found" do
      assert_raise RuntimeError, ~r/Failed to load content type configuration/, fn ->
        TypeRegistry.start_link(config_file: "nonexistent.yml")
      end
    end

    test "raises error if config is invalid" do
      # Create a temporary invalid config file
      invalid_config = """
      types:
        movie:
          parent_types: [nonexistent_type]
      """

      tmp_file = "test/tmp_invalid_content_types.yml"
      File.write!(tmp_file, invalid_config)

      assert_raise RuntimeError, ~r/Invalid type references/, fn ->
        TypeRegistry.start_link(config_file: tmp_file)
      end

      # Cleanup
      File.rm(tmp_file)
    end
  end

  describe "get_type/1" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns type definition for valid type" do
      assert {:ok, definition} = TypeRegistry.get_type(:movie)
      assert is_map(definition)
      assert definition.is_playable == true
      assert definition.is_container == false
      assert definition.parent_types == [:library]
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_type} = TypeRegistry.get_type(:invalid_type)
    end

    test "returns tv_show definition correctly" do
      assert {:ok, definition} = TypeRegistry.get_type(:tv_show)
      assert definition.is_container == true
      assert definition.is_playable == false
      assert :season in definition.child_types
    end

    test "returns season definition with virtual flag" do
      assert {:ok, definition} = TypeRegistry.get_type(:season)
      assert definition.virtual == true
      assert definition.sort_field == :season_number
    end

    test "returns episode definition correctly" do
      assert {:ok, definition} = TypeRegistry.get_type(:episode)
      assert definition.is_playable == true
      assert definition.parent_types == [:season]
    end
  end

  describe "get_type!/1" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns type definition for valid type" do
      definition = TypeRegistry.get_type!(:movie)
      assert is_map(definition)
      assert definition.is_playable == true
    end

    test "raises error for unknown type" do
      assert_raise ArgumentError, ~r/Unknown content type: invalid_type/, fn ->
        TypeRegistry.get_type!(:invalid_type)
      end
    end
  end

  describe "valid_child?/2" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns true for valid parent-child relationships" do
      assert TypeRegistry.valid_child?(:library, :movie) == true
      assert TypeRegistry.valid_child?(:library, :tv_show) == true
      assert TypeRegistry.valid_child?(:tv_show, :season) == true
      assert TypeRegistry.valid_child?(:season, :episode) == true
      assert TypeRegistry.valid_child?(:library, :artist) == true
      assert TypeRegistry.valid_child?(:artist, :album) == true
      assert TypeRegistry.valid_child?(:album, :track) == true
    end

    test "returns false for invalid parent-child relationships" do
      assert TypeRegistry.valid_child?(:movie, :season) == false
      assert TypeRegistry.valid_child?(:episode, :movie) == false
      assert TypeRegistry.valid_child?(:tv_show, :episode) == false
      assert TypeRegistry.valid_child?(:library, :episode) == false
    end

    test "returns false for unknown types" do
      assert TypeRegistry.valid_child?(:invalid_parent, :movie) == false
      assert TypeRegistry.valid_child?(:library, :invalid_child) == false
    end

    test "validates book can have multiple parent types" do
      assert TypeRegistry.valid_child?(:author, :book) == true
      assert TypeRegistry.valid_child?(:library, :book) == true
    end
  end

  describe "metadata_schema/1" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns metadata schema for movie type" do
      assert {:ok, schema} = TypeRegistry.metadata_schema(:movie)
      assert is_map(schema)

      # Check required fields
      assert schema.title.type == :string
      assert schema.title.required == true
      assert schema.year.type == :integer
      assert schema.year.required == true

      # Check optional fields
      assert schema.runtime.type == :integer
      assert schema.runtime.required == false
    end

    test "returns metadata schema for episode type" do
      assert {:ok, schema} = TypeRegistry.metadata_schema(:episode)

      assert schema.title.required == true
      assert schema.season_number.type == :integer
      assert schema.season_number.required == true
      assert schema.episode_number.type == :integer
      assert schema.episode_number.required == true
    end

    test "returns empty schema for types without metadata" do
      # If there's a type without metadata defined, it should return empty map
      assert {:ok, schema} = TypeRegistry.metadata_schema(:library)
      assert is_map(schema)
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_type} = TypeRegistry.metadata_schema(:invalid_type)
    end

    test "handles array field types correctly" do
      assert {:ok, schema} = TypeRegistry.metadata_schema(:movie)
      assert schema.genres.type == :array
      assert schema.genres.items == :string
    end
  end

  describe "list_types/0" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns list of all registered types" do
      types = TypeRegistry.list_types()
      assert is_list(types)
      assert :movie in types
      assert :tv_show in types
      assert :season in types
      assert :episode in types
      assert :library in types
      assert :artist in types
      assert :album in types
      assert :track in types
    end
  end

  describe "list_playable_types/0" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns only playable types" do
      playable_types = TypeRegistry.list_playable_types()
      assert is_list(playable_types)

      # Should include playable types
      assert :movie in playable_types
      assert :episode in playable_types
      assert :track in playable_types
      assert :book in playable_types
      assert :scene in playable_types
      assert :podcast_episode in playable_types

      # Should not include container types
      refute :library in playable_types
      refute :tv_show in playable_types
      refute :season in playable_types
      refute :artist in playable_types
      refute :album in playable_types
    end
  end

  describe "list_container_types/0" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns only container types" do
      container_types = TypeRegistry.list_container_types()
      assert is_list(container_types)

      # Should include container types
      assert :library in container_types
      assert :tv_show in container_types
      assert :season in container_types
      assert :artist in container_types
      assert :album in container_types
      assert :studio in container_types
      assert :podcast in container_types

      # Should not include playable leaf types
      refute :movie in container_types
      refute :episode in container_types
      refute :track in container_types
    end
  end

  describe "list_root_types/0" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns only root types" do
      root_types = TypeRegistry.list_root_types()
      assert is_list(root_types)
      assert :library in root_types

      # Only library should be root in our config
      refute :movie in root_types
      refute :tv_show in root_types
    end
  end

  describe "playable?/1" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns true for playable types" do
      assert TypeRegistry.playable?(:movie) == true
      assert TypeRegistry.playable?(:episode) == true
      assert TypeRegistry.playable?(:track) == true
    end

    test "returns false for non-playable types" do
      assert TypeRegistry.playable?(:library) == false
      assert TypeRegistry.playable?(:tv_show) == false
      assert TypeRegistry.playable?(:season) == false
    end

    test "returns false for unknown types" do
      assert TypeRegistry.playable?(:invalid_type) == false
    end
  end

  describe "container?/1" do
    setup do
      {:ok, _pid} = TypeRegistry.start_link()
      :ok
    end

    test "returns true for container types" do
      assert TypeRegistry.container?(:library) == true
      assert TypeRegistry.container?(:tv_show) == true
      assert TypeRegistry.container?(:season) == true
      assert TypeRegistry.container?(:artist) == true
    end

    test "returns false for non-container types" do
      assert TypeRegistry.container?(:movie) == false
      assert TypeRegistry.container?(:episode) == false
      assert TypeRegistry.container?(:track) == false
    end

    test "returns false for unknown types" do
      assert TypeRegistry.container?(:invalid_type) == false
    end
  end
end
