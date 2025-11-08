---
id: task-114
title: Implement TRaSH Guides alignment improvements
status: In Progress
assignee:
  - assistant
created_date: '2025-11-08 00:59'
updated_date: '2025-11-08 01:30'
labels:
  - enhancement
  - quality
  - file-handling
  - trash-guides
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Align mydia's media handling with TRaSH Guides best practices to improve quality management, file organization, and storage efficiency. This includes implementing hardlinks for efficient imports, TRaSH-compatible file naming, REMUX support, and a Custom Formats scoring system.

## Background

TRaSH Guides are industry-standard media server configuration guidelines developed in collaboration with Radarr/Sonarr teams. Key improvements needed:

1. **Hardlink support** - Instant moves, no duplicate storage
2. **TRaSH-compatible file naming** - Prevents download loops, preserves metadata
3. **REMUX quality tier** - Premium lossless quality support
4. **Custom Formats system** - Granular release scoring with weighted preferences
5. **Enhanced upgrade logic** - Better quality decision making

## TRaSH Naming Examples

Movies: `The Movie Title (2010) [IMAX][Bluray-1080p Proper][DV HDR10][DTS 5.1][x264]-RlsGrp`
TV: `Show Title (2020) - S01E01 - Episode Title [WEB-1080p][DTS 5.1][x264]-RlsGrp`

## References

- TRaSH Guides: https://trash-guides.info
- Analysis document in conversation context
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

Work through each subtask sequentially, building on previous features. The order is designed to minimize dependencies and allow incremental testing.

### Execution Order:

1. ✅ **Task 114.3 - REMUX quality tier** (COMPLETED)
   - Added REMUX to quality parser with highest score (500 points)
   - Created Remux-1080p and Remux-2160p quality profiles
   - All tests passing

2. **Task 114.1 - Hardlink support** (NEXT)
   - Update MediaImport to support hardlinks
   - Add filesystem detection logic
   - Add configuration options
   - Fallback to copy/move when needed

3. **Task 114.6 - Additional metadata fields**
   - Database migrations for bit_depth, audio_channels, edition, proper, repack
   - Update FileParser to extract new metadata
   - Update FileAnalyzer to capture from FFprobe
   - Store metadata in media_files table

4. **Task 114.2 - TRaSH-compatible file naming**
   - Create FileNamer module with template-based naming
   - Integrate with MediaImport before copy/move/hardlink
   - Add configuration for enable/disable renaming
   - Handle filename conflicts

5. **Task 114.4 - Custom Formats system**
   - Create database schema (custom_formats, join tables)
   - Implement CustomFormat matcher with regex scoring
   - Seed default TRaSH custom formats
   - Create UI for management
   - Integrate with QualityMatcher

6. **Task 114.5 - Enhanced upgrade logic**
   - Extend is_upgrade? to consider source quality
   - Add custom format score comparison
   - Implement PROPER/REPACK prioritization
   - Add upgrade history logging
   - Add configuration options

### Success Criteria:
- All subtasks completed and tested
- All existing tests continue to pass
- New features documented in commit messages
- Code follows project conventions
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Progress Update

### Completed Subtasks:
- ✅ Task 114.3: Add REMUX quality tier support (commit: 166f34b)
  - REMUX now recognized as highest quality source (500 points)
  - Two new quality profiles added: Remux-1080p and Remux-2160p
  - All tests passing

### Next Steps:
- Task 114.1: Implement hardlink support
- Task 114.6: Add additional metadata fields
- Task 114.2: TRaSH-compatible file naming
- Task 114.4: Custom Formats system
- Task 114.5: Enhanced upgrade logic
<!-- SECTION:NOTES:END -->
