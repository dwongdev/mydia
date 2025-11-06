---
id: task-96
title: Add support for custom library types beyond movies/series/mixed
status: To Do
assignee: []
created_date: '2025-11-06 03:32'
labels:
  - enhancement
  - library
  - configuration
  - metadata
  - breaking-change
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Currently, library types are hardcoded to three options: movies, series, and mixed. This limitation prevents users from organizing other types of media content in their libraries.

## Current Limitations

1. Library types are hardcoded as Ecto.Enum with values: [:movies, :series, :mixed]
2. No way to add custom library types (e.g., music, audiobooks, documentaries, anime, concerts, sports)
3. Metadata matching logic assumes only movies or series
4. Download matching and organization logic tied to hardcoded types
5. UI/API endpoints only support the three predefined types

## Proposed Solution

Add support for user-defined custom library types that can be configured and used throughout the system.

### 1. Database Schema Changes

Replace the hardcoded Ecto.Enum with a flexible string field:
```elixir
# library_paths table
field :type, :string  # Instead of Ecto.Enum
field :category, :string  # Optional: movies, series, music, books, etc.
field :metadata_source, :string  # Which metadata provider to use
```

Add a new `library_types` table for custom type definitions:
```elixir
create table(:library_types) do
  add :name, :string, null: false  # e.g., "Anime", "Documentaries"
  add :slug, :string, null: false  # e.g., "anime", "documentaries"
  add :category, :string  # movies, series, music, books, other
  add :metadata_enabled, :boolean, default: true
  add :auto_organize, :boolean, default: true
  add :naming_pattern, :string  # Custom file naming pattern
  add :folder_structure, :string  # Custom folder organization
  add :default_quality_profile_id, references(:quality_profiles)
  timestamps()
end
```

### 2. Default Built-in Types

Provide default library types on installation:
- Movies (category: movies)
- TV Shows (category: series)
- Anime Movies (category: movies, specialized for anime)
- Anime Series (category: series, specialized for anime)
- Documentaries (category: movies/series)
- Music Videos (category: music)
- Concerts (category: music)
- Audiobooks (category: books)
- Podcasts (category: audio)
- Custom (category: other)

### 3. Metadata Provider Mapping

Allow library types to specify which metadata providers to use:
```yaml
library_types:
  - name: "Anime"
    category: series
    metadata_providers:
      - type: anilist
        priority: 1
      - type: tmdb
        priority: 2
```

### 4. Configuration Updates

Update Config.Schema to support custom types:
```elixir
embeds_many :library_types, LibraryType do
  field :name, :string
  field :slug, :string
  field :category, :string
  field :metadata_source, :string
end

embeds_many :library_paths, LibraryPath do
  field :path, :string
  field :library_type_slug, :string  # References library type
  field :monitored, :boolean
  # ...
end
```

### 5. UI Changes

- Add Library Types management page
- Allow creating/editing custom library types
- Update library path creation to select from available types
- Show type-specific options based on category

### 6. Download & Metadata Matching

- Update torrent matching logic to use library type category
- Support type-specific metadata providers
- Allow custom matching rules per library type

## Benefits

- **Flexibility**: Users can organize any type of media content
- **Extensibility**: Easy to add new types without code changes
- **Specialized**: Different metadata sources for different content types
- **Organization**: Better file/folder organization per media type
- **Future-proof**: Ready for new media types and use cases

## Migration Strategy

1. Create library_types table with default types
2. Migrate existing library_paths to use default type slugs
3. Keep backward compatibility with old enum-based config
4. Gradually deprecate hardcoded types over several releases
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Database schema supports custom library types with all necessary fields
- [ ] #2 Default library types are created on installation/migration
- [ ] #3 Users can create, edit, and delete custom library types via UI
- [ ] #4 Library paths can be assigned to any library type
- [ ] #5 Configuration system (YAML/env) supports custom library types
- [ ] #6 Metadata matching respects library type category and providers
- [ ] #7 Download matching works with custom library types
- [ ] #8 Migration path preserves existing movies/series/mixed libraries
- [ ] #9 Documentation updated with custom type examples
- [ ] #10 API endpoints support custom library type CRUD operations
<!-- AC:END -->
