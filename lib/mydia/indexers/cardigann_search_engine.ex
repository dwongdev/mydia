defmodule Mydia.Indexers.CardigannSearchEngine do
  @moduledoc """
  Core search engine that executes searches using parsed Cardigann definitions.

  This module handles:
  - Building search URLs from templates with variable substitution
  - Executing HTTP requests with proper headers, cookies, and rate limiting
  - Validating responses before passing to the result parser
  - Error handling for timeouts, rate limits, and invalid responses

  ## Search Flow

  1. **Build Search URL:** Apply query template with parameters
  2. **Build Request Params:** Construct query parameters
  3. **Execute HTTP Request:** Send request with headers, cookies, etc.
  4. **Validate Response:** Check response is valid
  5. **Return Response:** Pass to result parser (handled by caller)

  ## URL Template Variables

  Cardigann definitions use Go-style template variables:
  - `{{ .Keywords }}` - Search query
  - `{{ .Query.Series }}` - TV show name
  - `{{ .Query.Season }}` - Season number
  - `{{ .Query.Ep }}` - Episode number
  - `{{ .Categories }}` - Category IDs

  ## Example

      definition = %Parsed{
        id: "1337x",
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}/1/"}],
          ...
        },
        ...
      }

      opts = [query: "Ubuntu 22.04", categories: [2000]]
      {:ok, response} = CardigannSearchEngine.execute_search(definition, opts)
  """

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.Adapter.Error

  require Logger

  @type search_opts :: [
          query: String.t(),
          categories: [integer()],
          season: integer() | nil,
          episode: integer() | nil,
          imdb_id: String.t() | nil,
          tmdb_id: integer() | nil
        ]

  @type http_response :: %{
          status: integer(),
          body: String.t(),
          headers: [{String.t(), String.t()}]
        }

  @doc """
  Executes a search using the given Cardigann definition and search options.

  ## Parameters

  - `definition` - Parsed Cardigann definition
  - `opts` - Search options (query, categories, season, episode, etc.)
  - `user_config` - Optional user configuration (cookies, credentials)

  ## Returns

  - `{:ok, response}` - HTTP response ready for parsing
  - `{:error, reason}` - Search execution error

  ## Examples

      iex> opts = [query: "Ubuntu", categories: [2000]]
      iex> {:ok, response} = execute_search(definition, opts)
      iex> response.status
      200
  """
  @spec execute_search(Parsed.t(), search_opts(), map()) ::
          {:ok, http_response()} | {:error, Error.t()}
  def execute_search(definition, opts, user_config \\ %{})

  def execute_search(%Parsed{} = definition, opts, user_config) when is_list(opts) do
    with {:ok, url} <- build_search_url(definition, opts),
         {:ok, request_params} <- build_request_params(definition, opts),
         {:ok, response} <- execute_http_request(definition, url, request_params, user_config),
         :ok <- validate_response(response) do
      {:ok, response}
    end
  end

  @doc """
  Builds the search URL from the definition's path template and search options.

  Selects the appropriate path from the definition based on categories (if specified),
  then substitutes template variables with actual values.

  ## Template Variables

  - `{{ .Keywords }}` - Main search query
  - `{{ .Query.Series }}` - TV show name (same as Keywords for now)
  - `{{ .Query.Season }}` - Season number
  - `{{ .Query.Ep }}` - Episode number
  - `{{ .Categories }}` - Comma-separated category IDs

  ## Examples

      iex> definition = %Parsed{
      ...>   links: ["https://1337x.to"],
      ...>   search: %{paths: [%{path: "/search/{{ .Keywords }}/1/"}]}
      ...> }
      iex> build_search_url(definition, query: "Ubuntu")
      {:ok, "https://1337x.to/search/Ubuntu/1/"}
  """
  @spec build_search_url(Parsed.t(), search_opts()) :: {:ok, String.t()} | {:error, Error.t()}
  def build_search_url(%Parsed{} = definition, opts) do
    with {:ok, base_url} <- get_base_url(definition),
         {:ok, path_config} <- select_search_path(definition, opts),
         {:ok, path} <- substitute_template_variables(path_config.path, opts) do
      url = build_full_url(base_url, path)
      {:ok, url}
    end
  end

  @doc """
  Builds request parameters including query params, headers, and method.

  Extracts input parameters from the definition and search options,
  then constructs the final set of query parameters to send.

  ## Returns

  - `{:ok, params}` - Map with :query_params, :headers, :method
  - `{:error, reason}` - Parameter building error

  ## Examples

      iex> definition = %Parsed{search: %{inputs: %{"type" => "search"}}}
      iex> build_request_params(definition, query: "test")
      {:ok, %{query_params: %{"type" => "search"}, headers: [], method: :get}}
  """
  @spec build_request_params(Parsed.t(), search_opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def build_request_params(%Parsed{} = definition, opts) do
    query_params = build_query_params(definition, opts)
    headers = build_headers(definition)
    method = get_http_method(definition, opts)

    params = %{
      query_params: query_params,
      headers: headers,
      method: method
    }

    {:ok, params}
  end

  @doc """
  Executes the HTTP request with proper timeout, headers, and rate limiting.

  Respects the definition's `request_delay` setting for rate limiting,
  handles redirects based on `follow_redirect`, and manages cookies.

  ## Parameters

  - `definition` - Parsed Cardigann definition
  - `url` - Full search URL
  - `request_params` - Request parameters from build_request_params/2
  - `user_config` - User configuration (cookies, credentials)

  ## Returns

  - `{:ok, response}` - HTTP response with status, body, headers
  - `{:error, reason}` - Request execution error

  ## Examples

      iex> params = %{query_params: %{}, headers: [], method: :get}
      iex> {:ok, response} = execute_http_request(definition, url, params, %{})
      iex> response.status
      200
  """
  @spec execute_http_request(Parsed.t(), String.t(), map(), map()) ::
          {:ok, http_response()} | {:error, Error.t()}
  def execute_http_request(%Parsed{} = definition, url, request_params, user_config) do
    # Apply rate limiting if configured
    apply_rate_limit(definition)

    # Build request options
    req_opts = build_request_options(definition, request_params, user_config)

    Logger.debug("Cardigann search request: #{request_params.method} #{url}")
    Logger.debug("Request params: #{inspect(request_params.query_params)}")

    # Execute request based on method
    result =
      case request_params.method do
        :get ->
          Req.get(url, req_opts)

        :post ->
          Req.post(url, req_opts)
      end

    case result do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        response = %{
          status: status,
          body: body,
          headers: headers
        }

        {:ok, response}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @doc """
  Validates the HTTP response before passing to the result parser.

  Checks for common error conditions:
  - Rate limiting (429)
  - Authentication errors (401, 403)
  - Server errors (5xx)
  - Invalid response format

  ## Returns

  - `:ok` - Response is valid and ready for parsing
  - `{:error, reason}` - Response indicates an error

  ## Examples

      iex> validate_response(%{status: 200, body: "<html>...</html>"})
      :ok

      iex> validate_response(%{status: 429, body: "Rate limit exceeded"})
      {:error, %Error{type: :rate_limited}}
  """
  @spec validate_response(http_response()) :: :ok | {:error, Error.t()}
  def validate_response(%{status: status, body: body}) do
    cond do
      status == 200 ->
        :ok

      status == 401 || status == 403 ->
        {:error, Error.connection_failed("Authentication failed")}

      status == 429 ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      status >= 500 ->
        {:error, Error.search_failed("Server error: HTTP #{status}")}

      status >= 400 ->
        Logger.warning("Cardigann search returned HTTP #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      true ->
        Logger.warning("Unexpected HTTP status: #{status}")
        {:error, Error.search_failed("Unexpected status: #{status}")}
    end
  end

  # Private functions

  defp get_base_url(%Parsed{links: [base_url | _]}),
    do: {:ok, String.trim_trailing(base_url, "/")}

  defp get_base_url(%Parsed{links: []}),
    do: {:error, Error.search_failed("No base URL configured")}

  defp select_search_path(%Parsed{search: %{paths: paths}}, opts) do
    categories = Keyword.get(opts, :categories, [])

    # Find the first path that matches the categories, or use the first path
    selected_path =
      if categories != [] do
        # Find a path that matches the categories, or default to first path
        Enum.find(paths, fn path ->
          path_categories = Map.get(path, :categories, [])
          # Match if path has matching categories
          path_categories != [] && Enum.any?(categories, &(&1 in path_categories))
        end) || List.first(paths)
      else
        List.first(paths)
      end

    case selected_path do
      nil -> {:error, Error.search_failed("No search path configured")}
      path -> {:ok, path}
    end
  end

  defp substitute_template_variables(template, opts) do
    query = Keyword.get(opts, :query, "")
    season = Keyword.get(opts, :season)
    episode = Keyword.get(opts, :episode)
    categories = Keyword.get(opts, :categories, [])

    # Use custom encoding that properly encodes all special characters
    # URI.encode/1 doesn't encode & and =, URI.encode_www_form/1 uses + for spaces
    # We need proper percent encoding for URL paths
    encoded_query = percent_encode(query)

    # Build template context
    result =
      template
      |> String.replace("{{ .Keywords }}", encoded_query)
      |> String.replace("{{ .Query.Series }}", encoded_query)
      |> String.replace("{{ .Query.Season }}", to_string(season || ""))
      |> String.replace("{{ .Query.Ep }}", to_string(episode || ""))
      |> String.replace("{{ .Categories }}", Enum.join(categories, ","))

    {:ok, result}
  end

  # Properly percent-encode a string for use in URL paths
  # This encodes all characters except unreserved characters (A-Z, a-z, 0-9, -, _, ., ~)
  defp percent_encode(string) do
    string
    |> String.to_charlist()
    |> Enum.map(fn char ->
      if is_unreserved?(char) do
        <<char>>
      else
        "%" <> Base.encode16(<<char>>, case: :upper)
      end
    end)
    |> Enum.join()
  end

  # Check if a character is unreserved per RFC 3986
  defp is_unreserved?(char) do
    (char >= ?A and char <= ?Z) or
      (char >= ?a and char <= ?z) or
      (char >= ?0 and char <= ?9) or
      char == ?- or
      char == ?_ or
      char == ?. or
      char == ?~
  end

  defp build_full_url(base_url, path) do
    # Ensure proper joining of base URL and path
    path_without_leading_slash = String.trim_leading(path, "/")
    "#{base_url}/#{path_without_leading_slash}"
  end

  defp build_query_params(%Parsed{search: search}, opts) do
    # Start with inputs from the definition
    base_params = Map.get(search, :inputs, %{})

    # Add query-specific parameters
    query = Keyword.get(opts, :query, "")
    categories = Keyword.get(opts, :categories, [])

    # Substitute template variables in input values
    Enum.reduce(base_params, %{}, fn {key, value}, acc ->
      substituted_value =
        case value do
          v when is_binary(v) ->
            v
            |> String.replace("$raw:{{ .Keywords }}", query)
            |> String.replace("{{ .Keywords }}", query)
            |> String.replace("{{ .Categories }}", Enum.join(categories, ","))

          v ->
            v
        end

      Map.put(acc, key, substituted_value)
    end)
  end

  defp build_headers(%Parsed{search: search}) do
    case Map.get(search, :headers) do
      nil -> []
      headers when is_map(headers) -> Map.to_list(headers)
      headers when is_list(headers) -> headers
    end
  end

  defp get_http_method(%Parsed{search: %{paths: paths}}, opts) do
    categories = Keyword.get(opts, :categories, [])

    # Find the selected path's method
    selected_path =
      if categories != [] do
        Enum.find(paths, List.first(paths), fn path ->
          path_categories = Map.get(path, :categories, [])
          path_categories == [] || Enum.any?(categories, &(&1 in path_categories))
        end)
      else
        List.first(paths)
      end

    method_str = Map.get(selected_path || %{}, :method, "get")

    case String.downcase(method_str) do
      "post" -> :post
      _ -> :get
    end
  end

  defp apply_rate_limit(%Parsed{request_delay: nil}), do: :ok

  defp apply_rate_limit(%Parsed{request_delay: delay}) when is_number(delay) do
    # Convert delay to milliseconds if needed (some definitions use seconds)
    delay_ms = if delay < 10, do: trunc(delay * 1000), else: trunc(delay)
    Process.sleep(delay_ms)
    :ok
  end

  defp build_request_options(definition, request_params, user_config) do
    # Base options
    base_opts = [
      headers: request_params.headers,
      receive_timeout: 30_000,
      redirect: definition.follow_redirect,
      retry: false
    ]

    # Add query params for GET, body for POST
    opts_with_params =
      case request_params.method do
        :get ->
          Keyword.put(base_opts, :params, request_params.query_params)

        :post ->
          Keyword.put(base_opts, :form, request_params.query_params)
      end

    # Add cookies if present in user config
    case Map.get(user_config, :cookies) do
      nil ->
        opts_with_params

      cookies when is_list(cookies) ->
        cookie_header = Enum.join(cookies, "; ")
        existing_headers = Keyword.get(opts_with_params, :headers, [])
        updated_headers = [{"Cookie", cookie_header} | existing_headers]
        Keyword.put(opts_with_params, :headers, updated_headers)

      _ ->
        opts_with_params
    end
  end
end
