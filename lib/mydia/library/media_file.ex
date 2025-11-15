defmodule Mydia.Library.MediaFile do
  @moduledoc """
  Schema for media files (multiple versions support).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_files" do
    field :path, :string
    field :size, :integer
    field :resolution, :string
    field :codec, :string
    field :hdr_format, :string
    field :audio_codec, :string
    field :bitrate, :integer
    field :verified_at, :utc_datetime
    field :metadata, :map

    # Relative path storage (Phase 1)
    field :relative_path, :string
    belongs_to :library_path, Mydia.Settings.LibraryPath

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode
    belongs_to :quality_profile, Mydia.Settings.QualityProfile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a media file.
  """
  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :quality_profile_id,
      :path,
      :size,
      :resolution,
      :codec,
      :hdr_format,
      :audio_codec,
      :bitrate,
      :verified_at,
      :metadata
    ])
    |> validate_required([:path])
    |> validate_one_parent()
    |> validate_library_type_compatibility()
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:bitrate, greater_than: 0)
    |> unique_constraint(:path)
    |> check_constraint(:media_item_id,
      name: :media_files_parent_check,
      message: "cannot set both media_item_id and episode_id"
    )
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:quality_profile_id)
  end

  @doc """
  Changeset for creating a media file during library scanning.
  Parent association (media_item_id or episode_id) is optional during initial creation
  and will be set later during metadata enrichment.
  """
  def scan_changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :quality_profile_id,
      :path,
      :size,
      :resolution,
      :codec,
      :hdr_format,
      :audio_codec,
      :bitrate,
      :verified_at,
      :metadata
    ])
    |> validate_required([:path])
    |> validate_parent_exclusivity()
    |> validate_library_type_compatibility()
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:bitrate, greater_than: 0)
    |> unique_constraint(:path)
    |> check_constraint(:media_item_id,
      name: :media_files_parent_check,
      message: "cannot set both media_item_id and episode_id"
    )
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:quality_profile_id)
  end

  # Ensure either media_item_id or episode_id is set, but not both
  defp validate_one_parent(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)

    cond do
      is_nil(media_item_id) and is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "either media_item_id or episode_id must be set")

      not is_nil(media_item_id) and not is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "cannot set both media_item_id and episode_id")

      true ->
        changeset
    end
  end

  # Ensure both media_item_id and episode_id are not set at the same time
  # (allows both to be nil for orphaned files during scanning)
  defp validate_parent_exclusivity(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)

    if not is_nil(media_item_id) and not is_nil(episode_id) do
      add_error(changeset, :media_item_id, "cannot set both media_item_id and episode_id")
    else
      changeset
    end
  end

  # Validates that the media type is compatible with the library path type
  defp validate_library_type_compatibility(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)
    path = get_field(changeset, :path)

    # Skip validation if path is missing (will be caught by validate_required)
    # or if neither parent association is set (orphaned file)
    if is_nil(path) or (is_nil(media_item_id) and is_nil(episode_id)) do
      changeset
    else
      validate_media_type_against_library_path(changeset, path, media_item_id, episode_id)
    end
  end

  defp validate_media_type_against_library_path(changeset, file_path, media_item_id, episode_id) do
    library_path = find_library_path_for_file(file_path)

    cond do
      # If no library path found, allow the operation
      # (file might be outside configured library paths)
      is_nil(library_path) ->
        changeset

      # If library is :mixed, allow both types
      library_path.type == :mixed ->
        changeset

      # Movie in :series library
      not is_nil(media_item_id) and library_path.type == :series ->
        media_type = get_media_type_for_item(media_item_id)

        if media_type == "movie" do
          add_error(
            changeset,
            :media_item_id,
            "cannot add movies to a library path configured for TV series only (path: #{library_path.path})"
          )
        else
          changeset
        end

      # TV show in :movies library
      not is_nil(episode_id) and library_path.type == :movies ->
        add_error(
          changeset,
          :episode_id,
          "cannot add TV episodes to a library path configured for movies only (path: #{library_path.path})"
        )

      # All other cases are valid
      true ->
        changeset
    end
  end

  # Finds the library path that contains the given file path
  # Prefers the longest matching prefix (most specific path)
  defp find_library_path_for_file(file_path) do
    library_paths = Mydia.Settings.list_library_paths()

    library_paths
    |> Enum.filter(fn library_path ->
      String.starts_with?(file_path, library_path.path)
    end)
    |> Enum.max_by(
      fn library_path -> String.length(library_path.path) end,
      fn -> nil end
    )
  end

  # Gets the media type (movie or tv_show) for a media item by ID
  defp get_media_type_for_item(media_item_id) do
    case Mydia.Repo.get(Mydia.Media.MediaItem, media_item_id) do
      nil -> nil
      media_item -> media_item.type
    end
  end
end
