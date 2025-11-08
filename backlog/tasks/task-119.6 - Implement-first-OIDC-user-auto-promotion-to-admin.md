---
id: task-119.6
title: Implement first OIDC user auto-promotion to admin
status: Done
assignee: []
created_date: '2025-11-08 22:10'
updated_date: '2025-11-08 22:18'
labels:
  - security
  - authentication
  - oidc
  - bug
dependencies: []
parent_task_id: '119'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When the first user logs in via OIDC and no admin user exists in the system, automatically promote them to admin role. This is critical for production deployments where local authentication is disabled.

## Problem

Currently, OIDC users are assigned roles based on OIDC provider claims (roles/groups), with a default of "user". In production deployments:
- Local auth is disabled
- No seed data creates default admin
- First OIDC user gets "user" role
- No admin exists to manage the system
- No way to elevate without database access

## Solution

Add logic in `Accounts.upsert_user_from_oidc/3` to:
1. Check if any admin user exists in the system
2. If no admin exists AND this is a new user (first time login)
3. Override the role from OIDC claims and set to "admin"
4. Log this action for audit purposes

## Implementation Details

- Add `Accounts.admin_exists?/0` helper function
- Modify `upsert_user_from_oidc/3` to check admin existence before creating new users
- Only apply auto-promotion for NEW users (not existing users logging in)
- Preserve OIDC role claims for subsequent users
- Add logging for security audit trail

## Security Considerations

- This only affects the FIRST user when database is empty
- Subsequent users follow normal OIDC role assignment
- Existing users are never auto-promoted
- Safe for multi-tenant scenarios (first user per tenant becomes admin)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Added admin_exists?/0 helper function to check for existing admin users
- [ ] #2 Modified upsert_user_from_oidc/3 to auto-promote first user when no admin exists
- [ ] #3 Auto-promotion only applies to NEW users (not existing users on subsequent logins)
- [ ] #4 Existing users always get their role from OIDC claims on re-login
- [ ] #5 Added logging when auto-promotion occurs for audit trail
- [ ] #6 All tests pass including 10 comprehensive test cases
- [ ] #7 Code is properly formatted and follows project conventions
<!-- AC:END -->
