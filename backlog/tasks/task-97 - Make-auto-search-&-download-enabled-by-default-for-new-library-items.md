---
id: task-97
title: Make auto search & download enabled by default for new library items
status: To Do
assignee: []
created_date: '2025-11-06 04:20'
labels:
  - automation
  - ui
  - downloads
  - configuration
  - ux-improvement
dependencies:
  - task-31.2
  - task-22.10.7
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When users add movies or TV shows to their library, automatically enable monitoring and auto search & download by default, rather than requiring manual button clicks after adding.

## Background

Currently the workflow requires multiple steps:
1. User adds item to library
2. User must manually click "Auto Search & Download" button on media detail page
3. Or user must check "Download immediately" option (task-31.2)

This creates friction and users might forget to enable auto download for items they add.

## Goal

Make the default behavior more automatic and user-friendly by:
- Enabling monitoring by default when adding items to library
- Optionally triggering auto search & download immediately upon adding
- Making this behavior configurable via settings

## Scope

**Configuration Options:**
- Add setting: `auto_search_on_add` (boolean, default: true)
  - When true, automatically search & download when adding to library
  - When false, require manual trigger (current behavior)
- Add setting: `monitor_by_default` (boolean, default: true)
  - When true, new items are monitored automatically
  - When false, require manual monitoring enable

**Implementation Areas:**
1. **Add to Library workflow** (`lib/mydia_web/live/search_live/index.ex`)
   - Check configuration settings
   - Auto-enable monitoring if configured
   - Auto-queue search job if configured
   - Show appropriate feedback messages

2. **Settings UI** (admin or user settings page)
   - Add toggles for both settings
   - Clear descriptions of behavior
   - Save to configuration system

3. **Search Results UI**
   - Update "Add to Library" flow to respect settings
   - Still allow override checkbox if user wants different behavior for specific item
   - Show indication that auto-search will trigger

**User Experience:**
- Default behavior: Add item → automatically monitored + search starts
- User feedback: "Added {title} to library. Searching for releases..."
- Settings allow users to opt-out if they prefer manual control
- Individual override still available in UI

**Related:**
- Builds on task-31.2 (download immediately option)
- Uses existing auto search infrastructure from task-22.10.x
- Integrates with monitoring system

## Technical Considerations

- Check that download clients are configured before auto-triggering
- Handle quality profile prerequisites
- Queue appropriate job type (MovieSearch vs TVShowSearch)
- Respect existing monitoring preferences if item already exists
- Provide clear feedback about what's happening automatically
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Configuration setting 'auto_search_on_add' controls automatic search triggering
- [ ] #2 Configuration setting 'monitor_by_default' controls default monitoring state
- [ ] #3 Settings UI allows users to configure both options with clear descriptions
- [ ] #4 Adding movie to library automatically triggers search if configured
- [ ] #5 Adding TV show to library automatically triggers search if configured
- [ ] #6 User sees clear feedback when auto-search is triggered automatically
- [ ] #7 Manual override still available via checkbox in add-to-library form
- [ ] #8 Prerequisites checked before auto-triggering (download clients, quality profile)
- [ ] #9 Appropriate job queued based on media type (MovieSearch/TVShowSearch)
- [ ] #10 Settings respected across all add-to-library entry points (search, discovery, etc)
- [ ] #11 Documentation updated to explain default behavior and settings
<!-- AC:END -->
