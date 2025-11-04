---
id: task-21.1
title: Create download client adapter abstraction layer
status: Done
assignee: []
created_date: '2025-11-04 03:33'
updated_date: '2025-11-04 03:42'
labels:
  - downloads
  - architecture
  - backend
dependencies: []
parent_task_id: task-21
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement the core abstraction layer for download client integrations. This includes creating an Elixir behaviour that defines the common interface all download client adapters must implement, along with shared utilities for connection management, error handling, and response parsing.

The abstraction should support the operations needed across all download clients: adding torrents (file or magnet link), checking status, removing torrents, and retrieving download progress. Follow Phoenix/Ecto patterns for adapter design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Behaviour module defines callbacks for add_torrent, get_status, list_torrents, remove_torrent, and test_connection
- [x] #2 Common error types are defined and handled consistently
- [x] #3 Adapter registry system allows runtime selection of configured clients
- [x] #4 Shared HTTP client configuration using Req library
- [x] #5 Documentation includes examples of implementing a new adapter
- [x] #6 Unit tests verify behaviour contract
<!-- AC:END -->
