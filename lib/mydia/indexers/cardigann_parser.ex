defmodule Mydia.Indexers.CardigannParser do
  @moduledoc """
  Parser for Cardigann v11 YAML indexer definitions.

  Parses YAML definition strings into structured `CardigannDefinition.Parsed` structs
  that can be used for search execution and validation.
  """

  alias Mydia.Indexers.CardigannDefinition.Parsed

  @doc """
  Parses a Cardigann YAML definition string into a structured Parsed struct.

  ## Examples

      iex> yaml = File.read!("definitions/v11/1337x.yml")
      iex> {:ok, parsed} = CardigannParser.parse_definition(yaml)
      iex> parsed.id
      "1337x"

  ## Returns

  - `{:ok, %Parsed{}}` - Successfully parsed definition
  - `{:error, reason}` - Parse or validation error
  """
  @spec parse_definition(String.t()) :: {:ok, Parsed.t()} | {:error, term()}
  def parse_definition(yaml_string) when is_binary(yaml_string) do
    with {:ok, yaml_data} <- YamlElixir.read_from_string(yaml_string),
         {:ok, parsed} <- build_parsed_struct(yaml_data),
         :ok <- validate_definition(parsed) do
      {:ok, parsed}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  @doc """
  Extracts and normalizes search configuration from parsed YAML data.

  ## Returns

  - `{:ok, search_config}` - Normalized search configuration map
  - `{:error, reason}` - Missing required fields or validation error
  """
  @spec parse_search_config(map()) :: {:ok, map()} | {:error, term()}
  def parse_search_config(yaml_data) when is_map(yaml_data) do
    search = Map.get(yaml_data, "search", %{})

    with {:ok, paths} <- extract_search_paths(search),
         {:ok, rows} <- extract_rows_selector(search),
         {:ok, fields} <- extract_field_selectors(search) do
      search_config = %{
        paths: paths,
        inputs: Map.get(search, "inputs", %{}),
        headers: Map.get(search, "headers"),
        keywordsfilters: Map.get(search, "keywordsfilters", []),
        rows: rows,
        fields: fields
      }

      {:ok, search_config}
    end
  end

  @doc """
  Extracts and validates HTML/JSON selectors from the definition.

  ## Returns

  - `{:ok, selectors}` - Map of validated selectors
  - `{:error, reason}` - Invalid selector format
  """
  @spec parse_selectors(map()) :: {:ok, map()} | {:error, term()}
  def parse_selectors(fields) when is_map(fields) do
    selectors =
      fields
      |> Enum.map(fn {key, value} ->
        {String.to_atom(key), normalize_selector(value)}
      end)
      |> Map.new()

    {:ok, selectors}
  end

  @doc """
  Extracts login configuration for private indexers.

  ## Returns

  - `{:ok, login_config | nil}` - Login configuration or nil if public indexer
  - `{:error, reason}` - Invalid login configuration
  """
  @spec parse_login_config(map()) :: {:ok, map() | nil} | {:error, term()}
  def parse_login_config(yaml_data) when is_map(yaml_data) do
    case Map.get(yaml_data, "login") do
      nil ->
        {:ok, nil}

      login when is_map(login) ->
        login_config = %{
          method: Map.fetch!(login, "method"),
          path: Map.get(login, "path"),
          submitpath: Map.get(login, "submitpath"),
          inputs: Map.get(login, "inputs", %{}),
          error: parse_error_selectors(login),
          test: Map.get(login, "test"),
          cookies: Map.get(login, "cookies", []),
          captcha: Map.get(login, "captcha")
        }

        {:ok, login_config}

      _ ->
        {:error, :invalid_login_config}
    end
  rescue
    KeyError -> {:error, :missing_login_method}
  end

  @doc """
  Validates a parsed definition for required fields and correct structure.

  ## Returns

  - `:ok` - Definition is valid
  - `{:error, reason}` - Validation error with details
  """
  @spec validate_definition(Parsed.t()) :: :ok | {:error, term()}
  def validate_definition(%Parsed{} = parsed) do
    with :ok <- validate_required_fields(parsed),
         :ok <- validate_search_fields(parsed.search),
         :ok <- validate_capabilities(parsed.capabilities) do
      :ok
    end
  end

  # Private functions

  defp build_parsed_struct(yaml_data) when is_map(yaml_data) do
    with {:ok, search} <- parse_search_config(yaml_data),
         {:ok, login} <- parse_login_config(yaml_data),
         {:ok, capabilities} <- parse_capabilities(yaml_data) do
      parsed = %Parsed{
        id: Map.fetch!(yaml_data, "id"),
        name: Map.fetch!(yaml_data, "name"),
        description: Map.fetch!(yaml_data, "description"),
        language: Map.fetch!(yaml_data, "language"),
        type: Map.fetch!(yaml_data, "type"),
        encoding: Map.fetch!(yaml_data, "encoding"),
        links: Map.fetch!(yaml_data, "links"),
        capabilities: capabilities,
        search: search,
        login: login,
        download: parse_download_config(yaml_data),
        settings: parse_settings(yaml_data),
        request_delay: Map.get(yaml_data, "requestdelay"),
        follow_redirect: Map.get(yaml_data, "followredirect", false),
        test_link_torrent: Map.get(yaml_data, "testlinktorrent", false),
        certificates: Map.get(yaml_data, "certificates", []),
        replaces: Map.get(yaml_data, "replaces", [])
      }

      {:ok, parsed}
    end
  rescue
    e in KeyError -> {:error, {:missing_required_field, e.key}}
  end

  defp extract_search_paths(search) do
    cond do
      path = Map.get(search, "path") ->
        {:ok, [%{path: path}]}

      paths = Map.get(search, "paths") ->
        if is_list(paths) do
          normalized_paths =
            Enum.map(paths, fn
              path when is_binary(path) -> %{path: path}
              path when is_map(path) -> normalize_path_entry(path)
            end)

          {:ok, normalized_paths}
        else
          {:error, :invalid_paths_format}
        end

      true ->
        {:error, :missing_search_path}
    end
  end

  defp normalize_path_entry(path_map) do
    %{
      path: Map.fetch!(path_map, "path"),
      categories: Map.get(path_map, "categories", []),
      method: Map.get(path_map, "method", "get")
    }
  end

  defp extract_rows_selector(search) do
    case Map.get(search, "rows") do
      nil -> {:error, :missing_rows_selector}
      rows -> {:ok, normalize_selector(rows)}
    end
  end

  defp extract_field_selectors(search) do
    case Map.get(search, "fields") do
      nil -> {:error, :missing_fields}
      fields when is_map(fields) -> parse_selectors(fields)
      _ -> {:error, :invalid_fields_format}
    end
  end

  defp normalize_selector(selector) when is_binary(selector) do
    %{selector: selector}
  end

  defp normalize_selector(selector) when is_map(selector) do
    %{
      selector: Map.get(selector, "selector", ""),
      attribute: Map.get(selector, "attribute"),
      remove: Map.get(selector, "remove"),
      case: Map.get(selector, "case"),
      filters: Map.get(selector, "filters", [])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_selector(_), do: %{selector: ""}

  defp parse_error_selectors(login) do
    case Map.get(login, "error") do
      nil -> []
      errors when is_list(errors) -> Enum.map(errors, &normalize_selector/1)
      error -> [normalize_selector(error)]
    end
  end

  defp parse_capabilities(yaml_data) do
    case Map.get(yaml_data, "caps") do
      nil ->
        {:error, :missing_capabilities}

      caps ->
        capabilities = %{
          modes: Map.get(caps, "modes", %{}),
          categories: Map.get(caps, "categories", %{}),
          categorymappings: Map.get(caps, "categorymappings", [])
        }

        {:ok, capabilities}
    end
  end

  defp parse_download_config(yaml_data) do
    case Map.get(yaml_data, "download") do
      nil ->
        nil

      download ->
        %{
          selectors: parse_download_selectors(download),
          before: Map.get(download, "before"),
          method: Map.get(download, "method", "get"),
          infohash: normalize_selector(Map.get(download, "infohash", ""))
        }
    end
  end

  defp parse_download_selectors(download) do
    case Map.get(download, "selectors") do
      nil -> []
      selectors when is_list(selectors) -> Enum.map(selectors, &normalize_selector/1)
      selector -> [normalize_selector(selector)]
    end
  end

  defp parse_settings(yaml_data) do
    case Map.get(yaml_data, "settings") do
      nil ->
        []

      settings when is_list(settings) ->
        Enum.map(settings, fn setting ->
          %{
            name: Map.fetch!(setting, "name"),
            type: Map.fetch!(setting, "type"),
            label: Map.get(setting, "label", ""),
            default: Map.get(setting, "default"),
            options: Map.get(setting, "options")
          }
        end)

      _ ->
        []
    end
  end

  defp validate_required_fields(%Parsed{} = parsed) do
    required = [:id, :name, :description, :language, :type, :encoding, :links]

    missing =
      Enum.filter(required, fn field ->
        value = Map.get(parsed, field)
        is_nil(value) || value == "" || value == []
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_required_fields, missing}}
    end
  end

  defp validate_search_fields(search) do
    required_fields = [:title, :size, :seeders]

    missing =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(search.fields, field)
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_search_fields, missing}}
    end
  end

  defp validate_capabilities(capabilities) do
    if Map.has_key?(capabilities, :modes) do
      :ok
    else
      {:error, :missing_capabilities_modes}
    end
  end
end
