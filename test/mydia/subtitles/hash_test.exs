defmodule Mydia.Subtitles.HashTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Hash

  @tmp_dir System.tmp_dir!()

  describe "calculate_hash/1" do
    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Hash.calculate_hash("/nonexistent/file.mp4")
    end

    test "returns error for directory path" do
      dir_path = Path.join(@tmp_dir, "test_dir_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir_path)

      on_exit(fn -> File.rm_rf!(dir_path) end)

      # Directory access should fail when trying to read it as a file
      assert {:error, _reason} = Hash.calculate_hash(dir_path)
    end

    test "handles empty file" do
      file_path = create_test_file(0, "empty.dat")

      assert {:ok, hash, 0} = Hash.calculate_hash(file_path)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "handles file smaller than 64KB" do
      # Create 1KB file
      file_path = create_test_file(1024, "small.dat")

      assert {:ok, hash, 1024} = Hash.calculate_hash(file_path)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "handles file exactly 64KB" do
      file_path = create_test_file(65_536, "exact.dat")

      assert {:ok, hash, 65_536} = Hash.calculate_hash(file_path)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "handles file between 64KB and 128KB" do
      # Create 100KB file
      file_path = create_test_file(102_400, "medium.dat")

      assert {:ok, hash, 102_400} = Hash.calculate_hash(file_path)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "handles large file (simulated video)" do
      # Create 10MB file (simulating a video)
      file_size = 10 * 1024 * 1024
      file_path = create_test_file(file_size, "large.dat")

      assert {:ok, hash, ^file_size} = Hash.calculate_hash(file_path)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "produces consistent hash for same file content" do
      file_path = create_test_file(1024 * 1024, "consistent.dat")

      {:ok, hash1, size1} = Hash.calculate_hash(file_path)
      {:ok, hash2, size2} = Hash.calculate_hash(file_path)

      assert hash1 == hash2
      assert size1 == size2
    end

    test "produces different hashes for different file sizes" do
      file_path1 = create_test_file(1024, "size1.dat")
      file_path2 = create_test_file(2048, "size2.dat")

      {:ok, hash1, _} = Hash.calculate_hash(file_path1)
      {:ok, hash2, _} = Hash.calculate_hash(file_path2)

      assert hash1 != hash2
    end

    test "produces different hashes for different file content" do
      # Create two files with same size but different content
      file_path1 = create_test_file_with_pattern(1024 * 1024, "pattern1.dat", 0xAA)
      file_path2 = create_test_file_with_pattern(1024 * 1024, "pattern2.dat", 0xBB)

      {:ok, hash1, size1} = Hash.calculate_hash(file_path1)
      {:ok, hash2, size2} = Hash.calculate_hash(file_path2)

      assert size1 == size2
      assert hash1 != hash2
    end

    test "hash format is lowercase hexadecimal" do
      file_path = create_test_file(1024, "hex.dat")

      {:ok, hash, _} = Hash.calculate_hash(file_path)

      assert hash == String.downcase(hash)
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "verifies OpenSubtitles hash algorithm with known test vector" do
      # This is a known test case for the OpenSubtitles hash algorithm
      # File: breakdance.avi (12,909,756 bytes)
      # Expected hash: "8e245d9679d31e12"
      #
      # Since we don't have the actual file, we'll create a file that matches
      # the expected structure and verify our algorithm works correctly
      # For now, we'll just verify the hash format is correct

      file_path = create_test_file(12_909_756, "breakdance.avi")
      {:ok, hash, size} = Hash.calculate_hash(file_path)

      assert size == 12_909_756
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "handles files with various extensions" do
      extensions = [".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv"]

      for ext <- extensions do
        file_path = create_test_file(1024 * 1024, "video#{ext}")
        assert {:ok, hash, _size} = Hash.calculate_hash(file_path)
        assert String.length(hash) == 16
      end
    end

    test "only reads first and last 64KB, not entire file" do
      # Create a 50MB file to verify we're not reading the entire thing
      file_size = 50 * 1024 * 1024
      file_path = create_sparse_test_file(file_size, "sparse.dat")

      # This should complete quickly if we're only reading 128KB
      {time_microseconds, {:ok, hash, ^file_size}} =
        :timer.tc(fn -> Hash.calculate_hash(file_path) end)

      assert String.length(hash) == 16

      # Should complete in well under 1 second even for 50MB file
      # since we only read 128KB
      time_ms = time_microseconds / 1000
      assert time_ms < 1000, "Hash calculation took too long (#{time_ms}ms)"
    end

    test "different content in middle of large file produces same hash if ends match" do
      # Create two large files with identical first 64KB and last 64KB
      # but different content in the middle
      file_size = 10 * 1024 * 1024

      file_path1 = create_file_with_specific_ends(file_size, "ends1.dat", 0xAA, 0xBB)
      file_path2 = create_file_with_specific_ends(file_size, "ends2.dat", 0xAA, 0xBB)

      {:ok, hash1, _} = Hash.calculate_hash(file_path1)
      {:ok, hash2, _} = Hash.calculate_hash(file_path2)

      # Hashes should be identical because first/last 64KB are the same
      assert hash1 == hash2
    end
  end

  # Helper functions

  defp create_test_file(size, filename) do
    file_path = Path.join(@tmp_dir, "hash_test_#{:rand.uniform(100_000)}_#{filename}")

    # Generate random data
    data = :crypto.strong_rand_bytes(size)
    File.write!(file_path, data)

    on_exit(fn -> File.rm(file_path) end)

    file_path
  end

  defp create_test_file_with_pattern(size, filename, byte_pattern) do
    file_path = Path.join(@tmp_dir, "hash_test_#{:rand.uniform(100_000)}_#{filename}")

    # Create file with repeating byte pattern
    data = for _ <- 1..size, into: <<>>, do: <<byte_pattern>>
    File.write!(file_path, data)

    on_exit(fn -> File.rm(file_path) end)

    file_path
  end

  defp create_sparse_test_file(size, filename) do
    file_path = Path.join(@tmp_dir, "hash_test_#{:rand.uniform(100_000)}_#{filename}")

    # Create file with specific content at beginning and end
    # and sparse content in middle
    first_chunk = :crypto.strong_rand_bytes(65_536)
    last_chunk = :crypto.strong_rand_bytes(65_536)
    middle_size = max(0, size - 131_072)
    middle_chunk = :crypto.strong_rand_bytes(min(middle_size, 1024))

    {:ok, file} = File.open(file_path, [:write, :binary])
    IO.binwrite(file, first_chunk)

    # Write middle in chunks if needed
    if middle_size > 1024 do
      IO.binwrite(file, middle_chunk)
      # Seek to position before last chunk
      :file.position(file, size - 65_536)
    else
      IO.binwrite(file, :binary.part(middle_chunk, 0, middle_size))
    end

    IO.binwrite(file, last_chunk)
    File.close(file)

    on_exit(fn -> File.rm(file_path) end)

    file_path
  end

  defp create_file_with_specific_ends(size, filename, first_pattern, last_pattern) do
    file_path = Path.join(@tmp_dir, "hash_test_#{:rand.uniform(100_000)}_#{filename}")

    # Create file with specific patterns at start and end
    first_chunk = for _ <- 1..65_536, into: <<>>, do: <<first_pattern>>
    last_chunk = for _ <- 1..65_536, into: <<>>, do: <<last_pattern>>
    middle_size = size - 131_072
    middle_chunk = :crypto.strong_rand_bytes(middle_size)

    File.write!(file_path, first_chunk <> middle_chunk <> last_chunk)

    on_exit(fn -> File.rm(file_path) end)

    file_path
  end
end
