defmodule MetadataRelay.Relay.ConnectionRegistryTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Relay.ConnectionRegistry

  setup do
    # ETS table is created by application.ex on startup
    # Clear any existing entries for a fresh state each test
    for {instance_id, _pid, _metadata, _registered_at} <- ConnectionRegistry.list_online() do
      ConnectionRegistry.unregister(instance_id)
    end

    :ok
  end

  describe "register/3 and lookup/1" do
    test "returns :not_found for unregistered instances" do
      assert :not_found = ConnectionRegistry.lookup("nonexistent")
    end

    test "registers and looks up instances" do
      pid = self()
      metadata = %{connected_at: DateTime.utc_now()}

      assert :ok = ConnectionRegistry.register("instance-123", pid, metadata)
      assert {:ok, ^pid, ^metadata} = ConnectionRegistry.lookup("instance-123")
    end

    test "register overwrites existing entries for same instance_id" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = ConnectionRegistry.register("instance-123", pid1, %{version: 1})
      assert {:ok, ^pid1, %{version: 1}} = ConnectionRegistry.lookup("instance-123")

      assert :ok = ConnectionRegistry.register("instance-123", pid2, %{version: 2})
      assert {:ok, ^pid2, %{version: 2}} = ConnectionRegistry.lookup("instance-123")

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end

    test "stores multiple independent instances" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = ConnectionRegistry.register("instance-1", pid1, %{})
      assert :ok = ConnectionRegistry.register("instance-2", pid2, %{})
      assert :ok = ConnectionRegistry.register("instance-3", pid3, %{})

      assert {:ok, ^pid1, _} = ConnectionRegistry.lookup("instance-1")
      assert {:ok, ^pid2, _} = ConnectionRegistry.lookup("instance-2")
      assert {:ok, ^pid3, _} = ConnectionRegistry.lookup("instance-3")

      # Cleanup
      Enum.each([pid1, pid2, pid3], &Process.exit(&1, :kill))
    end
  end

  describe "online?/1" do
    test "returns false for unregistered instances" do
      refute ConnectionRegistry.online?("nonexistent")
    end

    test "returns true for registered instances" do
      assert :ok = ConnectionRegistry.register("instance-123", self(), %{})
      assert ConnectionRegistry.online?("instance-123")
    end
  end

  describe "unregister/1" do
    test "removes registered instances" do
      assert :ok = ConnectionRegistry.register("instance-123", self(), %{})
      assert {:ok, _, _} = ConnectionRegistry.lookup("instance-123")

      assert :ok = ConnectionRegistry.unregister("instance-123")
      assert :not_found = ConnectionRegistry.lookup("instance-123")
    end

    test "unregistering non-existent instance is a no-op" do
      assert :ok = ConnectionRegistry.unregister("nonexistent")
    end
  end

  describe "list_online/0" do
    test "returns empty list when no instances registered" do
      assert [] = ConnectionRegistry.list_online()
    end

    test "returns all registered instances" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = ConnectionRegistry.register("instance-1", pid1, %{ip: "1.1.1.1"})
      assert :ok = ConnectionRegistry.register("instance-2", pid2, %{ip: "2.2.2.2"})

      online = ConnectionRegistry.list_online()
      assert length(online) == 2

      instance_ids = Enum.map(online, fn {id, _pid, _meta, _time} -> id end)
      assert "instance-1" in instance_ids
      assert "instance-2" in instance_ids

      # Cleanup
      Enum.each([pid1, pid2], &Process.exit(&1, :kill))
    end
  end

  describe "count/0" do
    test "returns 0 when no instances registered" do
      assert 0 = ConnectionRegistry.count()
    end

    test "returns correct count of registered instances" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = ConnectionRegistry.register("instance-1", pid1, %{})
      assert 1 = ConnectionRegistry.count()

      assert :ok = ConnectionRegistry.register("instance-2", pid2, %{})
      assert 2 = ConnectionRegistry.count()

      assert :ok = ConnectionRegistry.unregister("instance-1")
      assert 1 = ConnectionRegistry.count()

      # Cleanup
      Enum.each([pid1, pid2], &Process.exit(&1, :kill))
    end
  end

  describe "get_pid/1" do
    test "returns :not_found for unregistered instances" do
      assert :not_found = ConnectionRegistry.get_pid("nonexistent")
    end

    test "returns pid for registered instances" do
      pid = self()
      assert :ok = ConnectionRegistry.register("instance-123", pid, %{})
      assert {:ok, ^pid} = ConnectionRegistry.get_pid("instance-123")
    end
  end

  describe "concurrent access" do
    test "handles concurrent registrations and lookups" do
      # Spawn multiple processes to register and lookup concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            instance_id = "concurrent-#{i}"
            pid = spawn(fn -> Process.sleep(:infinity) end)
            ConnectionRegistry.register(instance_id, pid, %{index: i})
            ConnectionRegistry.lookup(instance_id)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)

      # All lookups should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, _pid, _metadata}, result)
             end)

      # Registry should have all entries
      assert ConnectionRegistry.count() >= 50
    end
  end
end
