---
id: task-114.4
title: Implement Custom Formats system with weighted scoring
status: To Do
assignee: []
created_date: '2025-11-08 01:00'
labels:
  - enhancement
  - quality
  - custom-formats
dependencies: []
parent_task_id: task-114
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement a Custom Formats system similar to Radarr/Sonarr that allows granular control over release preferences using weighted scoring. This enables users to prefer/avoid specific release attributes beyond basic quality.

## Custom Formats Overview

Custom Formats use regex patterns to match release attributes and assign scores:
- **Positive scores**: Preferred attributes (HDR formats, premium audio, trusted groups)
- **Negative scores**: Unwanted attributes (AV1 codec, upscaled content, 3D, bad groups)
- **Scoring range**: -10000 to +5000

## Implementation

1. **Create CustomFormat schema** (`lib/mydia/settings/custom_format.ex`)
   ```elixir
   schema "custom_formats" do
     field :name, :string
     field :category, :string  # audio, hdr, source, unwanted, release_group, etc.
     field :score, :integer
     field :regex_patterns, {:array, :string}
     field :enabled, :boolean, default: true
     field :description, :string
     
     many_to_many :quality_profiles, QualityProfile, 
       join_through: "quality_profile_custom_formats"
   end
   ```

2. **Create database migration**
   - Create `custom_formats` table
   - Create `quality_profile_custom_formats` join table
   - Add `custom_format_score` to quality_profiles

3. **Create CustomFormat matcher** (`lib/mydia/settings/custom_format_matcher.ex`)
   - `calculate_custom_format_score/2` - Calculate total CF score for release
   - `matching_formats/2` - Get all matching custom formats
   - `apply_format_regex/2` - Test release name against regex patterns

4. **Add default custom formats** (`lib/mydia/settings/default_custom_formats.ex`)
   Following TRaSH categories:
   - **HDR Formats**: DV (100), HDR10+ (75), HDR10 (50)
   - **Audio**: TrueHD Atmos (100), DTS-HD MA (75), DD+ (50), AAC (25)
   - **Release Groups**: Tier 01 (1800), Tier 02 (1600), Tier 03 (1400)
   - **Unwanted**: AV1 (-10000), 3D (-10000), Upscaled (-10000), BR-DISK (-10000)
   - **Streaming Services**: AMZN, NF, DSNP (for tagging, neutral score)

5. **Integrate with QualityMatcher** (`lib/mydia/settings/quality_matcher.ex`)
   - Add custom format scoring to `calculate_score/2`
   - Update `matches?/2` to check minimum custom format score
   - Add custom format info to match results

6. **Update QualityProfile**
   - Add `min_custom_format_score` field
   - Add `upgrade_on_custom_format_score` boolean
   - Associate custom formats with profiles

7. **Create UI for Custom Formats management**
   - List all custom formats
   - Enable/disable formats
   - Edit format scores
   - Import from JSON (for TRaSH-Guides sync)
   - Assign formats to quality profiles

## TRaSH Integration

- Support JSON import/export of custom formats
- Allow importing directly from TRaSH-Guides repository
- Provide default formats based on TRaSH recommendations

## Testing

- Test custom format matching against various releases
- Test scoring calculation with multiple formats
- Test unwanted format blocking
- Test upgrade logic with custom format scores
- Test format enable/disable
<!-- SECTION:DESCRIPTION:END -->
