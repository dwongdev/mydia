defmodule Mydia.Downloads.Client.Registry do
  @moduledoc """
  Registry for download client adapters.

  This module provides a centralized way to register and retrieve download
  client adapter modules based on client type. It allows runtime selection
  of the appropriate adapter implementation.

  ## Usage

      # Register an adapter
      Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)

      # Get an adapter module
      {:ok, adapter} = Registry.get_adapter(:qbittorrent)

      # List all registered adapters
      adapters = Registry.list_adapters()
      # => [qbittorrent: Mydia.Downloads.Client.QBittorrent, ...]

      # Check if an adapter is registered
      Registry.registered?(:qbittorrent)
      # => true

  ## Default Adapters

  The registry comes pre-configured with adapters for common download clients:

    * `:qbittorrent` - qBittorrent Web API adapter
    * `:transmission` - Transmission RPC adapter

  Additional adapters can be registered at runtime or during application startup.

  ## Configuration-based adapter selection

  You can use this module to dynamically select adapters based on configuration:

      defmodule MyApp.Downloads do
        alias Mydia.Downloads.Client.Registry

        def add_torrent(client_config, torrent, opts \\\\ []) do
          with {:ok, adapter} <- Registry.get_adapter(client_config.type) do
            adapter.add_torrent(client_config, torrent, opts)
          end
        end
      end
  """

  use Agent

  alias Mydia.Downloads.Client.Error

  @type adapter_type :: atom()
  @type adapter_module :: module()

  @doc """
  Starts the registry agent.

  This is typically called during application startup.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a download client adapter.

  ## Examples

      iex> Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      :ok

      iex> Registry.register(:custom_client, MyApp.CustomAdapter)
      :ok
  """
  @spec register(adapter_type(), adapter_module()) :: :ok
  def register(type, adapter_module) when is_atom(type) and is_atom(adapter_module) do
    Agent.update(__MODULE__, &Map.put(&1, type, adapter_module))
  end

  @doc """
  Gets the adapter module for a given client type.

  Returns `{:ok, module}` if the adapter is registered, or `{:error, error}`
  if the adapter type is not found.

  ## Examples

      iex> Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      iex> Registry.get_adapter(:qbittorrent)
      {:ok, Mydia.Downloads.Client.QBittorrent}

      iex> Registry.get_adapter(:unknown_client)
      {:error, %Error{type: :invalid_config, message: "Unknown client type: unknown_client"}}
  """
  @spec get_adapter(adapter_type()) :: {:ok, adapter_module()} | {:error, Error.t()}
  def get_adapter(type) when is_atom(type) do
    case Agent.get(__MODULE__, &Map.get(&1, type)) do
      nil ->
        {:error, Error.invalid_config("Unknown client type: #{type}")}

      adapter_module ->
        {:ok, adapter_module}
    end
  end

  @doc """
  Gets the adapter module for a given client type, raising if not found.

  ## Examples

      iex> Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      iex> Registry.get_adapter!(:qbittorrent)
      Mydia.Downloads.Client.QBittorrent

      iex> Registry.get_adapter!(:unknown_client)
      ** (Mydia.Downloads.Client.Error) Invalid config: Unknown client type: unknown_client
  """
  @spec get_adapter!(adapter_type()) :: adapter_module()
  def get_adapter!(type) when is_atom(type) do
    case get_adapter(type) do
      {:ok, adapter} -> adapter
      {:error, error} -> raise error
    end
  end

  @doc """
  Lists all registered adapters.

  Returns a keyword list of adapter types and their corresponding modules.

  ## Examples

      iex> Registry.list_adapters()
      [qbittorrent: Mydia.Downloads.Client.QBittorrent, transmission: Mydia.Downloads.Client.Transmission]
  """
  @spec list_adapters() :: [{adapter_type(), adapter_module()}]
  def list_adapters do
    Agent.get(__MODULE__, &Map.to_list/1)
  end

  @doc """
  Checks if an adapter is registered for the given type.

  ## Examples

      iex> Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      iex> Registry.registered?(:qbittorrent)
      true

      iex> Registry.registered?(:unknown_client)
      false
  """
  @spec registered?(adapter_type()) :: boolean()
  def registered?(type) when is_atom(type) do
    Agent.get(__MODULE__, &Map.has_key?(&1, type))
  end

  @doc """
  Unregisters an adapter.

  This is primarily useful for testing or hot-reloading adapter implementations.

  ## Examples

      iex> Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      iex> Registry.unregister(:qbittorrent)
      :ok
      iex> Registry.registered?(:qbittorrent)
      false
  """
  @spec unregister(adapter_type()) :: :ok
  def unregister(type) when is_atom(type) do
    Agent.update(__MODULE__, &Map.delete(&1, type))
  end

  @doc """
  Clears all registered adapters.

  This is primarily useful for testing.

  ## Examples

      iex> Registry.clear()
      :ok
  """
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end
