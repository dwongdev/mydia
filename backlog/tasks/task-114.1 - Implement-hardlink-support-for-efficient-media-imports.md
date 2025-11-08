---
id: task-114.1
title: Implement hardlink support for efficient media imports
status: In Progress
assignee: []
created_date: '2025-11-08 01:00'
updated_date: '2025-11-08 01:31'
labels:
  - enhancement
  - file-handling
  - storage-efficiency
dependencies: []
parent_task_id: task-114
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add hardlink support to media import process to enable instant moves without duplicating files. Hardlinks allow the same file data to appear in multiple locations (download folder and library folder) without consuming additional disk space.

## Key Changes Needed

1. **Add hardlink function to MediaImport** (`lib/mydia/jobs/media_import.ex`)
   - Implement `File.ln/2` for same-filesystem operations
   - Add `same_filesystem?/2` helper to detect if source/dest are on same volume
   - Prioritize: hardlink > move > copy

2. **Add configuration options**
   - `use_hardlinks`: boolean (default: true)
   - `move_files`: boolean (default: false)
   - Add to download client settings or global settings

3. **Add validation and warnings**
   - Detect when download and library paths are on different filesystems
   - Warn user that hardlinks won't work (will fallback to copy)
   - Add to admin config UI

4. **Update copy_or_move_file logic** (line 522-550)
   ```elixir
   defp copy_or_move_file(source, dest, args) do
     cond do
       args["use_hardlinks"] == true && same_filesystem?(source, dest) ->
         File.ln(source, dest)
       
       args["move_files"] == true ->
         File.rename(source, dest)
       
       true ->
         File.cp(source, dest)
     end
   end
   
   defp same_filesystem?(path1, path2) do
     # Use stat to check if on same device
     %{device: dev1} = File.stat!(path1)
     %{device: dev2} = File.stat!(Path.dirname(path2))
     dev1 == dev2
   rescue
     _ -> false
   end
   ```

## Testing

- Test hardlink creation on same filesystem
- Test fallback to copy on different filesystems
- Verify file integrity after hardlink
- Test cleanup behavior (download client removal shouldn't affect library)
<!-- SECTION:DESCRIPTION:END -->
