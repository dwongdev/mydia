defmodule MydiaWeb.Schema.Middleware.Logging do
  @moduledoc """
  GraphQL request logging for both HTTP and P2P requests.

  Provides a wrapper around `Absinthe.run/3` that logs:
  - Operation type (query/mutation/subscription)
  - Operation name
  - Source (http or p2p)
  - User ID (if authenticated)
  - Execution duration
  - Error count (if any)

  ## Example log output

      [info] GraphQL query=browseNode source=p2p user_id=123 duration_ms=45
      [info] GraphQL mutation=updateProgress source=http user_id=456 duration_ms=12
      [warning] GraphQL query=search source=p2p user_id=123 duration_ms=150 errors=1

  ## Usage

  Instead of calling `Absinthe.run/3` directly, use:

      Logging.run(query, schema, opts)
  """

  require Logger

  @doc """
  Executes a GraphQL operation with logging.

  Wraps `Absinthe.run/3` to capture timing and operation details.

  ## Options

  Same as `Absinthe.run/3`, with context expected to contain:
  - `:source` - `:http` or `:p2p` (defaults to `:unknown`)
  - `:current_user` - the authenticated user (optional)
  """
  def run(document, schema, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    result = Absinthe.run(document, schema, opts)

    duration_us = System.monotonic_time(:microsecond) - start_time
    duration_ms = div(duration_us, 1000)

    log_operation(document, opts, result, duration_ms)

    result
  end

  # Private helpers

  defp log_operation(document, opts, result, duration_ms) do
    context = Keyword.get(opts, :context, %{})
    operation_name = Keyword.get(opts, :operation_name) || extract_operation_name(document)
    operation_type = extract_operation_type(document)
    source = Map.get(context, :source, :unknown)
    user_id = get_user_id(context)
    error_count = count_errors(result)

    # Build metadata for structured logging
    metadata =
      [
        graphql_operation: operation_name || "anonymous",
        graphql_type: operation_type,
        graphql_source: source,
        graphql_duration_ms: duration_ms
      ]
      |> maybe_add(:user_id, user_id)
      |> maybe_add(:graphql_errors, error_count, error_count > 0)

    # Log at appropriate level
    message =
      format_log_message(
        operation_type,
        operation_name || "anonymous",
        source,
        user_id,
        duration_ms,
        error_count
      )

    if error_count > 0 do
      Logger.warning(message, metadata)
    else
      Logger.info(message, metadata)
    end
  end

  defp extract_operation_name(document) when is_binary(document) do
    # Try to extract operation name from query string
    # Matches: query OperationName, mutation OperationName, subscription OperationName
    case Regex.run(~r/(?:query|mutation|subscription)\s+(\w+)/i, document) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp extract_operation_name(_), do: nil

  defp extract_operation_type(document) when is_binary(document) do
    cond do
      String.contains?(document, "mutation") -> :mutation
      String.contains?(document, "subscription") -> :subscription
      true -> :query
    end
  end

  defp extract_operation_type(_), do: :query

  defp get_user_id(%{current_user: %{id: id}}), do: id
  defp get_user_id(_), do: nil

  defp count_errors({:ok, %{errors: errors}}) when is_list(errors), do: length(errors)
  defp count_errors({:error, _}), do: 1
  defp count_errors(_), do: 0

  defp maybe_add(keyword, _key, nil), do: keyword
  defp maybe_add(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp maybe_add(keyword, _key, _value, false), do: keyword
  defp maybe_add(keyword, key, value, true), do: Keyword.put(keyword, key, value)

  defp format_log_message(type, name, source, user_id, duration_ms, error_count) do
    base = "GraphQL #{type}=#{name} source=#{source}"

    base
    |> maybe_append("user_id=#{user_id}", user_id != nil)
    |> Kernel.<>(" duration_ms=#{duration_ms}")
    |> maybe_append("errors=#{error_count}", error_count > 0)
  end

  defp maybe_append(string, _suffix, false), do: string
  defp maybe_append(string, suffix, true), do: string <> " " <> suffix
end
