defmodule Mydia.Collections.Collection do
  @moduledoc """
  Schema for collections that organize media items.

  Collections can be either:
  - **Manual**: User-curated lists where items are explicitly added and can be reordered
  - **Smart**: Rule-based collections that auto-populate based on filter criteria

  ## Visibility

  - `private`: Only visible to the owner
  - `shared`: Visible to all users (admin only can create)

  ## System Collections

  Collections with `is_system: true` are automatically created (e.g., Favorites) and cannot be deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type_values ~w(manual smart)
  @visibility_values ~w(private shared)
  @sort_order_values ~w(position title year added_date rating)

  schema "collections" do
    field :name, :string
    field :description, :string
    field :type, :string, default: "manual"
    field :poster_path, :string
    field :sort_order, :string, default: "position"
    field :smart_rules, :string
    field :visibility, :string, default: "private"
    field :is_system, :boolean, default: false
    field :position, :integer, default: 0

    belongs_to :user, Mydia.Accounts.User
    has_many :collection_items, Mydia.Collections.CollectionItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a collection.
  """
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :poster_path,
      :sort_order,
      :smart_rules,
      :visibility,
      :position
    ])
    |> validate_required([:name, :type, :visibility])
    |> validate_inclusion(:type, @type_values)
    |> validate_inclusion(:visibility, @visibility_values)
    |> validate_inclusion(:sort_order, @sort_order_values)
    |> validate_smart_rules()
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for creating a system collection (e.g., Favorites).
  """
  def system_changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :type, :is_system])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @type_values)
    |> put_change(:visibility, "private")
    |> put_change(:is_system, true)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Returns the list of valid type values.
  """
  def valid_types, do: @type_values

  @doc """
  Returns the list of valid visibility values.
  """
  def valid_visibility_values, do: @visibility_values

  @doc """
  Returns the list of valid sort order values.
  """
  def valid_sort_orders, do: @sort_order_values

  # Validates that smart_rules is valid JSON when type is "smart"
  defp validate_smart_rules(changeset) do
    type = get_field(changeset, :type)
    smart_rules = get_change(changeset, :smart_rules)

    cond do
      type == "smart" && is_nil(smart_rules) && is_nil(get_field(changeset, :smart_rules)) ->
        add_error(changeset, :smart_rules, "is required for smart collections")

      type == "smart" && is_binary(smart_rules) ->
        case Jason.decode(smart_rules) do
          {:ok, _decoded} -> changeset
          {:error, _} -> add_error(changeset, :smart_rules, "must be valid JSON")
        end

      type == "manual" && not is_nil(smart_rules) ->
        add_error(changeset, :smart_rules, "should not be set for manual collections")

      true ->
        changeset
    end
  end
end
