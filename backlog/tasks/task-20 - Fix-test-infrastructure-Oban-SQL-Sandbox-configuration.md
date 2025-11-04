---
id: task-20
title: 'Fix test infrastructure: Oban/SQL Sandbox configuration'
status: Done
assignee: []
created_date: '2025-11-04 03:28'
updated_date: '2025-11-04 03:34'
labels:
  - testing
  - infrastructure
  - oban
  - bug
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Tests cannot run due to a pool configuration conflict between Oban and Ecto.Adapters.SQL.Sandbox. The error occurs in test_helper.exs when trying to set sandbox mode:

```
** (RuntimeError) cannot invoke sandbox operation with pool DBConnection.ConnectionPool.
To use the SQL Sandbox, configure your repository pool as:

    pool: Ecto.Adapters.SQL.Sandbox
```

The issue is that Oban starts with DBConnection.ConnectionPool in test environment, conflicting with the SQL Sandbox requirement. While config/test.exs has `config :mydia, Oban, testing: :manual`, this doesn't fully prevent the pool conflict.

Need to properly configure the test environment so that:
1. Ecto.Adapters.SQL.Sandbox can be used for test isolation
2. Oban doesn't interfere with test database connections
3. Tests can run successfully with `mix test`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 mix test runs without SQL Sandbox errors
- [x] #2 Oban properly configured for test environment
- [x] #3 Test support files load without warnings
- [x] #4 All existing tests pass (or failing tests are documented)
- [x] #5 Documentation added for test setup if needed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Summary

Fixed the Oban/SQL Sandbox pool conflict by properly configuring Oban to not start in test environment.

## Changes Made

### 1. Updated config/test.exs
Added `engine: false` to completely disable Oban's engine in test mode:
```elixir
config :mydia, Oban,
  testing: :manual,
  engine: false,
  queues: false,
  plugins: false
```

### 2. Updated lib/mydia/application.ex
Modified `oban_children/0` to check for both `:testing == :manual` and `:queues == false`:
```elixir
defp oban_children do
  oban_config = Application.get_env(:mydia, Oban, [])
  
  # Skip Oban if testing is manual or queues are disabled
  if Keyword.get(oban_config, :testing) == :manual or
       Keyword.get(oban_config, :queues) == false do
    []
  else
    [{Oban, oban_config}]
  end
end
```

## Root Cause

The issue was that Oban.Engines.Lite was attempting to use DBConnection.ConnectionPool even in test mode, which conflicted with Ecto.Adapters.SQL.Sandbox's requirement. Setting `engine: false` in test config completely disables Oban's engine initialization.

## Testing

Tests now run successfully without SQL Sandbox errors:
- `./dev test` completes with 18 tests, 1 unrelated failure (page content assertion)
- No SQL Sandbox pool errors
- Test helper loads without warnings
<!-- SECTION:NOTES:END -->
