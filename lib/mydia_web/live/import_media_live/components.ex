defmodule MydiaWeb.ImportMediaLive.Components do
  @moduledoc """
  Reusable UI components for the Import Media workflow.

  These components break down the import media interface into smaller,
  focused, and testable pieces. Each component is a pure presentation
  function with clearly defined attributes.
  """

  use Phoenix.Component
  import MydiaWeb.CoreComponents

  @doc """
  Renders the progress steps indicator for the import wizard.

  ## Attributes
    * `:step` - Current step (one of: `:select_path`, `:review`, `:importing`, `:complete`)
  """
  attr :step, :atom, required: true

  def progress_steps(assigns) do
    ~H"""
    <ul class="steps steps-horizontal w-full text-xs">
      <li class={"step step-sm " <> if(@step in [:select_path, :review, :importing, :complete], do: "step-primary", else: "")}>
        Select Path
      </li>
      <li class={"step step-sm " <> if(@step in [:review, :importing, :complete], do: "step-primary", else: "")}>
        Review Matches
      </li>
      <li class={"step step-sm " <> if(@step in [:importing, :complete], do: "step-primary", else: "")}>
        Import
      </li>
      <li class={"step step-sm " <> if(@step == :complete, do: "step-primary", else: "")}>
        Complete
      </li>
    </ul>
    """
  end

  @doc """
  Renders the path selection screen where users choose a directory to scan.

  ## Attributes
    * `:scan_path` - Current path value
    * `:library_paths` - List of available library paths
    * `:show_path_suggestions` - Whether to show path autocomplete suggestions
    * `:path_suggestions` - List of path suggestions for autocomplete
  """
  attr :scan_path, :string, required: true
  attr :library_paths, :list, default: []
  attr :show_path_suggestions, :boolean, default: false
  attr :path_suggestions, :list, default: []

  def path_selection_screen(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Select Directory to Scan</h2>
        <p class="text-sm text-base-content/70 mb-3">
          Enter a filesystem path or choose from your configured library paths.
        </p>

        <%!-- Manual Path Input --%>
        <div class="bg-base-200/30 rounded-lg p-3 mb-3">
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-pencil-square" class="w-4 h-4 text-base-content/70" />
            <span class="text-sm font-medium">Custom Path</span>
          </div>
          <form phx-change="autocomplete_path">
            <div class="relative">
              <input
                type="text"
                name="path"
                id="path-input"
                placeholder="/path/to/media/folder"
                class="input input-bordered w-full"
                value={@scan_path}
                phx-debounce="300"
                autocomplete="off"
                phx-hook="PathAutocomplete"
              />
              <%= if @show_path_suggestions and @path_suggestions != [] do %>
                <div
                  class="absolute z-10 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-48 overflow-y-auto"
                  id="path-suggestions"
                  phx-click-away="hide_path_suggestions"
                >
                  <%= for suggestion <- @path_suggestions do %>
                    <div
                      class="w-full text-left px-3 py-2 text-sm hover:bg-base-200 border-b border-base-300 last:border-b-0 flex items-center gap-2 cursor-pointer"
                      phx-click="select_path_suggestion"
                      phx-value-path={suggestion}
                    >
                      <.icon name="hero-folder" class="w-4 h-4 text-primary" />
                      <span class="font-mono truncate">{suggestion}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </form>
        </div>

        <%!-- Quick Select from Library Paths --%>
        <%= if @library_paths != [] do %>
          <div class="bg-primary/5 rounded-lg p-3">
            <div class="flex items-center gap-2 mb-2">
              <.icon name="hero-folder-open" class="w-4 h-4 text-primary" />
              <span class="text-sm font-medium text-primary">Library Paths</span>
            </div>
            <div class="flex flex-col gap-1.5">
              <%= for path <- @library_paths do %>
                <button
                  type="button"
                  class="btn btn-sm btn-outline justify-start hover:btn-primary"
                  phx-click="select_library_path"
                  phx-value-path_id={path.id}
                >
                  <.icon name="hero-folder" class="w-4 h-4" />
                  <span class="flex-1 text-left font-mono text-xs">{path.path}</span>
                  <span class="badge badge-primary badge-sm">{path.type}</span>
                </button>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="card-actions justify-end mt-4">
          <button
            type="button"
            class="btn btn-primary"
            phx-click="start_scan"
            disabled={String.trim(@scan_path) == ""}
          >
            <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Start Scan
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the scanning/matching progress indicator.

  ## Attributes
    * `:scanning` - Whether currently scanning
    * `:matching` - Whether currently matching files
    * `:scan_stats` - Map with stats (`:total`, `:skipped`, `:orphaned`)
  """
  attr :scanning, :boolean, required: true
  attr :matching, :boolean, required: true
  attr :scan_stats, :map, required: true

  def scanning_progress(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <h2 class="card-title mt-4">
          {if(@scanning, do: "Scanning Directory", else: "Matching Files")}
        </h2>
        <p class="text-base-content/70">
          {if(@scanning,
            do: "Discovering media files...",
            else: "Matching discovered files with TMDB metadata..."
          )}
        </p>
        <%= if @matching do %>
          <p class="text-sm text-base-content/50 mt-2">
            Found {@scan_stats.total} new files
          </p>
        <% end %>
        <%= if @scan_stats.skipped > 0 do %>
          <div class="alert alert-info mt-4 max-w-md">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span class="text-sm">
              Skipped {@scan_stats.skipped} {if(@scan_stats.skipped == 1,
                do: "file",
                else: "files"
              )} already in your library
            </span>
          </div>
        <% end %>
        <%= if @scan_stats[:orphaned] && @scan_stats.orphaned > 0 do %>
          <div class="alert alert-warning mt-4 max-w-md">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span class="text-sm">
              Found {@scan_stats.orphaned} orphaned {if(@scan_stats.orphaned == 1,
                do: "file",
                else: "files"
              )} that will be re-matched
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the import progress screen.

  ## Attributes
    * `:import_progress` - Map with `:current`, `:total`, and `:current_file`
  """
  attr :import_progress, :map, required: true

  def import_progress_screen(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <h2 class="card-title mt-4">Importing Files</h2>
        <p class="text-base-content/70">
          Please wait while files are being imported...
        </p>

        <div class="w-full max-w-md mt-6">
          <progress
            class="progress progress-primary w-full"
            value={@import_progress.current}
            max={@import_progress.total}
          >
          </progress>
          <p class="text-sm text-base-content/60 mt-2">
            {@import_progress.current} / {@import_progress.total} files
          </p>
          <%= if @import_progress.current_file do %>
            <p class="text-xs text-base-content/50 mt-1 truncate">
              Current: {@import_progress.current_file}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the stats cards for the review screen.

  ## Attributes
    * `:scan_stats` - Map with `:total`, `:matched`, `:unmatched`, `:skipped`, `:orphaned`
    * `:selected_files` - MapSet of selected file indices
  """
  attr :scan_stats, :map, required: true
  attr :selected_files, :any, required: true

  def review_stats(assigns) do
    ~H"""
    <div class="stats stats-vertical sm:stats-horizontal shadow w-full mb-3 text-xs">
      <div class="stat py-2 px-3">
        <div class="stat-title text-[10px]">New Files</div>
        <div class="stat-value text-lg text-primary">{@scan_stats.total}</div>
      </div>
      <div class="stat py-2 px-3">
        <div class="stat-title text-[10px]">Matched</div>
        <div class="stat-value text-lg text-success">{@scan_stats.matched}</div>
      </div>
      <div class="stat py-2 px-3">
        <div class="stat-title text-[10px]">Unmatched</div>
        <div class="stat-value text-lg text-warning">{@scan_stats.unmatched}</div>
      </div>
      <%= if @scan_stats.skipped > 0 do %>
        <div class="stat py-2 px-3">
          <div class="stat-title text-[10px]">Skipped</div>
          <div class="stat-value text-lg text-base-content/50">{@scan_stats.skipped}</div>
        </div>
      <% end %>
      <%= if @scan_stats[:orphaned] && @scan_stats.orphaned > 0 do %>
        <div class="stat py-2 px-3">
          <div class="stat-title text-[10px]">Orphaned</div>
          <div class="stat-value text-lg text-warning">{@scan_stats.orphaned}</div>
        </div>
      <% end %>
      <div class="stat py-2 px-3">
        <div class="stat-title text-[10px]">Selected</div>
        <div class="stat-value text-lg">{MapSet.size(@selected_files)}</div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the selection controls for the review screen.

  ## Attributes
    * `:selected_files` - MapSet of selected file indices
  """
  attr :selected_files, :any, required: true

  def selection_controls(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3">
      <div class="flex gap-2">
        <button type="button" class="btn btn-xs btn-outline" phx-click="select_all_files">
          Select All Matched
        </button>
        <button type="button" class="btn btn-xs btn-outline" phx-click="deselect_all_files">
          Deselect All
        </button>
      </div>
      <button
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="start_import"
        disabled={MapSet.size(@selected_files) == 0}
      >
        <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
        Import Selected ({MapSet.size(@selected_files)})
      </button>
    </div>
    """
  end

  @doc """
  Renders an episode match as a compact list item.

  ## Attributes
    * `:episode` - Episode data with `:index`, `:file`, `:match_result`
    * `:is_selected` - Whether this episode is selected
    * `:is_editing` - Whether this episode is being edited
    * `:edit_form` - Edit form data (if editing)
    * `:search_results` - Search results (if editing)
  """
  attr :episode, :map, required: true
  attr :is_selected, :boolean, required: true
  attr :is_editing, :boolean, required: true
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def episode_list_item(assigns) do
    ~H"""
    <% match = @episode.match_result %>
    <li class={"flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg " <> if(@is_selected, do: "bg-primary/10", else: "")}>
      <%= if @is_editing do %>
        <%!-- Edit Form --%>
        <.form
          for={%{}}
          phx-submit="save_edit"
          id={"edit-form-#{@episode.index}"}
          class="flex-1"
        >
          <%!-- Series/Movie Title with Search --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text text-xs">
                Series/Movie Title
              </span>
            </label>
            <div class="relative">
              <input
                type="text"
                name="edit_form[title]"
                value={@edit_form["title"]}
                class="input input-bordered input-sm w-full"
                phx-change="search_series"
                phx-debounce="300"
                autocomplete="off"
              />
              <%= if @search_results != [] do %>
                <.search_results_dropdown results={@search_results} />
              <% end %>
            </div>
          </div>
          <input
            type="hidden"
            name="edit_form[provider_id]"
            value={@edit_form["provider_id"]}
          />
          <input
            type="hidden"
            name="edit_form[type]"
            value={@edit_form["type"]}
          />
          <%!-- Season Number --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text text-xs">Season Number</span>
            </label>
            <input
              type="number"
              name="edit_form[season]"
              value={@edit_form["season"]}
              class="input input-bordered input-sm"
              placeholder="e.g., 1"
              min="0"
            />
          </div>
          <%!-- Episode Numbers --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text text-xs">
                Episode Number(s)
              </span>
            </label>
            <input
              type="text"
              name="edit_form[episodes]"
              value={@edit_form["episodes"]}
              class="input input-bordered input-sm"
              placeholder="e.g., 1, 2, 3"
            />
            <label class="label">
              <span class="label-text-alt text-xs">
                Comma-separated for multi-episode files
              </span>
            </label>
          </div>
          <%!-- Year --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text text-xs">Year</span>
            </label>
            <input
              type="number"
              name="edit_form[year]"
              value={@edit_form["year"]}
              class="input input-bordered input-sm"
              placeholder="e.g., 2024"
              min="1900"
              max="2100"
            />
          </div>
          <%!-- Action Buttons --%>
          <div class="flex gap-2 justify-end">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="cancel_edit"
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="w-4 h-4" /> Save
            </button>
          </div>
        </.form>
      <% else %>
        <%!-- Normal Display --%>
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={@is_selected}
          phx-click="toggle_file_selection"
          phx-value-index={@episode.index}
        />
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm truncate">
                {Path.basename(@episode.file.path)}
              </p>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <%= if match.parsed_info.episodes do %>
                  <span>
                    Ep. {Enum.join(match.parsed_info.episodes, ", ")}
                  </span>
                <% end %>
                <span>•</span>
                <span>{format_file_size(@episode.file.size)}</span>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <%= if Map.get(match, :manually_edited, false) do %>
                <div class="badge badge-xs badge-info gap-1">
                  <.icon name="hero-pencil" class="w-3 h-3" /> Edited
                </div>
              <% end %>
              <%= if @episode.file[:orphaned_media_file_id] do %>
                <div class="badge badge-xs badge-warning">Re-matching</div>
              <% end %>
              <div class={"badge badge-xs " <> confidence_badge_class(match.match_confidence)}>
                {confidence_label(match.match_confidence)}
              </div>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="edit_file"
                phx-value-index={@episode.index}
              >
                <.icon name="hero-pencil" class="w-3 h-3" />
              </button>
              <button
                type="button"
                class="btn btn-xs btn-ghost text-error"
                phx-click="clear_match"
                phx-value-index={@episode.index}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders a movie match as a compact list item.

  ## Attributes
    * `:movie` - Movie data with `:index`, `:file`, `:match_result`
    * `:is_selected` - Whether this movie is selected
    * `:is_editing` - Whether this movie is being edited
    * `:edit_form` - Edit form data (if editing)
    * `:search_results` - Search results (if editing)
  """
  attr :movie, :map, required: true
  attr :is_selected, :boolean, required: true
  attr :is_editing, :boolean, required: true
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def movie_list_item(assigns) do
    ~H"""
    <% match = @movie.match_result %>
    <li class={"flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg " <> if(@is_selected, do: "bg-primary/10", else: "")}>
      <%= if @is_editing do %>
        <%!-- Edit Form --%>
        <.form
          for={%{}}
          phx-submit="save_edit"
          id={"edit-form-#{@movie.index}"}
          class="flex-1"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text text-sm">Movie Title</span>
            </label>
            <div class="relative">
              <input
                type="text"
                name="edit_form[title]"
                value={@edit_form["title"]}
                class="input input-bordered input-sm w-full"
                phx-change="search_series"
                phx-debounce="300"
                autocomplete="off"
              />
              <%= if @search_results != [] do %>
                <.search_results_dropdown results={@search_results} />
              <% end %>
            </div>
          </div>
          <input type="hidden" name="edit_form[provider_id]" value={@edit_form["provider_id"]} />
          <input type="hidden" name="edit_form[type]" value={@edit_form["type"]} />
          <input type="hidden" name="edit_form[season]" value="" />
          <input type="hidden" name="edit_form[episodes]" value="" />
          <div class="form-control">
            <label class="label">
              <span class="label-text text-sm">Year</span>
            </label>
            <input
              type="number"
              name="edit_form[year]"
              value={@edit_form["year"]}
              class="input input-bordered input-sm"
              placeholder="e.g., 2024"
              min="1900"
              max="2100"
            />
          </div>
          <div class="flex gap-2 justify-end">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="w-4 h-4" /> Save
            </button>
          </div>
        </.form>
      <% else %>
        <%!-- Normal Display --%>
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={@is_selected}
          phx-click="toggle_file_selection"
          phx-value-index={@movie.index}
        />
        <%= if match.metadata.poster_path do %>
          <img
            src={"https://image.tmdb.org/t/p/w92#{match.metadata.poster_path}"}
            alt={match.title}
            class="w-12 h-18 rounded object-cover"
          />
        <% end %>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate">
                {match.title}
                <%= if match.year do %>
                  ({match.year})
                <% end %>
              </p>
              <p class="text-xs text-base-content/60 truncate">
                {Path.basename(@movie.file.path)}
              </p>
              <p class="text-xs text-base-content/50">
                {format_file_size(@movie.file.size)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <%= if Map.get(match, :manually_edited, false) do %>
                <div class="badge badge-xs badge-info gap-1">
                  <.icon name="hero-pencil" class="w-3 h-3" /> Edited
                </div>
              <% end %>
              <%= if @movie.file[:orphaned_media_file_id] do %>
                <div class="badge badge-xs badge-warning">Re-matching</div>
              <% end %>
              <div class={"badge badge-xs " <> confidence_badge_class(match.match_confidence)}>
                {confidence_label(match.match_confidence)}
              </div>
              <div class="badge badge-xs badge-accent">Movie</div>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="edit_file"
                phx-value-index={@movie.index}
              >
                <.icon name="hero-pencil" class="w-3 h-3" />
              </button>
              <button
                type="button"
                class="btn btn-xs btn-ghost text-error"
                phx-click="clear_match"
                phx-value-index={@movie.index}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders an unmatched file as a compact list item.

  ## Attributes
    * `:file` - File data with `:index`, `:file`
    * `:is_editing` - Whether this file is being edited
    * `:edit_form` - Edit form data (if editing)
    * `:search_results` - Search results (if editing)
  """
  attr :file, :map, required: true
  attr :is_editing, :boolean, required: true
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def unmatched_file_list_item(assigns) do
    ~H"""
    <li class={"flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg " <> if(!@is_editing, do: "opacity-60", else: "")}>
      <%= if @is_editing do %>
        <.form
          for={%{}}
          phx-submit="save_edit"
          id={"edit-form-#{@file.index}"}
          class="flex-1"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text text-sm">Search for Metadata Match</span>
            </label>
            <div class="relative">
              <input
                type="text"
                name="edit_form[title]"
                value={@edit_form["title"]}
                class="input input-bordered input-sm w-full"
                phx-change="search_series"
                phx-debounce="300"
                autocomplete="off"
                placeholder="Search by title..."
              />
              <%= if @search_results != [] do %>
                <.search_results_dropdown_with_poster results={@search_results} />
              <% end %>
            </div>
          </div>
          <input type="hidden" name="edit_form[provider_id]" value={@edit_form["provider_id"]} />
          <input type="hidden" name="edit_form[type]" value={@edit_form["type"]} />
          <%= if @edit_form["type"] == "tv_show" do %>
            <div class="grid grid-cols-2 gap-2">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Season</span>
                </label>
                <input
                  type="number"
                  name="edit_form[season]"
                  value={@edit_form["season"]}
                  class="input input-bordered input-sm"
                  placeholder="1"
                  min="0"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Episode(s)</span>
                </label>
                <input
                  type="text"
                  name="edit_form[episodes]"
                  value={@edit_form["episodes"]}
                  class="input input-bordered input-sm"
                  placeholder="1, 2"
                />
              </div>
            </div>
          <% else %>
            <input type="hidden" name="edit_form[season]" value="" />
            <input type="hidden" name="edit_form[episodes]" value="" />
          <% end %>
          <div class="form-control">
            <label class="label">
              <span class="label-text text-xs">Year</span>
            </label>
            <input
              type="number"
              name="edit_form[year]"
              value={@edit_form["year"]}
              class="input input-bordered input-sm"
              placeholder="2024"
              min="1900"
              max="2100"
            />
          </div>
          <div class="flex gap-2 justify-end">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit">
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              disabled={@edit_form["provider_id"] == nil or @edit_form["provider_id"] == ""}
            >
              <.icon name="hero-check" class="w-4 h-4" /> Apply Match
            </button>
          </div>
        </.form>
      <% else %>
        <input type="checkbox" class="checkbox checkbox-primary checkbox-sm" disabled />
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate text-error">
                {Path.basename(@file.file.path)}
              </p>
              <p class="text-xs text-base-content/60 truncate">
                {@file.file.path}
              </p>
              <p class="text-xs text-base-content/50">
                {format_file_size(@file.file.size)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <%= if @file.file[:orphaned_media_file_id] do %>
                <div class="badge badge-xs badge-warning">Re-matching</div>
              <% end %>
              <div class="badge badge-xs badge-error">No Match</div>
              <button
                type="button"
                class="btn btn-xs btn-primary"
                phx-click="edit_file"
                phx-value-index={@file.index}
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders a search results dropdown (compact version).

  ## Attributes
    * `:results` - List of search result maps
  """
  attr :results, :list, required: true

  def search_results_dropdown(assigns) do
    ~H"""
    <div class="absolute z-10 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-48 overflow-y-auto">
      <%= for result <- @results do %>
        <button
          type="button"
          class="w-full text-left px-3 py-2 hover:bg-base-200 border-b border-base-300 last:border-b-0"
          phx-click="select_search_result"
          phx-value-provider_id={result.provider_id}
          phx-value-title={result.title}
          phx-value-year={result.year || ""}
          phx-value-type={result.media_type}
        >
          <div class="font-medium text-sm">
            {result.title}
          </div>
          <div class="text-xs text-base-content/60">
            {result.year} • {String.upcase(to_string(result.media_type))}
          </div>
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a search results dropdown with poster images.

  ## Attributes
    * `:results` - List of search result maps
  """
  attr :results, :list, required: true

  def search_results_dropdown_with_poster(assigns) do
    ~H"""
    <div class="absolute z-10 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-64 overflow-y-auto">
      <%= for result <- @results do %>
        <button
          type="button"
          class="w-full text-left px-3 py-2 hover:bg-base-200 border-b border-base-300 last:border-b-0 flex gap-3"
          phx-click="select_search_result"
          phx-value-provider_id={result.provider_id}
          phx-value-title={result.title}
          phx-value-year={result.year || ""}
          phx-value-type={result.media_type}
        >
          <%= if result.poster_path do %>
            <img
              src={"https://image.tmdb.org/t/p/w92#{result.poster_path}"}
              alt={result.title}
              class="w-10 rounded"
            />
          <% end %>
          <div class="flex-1">
            <div class="font-medium text-sm">{result.title}</div>
            <div class="text-xs text-base-content/60">
              {result.year} • {String.upcase(to_string(result.media_type))}
            </div>
          </div>
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the import completion screen with results.

  ## Attributes
    * `:import_results` - Map with `:success`, `:failed`, `:skipped` counts
    * `:detailed_results` - List of detailed result maps
  """
  attr :import_results, :map, required: true
  attr :detailed_results, :list, required: true

  def import_complete_screen(assigns) do
    ~H"""
    <div class="mb-6">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-xl mb-6">
        <div class="card-body items-center text-center">
          <div class={"text-" <> if(@import_results.failed == 0, do: "success", else: "warning")}>
            <.icon
              name={
                if(@import_results.failed == 0,
                  do: "hero-check-circle",
                  else: "hero-exclamation-triangle"
                )
              }
              class="w-24 h-24"
            />
          </div>
          <h2 class="card-title text-2xl mt-4">Import Complete!</h2>
          <p class="text-base-content/60">
            {@import_results.success + @import_results.failed + @import_results.skipped} items processed
          </p>
        </div>
      </div>

      <%!-- Summary Stats --%>
      <div class="stats stats-horizontal shadow w-full mb-6">
        <div class="stat">
          <div class="stat-title">Successfully Imported</div>
          <div class="stat-value text-success">{@import_results.success}</div>
          <div class="stat-desc">Items added to library</div>
        </div>
        <div class="stat">
          <div class="stat-title">Failed</div>
          <div class="stat-value text-error">{@import_results.failed}</div>
          <div class="stat-desc">Items with errors</div>
        </div>
        <%= if @import_results.skipped > 0 do %>
          <div class="stat">
            <div class="stat-title">Skipped</div>
            <div class="stat-value text-base-content/50">{@import_results.skipped}</div>
            <div class="stat-desc">Items skipped</div>
          </div>
        <% end %>
      </div>

      <%!-- Action Buttons --%>
      <div class="flex items-center justify-between mb-6">
        <div class="flex gap-2">
          <%= if @import_results.failed > 0 do %>
            <button type="button" class="btn btn-warning btn-sm" phx-click="retry_all_failed">
              <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry All Failed
            </button>
          <% end %>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="export_results">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Export Details
          </button>
        </div>
        <div class="flex gap-2">
          <button type="button" class="btn btn-outline btn-sm" phx-click="start_over">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Import More Files
          </button>
          <button type="button" class="btn btn-primary btn-sm" phx-click="cancel">
            <.icon name="hero-check" class="w-4 h-4" /> Done
          </button>
        </div>
      </div>

      <%!-- Detailed Results --%>
      <%= if @import_results.success > 0 do %>
        <div class="mb-6">
          <h3 class="text-lg font-semibold mb-3 flex items-center gap-2">
            <.icon name="hero-check-circle" class="w-6 h-6 text-success" />
            Successfully Imported ({@import_results.success})
          </h3>
          <div class="space-y-2">
            <%= for {result, _idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :success do %>
                <div class="card bg-base-100 shadow-sm border border-success/20">
                  <div class="card-body p-4">
                    <div class="flex items-start gap-3">
                      <div class="text-success mt-1">
                        <.icon name="hero-check-circle" class="w-5 h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="font-semibold text-sm">{result.file_name}</p>
                        <p class="text-xs text-base-content/60 truncate">{result.file_path}</p>
                        <%= if result.action_taken do %>
                          <p class="text-xs text-success mt-1">{result.action_taken}</p>
                        <% end %>
                      </div>
                      <div class="badge badge-success badge-sm">Success</div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @import_results.failed > 0 do %>
        <div class="mb-6">
          <h3 class="text-lg font-semibold mb-3 flex items-center gap-2">
            <.icon name="hero-x-circle" class="w-6 h-6 text-error" />
            Failed ({@import_results.failed})
          </h3>
          <div class="space-y-2">
            <%= for {result, idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :failed do %>
                <div class="card bg-base-100 shadow-sm border border-error/20">
                  <div class="card-body p-4">
                    <div class="flex items-start gap-3">
                      <div class="text-error mt-1">
                        <.icon name="hero-x-circle" class="w-5 h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="font-semibold text-sm">{result.file_name}</p>
                        <p class="text-xs text-base-content/60 truncate">{result.file_path}</p>
                        <%= if result.error_message do %>
                          <div class="alert alert-error mt-2 py-2 px-3">
                            <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                            <span class="text-xs">{result.error_message}</span>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex flex-col gap-2">
                        <div class="badge badge-error badge-sm">Failed</div>
                        <button
                          type="button"
                          class="btn btn-xs btn-warning"
                          phx-click="retry_failed_item"
                          phx-value-index={idx}
                        >
                          <.icon name="hero-arrow-path" class="w-3 h-3" /> Retry
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @import_results.skipped > 0 do %>
        <div class="mb-6">
          <h3 class="text-lg font-semibold mb-3 flex items-center gap-2">
            <.icon name="hero-arrow-path" class="w-6 h-6 text-base-content/50" />
            Skipped ({@import_results.skipped})
          </h3>
          <div class="space-y-2">
            <%= for {result, _idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :skipped do %>
                <div class="card bg-base-100 shadow-sm border border-base-content/10">
                  <div class="card-body p-4">
                    <div class="flex items-start gap-3">
                      <div class="text-base-content/50 mt-1">
                        <.icon name="hero-arrow-path" class="w-5 h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="font-semibold text-sm">{result.file_name}</p>
                        <p class="text-xs text-base-content/60 truncate">{result.file_path}</p>
                        <%= if result.error_message do %>
                          <p class="text-xs text-base-content/50 mt-1">
                            {result.error_message}
                          </p>
                        <% end %>
                      </div>
                      <div class="badge badge-ghost badge-sm">Skipped</div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Helper Functions

  defp format_file_size(size) when size < 1024, do: "#{size} B"
  defp format_file_size(size) when size < 1_048_576, do: "#{Float.round(size / 1024, 1)} KB"

  defp format_file_size(size) when size < 1_073_741_824,
    do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_file_size(size), do: "#{Float.round(size / 1_073_741_824, 1)} GB"

  defp confidence_badge_class(confidence) when confidence >= 0.8, do: "badge-success"
  defp confidence_badge_class(confidence) when confidence >= 0.5, do: "badge-warning"
  defp confidence_badge_class(_), do: "badge-error"

  defp confidence_label(confidence) when confidence >= 0.8, do: "High"
  defp confidence_label(confidence) when confidence >= 0.5, do: "Medium"
  defp confidence_label(_), do: "Low"
end
