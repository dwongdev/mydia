---
id: task-114.3
title: Add REMUX quality tier support
status: Done
assignee:
  - assistant
created_date: '2025-11-08 01:00'
updated_date: '2025-11-08 01:19'
labels:
  - enhancement
  - quality
dependencies: []
parent_task_id: task-114
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add support for REMUX quality tier, which represents lossless rips from Blu-ray with original video/audio streams. REMUX is a premium quality tier emphasized by TRaSH Guides.

## Changes Needed

1. **Update QualityParser** (`lib/mydia/indexers/quality_parser.ex`)
   - Add REMUX to `@sources` patterns (line 53-67):
     ```elixir
     @sources [
       {"REMUX", ~r/remux/i},  # Add as highest priority
       {"BluRay", ~r/blu[\-\s]?ray|bluray|bdrip|brrip|bd(?:$|[\.\s])/i},
       # ... rest
     ]
     ```
   - Update `source_score/1` to give REMUX highest score (500 points)

2. **Update DefaultQualityProfiles** (`lib/mydia/settings/default_quality_profiles.ex`)
   - Add new profile: "Remux-1080p" (20-40GB, lossless 1080p)
   - Add new profile: "Remux-2160p" (40-100GB, lossless 4K)
   - Update existing profiles to include/exclude REMUX as appropriate

3. **Update quality scoring** (`lib/mydia/indexers/quality_parser.ex:314-325`)
   ```elixir
   defp source_score("REMUX"), do: 500
   defp source_score("BluRay"), do: 450
   defp source_score("WEB-DL"), do: 400
   # ... rest
   ```

4. **Update FileParser** (`lib/mydia/library/file_parser.ex`)
   - Add REMUX to sources list (line 39)
   - Ensure proper detection in filename parsing

## Testing

- Test REMUX detection in release names
- Test quality scoring prioritizes REMUX correctly
- Test new quality profiles work as expected
- Verify upgrade logic prefers REMUX over BluRay
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

Add REMUX as a premium quality tier in the quality parsing and scoring system.

### Changes needed:

1. **Update QualityParser** (`lib/mydia/indexers/quality_parser.ex`)
   - Add REMUX to @sources patterns (line 54) - highest priority
   - Update source_score/1 to give REMUX 500 points (highest score)

2. **Update FileParser** (`lib/mydia/library/file_parser.ex`)
   - Add REMUX to @sources list (line 39)

3. **Update DefaultQualityProfiles** (`lib/mydia/settings/default_quality_profiles.ex`)
   - Add "Remux-1080p" profile
   - Add "Remux-2160p" profile
   - Update existing profiles to include/exclude REMUX appropriately

### Testing:
- Test REMUX detection in various release names
- Verify quality scoring prioritizes REMUX over BluRay
- Check new quality profiles are available
- Run test suite to ensure no regressions
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation completed

### Changes made:

1. **QualityParser** (`lib/mydia/indexers/quality_parser.ex`)
   - Added REMUX to @sources patterns as highest priority
   - Added source_score/1 function for REMUX (500 points - highest score)

2. **FileParser** (`lib/mydia/library/file_parser.ex`)
   - Added REMUX to @sources list as highest priority

3. **DefaultQualityProfiles** (`lib/mydia/settings/default_quality_profiles.ex`)
   - Added "Remux-1080p" profile (20-40GB)
   - Added "Remux-2160p" profile (40-100GB)
   - Updated "Full HD" profile to prefer REMUX sources
   - Updated "4K/UHD" profile to prefer REMUX sources

### Testing:
- All QualityParser tests pass (55 tests)
- All FileParser tests pass (51 tests)
- REMUX now has the highest source quality score (500 points)
- New quality profiles are available for selection
<!-- SECTION:NOTES:END -->
