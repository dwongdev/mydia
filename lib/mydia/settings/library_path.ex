defmodule Mydia.Settings.LibraryPath do
  @moduledoc """
  Schema for library paths that should be monitored for media files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Media.MediaCategory

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @path_types [:movies, :series, :mixed, :music, :books, :adult]
  @scan_statuses [:success, :failed, :in_progress]

  schema "library_paths" do
    field :path, :string
    field :type, Ecto.Enum, values: @path_types
    field :monitored, :boolean, default: true
    field :scan_interval, :integer, default: 3600
    field :last_scan_at, :utc_datetime
    field :last_scan_status, Ecto.Enum, values: @scan_statuses
    field :last_scan_error, :string
    # Tracks if this library path was created from environment variables
    field :from_env, :boolean, default: false
    # Controls whether the library path is hidden from the UI
    field :disabled, :boolean, default: false
    # Map of category -> relative path for auto-organization
    field :category_paths, :map, default: %{}
    # Enable/disable auto-organization for this library
    field :auto_organize, :boolean, default: false

    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a library path.
  """
  def changeset(library_path, attrs) do
    library_path
    |> cast(attrs, [
      :path,
      :type,
      :monitored,
      :scan_interval,
      :last_scan_at,
      :last_scan_status,
      :last_scan_error,
      :quality_profile_id,
      :updated_by_id,
      :from_env,
      :disabled,
      :category_paths,
      :auto_organize
    ])
    |> validate_required([:path, :type])
    |> validate_inclusion(:type, @path_types)
    |> validate_number(:scan_interval, greater_than: 0)
    |> validate_category_paths()
    |> unique_constraint(:path)
  end

  @doc """
  Validates that category_paths keys are valid MediaCategory values.
  """
  def validate_category_paths(changeset) do
    case get_change(changeset, :category_paths) do
      nil ->
        changeset

      category_paths when is_map(category_paths) ->
        invalid_keys =
          category_paths
          |> Map.keys()
          |> Enum.reject(&valid_category_key?/1)

        if invalid_keys == [] do
          changeset
        else
          add_error(
            changeset,
            :category_paths,
            "contains invalid category keys: #{Enum.join(invalid_keys, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :category_paths, "must be a map")
    end
  end

  defp valid_category_key?(key) when is_binary(key) do
    # Use MediaCategory.all() to check if the string matches a valid category
    # This avoids issues with String.to_existing_atom when the atom isn't loaded yet
    valid_keys = MediaCategory.all() |> Enum.map(&Atom.to_string/1)
    key in valid_keys
  end

  defp valid_category_key?(key) when is_atom(key), do: MediaCategory.valid?(key)
  defp valid_category_key?(_), do: false

  @doc """
  Resolves the full destination path for a media item based on its category.

  If the library has auto_organize enabled and a category path is configured
  for the given category, returns: library_path / category_path / media_folder

  Otherwise returns: library_path / media_folder

  ## Examples

      iex> library = %LibraryPath{path: "/media/movies", category_paths: %{"anime_movie" => "Anime"}, auto_organize: true}
      iex> resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      "/media/movies/Anime/Spirited Away (2001)"

      iex> library = %LibraryPath{path: "/media/movies", category_paths: %{}, auto_organize: false}
      iex> resolve_category_path(library, :movie, "The Matrix (1999)")
      "/media/movies/The Matrix (1999)"
  """
  @spec resolve_category_path(%__MODULE__{}, atom() | String.t(), String.t()) :: String.t()
  def resolve_category_path(%__MODULE__{} = library_path, category, media_folder) do
    category_key = if is_atom(category), do: Atom.to_string(category), else: category

    category_subpath =
      if library_path.auto_organize do
        Map.get(library_path.category_paths || %{}, category_key)
      end

    case category_subpath do
      nil -> Path.join(library_path.path, media_folder)
      subpath -> Path.join([library_path.path, subpath, media_folder])
    end
  end
end
