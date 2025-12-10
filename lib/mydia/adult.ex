defmodule Mydia.Adult do
  @moduledoc """
  The Adult context handles adult content library functionality including studios, scenes, and files.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Adult.{Studio, Scene, AdultFile}

  ## Studios

  @doc """
  Returns the list of studios.

  ## Options
    - `:preload` - List of associations to preload
    - `:search` - Search term for filtering by name
  """
  def list_studios(opts \\ []) do
    Studio
    |> apply_studio_filters(opts)
    |> order_by([s], asc: fragment("COALESCE(?, ?)", s.sort_name, s.name))
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single studio.

  Raises `Ecto.NoResultsError` if the Studio does not exist.
  """
  def get_studio!(id, opts \\ []) do
    Studio
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a studio by name.
  """
  def get_studio_by_name(name) do
    Repo.get_by(Studio, name: name)
  end

  @doc """
  Creates a studio.
  """
  def create_studio(attrs \\ %{}) do
    %Studio{}
    |> Studio.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a studio.
  """
  def update_studio(%Studio{} = studio, attrs) do
    studio
    |> Studio.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a studio.
  """
  def delete_studio(%Studio{} = studio) do
    Repo.delete(studio)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking studio changes.
  """
  def change_studio(%Studio{} = studio, attrs \\ %{}) do
    Studio.changeset(studio, attrs)
  end

  ## Scenes

  @doc """
  Returns the list of scenes.

  ## Options
    - `:preload` - List of associations to preload
    - `:studio_id` - Filter by studio ID
    - `:search` - Search term for filtering by title
    - `:monitored` - Filter by monitored status
  """
  def list_scenes(opts \\ []) do
    Scene
    |> apply_scene_filters(opts)
    |> order_by([s], desc: s.release_date, asc: s.title)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Returns the count of scenes.
  """
  def count_scenes(opts \\ []) do
    Scene
    |> apply_scene_filters(opts)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Gets a single scene.

  Raises `Ecto.NoResultsError` if the Scene does not exist.
  """
  def get_scene!(id, opts \\ []) do
    Scene
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a scene.
  """
  def create_scene(attrs \\ %{}) do
    %Scene{}
    |> Scene.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a scene.
  """
  def update_scene(%Scene{} = scene, attrs) do
    scene
    |> Scene.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a scene.
  """
  def delete_scene(%Scene{} = scene) do
    Repo.delete(scene)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking scene changes.
  """
  def change_scene(%Scene{} = scene, attrs \\ %{}) do
    Scene.changeset(scene, attrs)
  end

  ## Adult Files

  @doc """
  Returns the list of adult files.

  ## Options
    - `:preload` - List of associations to preload
    - `:scene_id` - Filter by scene ID
    - `:library_path_id` - Filter by library path ID
  """
  def list_adult_files(opts \\ []) do
    AdultFile
    |> apply_adult_file_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single adult file.

  Raises `Ecto.NoResultsError` if the AdultFile does not exist.
  """
  def get_adult_file!(id, opts \\ []) do
    AdultFile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets an adult file by path.
  """
  def get_adult_file_by_path(path) do
    Repo.get_by(AdultFile, path: path)
  end

  @doc """
  Creates an adult file.
  """
  def create_adult_file(attrs \\ %{}) do
    %AdultFile{}
    |> AdultFile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an adult file.
  """
  def update_adult_file(%AdultFile{} = adult_file, attrs) do
    adult_file
    |> AdultFile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an adult file.
  """
  def delete_adult_file(%AdultFile{} = adult_file) do
    Repo.delete(adult_file)
  end

  @doc """
  Deletes adult files by library path ID that are not in the given paths list.
  Returns the count of deleted files.
  """
  def delete_missing_adult_files(library_path_id, current_paths) do
    from(f in AdultFile,
      where: f.library_path_id == ^library_path_id,
      where: f.path not in ^current_paths
    )
    |> Repo.delete_all()
  end

  ## Helper Functions

  defp apply_studio_filters(query, opts) do
    query
    |> filter_by_search(opts[:search], :name)
  end

  defp apply_scene_filters(query, opts) do
    query
    |> filter_by_studio_id(opts[:studio_id])
    |> filter_by_monitored(opts[:monitored])
    |> filter_by_search(opts[:search], :title)
  end

  defp apply_adult_file_filters(query, opts) do
    query
    |> filter_by_scene_id(opts[:scene_id])
    |> filter_by_library_path_id(opts[:library_path_id])
  end

  defp filter_by_search(query, nil, _field), do: query

  defp filter_by_search(query, search, field) do
    search_term = "%#{String.downcase(search)}%"
    where(query, [q], fragment("LOWER(?) LIKE ?", field(q, ^field), ^search_term))
  end

  defp filter_by_studio_id(query, nil), do: query
  defp filter_by_studio_id(query, studio_id), do: where(query, [q], q.studio_id == ^studio_id)

  defp filter_by_scene_id(query, nil), do: query
  defp filter_by_scene_id(query, scene_id), do: where(query, [q], q.scene_id == ^scene_id)

  defp filter_by_library_path_id(query, nil), do: query

  defp filter_by_library_path_id(query, library_path_id),
    do: where(query, [q], q.library_path_id == ^library_path_id)

  defp filter_by_monitored(query, nil), do: query
  defp filter_by_monitored(query, monitored), do: where(query, [q], q.monitored == ^monitored)

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
