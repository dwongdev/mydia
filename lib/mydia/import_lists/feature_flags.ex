defmodule Mydia.ImportLists.FeatureFlags do
  @moduledoc """
  Helper module for checking Import Lists feature flag.

  This module handles the ENABLE_IMPORT_LISTS feature flag which controls
  whether Import Lists functionality is visible in the UI.

  When enabled, users can configure external lists (like TMDB watchlists)
  to automatically import media into their libraries.

  ## Features Controlled

  - Navigation link to Import Lists in admin menu
  - Import Lists management UI

  ## Configuration

  The feature flag reads from `:mydia, :features, :import_lists_enabled`
  configuration and defaults to `false` (disabled).

  Set via environment variable:
  - `ENABLE_IMPORT_LISTS=true` - Enable Import Lists UI
  - `ENABLE_IMPORT_LISTS=false` - Disable Import Lists UI (default)
  """

  @doc """
  Returns true if Import Lists functionality is enabled, false otherwise.

  Reads from the :import_lists_enabled configuration under the :features key.

  ## Examples

      iex> Mydia.ImportLists.FeatureFlags.enabled?()
      false

      # After setting ENABLE_IMPORT_LISTS=true environment variable
      iex> Mydia.ImportLists.FeatureFlags.enabled?()
      true

  """
  def enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:import_lists_enabled, false)
  end
end
