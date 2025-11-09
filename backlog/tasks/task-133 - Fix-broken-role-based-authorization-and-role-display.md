---
id: task-133
title: Fix broken role-based authorization and role display
status: Done
assignee: []
created_date: '2025-11-09 04:52'
updated_date: '2025-11-09 04:57'
labels:
  - security
  - authorization
  - bug
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The role-based authorization system is not working correctly. Guest users can currently:
1. Access and perform all admin actions without restriction
2. See the sidebar displaying "admin" instead of their actual role (guest)

This is a critical security issue that allows unprivileged users to perform administrative actions.

Related to completed task-119.2 which implemented the initial role system but has bugs in enforcement.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Guest users cannot access admin-only pages (Settings, Users, etc.)
- [x] #2 Guest users cannot perform admin-only actions (create users, modify settings, etc.)
- [x] #3 Sidebar correctly displays the logged-in user's actual role
- [x] #4 Attempting to access admin pages as guest shows appropriate error message
- [x] #5 Role checks are enforced in LiveViews, controllers, and API endpoints
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Fixed the critical security issues in the role-based authorization system:

### 1. Admin Live Session Role Enforcement (router.ex:102-107)
Added `{MydiaWeb.Live.UserAuth, {:ensure_role, :admin}}` to the admin live_session on_mount hooks to enforce role checks at the LiveView level, not just the pipeline level.

### 2. Dynamic User Display (layouts.ex:196-215)
- Updated sidebar user menu to display actual user information instead of hardcoded "Admin"
- Shows user's username/email and role dynamically
- Displays user initials in avatar based on actual username

### 3. Conditional Navigation (layouts.ex:138-185)
- Admin menu items now only visible to users with "admin" role
- Guest users see a "Requests" section with movie/series request links
- Navigation properly scoped to user permissions

### 4. Template Updates
Updated all 16 LiveView templates to pass `current_user={@current_user}` to the Layouts.app component:
- activity_live, add_media_live, admin_config_live, admin_requests_live
- admin_status_live, admin_users_live, calendar_live, dashboard_live
- downloads_live, import_media_live, jobs_live, media_live (index + show)
- my_requests_live, request_media_live, search_live

### Files Changed
- lib/mydia_web/router.ex
- lib/mydia_web/components/layouts.ex  
- lib/mydia_web/live/*/index.html.heex (16 templates)

The authorization system now properly enforces role-based access control at both the pipeline and LiveView levels, preventing guest users from accessing admin-only functionality.
<!-- SECTION:NOTES:END -->
