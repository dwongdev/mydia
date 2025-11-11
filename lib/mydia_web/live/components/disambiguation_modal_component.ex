defmodule MydiaWeb.Live.Components.DisambiguationModalComponent do
  @moduledoc """
  A reusable LiveComponent for displaying metadata disambiguation modal.

  This component is shown when multiple metadata matches are found from TMDB
  and the user needs to select the correct one.

  ## Usage

      <.live_component
        module={MydiaWeb.Live.Components.DisambiguationModalComponent}
        id="disambiguation-modal"
        show={@show_disambiguation_modal}
        matches={@metadata_matches}
        on_select="select_metadata_match"
        on_cancel="close_disambiguation_modal"
      />

  ## Events

  The component emits these events to the parent LiveView:

  - `on_select` - When user clicks a match. Includes `match_id` param.
  - `on_cancel` - When user clicks Cancel button.
  """
  use MydiaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @show do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-4xl">
            <h3 class="font-bold text-lg mb-4">
              Multiple Matches Found
            </h3>
            <p class="text-sm text-base-content/70 mb-4">
              We found multiple metadata matches. Please select the correct one:
            </p>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 max-h-[60vh] overflow-y-auto">
              <div
                :for={match <- @matches}
                class="card bg-base-200 hover:bg-base-300 cursor-pointer transition-colors"
                phx-click={@on_select}
                phx-value-match_id={match.provider_id}
              >
                <div class="card-body p-4">
                  <div class="flex gap-4">
                    <%= if Map.get(match, :poster_path) do %>
                      <img
                        src={"https://image.tmdb.org/t/p/w92#{match.poster_path}"}
                        alt={match.title}
                        class="w-16 h-24 object-cover rounded"
                      />
                    <% else %>
                      <div class="w-16 h-24 bg-base-300 rounded flex items-center justify-center">
                        <.icon name="hero-film" class="w-8 h-8 text-base-content/30" />
                      </div>
                    <% end %>
                    <div class="flex-1 min-w-0">
                      <h4 class="font-semibold text-base line-clamp-2">
                        {match.title}
                      </h4>
                      <%= if Map.get(match, :release_date) || Map.get(match, :first_air_date) do %>
                        <p class="text-sm text-base-content/60">
                          {String.slice(match.release_date || match.first_air_date, 0..3)}
                        </p>
                      <% end %>
                      <%= if Map.get(match, :overview) do %>
                        <p class="text-xs text-base-content/50 mt-2 line-clamp-3">
                          {match.overview}
                        </p>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <div class="modal-action">
              <button class="btn btn-ghost" phx-click={@on_cancel}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show, fn -> false end)
     |> assign_new(:matches, fn -> [] end)}
  end
end
