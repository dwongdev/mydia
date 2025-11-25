defmodule Mydia.Settings do
  @moduledoc """
  The Settings context handles quality profiles and application configuration.

  ## Runtime Configuration

  The runtime configuration is loaded from multiple sources with precedence:
  1. **Environment variables** (highest priority) - Deployment-specific overrides
  2. **Database/UI settings** - Admin-managed configuration via ConfigSetting records
  3. **YAML configuration file** (config/config.yml) - File-based defaults
  4. **Schema defaults** (lowest priority) - Hard-coded defaults

  Each layer overrides the previous one, with environment variables having the
  final say. This allows admins to configure the application via the UI while
  still allowing deployment-specific overrides through environment variables.

  ### Database Configuration

  Configuration settings stored in the database use dot notation for keys:
  - `"server.port"` maps to the `:server` → `:port` config value
  - `"auth.local_enabled"` maps to `:auth` → `:local_enabled`

  Use `load_database_config/0` to retrieve all database settings as a nested map.

  Access configuration using `get_config/1` or `get_config/2`.

  ### Collection-Based Configuration Merge Pattern

  For collection-based configurations (download clients, indexers, library paths),
  this module merges database records with runtime configuration (from environment
  variables). Database records take precedence - runtime items are only included
  if they don't already exist in the database (matched by name or path).

  This pattern is implemented via the private `merge_with_runtime_config/4` helper
  and used by `list_download_client_configs/1`, `list_indexer_configs/1`, and
  `list_library_paths/1`.

  Note: `list_config_settings/0` is intentionally database-only as it's used by
  the config loader to build the configuration hierarchy.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo

  alias Mydia.Settings.{
    QualityProfile,
    ConfigSetting,
    DownloadClientConfig,
    IndexerConfig,
    LibraryPath,
    DefaultQualityProfiles,
    DefaultMetadataPreferences
  }

  @doc """
  Returns the list of quality profiles.

  ## Options
    - `:preload` - List of associations to preload
    - `:is_system` - Filter by is_system flag (true/false)
    - `:version` - Filter by version number
    - `:source_url` - Filter by source URL (exact match)
  """
  def list_quality_profiles(opts \\ []) do
    QualityProfile
    |> apply_quality_profile_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([q], asc: q.name)
    |> Repo.all()
  end

  @doc """
  Gets a single quality profile.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the quality profile does not exist.
  """
  def get_quality_profile!(id, opts \\ []) do
    QualityProfile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a quality profile by name.
  """
  def get_quality_profile_by_name(name, opts \\ []) do
    QualityProfile
    |> where([q], q.name == ^name)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a quality profile.
  """
  def create_quality_profile(attrs \\ %{}) do
    %QualityProfile{}
    |> QualityProfile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a quality profile.

  If quality_standards are changed, automatically triggers re-evaluation of all
  associated media files in the background to ensure scores reflect the new criteria.

  ## Options
    - `:skip_reevaluation` - Skip automatic re-evaluation (default: false)
  """
  def update_quality_profile(%QualityProfile{} = quality_profile, attrs, opts \\ []) do
    skip_reevaluation = Keyword.get(opts, :skip_reevaluation, false)

    changeset = QualityProfile.changeset(quality_profile, attrs)

    # Check if quality_standards are changing
    quality_standards_changed? =
      Ecto.Changeset.get_change(changeset, :quality_standards) != nil

    case Repo.update(changeset) do
      {:ok, updated_profile} = result ->
        # Trigger re-evaluation if quality_standards changed and not skipped
        if quality_standards_changed? and not skip_reevaluation do
          trigger_profile_reevaluation(updated_profile.id)
        end

        result

      error ->
        error
    end
  end

  @doc """
  Triggers background re-evaluation of all files associated with a quality profile.

  This is called automatically when a profile's quality_standards are updated.
  It spawns a background task to re-evaluate all associated files without blocking.

  ## Parameters
    - `profile_id` - ID of the profile to re-evaluate

  ## Returns
    - `:ok` - Re-evaluation task spawned successfully
  """
  def trigger_profile_reevaluation(profile_id) do
    require Logger

    Logger.info("Triggering background re-evaluation for quality profile",
      profile_id: profile_id
    )

    # Spawn a supervised task to re-evaluate files
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      alias Mydia.Settings.QualityProfileEngine

      case QualityProfileEngine.reevaluate_profile_files(profile_id) do
        {:ok, summary} ->
          Logger.info("Quality profile re-evaluation completed",
            profile_id: profile_id,
            processed: summary.processed,
            updated: summary.updated,
            errors: length(summary.errors)
          )

        {:error, reason} ->
          Logger.error("Quality profile re-evaluation failed",
            profile_id: profile_id,
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  @doc """
  Deletes a quality profile.

  Returns `{:error, :profile_in_use}` if the profile is assigned to any media items.
  """
  def delete_quality_profile(%QualityProfile{} = quality_profile) do
    # Check if profile is assigned to any media items
    if profile_in_use?(quality_profile.id) do
      {:error, :profile_in_use}
    else
      Repo.delete(quality_profile)
    end
  end

  @doc """
  Checks if a quality profile is assigned to any media items.
  """
  def profile_in_use?(profile_id) do
    alias Mydia.Media.MediaItem

    MediaItem
    |> where([m], m.quality_profile_id == ^profile_id)
    |> Repo.exists?()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking quality profile changes.
  """
  def change_quality_profile(%QualityProfile{} = quality_profile, attrs \\ %{}) do
    QualityProfile.changeset(quality_profile, attrs)
  end

  @doc """
  Ensures default quality profiles exist in the database.

  Creates default quality profiles if they don't already exist. This function
  is idempotent and safe to call multiple times - it will only create profiles
  that are missing.

  Default profiles include: Any, SD, HD-720p, HD-1080p, Full HD, and 4K/UHD.

  Returns `{:ok, created_count}` on success, where `created_count` is the number
  of profiles that were created. Returns `{:error, reason}` if the database is
  not available or there's an error creating profiles.

  ## Examples

      iex> ensure_default_quality_profiles()
      {:ok, 6}

      iex> ensure_default_quality_profiles()
      {:ok, 0}  # All profiles already exist
  """
  def ensure_default_quality_profiles do
    try do
      # Get existing profile names to avoid duplicates
      existing_names =
        QualityProfile
        |> select([q], q.name)
        |> Repo.all()
        |> MapSet.new()

      # Create missing default profiles
      created_count =
        DefaultQualityProfiles.defaults()
        |> Enum.reject(fn profile -> MapSet.member?(existing_names, profile.name) end)
        |> Enum.reduce(0, fn profile_attrs, count ->
          case create_quality_profile(profile_attrs) do
            {:ok, _profile} -> count + 1
            {:error, _changeset} -> count
          end
        end)

      {:ok, created_count}
    rescue
      # Database might not be available during initial setup
      DBConnection.ConnectionError -> {:error, :database_unavailable}
      # Catch query errors (e.g., table doesn't exist yet)
      Ecto.QueryError -> {:error, :database_unavailable}
      # Catch SQLite-specific errors
      Exqlite.Error -> {:error, :database_unavailable}
      # Catch Repo not started yet error
      RuntimeError -> {:error, :database_unavailable}
    end
  end

  @doc """
  Clones a quality profile with a new name.

  Creates a copy of the given profile with all settings preserved except:
  - New name (with " (Copy)" suffix if not provided)
  - New ID
  - is_system set to false
  - source_url set to nil
  - New timestamps

  ## Examples

      iex> clone_quality_profile(profile, "My Custom Profile")
      {:ok, %QualityProfile{name: "My Custom Profile"}}

      iex> clone_quality_profile(profile)
      {:ok, %QualityProfile{name: "HD-1080p (Copy)"}}
  """
  def clone_quality_profile(%QualityProfile{} = profile, new_name \\ nil) do
    name = new_name || "#{profile.name} (Copy)"

    attrs = %{
      name: name,
      upgrades_allowed: profile.upgrades_allowed,
      upgrade_until_quality: profile.upgrade_until_quality,
      qualities: profile.qualities,
      description: profile.description,
      is_system: false,
      version: 1,
      source_url: nil,
      quality_standards: profile.quality_standards,
      metadata_preferences: profile.metadata_preferences,
      customizations: nil
    }

    create_quality_profile(attrs)
  end

  @doc """
  Gets the default metadata preferences.

  Returns sensible default metadata preferences that can be used when
  creating new quality profiles.

  ## Examples

      iex> get_default_metadata_preferences()
      %{
        provider_priority: ["metadata_relay", "tvdb", "tmdb"],
        language: "en-US",
        ...
      }
  """
  def get_default_metadata_preferences do
    DefaultMetadataPreferences.default()
  end

  @doc """
  Gets metadata preferences with custom overrides merged with defaults.

  ## Examples

      iex> get_metadata_preferences_with_defaults(%{language: "fr-FR"})
      %{
        provider_priority: ["metadata_relay", "tvdb", "tmdb"],
        language: "fr-FR",
        ...
      }
  """
  def get_metadata_preferences_with_defaults(custom_prefs) when is_map(custom_prefs) do
    DefaultMetadataPreferences.with_defaults(custom_prefs)
  end

  @doc """
  Validates that all providers referenced in metadata preferences are available.

  Returns `{:ok, preferences}` if valid, or `{:error, missing_providers}`
  if some providers are not registered in the system.

  ## Examples

      iex> validate_metadata_preferences_providers(%{provider_priority: ["metadata_relay"]})
      {:ok, %{provider_priority: ["metadata_relay"]}}

      iex> validate_metadata_preferences_providers(%{provider_priority: ["invalid"]})
      {:error, ["invalid"]}
  """
  def validate_metadata_preferences_providers(prefs) when is_map(prefs) do
    DefaultMetadataPreferences.validate_providers(prefs)
  end

  @doc """
  Gets the effective metadata provider for a specific field.

  Looks up the provider for a field based on the profile's metadata preferences.
  If a field-specific override exists, uses that; otherwise uses the first
  provider from the priority list.

  ## Examples

      iex> prefs = %{
        provider_priority: ["metadata_relay", "tvdb"],
        field_providers: %{"title" => "tvdb"}
      }
      iex> get_field_provider(prefs, "title")
      "tvdb"

      iex> get_field_provider(prefs, "overview")
      "metadata_relay"
  """
  def get_field_provider(prefs, field) when is_map(prefs) and is_binary(field) do
    # Check for field-specific override
    case Map.get(prefs, :field_providers, %{}) do
      field_providers when is_map(field_providers) ->
        case Map.get(field_providers, field) do
          nil ->
            # No override, use first from priority list
            prefs
            |> Map.get(:provider_priority, [])
            |> List.first()

          provider ->
            provider
        end

      _ ->
        # Invalid field_providers, use first from priority list
        prefs
        |> Map.get(:provider_priority, [])
        |> List.first()
    end
  end

  @doc """
  Compares two quality profile versions and returns the differences.

  Returns a map with differences between the two profiles:
  - `:changed` - Map of fields that changed with {old_value, new_value}
  - `:added` - Map of fields added in profile2
  - `:removed` - Map of fields removed in profile2

  ## Examples

      iex> compare_quality_profile_versions(profile1, profile2)
      %{
        changed: %{qualities: {["720p"], ["1080p"]}, version: {1, 2}},
        added: %{quality_standards: %{...}},
        removed: %{}
      }
  """
  def compare_quality_profile_versions(%QualityProfile{} = profile1, %QualityProfile{} = profile2) do
    # Fields to compare (excluding id, timestamps, and associations)
    fields = [
      :name,
      :upgrades_allowed,
      :upgrade_until_quality,
      :qualities,
      :description,
      :is_system,
      :version,
      :source_url,
      :last_synced_at,
      :quality_standards,
      :metadata_preferences,
      :customizations
    ]

    changed =
      Enum.reduce(fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if val1 != val2 do
          Map.put(acc, field, {val1, val2})
        else
          acc
        end
      end)

    # For added/removed, focus on optional map fields
    optional_fields = [:quality_standards, :metadata_preferences, :customizations]

    added =
      Enum.reduce(optional_fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if is_nil(val1) and not is_nil(val2) do
          Map.put(acc, field, val2)
        else
          acc
        end
      end)

    removed =
      Enum.reduce(optional_fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if not is_nil(val1) and is_nil(val2) do
          Map.put(acc, field, val1)
        else
          acc
        end
      end)

    %{
      changed: changed,
      added: added,
      removed: removed
    }
  end

  @doc """
  Exports a quality profile to a shareable format (JSON or YAML).

  ## Options
    - `:format` - Output format, either `:json` or `:yaml` (default: `:json`)
    - `:pretty` - Pretty print the output (default: `true`)

  ## Returns
    - `{:ok, content}` - The exported profile as a string
    - `{:error, reason}` - If the export fails

  ## Examples

      iex> export_profile(profile, format: :json)
      {:ok, "{\"schema_version\": 1, \"name\": \"HD-1080p\", ...}"}

      iex> export_profile(profile, format: :yaml)
      {:ok, "schema_version: 1\\nname: HD-1080p\\n..."}
  """
  def export_profile(%QualityProfile{} = profile, opts \\ []) do
    format = Keyword.get(opts, :format, :json)
    pretty = Keyword.get(opts, :pretty, true)

    # Build export data structure with schema version
    export_data = %{
      schema_version: 1,
      name: profile.name,
      description: profile.description,
      upgrades_allowed: profile.upgrades_allowed,
      upgrade_until_quality: profile.upgrade_until_quality,
      qualities: profile.qualities,
      quality_standards: profile.quality_standards,
      metadata_preferences: profile.metadata_preferences,
      customizations: profile.customizations,
      version: profile.version,
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case format do
      :json ->
        encode_json(export_data, pretty)

      :yaml ->
        encode_yaml(export_data)

      _ ->
        {:error, "Unsupported format: #{format}. Use :json or :yaml"}
    end
  end

  @doc """
  Imports a quality profile from a file or URL.

  ## Parameters
    - `source` - Either a file path (string), URL (string starting with http/https), or raw content
    - `opts` - Import options

  ## Options
    - `:dry_run` - If true, returns preview without saving (default: `false`)
    - `:name` - Override the profile name from the import
    - `:source_url` - Explicitly set the source URL (auto-detected for URL imports)

  ## Returns
    - `{:ok, profile}` - Successfully imported profile (or preview if dry_run)
    - `{:ok, %{action: :skip, reason: reason}}` - Skipped import with reason
    - `{:error, reason}` - If the import fails

  ## Examples

      iex> import_profile("/path/to/profile.json")
      {:ok, %QualityProfile{}}

      iex> import_profile("https://example.com/profile.yaml")
      {:ok, %QualityProfile{}}

      iex> import_profile(content, dry_run: true)
      {:ok, %{action: :create, profile: %QualityProfile{}, conflicts: []}}
  """
  def import_profile(source, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, content} <- fetch_import_content(source, opts),
         {:ok, data} <- parse_import_content(content),
         {:ok, validated_data} <- validate_import_schema(data),
         {:ok, attrs} <- prepare_import_attrs(validated_data, source, opts),
         {:ok, result} <- perform_import(attrs, dry_run) do
      {:ok, result}
    end
  end

  # Private helper functions for export/import

  defp encode_json(data, true) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, "JSON encoding failed: #{inspect(error)}"}
    end
  end

  defp encode_json(data, false) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, "JSON encoding failed: #{inspect(error)}"}
    end
  end

  defp encode_yaml(data) do
    case Ymlr.document(data) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, error} -> {:error, "YAML encoding failed: #{inspect(error)}"}
    end
  end

  defp fetch_import_content(source, opts) when is_binary(source) do
    cond do
      # Check if it's a URL
      String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
        fetch_from_url(source, opts)

      # Check if it's a file path
      File.exists?(source) ->
        File.read(source)

      # Assume it's raw content
      true ->
        {:ok, source}
    end
  end

  defp fetch_import_content(_source, _opts) do
    {:error, "Invalid source: must be a file path, URL, or raw content string"}
  end

  defp fetch_from_url(url, _opts) do
    timeout = 30_000

    # Disable auto-decoding to get raw body
    case Req.get(url,
           connect_options: [timeout: timeout],
           receive_timeout: timeout,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "Failed to fetch from URL: HTTP #{status}"}

      {:error, error} ->
        {:error, "Failed to fetch from URL: #{inspect(error)}"}
    end
  end

  defp parse_import_content(content) when is_binary(content) do
    # Try JSON first
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, _json_error} ->
        # Try YAML if JSON fails
        case YamlElixir.read_from_string(content) do
          {:ok, data} ->
            {:ok, data}

          {:error, yaml_error} ->
            {:error, "Failed to parse content as JSON or YAML: #{inspect(yaml_error)}"}
        end
    end
  end

  defp validate_import_schema(%{"schema_version" => 1} = data) do
    # Schema version 1 - validate required fields
    required_fields = ["name", "qualities"]

    missing_fields =
      required_fields
      |> Enum.reject(&Map.has_key?(data, &1))

    if Enum.empty?(missing_fields) do
      {:ok, data}
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp validate_import_schema(%{"schema_version" => version}) do
    {:error,
     "Unsupported schema version: #{version}. This version only supports schema version 1. Please export the profile from a compatible version."}
  end

  defp validate_import_schema(_data) do
    {:error,
     "Invalid profile format: missing schema_version field. This may be a legacy format that is no longer supported. Please export the profile from a newer version."}
  end

  defp prepare_import_attrs(data, source, opts) do
    # Extract attributes from import data
    attrs = %{
      name: Keyword.get(opts, :name, data["name"]),
      description: data["description"],
      upgrades_allowed: data["upgrades_allowed"],
      upgrade_until_quality: data["upgrade_until_quality"],
      qualities: data["qualities"],
      quality_standards: atomize_keys(data["quality_standards"]),
      metadata_preferences: atomize_keys(data["metadata_preferences"]),
      customizations: atomize_keys(data["customizations"]),
      version: data["version"] || 1,
      is_system: false,
      source_url: determine_source_url(source, opts),
      last_synced_at: DateTime.utc_now()
    }

    {:ok, attrs}
  end

  defp determine_source_url(source, opts) do
    case Keyword.get(opts, :source_url) do
      nil ->
        # Auto-detect if source is a URL
        if is_binary(source) and
             (String.starts_with?(source, "http://") or String.starts_with?(source, "https://")) do
          source
        else
          nil
        end

      url ->
        url
    end
  end

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = atomize_keys_value(v)
      {key, value}
    end)
  end

  defp atomize_keys_value(map) when is_map(map), do: atomize_keys(map)
  defp atomize_keys_value(list) when is_list(list), do: Enum.map(list, &atomize_keys_value/1)
  defp atomize_keys_value(value), do: value

  defp perform_import(attrs, true) do
    # Dry run - validate and return preview
    changeset = QualityProfile.changeset(%QualityProfile{}, attrs)

    if changeset.valid? do
      # Check for conflicts
      conflicts = detect_profile_conflicts(attrs.name)

      preview = %{
        action: if(Enum.empty?(conflicts), do: :create, else: :update),
        profile: Ecto.Changeset.apply_changes(changeset),
        conflicts: conflicts,
        dry_run: true
      }

      {:ok, preview}
    else
      {:error, "Validation failed: #{format_changeset_errors(changeset)}"}
    end
  end

  defp perform_import(attrs, false) do
    # Real import - check for conflicts and create/update
    existing_profile = get_quality_profile_by_name(attrs.name)

    case existing_profile do
      nil ->
        # No conflict, create new profile
        create_quality_profile(attrs)

      _profile ->
        # Profile exists, return conflict error
        {:error,
         "Profile '#{attrs.name}' already exists. Use dry_run mode to preview changes or provide a different name."}
    end
  end

  defp detect_profile_conflicts(name) do
    case get_quality_profile_by_name(name) do
      nil -> []
      profile -> [%{type: :name_conflict, existing_profile_id: profile.id, name: name}]
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  ## Configuration Settings (Database)

  @doc """
  Lists all configuration settings from the database.

  Note: This function is intentionally database-only (no runtime config merge)
  as it's used by the config loader to build the configuration hierarchy.
  """
  def list_config_settings(opts \\ []) do
    ConfigSetting
    |> maybe_preload(opts[:preload])
    |> order_by([c], asc: c.category, asc: c.key)
    |> Repo.all()
  end

  @doc """
  Gets a configuration setting from the database by key.
  """
  def get_config_setting_by_key(key) do
    Repo.get_by(ConfigSetting, key: key)
  end

  @doc """
  Creates a configuration setting in the database.
  """
  def create_config_setting(attrs) do
    %ConfigSetting{}
    |> ConfigSetting.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a configuration setting in the database.
  """
  def update_config_setting(%ConfigSetting{} = config_setting, attrs) do
    config_setting
    |> ConfigSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a configuration setting from the database.
  """
  def delete_config_setting(%ConfigSetting{} = config_setting) do
    Repo.delete(config_setting)
  end

  ## Download Client Configs

  @doc """
  Lists all download client configurations.

  Returns download clients from both the database and runtime configuration
  (environment variables). Runtime config clients are returned as structs
  compatible with DownloadClientConfig but without database IDs.
  """
  def list_download_client_configs(opts \\ []) do
    # Get database configs
    db_configs =
      DownloadClientConfig
      |> maybe_preload(opts[:preload])
      |> order_by([d], desc: d.enabled, asc: d.priority, asc: d.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    merge_with_runtime_config(db_configs, &get_runtime_download_clients/0, :name, opts)
  end

  @doc """
  Gets a download client configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::download_client::"). Runtime identifiers are resolved by looking
  up the client in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_download_client_config!(id, opts \\ [])

  def get_download_client_config!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:download_client, name}} ->
          # Find the runtime download client by matching the name
          runtime_clients = get_runtime_download_clients()

          case Enum.find(runtime_clients, &(&1.name == name)) do
            nil ->
              raise "Runtime download client not found: #{name}"

            client ->
              client
          end

        _ ->
          raise "Invalid runtime download client ID: #{id}"
      end
    else
      # Check if it's a valid UUID (binary_id)
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          # Query by UUID
          DownloadClientConfig
          |> maybe_preload(opts[:preload])
          |> Repo.get!(uuid)

        :error ->
          # Try to parse as integer ID for database lookup
          case Integer.parse(id) do
            {int_id, ""} ->
              get_download_client_config!(int_id, opts)

            _ ->
              raise "Invalid download client ID: #{id}"
          end
      end
    end
  end

  def get_download_client_config!(id, opts) when is_integer(id) do
    DownloadClientConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a download client configuration.
  """
  def create_download_client_config(attrs) do
    %DownloadClientConfig{}
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a download client configuration.
  """
  def update_download_client_config(%DownloadClientConfig{} = config, attrs) do
    config
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a download client configuration.
  """
  def delete_download_client_config(%DownloadClientConfig{} = config) do
    Repo.delete(config)
  end

  ## Indexer Configs

  @doc """
  Lists all indexer configurations.

  Returns indexers from both the database and runtime configuration
  (environment variables). Runtime config indexers are returned as structs
  compatible with IndexerConfig but without database IDs.
  """
  def list_indexer_configs(opts \\ []) do
    # Get database configs
    db_configs =
      IndexerConfig
      |> maybe_preload(opts[:preload])
      |> order_by([i], desc: i.enabled, asc: i.priority, asc: i.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    merge_with_runtime_config(db_configs, &get_runtime_indexers/0, :name, opts)
  end

  @doc """
  Gets an indexer configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::indexer::"). Runtime identifiers are resolved by looking
  up the indexer in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_indexer_config!(id, opts \\ [])

  def get_indexer_config!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:indexer, name}} ->
          # Find the runtime indexer by matching the name
          runtime_indexers = get_runtime_indexers()

          case Enum.find(runtime_indexers, &(&1.name == name)) do
            nil ->
              raise "Runtime indexer not found: #{name}"

            indexer ->
              indexer
          end

        _ ->
          raise "Invalid runtime indexer ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup
      case Integer.parse(id) do
        {int_id, ""} ->
          get_indexer_config!(int_id, opts)

        _ ->
          # Try as UUID for database lookup
          case Ecto.UUID.cast(id) do
            {:ok, uuid} ->
              IndexerConfig
              |> maybe_preload(opts[:preload])
              |> Repo.get!(uuid)

            :error ->
              raise "Invalid indexer ID: #{id}"
          end
      end
    end
  end

  def get_indexer_config!(id, opts) when is_integer(id) do
    IndexerConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates an indexer configuration.
  """
  def create_indexer_config(attrs) do
    %IndexerConfig{}
    |> IndexerConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an indexer configuration.
  """
  def update_indexer_config(%IndexerConfig{} = config, attrs) do
    config
    |> IndexerConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an indexer configuration.
  """
  def delete_indexer_config(%IndexerConfig{} = config) do
    Repo.delete(config)
  end

  ## Library Paths

  @doc """
  Lists all library paths.

  Returns library paths from both the database and runtime configuration
  (environment variables). Runtime config paths are returned as structs
  compatible with LibraryPath but without database IDs.
  """
  def list_library_paths(opts \\ []) do
    # Get database library paths
    db_paths =
      LibraryPath
      |> maybe_preload(opts[:preload])
      |> order_by([l], desc: l.monitored, asc: l.path)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by path)
    merge_with_runtime_config(db_paths, &get_runtime_library_paths/0, :path, opts)
  end

  @doc """
  Gets a library path by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::library_path::"). Runtime identifiers are resolved by looking
  up the path in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_library_path!(id, opts \\ [])

  def get_library_path!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:library_path, path}} ->
          # Find the runtime library path by matching the path
          runtime_paths = get_runtime_library_paths()

          case Enum.find(runtime_paths, &(&1.path == path)) do
            nil ->
              raise "Runtime library path not found: #{path}"

            library_path ->
              library_path
          end

        _ ->
          raise "Invalid runtime library path ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup, or use directly as UUID
      case Integer.parse(id) do
        {int_id, ""} ->
          get_library_path!(int_id, opts)

        _ ->
          # Assume it's a UUID string and try to fetch directly
          LibraryPath
          |> maybe_preload(opts[:preload])
          |> Repo.get!(id)
      end
    end
  end

  def get_library_path!(id, opts) when is_integer(id) do
    LibraryPath
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a library path.
  """
  def create_library_path(attrs) do
    %LibraryPath{}
    |> LibraryPath.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a library path.

  If the path is being changed, validates that files are accessible at the new
  location before allowing the change.
  """
  def update_library_path(%LibraryPath{} = library_path, attrs) do
    changeset = LibraryPath.changeset(library_path, attrs)

    # Check if path is being changed
    case Ecto.Changeset.get_change(changeset, :path) do
      nil ->
        # No path change, proceed normally
        Repo.update(changeset)

      new_path ->
        # Path is changing, validate accessibility
        case validate_new_library_path(library_path, new_path) do
          :ok ->
            result = Repo.update(changeset)

            # Log the path change if successful
            if match?({:ok, _}, result) do
              require Logger

              Logger.info(
                "Library path updated: #{library_path.path} -> #{new_path}",
                library_path_id: library_path.id,
                old_path: library_path.path,
                new_path: new_path
              )
            end

            result

          {:error, reason} ->
            # Add validation error to changeset
            changeset_with_error =
              Ecto.Changeset.add_error(changeset, :path, reason)

            {:error, changeset_with_error}
        end
    end
  end

  @doc """
  Validates that files are accessible at a new library path location.

  Samples up to 10 media files from the library path and checks if they are
  accessible at the new location. Returns `:ok` if validation passes, or
  `{:error, message}` with a user-friendly error message if validation fails.

  ## Parameters

    - `library_path` - The existing LibraryPath struct
    - `new_path` - The new path to validate

  ## Examples

      iex> validate_new_library_path(library_path, "/new/media/path")
      :ok

      iex> validate_new_library_path(library_path, "/wrong/path")
      {:error, "Files not accessible at new location. Checked 5 files, 0 found."}
  """
  def validate_new_library_path(%LibraryPath{} = library_path, new_path) do
    alias Mydia.Library.MediaFile
    require Logger

    # Get sample of media files (up to 10)
    sample_files =
      MediaFile
      |> where([mf], mf.library_path_id == ^library_path.id)
      |> where([mf], not is_nil(mf.relative_path))
      |> limit(10)
      |> Repo.all()

    # If no files exist, allow the change
    if Enum.empty?(sample_files) do
      Logger.debug("No files to validate for library path change",
        library_path_id: library_path.id,
        old_path: library_path.path,
        new_path: new_path
      )

      :ok
    else
      # Check how many files are accessible at new location
      accessible_count =
        Enum.count(sample_files, fn file ->
          new_absolute_path = Path.join(new_path, file.relative_path)
          File.exists?(new_absolute_path)
        end)

      total_checked = length(sample_files)

      if accessible_count == total_checked do
        Logger.info("Library path validation passed",
          library_path_id: library_path.id,
          old_path: library_path.path,
          new_path: new_path,
          files_checked: total_checked
        )

        :ok
      else
        error_message =
          "Files not accessible at new location. " <>
            "Checked #{total_checked} files, #{accessible_count} found. " <>
            "Ensure files have been moved to the new location before updating the path."

        Logger.warning("Library path validation failed",
          library_path_id: library_path.id,
          old_path: library_path.path,
          new_path: new_path,
          files_checked: total_checked,
          files_found: accessible_count
        )

        {:error, error_message}
      end
    end
  end

  @doc """
  Deletes a library path.
  """
  def delete_library_path(%LibraryPath{} = library_path) do
    Repo.delete(library_path)
  end

  ## Runtime Configuration Functions

  @doc """
  Loads database configuration settings and converts them to a nested map structure.

  Converts flat ConfigSetting records (e.g., key: "server.port", value: "8080")
  into a nested map structure (e.g., %{server: %{port: 8080}}).

  Returns `{:ok, config_map}` where config_map is a nested map, or
  `{:ok, %{}}` if the database is unavailable.
  """
  def load_database_config do
    try do
      config_settings = list_config_settings()
      config_map = build_config_map(config_settings)
      {:ok, config_map}
    rescue
      # Database might not be available during initial setup
      DBConnection.ConnectionError -> {:ok, %{}}
      # Catch query errors during app startup (e.g., table doesn't exist yet)
      Ecto.QueryError -> {:ok, %{}}
      # Catch SQLite-specific errors
      Exqlite.Error -> {:ok, %{}}
      # Catch Repo not started yet error during application startup
      RuntimeError -> {:ok, %{}}
    end
  end

  @doc """
  Gets the runtime configuration.

  Returns the full configuration struct loaded at application startup.
  """
  def get_runtime_config do
    Application.get_env(:mydia, :runtime_config, Mydia.Config.Schema.defaults())
  end

  @doc """
  Gets download clients from the runtime configuration.

  Converts runtime config download client maps to DownloadClientConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::download_client::name").
  """
  def get_runtime_download_clients do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
      runtime_config.download_clients
      |> Enum.map(&map_to_download_client_config/1)
    else
      []
    end
  end

  defp map_to_download_client_config(map) when is_map(map) do
    name = Map.get(map, :name)

    %DownloadClientConfig{
      id: build_runtime_id(:download_client, name),
      name: name,
      type: Map.get(map, :type),
      enabled: Map.get(map, :enabled, true),
      priority: Map.get(map, :priority, 10),
      host: Map.get(map, :host),
      port: Map.get(map, :port),
      use_ssl: Map.get(map, :use_ssl, false),
      url_base: Map.get(map, :url_base),
      username: Map.get(map, :username),
      password: Map.get(map, :password),
      api_key: Map.get(map, :api_key),
      category: Map.get(map, :category),
      download_directory: Map.get(map, :download_directory),
      connection_settings: Map.get(map, :connection_settings, %{}),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  @doc """
  Gets indexers from the runtime configuration.

  Converts runtime config indexer maps to IndexerConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::indexer::name").
  """
  def get_runtime_indexers do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :indexers) do
      runtime_config.indexers
      |> Enum.map(&map_to_indexer_config/1)
    else
      []
    end
  end

  defp map_to_indexer_config(map) when is_map(map) do
    name = Map.get(map, :name)

    %IndexerConfig{
      id: build_runtime_id(:indexer, name),
      name: name,
      type: Map.get(map, :type),
      enabled: Map.get(map, :enabled, true),
      priority: Map.get(map, :priority, 10),
      base_url: Map.get(map, :base_url),
      api_key: Map.get(map, :api_key),
      indexer_ids: Map.get(map, :indexer_ids, []),
      categories: Map.get(map, :categories, []),
      rate_limit: Map.get(map, :rate_limit),
      connection_settings: Map.get(map, :connection_settings, %{}),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  @doc """
  Gets library paths from the runtime configuration.

  Converts runtime config library paths to LibraryPath structs for compatibility
  with the rest of the application. These structs have stable runtime identifiers
  instead of database IDs (format: "runtime::library_path::/path/to/media").

  Supports both the new library_paths schema and legacy media.movies_path/tv_path
  configuration for backward compatibility.
  """
  def get_runtime_library_paths do
    runtime_config = get_runtime_config()

    # Start with new library_paths schema if available
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :library_paths) do
        runtime_config.library_paths
        |> Enum.map(&map_to_library_path/1)
      else
        []
      end

    # Add legacy movies path if configured and not already in library_paths
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.movies_path do
        movies_path = runtime_config.media.movies_path

        # Only add if not already in library_paths
        if Enum.any?(paths, &(&1.path == movies_path)) do
          paths
        else
          [
            %LibraryPath{
              id: build_runtime_id(:library_path, movies_path),
              path: movies_path,
              type: :movies,
              monitored: true,
              scan_interval: 360,
              last_scan_at: nil,
              last_scan_status: nil,
              last_scan_error: nil,
              quality_profile_id: nil,
              updated_by_id: nil,
              inserted_at: nil,
              updated_at: nil
            }
            | paths
          ]
        end
      else
        paths
      end

    # Add legacy TV path if configured and not already in library_paths
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.tv_path do
        tv_path = runtime_config.media.tv_path

        # Only add if not already in library_paths
        if Enum.any?(paths, &(&1.path == tv_path)) do
          paths
        else
          [
            %LibraryPath{
              id: build_runtime_id(:library_path, tv_path),
              path: tv_path,
              type: :series,
              monitored: true,
              scan_interval: 360,
              last_scan_at: nil,
              last_scan_status: nil,
              last_scan_error: nil,
              quality_profile_id: nil,
              updated_by_id: nil,
              inserted_at: nil,
              updated_at: nil
            }
            | paths
          ]
        end
      else
        paths
      end

    paths
  end

  defp map_to_library_path(map) when is_map(map) do
    path = Map.get(map, :path)

    %LibraryPath{
      id: build_runtime_id(:library_path, path),
      path: path,
      type: Map.get(map, :type),
      monitored: Map.get(map, :monitored, true),
      scan_interval: Map.get(map, :scan_interval, 3600),
      last_scan_at: nil,
      last_scan_status: nil,
      last_scan_error: nil,
      quality_profile_id: Map.get(map, :quality_profile_id),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  @doc """
  Gets a configuration value by path.

  ## Examples

      iex> get_config([:server, :port])
      4000

      iex> get_config([:database, :path])
      "mydia_dev.db"

      iex> get_config([:auth, :oidc_enabled])
      false
  """
  def get_config(path) when is_list(path) do
    config = get_runtime_config()
    get_in(config, path_to_access_keys(path))
  end

  @doc """
  Gets a configuration value by path with a default.

  ## Examples

      iex> get_config([:server, :port], 8080)
      4000

      iex> get_config([:nonexistent, :key], "default")
      "default"
  """
  def get_config(path, default) when is_list(path) do
    case get_config(path) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Gets server configuration.
  """
  def get_server_config do
    get_runtime_config().server
  end

  @doc """
  Gets database configuration.
  """
  def get_database_config do
    get_runtime_config().database
  end

  @doc """
  Gets authentication configuration.
  """
  def get_auth_config do
    get_runtime_config().auth
  end

  @doc """
  Gets media configuration.
  """
  def get_media_config do
    get_runtime_config().media
  end

  @doc """
  Gets downloads configuration.
  """
  def get_downloads_config do
    get_runtime_config().downloads
  end

  @doc """
  Gets logging configuration.
  """
  def get_logging_config do
    get_runtime_config().logging
  end

  @doc """
  Gets Oban configuration.
  """
  def get_oban_config do
    get_runtime_config().oban
  end

  ## Private Functions

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Applies optional filters to quality profile queries
  defp apply_quality_profile_filters(query, opts) do
    query
    |> apply_is_system_filter(opts[:is_system])
    |> apply_version_filter(opts[:version])
    |> apply_source_url_filter(opts[:source_url])
  end

  defp apply_is_system_filter(query, nil), do: query

  defp apply_is_system_filter(query, is_system) when is_boolean(is_system) do
    where(query, [q], q.is_system == ^is_system)
  end

  defp apply_version_filter(query, nil), do: query

  defp apply_version_filter(query, version) when is_integer(version) do
    where(query, [q], q.version == ^version)
  end

  defp apply_source_url_filter(query, nil), do: query

  defp apply_source_url_filter(query, source_url) when is_binary(source_url) do
    where(query, [q], q.source_url == ^source_url)
  end

  # Merges database records with runtime configuration items.
  #
  # Database records take precedence - runtime items are only included if they
  # don't already exist in the database (matched by the specified merge_key).
  #
  # ## Parameters
  #   - db_records: List of database records
  #   - runtime_getter: Zero-arity function that returns runtime config items
  #   - merge_key: Atom key to use for deduplication (:name, :path, etc.)
  #   - _opts: Reserved for future options (currently unused)
  #
  # ## Returns
  #   Combined list of database records + filtered runtime items
  defp merge_with_runtime_config(db_records, runtime_getter, merge_key, _opts) do
    # Get runtime config items
    runtime_items = runtime_getter.()

    # Create MapSet of database keys for efficient deduplication
    db_keys = MapSet.new(db_records, &Map.get(&1, merge_key))

    # Filter runtime items to exclude those already in database
    runtime_items_filtered =
      Enum.reject(runtime_items, &MapSet.member?(db_keys, Map.get(&1, merge_key)))

    # Return merged list (database + filtered runtime)
    db_records ++ runtime_items_filtered
  end

  defp path_to_access_keys(path) do
    Enum.map(path, fn
      key when is_atom(key) -> Access.key(key)
      key -> key
    end)
  end

  defp build_config_map(config_settings) do
    Enum.reduce(config_settings, %{}, fn setting, acc ->
      # Parse the dot-notation key into path segments
      # e.g., "server.port" -> [:server, :port]
      path =
        setting.key
        |> String.split(".")
        |> Enum.map(&String.to_atom/1)

      # Parse the value based on common patterns
      parsed_value = parse_config_value(setting.value)

      # Put the value into the nested map
      put_in_path(acc, path, parsed_value)
    end)
  end

  defp parse_config_value(nil), do: nil
  defp parse_config_value(""), do: nil

  defp parse_config_value(value) when is_binary(value) do
    cond do
      # Boolean values
      value == "true" ->
        true

      value == "false" ->
        false

      # Integer values
      match?({_int, ""}, Integer.parse(value)) ->
        {int, ""} = Integer.parse(value)
        int

      # Default to string
      true ->
        value
    end
  end

  defp parse_config_value(value), do: value

  defp put_in_path(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_in_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_path(nested, rest, value))
  end

  ## Runtime ID Helpers

  @doc """
  Checks if a configuration struct is from runtime config (environment variables)
  rather than the database.

  Runtime configs have IDs that start with "runtime::" and cannot be updated
  via the normal update functions as they are not loaded from the database.

  ## Examples

      iex> runtime_config?(client)
      true

      iex> database_config?(client)
      false
  """
  def runtime_config?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  def runtime_config?(_), do: false

  # Builds a stable runtime identifier for a runtime config item.
  #
  # Format: "runtime::{type}::{key}"
  # Examples:
  #   - "runtime::library_path::/media/movies"
  #   - "runtime::download_client::qbittorrent"
  #   - "runtime::indexer::prowlarr"
  defp build_runtime_id(type, key) when is_atom(type) and is_binary(key) do
    "runtime::#{type}::#{key}"
  end

  # Parses a runtime identifier into its type and key components.
  #
  # Returns {:ok, {type, key}} or :error
  defp parse_runtime_id("runtime::" <> rest) do
    case String.split(rest, "::", parts: 2) do
      [type_str, key] ->
        type = String.to_existing_atom(type_str)
        {:ok, {type, key}}

      _ ->
        :error
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom raises if atom doesn't exist
      :error
  end

  defp parse_runtime_id(_), do: :error

  # Checks if an ID is a runtime identifier
  defp runtime_id?(id) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  defp runtime_id?(_), do: false
end
