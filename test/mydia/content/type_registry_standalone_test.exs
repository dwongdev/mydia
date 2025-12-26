defmodule Mydia.Content.TypeRegistryStandaloneTest do
  @moduledoc """
  Standalone test for TypeRegistry that doesn't require the full application context.
  This test can be run independently to verify the module works correctly.
  """
  use ExUnit.Case, async: false

  alias Mydia.Content.TypeRegistry

  # Start a new registry for each test
  setup do
    # Generate a unique name for this test's registry
    registry_name = :"TypeRegistry_#{:erlang.unique_integer([:positive])}"

    # Stop any existing registry with the default name
    if Process.whereis(TypeRegistry) do
      try do
        Agent.stop(TypeRegistry, :normal, 100)
      catch
        :exit, _ -> :ok
      end

      # Wait for cleanup
      :timer.sleep(50)
    end

    # Start registry with unique name
    {:ok, pid} = TypeRegistry.start_link(name: registry_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Agent.stop(pid, :normal, 100)
      end
    end)

    %{registry: registry_name, pid: pid}
  end

  describe "basic functionality" do
    test "module loads and config is valid", %{registry: _registry} do
      # If we got here, the registry started successfully
      assert true
    end

    test "can retrieve type definitions", %{registry: _registry} do
      assert {:ok, movie_def} = TypeRegistry.get_type(:movie)
      assert movie_def.is_playable == true
      assert movie_def.is_container == false
      assert movie_def.parent_types == [:library]
    end

    test "validates parent-child relationships", %{registry: _registry} do
      # Valid relationships
      assert TypeRegistry.valid_child?(:library, :movie) == true
      assert TypeRegistry.valid_child?(:tv_show, :season) == true
      assert TypeRegistry.valid_child?(:season, :episode) == true

      # Invalid relationships
      assert TypeRegistry.valid_child?(:movie, :season) == false
      assert TypeRegistry.valid_child?(:episode, :tv_show) == false
    end

    test "returns metadata schema", %{registry: _registry} do
      assert {:ok, schema} = TypeRegistry.metadata_schema(:movie)
      assert schema.title.type == :string
      assert schema.title.required == true
      assert schema.year.type == :integer
      assert schema.year.required == true
    end

    test "lists content types correctly", %{registry: _registry} do
      playable = TypeRegistry.list_playable_types()
      assert :movie in playable
      assert :episode in playable
      refute :tv_show in playable

      containers = TypeRegistry.list_container_types()
      assert :library in containers
      assert :tv_show in containers
      refute :movie in containers
    end

    test "type predicate functions work", %{registry: _registry} do
      assert TypeRegistry.playable?(:movie) == true
      assert TypeRegistry.playable?(:tv_show) == false

      assert TypeRegistry.container?(:tv_show) == true
      assert TypeRegistry.container?(:movie) == false
    end
  end
end
