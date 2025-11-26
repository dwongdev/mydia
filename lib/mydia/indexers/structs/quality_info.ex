defmodule Mydia.Indexers.Structs.QualityInfo do
  @moduledoc """
  Represents quality information extracted from torrent release titles.

  This struct provides compile-time safety for quality data parsed from
  indexer search results. It includes release-specific flags like PROPER
  and REPACK that are important for ranking and selection.

  ## HDR Format Tiers (per TRaSH Guides)

  HDR formats are ranked in order of preference:
  - "DV" (Dolby Vision) - highest quality, includes fallback layer
  - "HDR10+" (HDR10 Plus) - dynamic metadata
  - "HDR10" - static metadata HDR
  - nil (SDR) - standard dynamic range

  ## Audio Codec Tiers (per TRaSH Guides)

  Audio codecs detected and ranked:
  - "TrueHD Atmos" - highest quality lossless with object audio
  - "TrueHD" - lossless audio
  - "DTS-HD MA" - lossless DTS
  - "DTS-HD" - high quality DTS
  - "DD+" (Dolby Digital Plus) - lossy but good
  - "DTS" - standard DTS
  - "AC3" (Dolby Digital) - standard lossy
  - "AAC" - compressed audio
  - "MP3" - lowest quality

  ## Examples

      iex> QualityInfo.new(
      ...>   resolution: "1080p",
      ...>   source: "BluRay",
      ...>   codec: "x264",
      ...>   hdr: false,
      ...>   hdr_format: nil,
      ...>   proper: false,
      ...>   repack: false
      ...> )
      %QualityInfo{...}
  """

  defstruct [
    :resolution,
    :source,
    :codec,
    :audio,
    :hdr,
    :hdr_format,
    :proper,
    :repack
  ]

  @type hdr_format :: String.t() | nil
  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil,
          hdr: boolean(),
          hdr_format: hdr_format(),
          proper: boolean(),
          repack: boolean()
        }

  @doc """
  Creates a new QualityInfo struct.

  ## Examples

      iex> new(resolution: "1080p", source: "BluRay")
      %QualityInfo{resolution: "1080p", source: "BluRay", codec: nil, audio: nil, hdr: false, hdr_format: nil, proper: false, repack: false}

      iex> new(%{resolution: "2160p", hdr: true, hdr_format: "DV", proper: true})
      %QualityInfo{resolution: "2160p", source: nil, codec: nil, audio: nil, hdr: true, hdr_format: "DV", proper: true, repack: false}
  """
  def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
    # Ensure boolean fields have defaults
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:hdr, false)
      |> Map.put_new(:hdr_format, nil)
      |> Map.put_new(:proper, false)
      |> Map.put_new(:repack, false)

    struct(__MODULE__, attrs)
  end

  @doc """
  Returns an empty QualityInfo struct with all flags set to false.
  """
  def empty do
    %__MODULE__{
      hdr: false,
      hdr_format: nil,
      proper: false,
      repack: false
    }
  end

  @doc """
  Checks if a QualityInfo struct is empty (all fields except flags are nil).
  """
  def empty?(%__MODULE__{} = quality) do
    quality.resolution == nil &&
      quality.source == nil &&
      quality.codec == nil &&
      quality.audio == nil
  end
end
