defmodule MydiaWeb.Live.Components.MetadataSearchForm do
  @moduledoc """
  A reusable function component for metadata search with live results.

  Provides a search input with autocomplete-style dropdown showing TMDB search results.
  Used for searching and selecting media metadata.

  ## Usage

      <.metadata_search_form
        title_value={@edit_form["title"]}
        search_results={@search_results}
        on_search="search_series"
        on_select="select_search_result"
        placeholder="Search by title..."
        input_name="edit_form[title]"
        input_class="input input-bordered w-full"
      />

  ## Attributes

  - `title_value` - Current value of the search input
  - `search_results` - List of search results to display
  - `on_search` - Event to trigger when user types (includes title param)
  - `on_select` - Event to trigger when user clicks a result (includes match params)
  - `placeholder` - (optional) Placeholder text for input
  - `input_name` - (optional) Name attribute for the input field
  - `input_class` - (optional) CSS classes for the input
  - `show_no_results` - (optional) Whether to show "no results" message
  """
  use Phoenix.Component
  import MydiaWeb.CoreComponents

  attr :title_value, :string, required: true
  attr :search_results, :list, default: []
  attr :on_search, :string, required: true
  attr :on_select, :string, required: true
  attr :placeholder, :string, default: "Search by title..."
  attr :input_name, :string, default: "title"
  attr :input_class, :string, default: "input input-bordered w-full"
  attr :show_no_results, :boolean, default: false

  def metadata_search_form(assigns) do
    ~H"""
    <div class="relative">
      <input
        type="text"
        name={@input_name}
        value={@title_value}
        class={@input_class}
        phx-change={@on_search}
        phx-debounce="300"
        autocomplete="off"
        placeholder={@placeholder}
      />
      <%= if @search_results != [] do %>
        <div class="absolute z-10 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-64 overflow-y-auto">
          <%= for result <- @search_results do %>
            <button
              type="button"
              class="w-full text-left px-3 py-2 hover:bg-base-200 border-b border-base-300 last:border-b-0 flex gap-3"
              phx-click={@on_select}
              phx-value-provider_id={result.provider_id}
              phx-value-title={result.title}
              phx-value-year={String.slice(result.release_date || result.first_air_date || "", 0..3)}
              phx-value-type={if result.media_type == :tv_show, do: "tv", else: "movie"}
            >
              <%= if Map.get(result, :poster_path) do %>
                <img
                  src={"https://image.tmdb.org/t/p/w92#{result.poster_path}"}
                  alt={result.title}
                  class="w-10 h-14 object-cover rounded flex-shrink-0"
                />
              <% else %>
                <div class="w-10 h-14 bg-base-300 rounded flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-film" class="w-5 h-5 text-base-content/30" />
                </div>
              <% end %>
              <div class="flex-1 min-w-0">
                <div class="font-medium text-sm line-clamp-1">
                  {result.title}
                </div>
                <div class="flex gap-2 items-center mt-0.5">
                  <%= if result.release_date || result.first_air_date do %>
                    <span class="text-xs text-base-content/60">
                      {String.slice(result.release_date || result.first_air_date, 0..3)}
                    </span>
                  <% end %>
                  <span class="badge badge-xs badge-outline">
                    {if result.media_type == :tv_show, do: "TV", else: "Movie"}
                  </span>
                </div>
              </div>
            </button>
          <% end %>
        </div>
      <% end %>
      <%= if @show_no_results && @title_value != "" && @search_results == [] do %>
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            Type at least 2 characters to search...
          </span>
        </label>
      <% end %>
    </div>
    """
  end
end
