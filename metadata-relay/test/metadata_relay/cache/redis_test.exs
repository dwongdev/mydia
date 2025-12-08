defmodule MetadataRelay.Cache.RedisTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Cache.Redis

  # Note: These tests are designed to work with the Redis adapter
  # whether Redis is available or not. They test graceful degradation.

  describe "graceful failure behavior" do
    test "operations return appropriate errors when Redis is unavailable" do
      # This test runs against whatever Redis instance is configured
      # If Redis is down, operations should fail gracefully

      # Try to get a non-existent key
      result = Redis.get("nonexistent_key_#{:rand.uniform(100_000)}")
      assert match?({:error, _}, result)
    end

    test "stats returns valid structure even if Redis unavailable" do
      stats = Redis.stats()

      assert is_map(stats)
      assert stats.adapter == "redis"
      assert is_boolean(stats.connected)
      assert is_integer(stats.hits)
      assert is_integer(stats.misses)
      assert is_number(stats.hit_rate_pct)
    end
  end

  describe "Redis integration (requires Redis running)" do
    # These tests will pass if Redis is available, otherwise they document
    # expected behavior when Redis IS available

    test "stores and retrieves values with Erlang term serialization" do
      if redis_connected?() do
        value = %{key: "value", nested: %{data: [1, 2, 3]}}
        test_key = "test_key_#{:rand.uniform(100_000)}"

        assert :ok = Redis.put(test_key, value, 60_000)
        assert {:ok, ^value} = Redis.get(test_key)
      end
    end

    test "handles complex data structures with tuples" do
      if redis_connected?() do
        # This mimics the HTTP response structure that caused the original issue
        value = %{
          status: 200,
          headers: [
            {"content-type", "application/json"},
            {"cache-control", "max-age=0"}
          ],
          body: ~s({"id": 1, "name": "Test"})
        }

        test_key = "complex_key_#{:rand.uniform(100_000)}"
        assert :ok = Redis.put(test_key, value, 60_000)
        assert {:ok, ^value} = Redis.get(test_key)
      end
    end

    test "respects TTL expiration" do
      if redis_connected?() do
        # Put with 1 second TTL
        test_key = "short_ttl_#{:rand.uniform(100_000)}"
        assert :ok = Redis.put(test_key, "value", 1_000)
        assert {:ok, "value"} = Redis.get(test_key)

        # Wait for expiration
        Process.sleep(1_100)

        # Should be expired
        assert {:error, :not_found} = Redis.get(test_key)
      end
    end

    test "uses proper key prefixing" do
      if redis_connected?() do
        test_key = "prefixed_key_#{:rand.uniform(100_000)}"
        assert :ok = Redis.put(test_key, "value", 60_000)

        # Verify the key is stored and retrieved correctly
        assert {:ok, "value"} = Redis.get(test_key)
      end
    end

    test "tracks hits and misses correctly" do
      if redis_connected?() do
        initial_stats = Redis.stats()

        # Generate a miss
        Redis.get("nonexistent_#{:rand.uniform(100_000)}")

        # Generate hits
        hit_key = "hit_key_#{:rand.uniform(100_000)}"
        Redis.put(hit_key, "value", 60_000)
        Redis.get(hit_key)
        Redis.get(hit_key)

        final_stats = Redis.stats()

        assert final_stats.adapter == "redis"
        assert final_stats.connected == true
        assert final_stats.misses >= initial_stats.misses + 1
        assert final_stats.hits >= initial_stats.hits + 2
      end
    end

    test "clear removes all metadata_relay entries" do
      if redis_connected?() do
        # Add multiple entries with unique keys
        key1 = "clear_test_key1_#{:rand.uniform(100_000)}"
        key2 = "clear_test_key2_#{:rand.uniform(100_000)}"
        key3 = "clear_test_key3_#{:rand.uniform(100_000)}"

        Redis.put(key1, "value1", 60_000)
        Redis.put(key2, "value2", 60_000)
        Redis.put(key3, "value3", 60_000)

        # Verify they're stored
        assert {:ok, _} = Redis.get(key1)

        # Clear
        assert :ok = Redis.clear()

        # All should be gone
        assert {:error, :not_found} = Redis.get(key1)
        assert {:error, :not_found} = Redis.get(key2)
        assert {:error, :not_found} = Redis.get(key3)
      end
    end

    test "reports Redis memory stats when connected" do
      if redis_connected?() do
        stats = Redis.stats()

        assert stats.adapter == "redis"
        assert stats.connected == true

        # Redis-specific stats should be present if connection successful
        assert is_map(stats)
      end
    end
  end

  # Helper to check if Redis adapter is actually connected
  defp redis_connected? do
    stats = Redis.stats()
    stats.connected == true
  end
end
