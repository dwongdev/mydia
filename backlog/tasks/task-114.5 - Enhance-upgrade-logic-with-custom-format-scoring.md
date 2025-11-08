---
id: task-114.5
title: Enhance upgrade logic with custom format scoring
status: To Do
assignee: []
created_date: '2025-11-08 01:00'
labels:
  - enhancement
  - quality
  - upgrade-logic
dependencies: []
parent_task_id: task-114
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Improve upgrade decision logic to consider custom format scores in addition to quality level. This allows upgrades within the same quality tier when custom format score improves (e.g., upgrading from generic release to premium release group).

## Current Limitations

- Only considers resolution for upgrades (`lib/mydia/settings/quality_matcher.ex:71-113`)
- Doesn't account for source quality differences (WEB-DL vs BluRay at same resolution)
- No PROPER/REPACK prioritization
- No custom format score consideration

## Enhancements

1. **Update is_upgrade? function** (`lib/mydia/settings/quality_matcher.ex`)
   ```elixir
   def is_upgrade?(result, profile, current_media_file) do
     # Consider:
     # 1. Resolution upgrade
     # 2. Source quality upgrade (WEB-DL to BluRay, BluRay to REMUX)
     # 3. Custom format score improvement
     # 4. PROPER/REPACK over original
     # 5. Codec upgrade (x264 to x265 if preferred)
   end
   ```

2. **Add upgrade history tracking**
   - Log upgrade decisions to activity feed
   - Show why upgrade was triggered
   - Track rejected upgrades (didn't meet threshold)

3. **Add configuration options**
   - `upgrade_on_custom_format_score`: boolean (default: true)
   - `min_custom_format_score_improvement`: integer (default: 100)
   - `prefer_proper_repack`: boolean (default: true)
   - `upgrade_on_codec_change`: boolean (default: false)

4. **Implement upgrade scoring system**
   ```elixir
   defp calculate_upgrade_value(new_quality, current_quality, profile) do
     resolution_value = resolution_upgrade_value(new, current)
     source_value = source_upgrade_value(new, current)
     cf_value = custom_format_upgrade_value(new, current, profile)
     proper_value = proper_repack_value(new, current)
     
     total = resolution_value + source_value + cf_value + proper_value
     
     # Upgrade if total value exceeds threshold
     total >= profile.upgrade_threshold
   end
   ```

5. **Add PROPER/REPACK logic**
   - Always upgrade from non-PROPER to PROPER at same quality
   - Always upgrade from non-REPACK to REPACK at same quality
   - Store PROPER/REPACK status in media_files metadata

## Files to Modify

- `lib/mydia/settings/quality_matcher.ex` - Main upgrade logic
- `lib/mydia/settings/quality_profile.ex` - Add upgrade threshold config
- `lib/mydia/library/media_file.ex` - Store PROPER/REPACK status
- `lib/mydia/jobs/download_monitor.ex` - Use new upgrade logic

## Testing

- Test resolution-based upgrades still work
- Test source quality upgrades (WEB-DL to BluRay)
- Test custom format score upgrades
- Test PROPER/REPACK upgrades
- Test upgrade threshold configuration
- Test upgrade history logging
<!-- SECTION:DESCRIPTION:END -->
