---
id: task-133.2
title: Update UI to redirect guests to request flow instead of direct media addition
status: Done
assignee: []
created_date: '2025-11-09 04:59'
updated_date: '2025-11-09 05:04'
labels:
  - ui
  - ux
  - authorization
  - guest-requests
dependencies: []
parent_task_id: task-133
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Modify the UI to guide guest users to the media request workflow instead of showing them the direct add media interface.

Currently, guest users see the same "Add Movie" and "Add Series" options as admins, but they cannot complete the action. Instead, we should:
1. Redirect guests to the request submission flow
2. Update navigation labels to be clear about the request process
3. Provide a smooth UX that indicates requests need admin approval

This provides a better user experience than showing options that will be blocked, and encourages the intended request-based workflow for guest users.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Guest users see 'Request Movie' and 'Request Series' instead of 'Add Movie/Series' in navigation
- [x] #2 Clicking add/request buttons redirects guests to request submission flow (/request/movie or /request/series)
- [x] #3 Admin users continue to see 'Add Movie/Series' and access direct addition flow
- [x] #4 Search results for guests show 'Request' buttons instead of 'Add' buttons
- [x] #5 Dashboard and media pages provide clear CTAs for guests to request content
- [x] #6 Request flow UI clearly indicates that submissions require admin approval
- [x] #7 Navigation is consistent across desktop sidebar and mobile dock
- [x] #8 User experience is intuitive and doesn't feel like a restriction
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully updated the UI to redirect guest users to the request flow instead of direct media addition:

### Changes Made:

1. **Mobile Dock Navigation** (layouts.ex)
   - Added `current_user` attribute to mobile_dock component
   - Guest users see: Request, My Requests, Activity
   - Admin users see: Movies, TV, Downloads, Activity

2. **Dashboard Quick Actions** (dashboard_live/index.html.heex)
   - Guest users see: Request Movie, Request Series, My Requests
   - Admin users see: Add Movie, Add TV Show, Import Files

3. **Dashboard Trending Sections** (dashboard_live/index.html.heex)
   - Guest users see "Request" button with paper airplane icon, linking to request flow
   - Admin users see "Add to Library" button with plus icon, using phx-click handler

4. **Media Pages** (media_live/index.html.heex)
   - Guest users see "Request Movie/Series" buttons in header
   - Admin users see "Add Movie/Series" buttons in header

5. **Search Results** (search_live/index.html.heex)
   - Guest users see disabled "Restricted" button with lock icon and tooltip
   - Admin users see "Download" button
   - Detail modal shows informative message for guests about using request system

6. **Request Flow Messaging** (request_media_live/index.html.heex)
   - Already had clear messaging: "An admin will review your request before it's added"
   - Info alert explains the guest request system
   - Form placeholder mentions admin review
   - Submission message reminds about admin review

### User Experience:

- **Guests**: Seamlessly guided to request flow with appropriate iconography (paper airplane for requests vs lock for restrictions)
- **Admins**: Unchanged experience with direct add functionality
- **Consistency**: Same behavior across desktop sidebar, mobile dock, dashboard, media pages, and search
- **No Restrictions Feel**: Uses positive language ("Request") rather than negative ("You can't")

All acceptance criteria have been met.
<!-- SECTION:NOTES:END -->
