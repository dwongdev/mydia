defmodule Mydia.Collections.SmartRules do
  @moduledoc """
  Builds dynamic Ecto queries from JSON smart collection rule definitions.

  ## Rules Format

  Smart rules are defined as a JSON object with the following structure:

      %{
        "match_type" => "all",  # "all" (AND) or "any" (OR)
        "conditions" => [
          %{"field" => "category", "operator" => "in", "value" => ["movie", "anime_movie"]},
          %{"field" => "year", "operator" => "gte", "value" => 2020},
          %{"field" => "metadata.vote_average", "operator" => "gte", "value" => 7.0}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"},  # optional
        "limit" => 100  # optional
      }

  ## Supported Fields

  - `category` - Media category (movie, anime_movie, tv_show, etc.)
  - `type` - Media type (movie or tv_show)
  - `year` - Release year
  - `title` - Title (for text search)
  - `monitored` - Monitored status
  - `metadata.vote_average` - Rating from TMDB
  - `metadata.genres` - Genres array
  - `metadata.original_language` - Original language code
  - `metadata.status` - Status (Ended, Returning Series, etc.)
  - `inserted_at` - Date added to library

  ## Supported Operators

  - `eq` - Equal
  - `gt` - Greater than
  - `gte` - Greater than or equal
  - `lt` - Less than
  - `lte` - Less than or equal
  - `in` - Value is in list
  - `not_in` - Value is not in list
  - `contains` - String/array contains value
  - `contains_any` - Array contains any of the values
  - `between` - Value is between two numbers [min, max]
  """

  import Ecto.Query, warn: false
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @valid_fields ~w(
    category type year title monitored
    metadata.vote_average metadata.genres metadata.original_language metadata.status
    inserted_at
  )

  @valid_operators ~w(eq gt gte lt lte in not_in contains contains_any between)

  @valid_sort_fields ~w(title year rating added_date position)
  @valid_sort_directions ~w(asc desc)

  @doc """
  Validates a smart rules definition.

  Returns `{:ok, rules}` if valid, or `{:error, errors}` with a list of validation errors.

  ## Examples

      iex> validate(%{"match_type" => "all", "conditions" => []})
      {:ok, %{"match_type" => "all", "conditions" => []}}

      iex> validate(%{"match_type" => "invalid"})
      {:error, ["match_type must be 'all' or 'any'"]}
  """
  def validate(rules) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> validate(decoded)
      {:error, _} -> {:error, ["Invalid JSON"]}
    end
  end

  def validate(rules) when is_map(rules) do
    errors = []

    # Validate match_type
    errors =
      case Map.get(rules, "match_type") do
        nil -> errors
        type when type in ["all", "any"] -> errors
        _ -> ["match_type must be 'all' or 'any'" | errors]
      end

    # Validate conditions
    conditions = Map.get(rules, "conditions", [])

    errors =
      if is_list(conditions) do
        condition_errors =
          conditions
          |> Enum.with_index()
          |> Enum.flat_map(fn {condition, idx} -> validate_condition(condition, idx) end)

        errors ++ condition_errors
      else
        ["conditions must be a list" | errors]
      end

    # Validate sort (optional)
    errors =
      case Map.get(rules, "sort") do
        nil ->
          errors

        sort when is_map(sort) ->
          sort_errors = validate_sort(sort)
          errors ++ sort_errors

        _ ->
          ["sort must be an object" | errors]
      end

    # Validate limit (optional)
    errors =
      case Map.get(rules, "limit") do
        nil -> errors
        limit when is_integer(limit) and limit > 0 -> errors
        _ -> ["limit must be a positive integer" | errors]
      end

    if errors == [] do
      {:ok, rules}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["Rules must be a map or JSON string"]}

  @doc """
  Executes a smart rules query and returns matching media items.

  ## Options
    - `:preload` - List of associations to preload
    - `:limit` - Override the limit in rules
    - `:offset` - Number of items to skip
  """
  def execute_query(rules, opts \\ [])

  def execute_query(rules, opts) when is_map(rules) do
    rules
    |> build_query()
    |> apply_sort(rules)
    |> apply_limit(rules, opts)
    |> apply_offset(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  def execute_query(rules, opts) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> execute_query(decoded, opts)
      {:error, _} -> []
    end
  end

  @doc """
  Returns the count of items matching the smart rules.
  """
  def execute_count(rules) when is_map(rules) do
    rules
    |> build_query()
    |> apply_limit(rules, [])
    |> Repo.aggregate(:count)
  end

  def execute_count(rules) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> execute_count(decoded)
      {:error, _} -> 0
    end
  end

  @doc """
  Returns a preview of items matching the rules (limited to 10 items).
  Useful for showing users what a smart collection will contain.
  """
  def preview(rules, limit \\ 10) do
    execute_query(rules, limit: limit)
  end

  @doc """
  Returns the list of valid fields for smart rules.
  """
  def valid_fields, do: @valid_fields

  @doc """
  Returns the list of valid operators for smart rules.
  """
  def valid_operators, do: @valid_operators

  ## Private Functions

  defp validate_condition(condition, idx) when is_map(condition) do
    errors = []
    prefix = "conditions[#{idx}]"

    field = Map.get(condition, "field")
    operator = Map.get(condition, "operator")
    value = Map.get(condition, "value")

    errors =
      cond do
        is_nil(field) -> ["#{prefix}: field is required" | errors]
        field not in @valid_fields -> ["#{prefix}: unknown field '#{field}'" | errors]
        true -> errors
      end

    errors =
      cond do
        is_nil(operator) -> ["#{prefix}: operator is required" | errors]
        operator not in @valid_operators -> ["#{prefix}: unknown operator '#{operator}'" | errors]
        true -> errors
      end

    # Validate value based on operator
    errors =
      cond do
        is_nil(value) ->
          ["#{prefix}: value is required" | errors]

        operator in ["in", "not_in", "contains_any"] and not is_list(value) ->
          ["#{prefix}: value must be a list for operator '#{operator}'" | errors]

        operator == "between" and
            not (is_list(value) and length(value) == 2) ->
          ["#{prefix}: value must be a [min, max] list for 'between'" | errors]

        true ->
          errors
      end

    errors
  end

  defp validate_condition(_, idx) do
    ["conditions[#{idx}]: must be an object"]
  end

  defp validate_sort(sort) do
    errors = []

    errors =
      case Map.get(sort, "field") do
        nil -> errors
        field when field in @valid_sort_fields -> errors
        field -> ["sort.field '#{field}' is invalid" | errors]
      end

    errors =
      case Map.get(sort, "direction") do
        nil -> errors
        dir when dir in @valid_sort_directions -> errors
        dir -> ["sort.direction '#{dir}' is invalid" | errors]
      end

    errors
  end

  defp build_query(rules) do
    match_type = Map.get(rules, "match_type", "all")
    conditions = Map.get(rules, "conditions", [])

    base_query = from(m in MediaItem)

    if Enum.empty?(conditions) do
      base_query
    else
      Enum.reduce(conditions, base_query, fn condition, query ->
        apply_condition(query, condition, match_type)
      end)
    end
  end

  defp apply_condition(query, condition, match_type) do
    field = Map.get(condition, "field")
    operator = Map.get(condition, "operator")
    value = Map.get(condition, "value")

    dynamic_condition = build_dynamic(field, operator, value)

    case match_type do
      "any" ->
        from(m in query, or_where: ^dynamic_condition)

      _ ->
        # "all" - AND conditions (default)
        from(m in query, where: ^dynamic_condition)
    end
  end

  # Standard field conditions
  defp build_dynamic("category", "eq", value), do: dynamic([m], m.category == ^value)
  defp build_dynamic("category", "in", values), do: dynamic([m], m.category in ^values)
  defp build_dynamic("category", "not_in", values), do: dynamic([m], m.category not in ^values)

  defp build_dynamic("type", "eq", value), do: dynamic([m], m.type == ^value)
  defp build_dynamic("type", "in", values), do: dynamic([m], m.type in ^values)
  defp build_dynamic("type", "not_in", values), do: dynamic([m], m.type not in ^values)

  defp build_dynamic("year", "eq", value), do: dynamic([m], m.year == ^value)
  defp build_dynamic("year", "gt", value), do: dynamic([m], m.year > ^value)
  defp build_dynamic("year", "gte", value), do: dynamic([m], m.year >= ^value)
  defp build_dynamic("year", "lt", value), do: dynamic([m], m.year < ^value)
  defp build_dynamic("year", "lte", value), do: dynamic([m], m.year <= ^value)

  defp build_dynamic("year", "between", [min, max]),
    do: dynamic([m], m.year >= ^min and m.year <= ^max)

  defp build_dynamic("year", "in", values), do: dynamic([m], m.year in ^values)

  defp build_dynamic("title", "eq", value), do: dynamic([m], m.title == ^value)

  defp build_dynamic("title", "contains", value) do
    # SQLite doesn't support ilike, use LIKE with LOWER() for case-insensitive search
    pattern = "%#{String.downcase(value)}%"
    dynamic([m], fragment("LOWER(title) LIKE ?", ^pattern))
  end

  defp build_dynamic("monitored", "eq", true), do: dynamic([m], m.monitored == true)
  defp build_dynamic("monitored", "eq", false), do: dynamic([m], m.monitored == false)

  # Metadata fields - using SQLite json_extract
  defp build_dynamic("metadata.vote_average", "gte", value) do
    dynamic([m], fragment("json_extract(metadata, '$.vote_average') >= ?", ^value))
  end

  defp build_dynamic("metadata.vote_average", "gt", value) do
    dynamic([m], fragment("json_extract(metadata, '$.vote_average') > ?", ^value))
  end

  defp build_dynamic("metadata.vote_average", "lte", value) do
    dynamic([m], fragment("json_extract(metadata, '$.vote_average') <= ?", ^value))
  end

  defp build_dynamic("metadata.vote_average", "lt", value) do
    dynamic([m], fragment("json_extract(metadata, '$.vote_average') < ?", ^value))
  end

  defp build_dynamic("metadata.vote_average", "eq", value) do
    dynamic([m], fragment("json_extract(metadata, '$.vote_average') = ?", ^value))
  end

  defp build_dynamic("metadata.vote_average", "between", [min, max]) do
    dynamic(
      [m],
      fragment(
        "json_extract(metadata, '$.vote_average') >= ? AND json_extract(metadata, '$.vote_average') <= ?",
        ^min,
        ^max
      )
    )
  end

  defp build_dynamic("metadata.genres", "contains", value) do
    # SQLite JSON array search using LIKE on the JSON string
    pattern = "%\"#{value}\"%"
    dynamic([m], fragment("json_extract(metadata, '$.genres') LIKE ?", ^pattern))
  end

  defp build_dynamic("metadata.genres", "contains_any", values) when is_list(values) do
    # Build OR conditions for each value
    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      pattern = "%\"#{value}\"%"
      dynamic([m], ^acc or fragment("json_extract(metadata, '$.genres') LIKE ?", ^pattern))
    end)
  end

  defp build_dynamic("metadata.original_language", "eq", value) do
    dynamic([m], fragment("json_extract(metadata, '$.original_language') = ?", ^value))
  end

  defp build_dynamic("metadata.original_language", "in", values) when is_list(values) do
    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      dynamic([m], ^acc or fragment("json_extract(metadata, '$.original_language') = ?", ^value))
    end)
  end

  defp build_dynamic("metadata.status", "eq", value) do
    dynamic([m], fragment("json_extract(metadata, '$.status') = ?", ^value))
  end

  defp build_dynamic("metadata.status", "in", values) when is_list(values) do
    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      dynamic([m], ^acc or fragment("json_extract(metadata, '$.status') = ?", ^value))
    end)
  end

  defp build_dynamic("inserted_at", "gte", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at >= ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "lte", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at <= ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "gt", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at > ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "lt", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at < ^datetime)
      _ -> dynamic([m], true)
    end
  end

  # Fallback for unknown conditions
  defp build_dynamic(_field, _operator, _value), do: dynamic([m], true)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_), do: :error

  defp apply_sort(query, rules) do
    case Map.get(rules, "sort") do
      %{"field" => field, "direction" => direction} ->
        do_apply_sort(query, field, direction)

      %{"field" => field} ->
        do_apply_sort(query, field, "asc")

      _ ->
        query
    end
  end

  defp do_apply_sort(query, "title", "asc"), do: order_by(query, [m], asc: m.title)
  defp do_apply_sort(query, "title", "desc"), do: order_by(query, [m], desc: m.title)
  defp do_apply_sort(query, "year", "asc"), do: order_by(query, [m], asc: m.year)
  defp do_apply_sort(query, "year", "desc"), do: order_by(query, [m], desc: m.year)
  defp do_apply_sort(query, "added_date", "asc"), do: order_by(query, [m], asc: m.inserted_at)
  defp do_apply_sort(query, "added_date", "desc"), do: order_by(query, [m], desc: m.inserted_at)

  defp do_apply_sort(query, "rating", "asc") do
    order_by(query, [m], fragment("json_extract(metadata, '$.vote_average') ASC"))
  end

  defp do_apply_sort(query, "rating", "desc") do
    order_by(query, [m], fragment("json_extract(metadata, '$.vote_average') DESC"))
  end

  defp do_apply_sort(query, _, _), do: query

  defp apply_limit(query, rules, opts) do
    # opts[:limit] takes precedence over rules limit
    limit_val =
      case Keyword.get(opts, :limit) do
        nil -> Map.get(rules, "limit")
        opt_limit -> opt_limit
      end

    case limit_val do
      limit when is_integer(limit) and limit > 0 -> limit(query, ^limit)
      _ -> query
    end
  end

  defp apply_offset(query, opts) do
    case Keyword.get(opts, :offset) do
      offset when is_integer(offset) and offset > 0 -> offset(query, ^offset)
      _ -> query
    end
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
