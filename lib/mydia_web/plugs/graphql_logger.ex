defmodule MydiaWeb.Plugs.GraphQLLogger do
  @moduledoc """
  Plug that logs GraphQL HTTP requests.

  This plug captures timing information and logs the GraphQL operation
  after the response is computed. It extracts operation details from
  the request body and context.

  Should be placed in the pipeline before Absinthe.Plug.
  """

  @behaviour Plug

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time(:microsecond)

    # Register a callback to log after the response is computed
    Plug.Conn.register_before_send(conn, fn conn ->
      log_request(conn, start_time)
      conn
    end)
  end

  defp log_request(conn, start_time) do
    duration_us = System.monotonic_time(:microsecond) - start_time
    duration_ms = div(duration_us, 1000)

    # Try to get operation info from the parsed body
    {operation_name, operation_type} = extract_operation_info(conn)

    # Get user from absinthe context
    user_id = get_user_id(conn)

    # Check response status for errors
    has_errors = conn.status >= 400

    # Build metadata for structured logging
    metadata =
      [
        graphql_operation: operation_name,
        graphql_type: operation_type,
        graphql_source: :http,
        graphql_duration_ms: duration_ms
      ]
      |> maybe_add(:user_id, user_id)
      |> maybe_add(:graphql_errors, 1, has_errors)

    # Format log message
    message = format_log_message(operation_type, operation_name, user_id, duration_ms, has_errors)

    if has_errors do
      Logger.warning(message, metadata)
    else
      Logger.info(message, metadata)
    end
  end

  defp extract_operation_info(conn) do
    # Try to get from body params first
    body_params = conn.body_params || %{}

    operation_name =
      Map.get(body_params, "operationName") ||
        Map.get(body_params, :operationName) ||
        extract_operation_name_from_query(
          Map.get(body_params, "query") || Map.get(body_params, :query)
        )

    query = Map.get(body_params, "query") || Map.get(body_params, :query) || ""
    operation_type = extract_operation_type(query)

    {operation_name || "anonymous", operation_type}
  end

  defp extract_operation_name_from_query(nil), do: nil

  defp extract_operation_name_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:query|mutation|subscription)\s+(\w+)/i, query) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp extract_operation_type(query) when is_binary(query) do
    cond do
      String.contains?(query, "mutation") -> :mutation
      String.contains?(query, "subscription") -> :subscription
      true -> :query
    end
  end

  defp extract_operation_type(_), do: :query

  defp get_user_id(conn) do
    case Mydia.Auth.Guardian.Plug.current_resource(conn) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp maybe_add(keyword, _key, nil), do: keyword
  defp maybe_add(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp maybe_add(keyword, _key, _value, false), do: keyword
  defp maybe_add(keyword, key, value, true), do: Keyword.put(keyword, key, value)

  defp format_log_message(type, name, user_id, duration_ms, has_errors) do
    base = "GraphQL #{type}=#{name} source=http"

    base
    |> maybe_append("user_id=#{user_id}", user_id != nil)
    |> Kernel.<>(" duration_ms=#{duration_ms}")
    |> maybe_append("errors=1", has_errors)
  end

  defp maybe_append(string, _suffix, false), do: string
  defp maybe_append(string, suffix, true), do: string <> " " <> suffix
end
