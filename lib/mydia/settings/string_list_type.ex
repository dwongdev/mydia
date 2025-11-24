defmodule Mydia.Settings.StringListType do
  @moduledoc """
  Custom Ecto type for storing a list of strings as JSON in a text column.

  This type allows storing lists of strings in databases that don't support
  native array types (like SQLite) or when using a text column instead of
  a native array type.

  ## Usage
  In your schema:

      schema "my_table" do
        field :tags, Mydia.Settings.StringListType
      end

  When you load a record from the database, the field will automatically
  be a list of strings instead of raw JSON text.
  """

  use Ecto.Type

  @doc """
  Returns the underlying database type (:string for text columns).
  """
  def type, do: :string

  @doc """
  Casts the given value to a list of strings.

  Accepts:
  - List of strings (validates all elements are strings)
  - nil (returns empty list or nil depending on context)
  """
  def cast(nil), do: {:ok, []}
  def cast([]), do: {:ok, []}

  def cast(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      :error
    end
  end

  def cast(_), do: :error

  @doc """
  Loads data from the database (JSON string) and converts to a list of strings.
  """
  def load(nil), do: {:ok, []}
  def load(""), do: {:ok, []}

  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "Expected a list of strings"}
        end

      {:ok, _} ->
        {:error, "Expected a JSON array"}

      {:error, _} ->
        {:error, "Invalid JSON"}
    end
  end

  # Handle case where data is already a list (some adapters may do this)
  def load(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      {:error, "Expected a list of strings"}
    end
  end

  def load(_), do: :error

  @doc """
  Dumps a list of strings to a JSON string for database storage.
  """
  def dump(nil), do: {:ok, "[]"}
  def dump([]), do: {:ok, "[]"}

  def dump(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, Jason.encode!(list)}
    else
      :error
    end
  end

  def dump(_), do: :error

  @doc """
  Compares two values for equality.
  """
  def equal?(list1, list2), do: list1 == list2

  @doc """
  Embeds the type as a parameter in queries.
  """
  def embed_as(_), do: :dump
end
