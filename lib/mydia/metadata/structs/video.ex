defmodule Mydia.Metadata.Structs.Video do
  @moduledoc """
  Represents a video (trailer, teaser, featurette) from TMDB metadata.

  This struct provides compile-time safety for video information from TMDB API
  responses. Videos are typically trailers hosted on YouTube or Vimeo.

  ## YouTube Embed URL

  To embed a YouTube video, use the key to construct the URL:

      https://www.youtube.com/embed/{key}

  For example, a video with key "abc123" would embed as:

      https://www.youtube.com/embed/abc123
  """

  @enforce_keys [:key, :site]

  defstruct [
    :id,
    :key,
    :name,
    :site,
    :type,
    :official,
    :published_at
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t(),
          name: String.t() | nil,
          site: String.t(),
          type: String.t() | nil,
          official: boolean() | nil,
          published_at: DateTime.t() | nil
        }

  @doc """
  Creates a new Video struct from a map or keyword list.

  ## Examples

      iex> new(key: "dQw4w9WgXcQ", site: "YouTube", name: "Official Trailer", type: "Trailer")
      %Video{
        key: "dQw4w9WgXcQ",
        site: "YouTube",
        name: "Official Trailer",
        type: "Trailer",
        official: nil,
        published_at: nil
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Creates a Video struct from a raw TMDB API response map.

  ## Examples

      iex> from_api_response(%{
      ...>   "id" => "123abc",
      ...>   "key" => "dQw4w9WgXcQ",
      ...>   "name" => "Official Trailer",
      ...>   "site" => "YouTube",
      ...>   "type" => "Trailer",
      ...>   "official" => true,
      ...>   "published_at" => "2024-01-15T14:00:00.000Z"
      ...> })
      %Video{
        id: "123abc",
        key: "dQw4w9WgXcQ",
        name: "Official Trailer",
        site: "YouTube",
        type: "Trailer",
        official: true,
        published_at: ~U[2024-01-15 14:00:00Z]
      }
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      key: data["key"],
      name: data["name"],
      site: data["site"],
      type: data["type"],
      official: data["official"],
      published_at: parse_datetime(data["published_at"])
    }
  end

  @doc """
  Returns the YouTube embed URL for this video.

  Returns nil if the video is not hosted on YouTube.

  ## Examples

      iex> video = %Video{key: "dQw4w9WgXcQ", site: "YouTube"}
      iex> youtube_embed_url(video)
      "https://www.youtube.com/embed/dQw4w9WgXcQ"

      iex> video = %Video{key: "abc123", site: "Vimeo"}
      iex> youtube_embed_url(video)
      nil
  """
  def youtube_embed_url(%__MODULE__{site: "YouTube", key: key}) when is_binary(key) do
    "https://www.youtube.com/embed/#{key}"
  end

  def youtube_embed_url(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
