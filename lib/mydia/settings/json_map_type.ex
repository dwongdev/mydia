defmodule Mydia.Settings.JsonMapType do
  @moduledoc """
  Custom Ecto type for storing a map as JSON in a text column.

  This type allows storing maps in databases when using a text column instead of
  a native JSON/JSONB type. Works with both SQLite (which stores as text) and
  PostgreSQL (when the column is defined as text instead of jsonb).

  ## Usage
  In your schema:

      schema "my_table" do
        field :settings, Mydia.Settings.JsonMapType
      end

  When you load a record from the database, the field will automatically
  be a map instead of raw JSON text.
  """

  use Ecto.Type

  @doc """
  Returns the underlying database type (:string for text columns).
  """
  def type, do: :string

  @doc """
  Casts the given value to a map.

  Accepts:
  - Map (returns as-is)
  - nil (returns empty map or nil depending on context)
  """
  def cast(nil), do: {:ok, %{}}
  def cast(map) when is_map(map), do: {:ok, map}
  def cast(_), do: :error

  @doc """
  Loads data from the database (JSON string) and converts to a map.
  """
  def load(nil), do: {:ok, %{}}
  def load(""), do: {:ok, %{}}

  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "Expected a JSON object"}
      {:error, _} -> {:error, "Invalid JSON"}
    end
  end

  # Handle case where data is already a map (some adapters may do this)
  def load(map) when is_map(map), do: {:ok, map}
  def load(_), do: :error

  @doc """
  Dumps a map to a JSON string for database storage.
  """
  def dump(nil), do: {:ok, "{}"}
  def dump(map) when map == %{}, do: {:ok, "{}"}

  def dump(map) when is_map(map) do
    {:ok, Jason.encode!(map)}
  end

  def dump(_), do: :error

  @doc """
  Compares two values for equality.
  """
  def equal?(map1, map2), do: map1 == map2

  @doc """
  Embeds the type as a parameter in queries.
  """
  def embed_as(_), do: :dump
end
