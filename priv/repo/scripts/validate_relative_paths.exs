#!/usr/bin/env elixir

# Validation script for relative path migration
#
# This script verifies that all media files have been properly migrated
# to use relative paths with library_path_id references.
#
# Run with: mix run priv/repo/scripts/validate_relative_paths.exs

alias Mydia.Repo
alias Mydia.Library.MediaFile
alias Mydia.Settings
import Ecto.Query

defmodule RelativePathValidator do
  @moduledoc """
  Validates the relative path migration for media files.
  """

  def run do
    IO.puts("\n=== Relative Path Migration Validation ===\n")

    checks = [
      &check_all_files_have_library_path_id/0,
      &check_all_files_have_relative_path/0,
      &check_orphaned_files/0,
      &check_path_reconstruction/0,
      &check_file_accessibility/0,
      &check_library_path_consistency/0
    ]

    results = Enum.map(checks, fn check -> check.() end)

    failures = Enum.count(results, fn {status, _} -> status == :fail end)
    warnings = Enum.count(results, fn {status, _} -> status == :warning end)

    IO.puts("\n=== Summary ===")
    IO.puts("Total checks: #{length(results)}")
    IO.puts("Passed: #{length(results) - failures - warnings}")
    IO.puts("Warnings: #{warnings}")
    IO.puts("Failed: #{failures}")

    if failures > 0 do
      IO.puts("\n❌ Validation FAILED")
      System.halt(1)
    else
      IO.puts("\n✅ Validation PASSED")
      System.halt(0)
    end
  end

  defp check_all_files_have_library_path_id do
    IO.puts("1. Checking that all media files have library_path_id...")

    count =
      Repo.aggregate(
        from(m in MediaFile, where: is_nil(m.library_path_id)),
        :count
      )

    if count == 0 do
      IO.puts("   ✅ All media files have library_path_id")
      {:pass, nil}
    else
      IO.puts("   ❌ Found #{count} media files without library_path_id")
      {:fail, "#{count} files missing library_path_id"}
    end
  end

  defp check_all_files_have_relative_path do
    IO.puts("2. Checking that all media files have relative_path...")

    count =
      Repo.aggregate(
        from(m in MediaFile, where: is_nil(m.relative_path)),
        :count
      )

    if count == 0 do
      IO.puts("   ✅ All media files have relative_path")
      {:pass, nil}
    else
      IO.puts("   ❌ Found #{count} media files without relative_path")
      {:fail, "#{count} files missing relative_path"}
    end
  end

  defp check_orphaned_files do
    IO.puts("3. Checking for orphaned files...")

    # Files with library_path_id that doesn't exist in library_paths table
    orphaned_query =
      from m in MediaFile,
        left_join: lp in assoc(m, :library_path),
        where: not is_nil(m.library_path_id) and is_nil(lp.id),
        select: m

    orphaned = Repo.all(orphaned_query)

    if Enum.empty?(orphaned) do
      IO.puts("   ✅ No orphaned files found")
      {:pass, nil}
    else
      IO.puts("   ⚠️  Found #{length(orphaned)} orphaned files")
      Enum.each(orphaned, fn file ->
        IO.puts("      - ID: #{file.id}, Path: #{file.path}")
      end)
      {:warning, "#{length(orphaned)} orphaned files"}
    end
  end

  defp check_path_reconstruction do
    IO.puts("4. Verifying path reconstruction accuracy...")

    # Sample 10 files and verify that absolute_path matches the old path field
    sample_files =
      Repo.all(
        from m in MediaFile,
          where: not is_nil(m.path) and not is_nil(m.relative_path),
          limit: 10,
          preload: :library_path
      )

    mismatches =
      Enum.filter(sample_files, fn file ->
        reconstructed = MediaFile.absolute_path(file)
        reconstructed != file.path
      end)

    if Enum.empty?(mismatches) do
      IO.puts("   ✅ Path reconstruction verified (sampled #{length(sample_files)} files)")
      {:pass, nil}
    else
      IO.puts("   ❌ Found #{length(mismatches)} files with path reconstruction mismatches")
      Enum.each(mismatches, fn file ->
        IO.puts("      - ID: #{file.id}")
        IO.puts("        Original: #{file.path}")
        IO.puts("        Reconstructed: #{MediaFile.absolute_path(file)}")
      end)
      {:fail, "#{length(mismatches)} path reconstruction mismatches"}
    end
  end

  defp check_file_accessibility do
    IO.puts("5. Checking file accessibility on disk...")

    # Sample 10 files and check if they exist on disk
    sample_files =
      Repo.all(
        from m in MediaFile,
          where: not is_nil(m.relative_path),
          limit: 10,
          preload: :library_path
      )

    {accessible, inaccessible} =
      Enum.split_with(sample_files, fn file ->
        case MediaFile.absolute_path(file) do
          nil -> false
          path -> File.exists?(path)
        end
      end)

    total_sampled = length(sample_files)
    accessible_count = length(accessible)

    if accessible_count == total_sampled do
      IO.puts("   ✅ All sampled files are accessible (#{accessible_count}/#{total_sampled})")
      {:pass, nil}
    else
      IO.puts("   ⚠️  Some files are not accessible (#{accessible_count}/#{total_sampled})")
      Enum.each(inaccessible, fn file ->
        path = MediaFile.absolute_path(file) || "nil"
        IO.puts("      - #{path}")
      end)
      {:warning, "#{length(inaccessible)} files not accessible on disk"}
    end
  end

  defp check_library_path_consistency do
    IO.puts("6. Checking library path consistency...")

    # Verify all library_path_ids reference existing library paths
    invalid_refs_query =
      from m in MediaFile,
        left_join: lp in assoc(m, :library_path),
        where: not is_nil(m.library_path_id) and is_nil(lp.id),
        select: count(m.id)

    invalid_count = Repo.one(invalid_refs_query)

    # Also check for any duplicate library path records
    library_paths = Settings.list_library_paths()
    paths_by_location = Enum.group_by(library_paths, & &1.path)
    duplicates = Enum.filter(paths_by_location, fn {_, paths} -> length(paths) > 1 end)

    issues = []

    issues = if invalid_count > 0 do
      IO.puts("   ❌ Found #{invalid_count} media files with invalid library_path_id references")
      issues ++ ["#{invalid_count} invalid library_path_id references"]
    else
      issues
    end

    issues = if not Enum.empty?(duplicates) do
      IO.puts("   ⚠️  Found #{length(duplicates)} duplicate library path records")
      Enum.each(duplicates, fn {path, paths} ->
        ids = Enum.map_join(paths, ", ", & &1.id)
        IO.puts("      - Path: #{path} (IDs: #{ids})")
      end)
      issues ++ ["#{length(duplicates)} duplicate library paths"]
    else
      issues
    end

    if Enum.empty?(issues) do
      IO.puts("   ✅ Library path consistency verified")
      {:pass, nil}
    else
      if invalid_count > 0 do
        {:fail, Enum.join(issues, "; ")}
      else
        {:warning, Enum.join(issues, "; ")}
      end
    end
  end
end

# Run the validation
RelativePathValidator.run()
