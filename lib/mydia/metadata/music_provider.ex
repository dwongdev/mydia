defmodule Mydia.Metadata.MusicProvider do
  @moduledoc """
  Behaviour for music metadata provider adapters.
  """

  alias Mydia.Metadata.Provider.Error

  @type config :: map()

  @callback search_artist(config(), query :: String.t(), opts :: Keyword.t()) ::
              {:ok, [map()]} | {:error, Error.t()}

  @callback search_release(config(), query :: String.t(), opts :: Keyword.t()) ::
              {:ok, [map()]} | {:error, Error.t()}

  @callback get_artist(config(), mbid :: String.t()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback get_release(config(), mbid :: String.t()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback get_release_group(config(), mbid :: String.t()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback get_recording(config(), mbid :: String.t()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback get_cover_art(config(), release_mbid :: String.t()) ::
              {:ok, binary()} | {:error, Error.t()}
end
