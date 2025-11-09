---
id: task-133.1
title: Enforce authorization checks for privileged media operations
status: Done
assignee: []
created_date: '2025-11-09 04:58'
updated_date: '2025-11-09 05:06'
labels:
  - security
  - authorization
  - backend
dependencies: []
parent_task_id: task-133
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add authorization checks to prevent guest users from performing privileged actions like adding, editing, or deleting media items. 

While the UI/navigation has been fixed to hide these actions from guests, we need backend enforcement to ensure guests cannot bypass these restrictions by directly calling LiveView event handlers or API endpoints.

This ensures defense-in-depth security by enforcing authorization at multiple layers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Guest users cannot add new movies or TV series (LiveView and API)
- [x] #2 Guest users cannot edit existing media metadata or settings
- [x] #3 Guest users cannot delete media items from the library
- [x] #4 Guest users cannot trigger downloads or manage indexers/clients
- [x] #5 Guest users cannot modify system configuration
- [x] #6 Authorization checks return 403 Forbidden with appropriate error messages
- [x] #7 All privileged LiveView event handlers check user role before executing
- [x] #8 All privileged API endpoints enforce role-based authorization
- [x] #9 Tests verify authorization enforcement for guest and admin users
<!-- AC:END -->
