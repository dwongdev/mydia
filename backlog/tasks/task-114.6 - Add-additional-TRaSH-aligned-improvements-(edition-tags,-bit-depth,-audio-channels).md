---
id: task-114.6
title: >-
  Add additional TRaSH-aligned improvements (edition tags, bit depth, audio
  channels)
status: To Do
assignee: []
created_date: '2025-11-08 01:00'
labels:
  - enhancement
  - metadata
  - quality
dependencies: []
parent_task_id: task-114
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement remaining TRaSH Guides improvements for comprehensive quality tracking and metadata preservation.

## Features to Add

1. **Edition Tag Support**
   - Detect edition types: Director's Cut, Extended, Theatrical, Unrated, IMAX
   - Parse from filename (`lib/mydia/library/file_parser.ex`)
   - Store in media_item metadata
   - Include in renamed filenames
   - Allow edition preference in quality profiles

2. **Bit Depth Capture**
   - Detect 8-bit, 10-bit, 12-bit from filename and FFprobe
   - Add `bit_depth` field to media_files table (migration needed)
   - Include in quality scoring (10-bit HEVC preferred over 8-bit)
   - Include in renamed filenames

3. **Audio Channels Storage**
   - Already extracted by FileAnalyzer, but not stored
   - Add `audio_channels` field to media_files table (migration needed)
   - Store channel count (1.0, 2.0, 5.1, 7.1, etc.)
   - Include in renamed filenames
   - Allow channel preference in quality profiles

4. **Release Group Management**
   - Create release_groups table for tier management
   - UI to manage preferred/blocked groups
   - Import tier lists from TRaSH-Guides
   - Integrate with custom formats scoring

5. **Language Profile Support**
   - Detect audio language tracks
   - Original language preference
   - Multi-audio track support
   - Language-specific quality profiles (French, German, etc.)

6. **Folder Structure Options**
   - Add TRaSH-style folder structure option
   - Intermediate "Movies" and "TV" folders
   - Configurable in settings
   - Migration tool for existing libraries

## Database Migrations Needed

- Add `bit_depth` to media_files
- Add `audio_channels` to media_files  
- Add `edition` to media_items
- Create `release_groups` table
- Create `language_profiles` table

## Configuration Options

- `edition_preference`: string (any, directors_cut, extended, theatrical, imax)
- `prefer_10bit`: boolean (default: false)
- `min_audio_channels`: string (any, stereo, 5.1, 7.1)
- `folder_structure_style`: string (flat, trash)

## Testing

- Test edition detection from filenames
- Test bit depth detection
- Test audio channels storage
- Test release group tier scoring
- Test language detection
- Test folder structure generation
<!-- SECTION:DESCRIPTION:END -->
