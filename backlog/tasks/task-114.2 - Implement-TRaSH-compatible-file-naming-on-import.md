---
id: task-114.2
title: Implement TRaSH-compatible file naming on import
status: To Do
assignee: []
created_date: '2025-11-08 01:00'
labels:
  - enhancement
  - file-naming
  - metadata
dependencies: []
parent_task_id: task-114
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add optional file renaming during import using TRaSH Guides naming conventions. This preserves non-recoverable metadata (quality source, edition, proper/repack status) and prevents download loops.

## TRaSH Naming Formats

**Movies:**
```
{Movie CleanTitle} ({Release Year}) [Edition]{[Custom Formats]}{[Quality Full]}{[Audio]}{[HDR]}{[Codec]}{-Release Group}
```
Example: `The Movie Title (2010) [IMAX][Bluray-1080p Proper][DTS 5.1][DV HDR10][x264]-RlsGrp`

**TV Shows:**
```
{Series Title} ({Year}) - S{season:00}E{episode:00} - {Episode Title} {[Quality Full]}{[Audio]}{[HDR]}{[Codec]}{-Release Group}
```
Example: `Show Title (2020) - S01E01 - Episode Title [WEB-1080p][DTS 5.1][HDR10][x264]-RlsGrp`

## Implementation

1. **Create FileNamer module** (`lib/mydia/library/file_namer.ex`)
   - `generate_movie_filename/3` - Generate movie filename
   - `generate_episode_filename/4` - Generate TV episode filename
   - `sanitize_title/1` - Clean title for filesystem
   - Support template-based naming with configurable patterns

2. **Update MediaImport job** (`lib/mydia/jobs/media_import.ex`)
   - Add rename option to `import_file/4` function
   - Generate new filename before copy/move/hardlink
   - Preserve file extension
   - Handle filename conflicts

3. **Add metadata preservation**
   - Include PROPER/REPACK tags from quality info
   - Include HDR format (DV, HDR10+, HDR10)
   - Include audio codec and channels (DTS 5.1, AAC Stereo)
   - Include video codec (x264, x265, HEVC)
   - Include release group

4. **Add configuration**
   - `rename_files_on_import`: boolean (default: false for safety)
   - `naming_pattern`: template string (default: TRaSH format)
   - Allow users to customize naming pattern
   - Add to admin config UI

5. **Expand quality detection**
   - Capture bit depth (8-bit, 10-bit, 12-bit)
   - Store audio channels in media_files table (needs migration)
   - Better edition detection (Directors Cut, Extended, etc.)

## Files to Modify

- `lib/mydia/jobs/media_import.ex` - Update import logic
- `lib/mydia/indexers/quality_parser.ex` - Add bit depth, edition parsing
- `lib/mydia/library/media_file.ex` - Add audio_channels field (migration needed)

## Testing

- Test movie renaming with various quality levels
- Test TV episode renaming
- Test multi-episode files
- Test special characters in titles
- Test filename conflict handling
- Verify metadata preservation in filename
<!-- SECTION:DESCRIPTION:END -->
