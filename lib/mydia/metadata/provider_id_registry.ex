defmodule Mydia.Metadata.ProviderIDRegistry do
  @moduledoc """
  Registry for tracking provider ID to media type mappings.

  This module prevents 404 errors caused by using the wrong media type with a provider ID.
  For example, trying to fetch a TV show ID (like 456 for The Simpsons) as a movie.

  When a successful metadata fetch occurs, the ID→type mapping is recorded.
  Before making a fetch request, we check if the ID is known to belong to a different type
  and skip the invalid request.

  ## Examples

      # Record a successful fetch
      ProviderIDRegistry.record_id_type("456", :tmdb, :tv_show)

      # Check before fetching
      case ProviderIDRegistry.validate_id_type("456", :tmdb, :movie) do
        :ok -> # Safe to fetch
        {:error, :type_mismatch, actual_type} -> # Skip fetch, log warning
      end
  """

  use GenServer
  require Logger

  @table_name :provider_id_registry

  @doc """
  Starts the registry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a provider ID with its confirmed media type.

  This should be called after a successful metadata fetch (HTTP 200 response).

  ## Parameters
    - `provider_id` - The provider-specific ID (e.g., "456")
    - `provider` - Provider atom (e.g., :tmdb, :tvdb)
    - `media_type` - Media type atom (e.g., :movie, :tv_show)

  ## Examples

      iex> ProviderIDRegistry.record_id_type("603", :tmdb, :movie)
      :ok
  """
  def record_id_type(provider_id, provider, media_type)
      when is_binary(provider_id) and is_atom(provider) and is_atom(media_type) do
    key = {provider_id, provider}
    :ets.insert(@table_name, {key, media_type})
    :ok
  end

  @doc """
  Validates that a provider ID can be fetched with the given media type.

  Returns `:ok` if:
  - The ID is unknown (first time fetch)
  - The ID's known type matches the requested type

  Returns `{:error, :type_mismatch, actual_type}` if:
  - The ID is known to belong to a different media type

  ## Parameters
    - `provider_id` - The provider-specific ID (e.g., "456")
    - `provider` - Provider atom (e.g., :tmdb, :tvdb)
    - `media_type` - Requested media type atom (e.g., :movie, :tv_show)

  ## Examples

      iex> ProviderIDRegistry.record_id_type("456", :tmdb, :tv_show)
      iex> ProviderIDRegistry.validate_id_type("456", :tmdb, :movie)
      {:error, :type_mismatch, :tv_show}

      iex> ProviderIDRegistry.validate_id_type("999", :tmdb, :movie)
      :ok
  """
  def validate_id_type(provider_id, provider, media_type)
      when is_binary(provider_id) and is_atom(provider) and is_atom(media_type) do
    key = {provider_id, provider}

    case :ets.lookup(@table_name, key) do
      [{^key, ^media_type}] ->
        # Known ID, correct type
        :ok

      [{^key, known_type}] ->
        # Known ID, wrong type
        {:error, :type_mismatch, known_type}

      [] ->
        # Unknown ID, allow fetch
        :ok
    end
  end

  @doc """
  Gets the known media type for a provider ID, if any.

  Returns `{:ok, media_type}` if the ID is known, or `{:error, :not_found}` otherwise.

  ## Examples

      iex> ProviderIDRegistry.record_id_type("456", :tmdb, :tv_show)
      iex> ProviderIDRegistry.get_known_type("456", :tmdb)
      {:ok, :tv_show}

      iex> ProviderIDRegistry.get_known_type("999", :tmdb)
      {:error, :not_found}
  """
  def get_known_type(provider_id, provider)
      when is_binary(provider_id) and is_atom(provider) do
    key = {provider_id, provider}

    case :ets.lookup(@table_name, key) do
      [{^key, media_type}] -> {:ok, media_type}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Clears all entries from the registry.

  This is primarily useful for testing.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("Provider ID registry started")
    {:ok, %{}}
  end
end
