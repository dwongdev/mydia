defmodule MydiaWeb.MediaLive.Show.Modals do
  @moduledoc """
  Modal components for the MediaLive.Show page.
  """
  use Phoenix.Component
  import MydiaWeb.CoreComponents

  # Import the formatting and search helper functions
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.SearchHelpers

  @doc """
  Delete confirmation modal for removing media item from library.
  Allows user to choose whether to delete files from disk.
  """
  attr :media_item, :map, required: true
  attr :delete_files, :boolean, required: true

  def delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">Delete {@media_item.title}?</h3>

        <form phx-change="toggle_delete_files">
          <div class="space-y-2.5 mb-5">
            <label class={[
              "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
              !@delete_files && "border-primary bg-primary/10",
              @delete_files && "border-base-300 hover:border-primary/50"
            ]}>
              <input
                type="radio"
                name="delete_files"
                value="false"
                class="radio radio-primary mt-0.5 flex-shrink-0"
                checked={!@delete_files}
              />
              <div>
                <div class="font-medium mb-1">Remove from library only</div>
                <div class="text-sm opacity-75">Files stay on disk, can be re-imported later</div>
              </div>
            </label>

            <label class={[
              "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
              @delete_files && "border-error bg-error/10",
              !@delete_files && "border-base-300 hover:border-error/50"
            ]}>
              <input
                type="radio"
                name="delete_files"
                value="true"
                class="radio radio-error mt-0.5 flex-shrink-0"
                checked={@delete_files}
              />
              <div>
                <div class="font-medium mb-1">Delete files from disk</div>
                <div class="text-sm opacity-75 flex items-center gap-1">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                  <span>Permanently deletes all files - cannot be undone</span>
                </div>
              </div>
            </label>
          </div>
        </form>

        <div class="modal-action">
          <button type="button" phx-click="hide_delete_confirm" class="btn btn-ghost">
            Cancel
          </button>
          <button
            type="button"
            phx-click="delete_media"
            class={["btn", (@delete_files && "btn-error") || "btn-warning"]}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            {if @delete_files, do: "Delete Everything", else: "Remove from Library"}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_delete_confirm"></div>
    </div>
    """
  end

  @doc """
  File delete confirmation modal for removing a media file record.
  """
  attr :file_to_delete, :map, required: true

  def file_delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Delete Media File?</h3>
        <p class="py-4">
          Are you sure you want to delete this file?
        </p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-mono text-base-content/70">
            {Mydia.Library.MediaFile.absolute_path(@file_to_delete)}
          </p>
          <p class="text-sm mt-2">
            <span class="font-semibold">Size:</span>
            {format_file_size(@file_to_delete.size)}
          </p>
        </div>
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          This will only remove the database record. The actual file will remain on disk.
        </p>
        <div class="modal-action">
          <button type="button" phx-click="hide_file_delete_confirm" class="btn btn-ghost">
            Cancel
          </button>
          <button type="button" phx-click="delete_media_file" class="btn btn-error">
            Delete Record
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_file_delete_confirm"></div>
    </div>
    """
  end

  @doc """
  File details modal showing comprehensive information about a media file.
  """
  attr :file_details, :map, required: true

  def file_details_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Media File Details</h3>

        <div class="space-y-4">
          <%!-- File Path --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">File Path</h4>
            <p class="text-sm font-mono bg-base-200 p-3 rounded-box break-all">
              {Mydia.Library.MediaFile.absolute_path(@file_details)}
            </p>
          </div>
          <%!-- Quality Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Resolution</h4>
              <p class="text-sm">
                <%= if @file_details.resolution do %>
                  <span class="badge badge-primary">{@file_details.resolution}</span>
                <% else %>
                  <span class="text-base-content/50">Unknown</span>
                <% end %>
              </p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Size</h4>
              <p class="text-sm">{format_file_size(@file_details.size)}</p>
            </div>
          </div>
          <%!-- Codec Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Video Codec</h4>
              <p class="text-sm">{@file_details.codec || "Unknown"}</p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Audio Codec</h4>
              <p class="text-sm">{@file_details.audio_codec || "Unknown"}</p>
            </div>
          </div>
          <%!-- Additional Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">HDR Format</h4>
              <p class="text-sm">
                <%= if @file_details.hdr_format do %>
                  <span class="badge badge-accent">{@file_details.hdr_format}</span>
                <% else %>
                  <span class="text-base-content/50">None</span>
                <% end %>
              </p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Bitrate</h4>
              <p class="text-sm">
                <%= if @file_details.bitrate do %>
                  {Float.round(@file_details.bitrate / 1_000_000, 2)} Mbps
                <% else %>
                  <span class="text-base-content/50">Unknown</span>
                <% end %>
              </p>
            </div>
          </div>
          <%!-- Verification Status --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">Verification Status</h4>
            <p class="text-sm">
              <%= if @file_details.verified_at do %>
                <span class="text-success">
                  <.icon name="hero-check-circle" class="w-4 h-4 inline" />
                  Verified on {Calendar.strftime(
                    @file_details.verified_at,
                    "%b %d, %Y at %I:%M %p"
                  )}
                </span>
              <% else %>
                <span class="text-warning">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" /> Not verified
                </span>
              <% end %>
            </p>
          </div>
          <%!-- Metadata (if present) --%>
          <%= if @file_details.metadata && map_size(@file_details.metadata) > 0 do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Additional Metadata</h4>
              <pre class="text-xs bg-base-200 p-3 rounded-box overflow-x-auto"><%= Jason.encode!(@file_details.metadata, pretty: true) %></pre>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_file_details" class="btn btn-ghost">
            Close
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_file_details"></div>
    </div>
    """
  end

  @doc """
  Download cancel confirmation modal.
  """
  attr :download_to_cancel, :map, required: true

  def download_cancel_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Cancel Download?</h3>
        <p class="py-4">
          Are you sure you want to cancel this download?
        </p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-medium">{@download_to_cancel.title}</p>
          <%= if quality = @download_to_cancel.metadata["quality"] do %>
            <p class="text-sm text-base-content/70 mt-1">
              Quality: <span class="badge badge-sm">{format_download_quality(quality)}</span>
            </p>
          <% end %>
          <%= if @download_to_cancel.progress do %>
            <p class="text-sm text-base-content/70 mt-1">
              Progress: {@download_to_cancel.progress}%
            </p>
          <% end %>
        </div>
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          The download will be stopped and marked as cancelled.
        </p>
        <div class="modal-action">
          <button type="button" phx-click="hide_download_cancel_confirm" class="btn btn-ghost">
            Keep Downloading
          </button>
          <button type="button" phx-click="cancel_download" class="btn btn-warning">
            Cancel Download
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_cancel_confirm"></div>
    </div>
    """
  end

  @doc """
  Download delete confirmation modal for removing a download record.
  """
  attr :download_to_delete, :map, required: true

  def download_delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Remove Download?</h3>
        <p class="py-4">
          Are you sure you want to remove this download from history?
        </p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-medium">{@download_to_delete.title}</p>
          <p class="text-sm text-base-content/70 mt-1">
            Status:
            <span class={[
              "badge badge-sm",
              @download_to_delete.status == "completed" && "badge-success",
              @download_to_delete.status == "failed" && "badge-error",
              @download_to_delete.status == "downloading" && "badge-info",
              @download_to_delete.status == "pending" && "badge-warning"
            ]}>
              {format_download_status(@download_to_delete.status)}
            </span>
          </p>
        </div>
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          This will only remove the download record. Downloaded files will remain on disk.
        </p>
        <div class="modal-action">
          <button
            type="button"
            phx-click="hide_download_delete_confirm"
            class="btn btn-ghost"
          >
            Cancel
          </button>
          <button type="button" phx-click="delete_download_record" class="btn btn-error">
            Remove Record
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_delete_confirm"></div>
    </div>
    """
  end

  @doc """
  Download details modal showing comprehensive information about a download.
  """
  attr :download_details, :map, required: true

  def download_details_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Download Details</h3>

        <div class="space-y-4">
          <%!-- Title and Status --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">Title</h4>
            <p class="text-sm font-medium">{@download_details.title}</p>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Status</h4>
              <span class={[
                "badge",
                @download_details.status == "completed" && "badge-success",
                @download_details.status == "failed" && "badge-error",
                @download_details.status == "downloading" && "badge-info",
                @download_details.status == "pending" && "badge-warning"
              ]}>
                {format_download_status(@download_details.status)}
              </span>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Quality</h4>
              <%= if quality = @download_details.metadata["quality"] do %>
                <span class="badge">{format_download_quality(quality)}</span>
              <% else %>
                <span class="text-base-content/50">Unknown</span>
              <% end %>
            </div>
          </div>
          <%!-- Progress --%>
          <%= if @download_details.progress do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Progress</h4>
              <div class="flex items-center gap-3">
                <progress
                  class="progress progress-primary flex-1"
                  value={@download_details.progress}
                  max="100"
                >
                </progress>
                <span class="text-sm font-mono">{@download_details.progress}%</span>
              </div>
            </div>
          <% end %>
          <%!-- Source URL --%>
          <%= if @download_details.source_url do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Source URL</h4>
              <p class="text-xs font-mono bg-base-200 p-3 rounded-box break-all">
                {@download_details.source_url}
              </p>
            </div>
          <% end %>
          <%!-- Error Message --%>
          <%= if @download_details.error_message do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Error Message</h4>
              <div class="alert alert-error">
                <.icon name="hero-exclamation-circle" class="w-5 h-5" />
                <span class="text-sm">{@download_details.error_message}</span>
              </div>
            </div>
          <% end %>
          <%!-- Timestamps --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">Added</h4>
              <p class="text-sm">
                {Calendar.strftime(@download_details.inserted_at, "%b %d, %Y at %I:%M %p")}
              </p>
            </div>
            <%= if @download_details.completed_at do %>
              <div>
                <h4 class="text-sm font-semibold text-base-content/70 mb-2">Completed</h4>
                <p class="text-sm">
                  {Calendar.strftime(@download_details.completed_at, "%b %d, %Y at %I:%M %p")}
                </p>
              </div>
            <% end %>
          </div>
          <%!-- Estimated Completion --%>
          <%= if @download_details.estimated_completion do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                Estimated Completion
              </h4>
              <p class="text-sm">
                {Calendar.strftime(
                  @download_details.estimated_completion,
                  "%b %d, %Y at %I:%M %p"
                )}
              </p>
            </div>
          <% end %>
          <%!-- Metadata (if present) --%>
          <%= if @download_details.metadata && map_size(@download_details.metadata) > 0 do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                Additional Metadata
              </h4>
              <pre class="text-xs bg-base-200 p-3 rounded-box overflow-x-auto"><%= Jason.encode!(@download_details.metadata, pretty: true) %></pre>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_download_details" class="btn btn-ghost">
            Close
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_details"></div>
    </div>
    """
  end

  @doc """
  Manual search modal for searching and downloading content manually.
  Uses DaisyUI list components for a cleaner, more scannable UI.
  """
  attr :manual_search_context, :map, default: nil
  attr :media_item, :map, required: true
  attr :manual_search_query, :string, required: true
  attr :searching, :boolean, required: true
  attr :downloading_release_url, :string, default: nil
  attr :results_empty?, :boolean, required: true
  attr :streams, :map, required: true
  attr :quality_filter, :string, default: nil
  attr :min_seeders, :integer, default: 0
  attr :sort_by, :atom, required: true
  attr :quality_profile, :map, default: nil

  def manual_search_modal(assigns) do
    # Calculate media_type for profile scoring
    media_type =
      case assigns.media_item.type do
        "movie" -> :movie
        "tv_show" -> :episode
        _ -> :movie
      end

    assigns = assign(assigns, :media_type, media_type)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl h-[90vh] flex flex-col p-0">
        <%!-- Modal Header --%>
        <div class="sticky top-0 z-10 bg-base-100 border-b border-base-300 p-4 sm:p-6">
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-xl sm:text-2xl font-bold">
              Manual Search
              <%= if @manual_search_context do %>
                <%= case @manual_search_context.type do %>
                  <% :episode -> %>
                    <span class="text-sm sm:text-base text-base-content/70">for Episode</span>
                  <% :season -> %>
                    <span class="text-sm sm:text-base text-base-content/70">
                      for {@media_item.title} - Season {@manual_search_context.season_number}
                    </span>
                  <% :media_item -> %>
                    <span class="text-sm sm:text-base text-base-content/70">
                      for {@media_item.title}
                    </span>
                  <% _ -> %>
                    <span></span>
                <% end %>
              <% end %>
            </h3>
            <button
              type="button"
              phx-click="close_manual_search_modal"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <.icon name="hero-x-mark" class="w-6 h-6" />
            </button>
          </div>
          <%!-- Search Query Display --%>
          <div class="flex items-center gap-2 text-sm">
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/60" />
            <span class="text-base-content/70">Searching for:</span>
            <span class="font-semibold truncate">{@manual_search_query}</span>
          </div>
        </div>
        <%!-- Filters Bar (compact) --%>
        <%= if !@searching do %>
          <div class="bg-base-200/50 border-b border-base-300 px-4 py-3">
            <div class="flex flex-wrap items-center gap-3">
              <form phx-change="filter_search" class="flex flex-wrap items-center gap-3">
                <select name="quality" class="select select-bordered select-sm">
                  <option value="" selected={is_nil(@quality_filter)}>All Quality</option>
                  <option value="720p" selected={@quality_filter == "720p"}>720p</option>
                  <option value="1080p" selected={@quality_filter == "1080p"}>1080p</option>
                  <option value="2160p" selected={@quality_filter in ["2160p", "4k"]}>4K</option>
                </select>
                <div class="join">
                  <span class="join-item btn btn-sm btn-ghost no-animation pointer-events-none">
                    Min Seeds
                  </span>
                  <input
                    type="number"
                    name="min_seeders"
                    value={@min_seeders}
                    min="0"
                    class="input input-bordered input-sm w-16 join-item"
                    placeholder="0"
                  />
                </div>
              </form>
              <div class="flex-1"></div>
              <form phx-change="sort_search">
                <select name="sort_by" class="select select-bordered select-sm">
                  <option value="quality" selected={@sort_by == :quality}>Best Score</option>
                  <option value="seeders" selected={@sort_by == :seeders}>Most Seeds</option>
                  <option value="size" selected={@sort_by == :size}>Largest</option>
                  <option value="date" selected={@sort_by == :date}>Newest</option>
                </select>
              </form>
            </div>
          </div>
        <% end %>
        <%!-- Modal Body --%>
        <div class="flex-1 overflow-y-auto">
          <%!-- Loading State --%>
          <%= if @searching do %>
            <div class="flex flex-col items-center justify-center py-16">
              <span class="loading loading-spinner loading-lg text-primary mb-4"></span>
              <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                Searching across indexers...
              </h3>
              <p class="text-base-content/50">
                This may take a few seconds
              </p>
            </div>
          <% end %>
          <%!-- Empty State (no results) --%>
          <%= if @results_empty? && !@searching do %>
            <div class="flex flex-col items-center justify-center py-16 text-center px-4">
              <.icon name="hero-exclamation-circle" class="w-16 h-16 text-base-content/20 mb-4" />
              <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                No Results Found
              </h3>
              <p class="text-base-content/50 max-w-sm mb-4">
                We couldn't find any releases matching
                "<span class="font-semibold">{@manual_search_query}</span>"
              </p>
              <div class="text-sm text-base-content/60">
                <p>Try different keywords, adjusting filters, or checking your indexers.</p>
              </div>
            </div>
          <% end %>
          <%!-- Results List --%>
          <%= if !@searching && !@results_empty? do %>
            <ul id="manual-search-results" class="list bg-base-100" phx-update="stream">
              <li
                :for={{id, result} <- @streams.search_results}
                id={id}
                class="list-row hover:bg-base-200/50 transition-colors px-4 py-3 border-b border-base-200 last:border-b-0"
              >
                <%!-- Score display --%>
                <%= if @quality_profile do %>
                  <%!-- Profile-based score with breakdown dropdown --%>
                  <% score_data = profile_score_breakdown(result, @quality_profile, @media_type) %>
                  <% score = score_data.score %>
                  <div class="dropdown dropdown-hover dropdown-right">
                    <div
                      tabindex="0"
                      role="button"
                      class={[
                        "radial-progress text-sm font-bold cursor-pointer",
                        score >= 80 && "text-success",
                        score >= 50 && score < 80 && "text-warning",
                        score < 50 && "text-error"
                      ]}
                      style={"--value:#{trunc(score)}; --size:3rem; --thickness:4px;"}
                      title="Hover for score breakdown"
                    >
                      {trunc(score)}
                    </div>
                    <div
                      tabindex="0"
                      class="dropdown-content z-50 card card-compact bg-base-200 shadow-xl w-72 ml-2"
                    >
                      <div class="card-body p-3">
                        <h4 class="card-title text-sm mb-2">Score Breakdown</h4>
                        <div class="space-y-1.5 text-xs">
                          <.score_row
                            label="Resolution"
                            value={score_data.detected[:resolution]}
                            score={score_data.breakdown[:resolution]}
                            weight={20}
                          />
                          <.score_row
                            label="Video Codec"
                            value={score_data.detected[:video_codec]}
                            score={score_data.breakdown[:video_codec]}
                            weight={20}
                          />
                          <.score_row
                            label="Audio Codec"
                            value={score_data.detected[:audio_codec]}
                            score={score_data.breakdown[:audio_codec]}
                            weight={15}
                          />
                          <.score_row
                            label="Source"
                            value={score_data.detected[:source]}
                            score={score_data.breakdown[:source]}
                            weight={10}
                          />
                          <.score_row
                            label="Audio Channels"
                            value={nil}
                            score={score_data.breakdown[:audio_channels]}
                            weight={10}
                          />
                          <.score_row
                            label="Video Bitrate"
                            value={nil}
                            score={score_data.breakdown[:video_bitrate]}
                            weight={10}
                          />
                          <.score_row
                            label="File Size"
                            value={
                              if(score_data.detected[:size_mb],
                                do: "#{score_data.detected[:size_mb]} MB",
                                else: nil
                              )
                            }
                            score={score_data.breakdown[:file_size]}
                            weight={5}
                          />
                          <.score_row
                            label="Audio Bitrate"
                            value={nil}
                            score={score_data.breakdown[:audio_bitrate]}
                            weight={5}
                          />
                          <.score_row
                            label="HDR"
                            value={if(score_data.detected[:hdr], do: "Yes", else: "No")}
                            score={score_data.breakdown[:hdr]}
                            weight={5}
                          />
                        </div>
                        <%= if score_data.violations != [] do %>
                          <div class="divider my-1"></div>
                          <div class="text-error text-xs">
                            <span class="font-semibold">Violations:</span>
                            <ul class="list-disc list-inside">
                              <%= for violation <- score_data.violations do %>
                                <li>{violation}</li>
                              <% end %>
                            </ul>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <%!-- No profile - just show seeders count (sorted by most seeders) --%>
                  <div
                    class={[
                      "flex items-center justify-center w-12 h-12 rounded-full font-bold text-sm",
                      result.seeders >= 50 && "bg-success/20 text-success",
                      result.seeders >= 10 && result.seeders < 50 && "bg-warning/20 text-warning",
                      result.seeders < 10 && "bg-base-300 text-base-content/70"
                    ]}
                    title={"#{result.seeders} seeders"}
                  >
                    <.icon name="hero-arrow-up" class="w-3 h-3 mr-0.5" />
                    {result.seeders}
                  </div>
                <% end %>
                <%!-- Main content (title + badges) --%>
                <div class="flex-1 min-w-0">
                  <%!-- Release Title --%>
                  <div
                    class="font-medium text-sm leading-tight mb-2 line-clamp-2"
                    title={result.title}
                  >
                    {result.title}
                  </div>
                  <%!-- Quality badges row --%>
                  <div class="flex flex-wrap gap-1.5">
                    <%!-- Resolution/Quality badge --%>
                    <span class="badge badge-primary badge-sm">
                      {get_search_quality_badge(result)}
                    </span>
                    <%!-- Size badge --%>
                    <span class="badge badge-ghost badge-sm font-mono">
                      {format_search_size(result)}
                    </span>
                    <%!-- Seeders badge --%>
                    <span class={[
                      "badge badge-sm",
                      result.seeders >= 50 && "badge-success",
                      result.seeders >= 10 && result.seeders < 50 && "badge-warning",
                      result.seeders < 10 && "badge-error badge-outline"
                    ]}>
                      <.icon name="hero-arrow-up" class="w-3 h-3 mr-0.5" />
                      {result.seeders}
                    </span>
                    <%!-- Indexer badge (visible on larger screens) --%>
                    <span class="badge badge-outline badge-sm hidden sm:inline-flex">
                      {result.indexer}
                    </span>
                  </div>
                </div>
                <%!-- Download Action --%>
                <div class="flex items-center">
                  <button
                    class={[
                      "btn btn-primary btn-sm",
                      @downloading_release_url == result.download_url && "btn-disabled"
                    ]}
                    phx-click="download_from_search"
                    phx-value-download-url={result.download_url}
                    phx-value-title={result.title}
                    phx-value-indexer={result.indexer}
                    phx-value-size={result.size || 0}
                    phx-value-seeders={result.seeders || 0}
                    phx-value-leechers={result.leechers || 0}
                    phx-value-quality={get_search_quality_badge(result) || "Unknown"}
                    title="Download this release"
                    disabled={@downloading_release_url == result.download_url}
                  >
                    <%= if @downloading_release_url == result.download_url do %>
                      <span class="loading loading-spinner loading-xs"></span>
                    <% else %>
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    <% end %>
                    <span class="hidden sm:inline">
                      {if @downloading_release_url == result.download_url, do: "...", else: "Download"}
                    </span>
                  </button>
                </div>
              </li>
            </ul>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_manual_search_modal"></div>
    </div>
    """
  end

  @doc """
  Rename files modal showing preview of current and proposed filenames.
  """
  attr :rename_previews, :list, required: true
  attr :renaming_files, :boolean, required: true

  def rename_files_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl max-h-[85vh] flex flex-col p-0">
        <%!-- Modal Header --%>
        <div class="sticky top-0 z-10 bg-base-100 border-b border-base-300 px-4 py-3">
          <div class="flex items-center justify-between gap-4">
            <h3 class="text-lg font-bold">Rename Files</h3>
            <button
              type="button"
              phx-click="hide_rename_modal"
              class="btn btn-ghost btn-xs btn-circle"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <%!-- Modal Body --%>
        <div class="flex-1 overflow-y-auto p-3">
          <%= if Enum.empty?(@rename_previews) do %>
            <div class="flex flex-col items-center justify-center py-12 text-center">
              <.icon name="hero-exclamation-circle" class="w-12 h-12 text-base-content/20 mb-3" />
              <h3 class="text-lg font-semibold text-base-content/70 mb-1">No Files to Rename</h3>
              <p class="text-sm text-base-content/50">
                There are no media files to rename.
              </p>
            </div>
          <% else %>
            <div class="space-y-2">
              <%= for preview <- @rename_previews do %>
                <div class="border border-base-300 rounded-lg p-2 bg-base-100">
                  <%!-- Current → Proposed in compact format --%>
                  <div class="flex items-center gap-2 text-xs">
                    <%= if preview.current_filename != preview.proposed_filename do %>
                      <span class="badge badge-primary badge-xs">Rename</span>
                    <% else %>
                      <span class="badge badge-ghost badge-xs">Same</span>
                    <% end %>
                    <div class="flex-1 min-w-0">
                      <div
                        class="font-mono text-base-content/60 truncate"
                        title={preview.current_filename}
                      >
                        {preview.current_filename}
                      </div>
                      <div class="flex items-center gap-1 mt-0.5">
                        <.icon name="hero-arrow-right" class="w-3 h-3 text-primary flex-shrink-0" />
                        <div
                          class="font-mono text-primary font-medium truncate"
                          title={preview.proposed_filename}
                        >
                          {preview.proposed_filename}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        <%!-- Modal Footer --%>
        <div class="sticky bottom-0 bg-base-100 border-t border-base-300 px-4 py-2">
          <%= if !Enum.empty?(@rename_previews) do %>
            <div class="flex items-center justify-between gap-3">
              <div class="text-xs text-base-content/70">
                {Enum.count(@rename_previews, fn p ->
                  p.current_filename != p.proposed_filename
                end)} of {length(@rename_previews)} will be renamed
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  phx-click="hide_rename_modal"
                  class="btn btn-ghost btn-sm"
                  disabled={@renaming_files}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  phx-click="confirm_rename_files"
                  class="btn btn-primary btn-sm"
                  disabled={@renaming_files}
                >
                  <%= if @renaming_files do %>
                    <span class="loading loading-spinner loading-xs"></span> Renaming...
                  <% else %>
                    <.icon name="hero-check" class="w-4 h-4" /> Rename
                  <% end %>
                </button>
              </div>
            </div>
          <% else %>
            <button type="button" phx-click="hide_rename_modal" class="btn btn-ghost btn-sm">
              Close
            </button>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_rename_modal"></div>
    </div>
    """
  end

  @doc """
  Category override modal for changing media item category.
  """
  attr :media_item, :map, required: true
  attr :category_form, :map, required: true
  attr :available_categories, :list, required: true

  def category_override_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Change Category</h3>

        <div class="mb-4 p-3 bg-base-200 rounded-box">
          <div class="flex items-center gap-2 text-sm">
            <span class="text-base-content/70">Current category:</span>
            <%= if @media_item.category do %>
              <.category_badge
                category={@media_item.category}
                override={@media_item.category_override}
              />
            <% else %>
              <span class="text-base-content/50">Not set</span>
            <% end %>
          </div>
          <%= if @media_item.category_override do %>
            <div class="text-xs text-warning mt-2 flex items-center gap-1">
              <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
              Category was manually set and won't change on metadata refresh
            </div>
          <% end %>
        </div>

        <.form
          for={@category_form}
          id="category-override-form"
          phx-change="validate_category"
          phx-submit="save_category"
        >
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text font-medium">Select Category</span>
            </label>
            <.input
              field={@category_form[:category]}
              type="select"
              options={@available_categories}
              prompt="Select a category"
            />
          </div>

          <div class="form-control mb-4">
            <label class="label cursor-pointer justify-start gap-4">
              <.input
                field={@category_form[:override]}
                type="checkbox"
                class="checkbox checkbox-primary"
              />
              <div>
                <span class="label-text font-medium">Lock category</span>
                <p class="label-text-alt mt-1 text-base-content/70">
                  Prevent auto-classification from changing this category
                </p>
              </div>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="hide_category_modal" class="btn btn-ghost">
              Cancel
            </button>
            <%= if @media_item.category_override do %>
              <button
                type="button"
                phx-click="reset_category_to_auto"
                class="btn btn-warning btn-outline"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" /> Reset to Auto
              </button>
            <% end %>
            <button type="submit" class="btn btn-primary">
              Save Category
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="hide_category_modal"></div>
    </div>
    """
  end

  @doc """
  Subtitle search modal for searching and downloading subtitles.
  """
  attr :media_file, :map, required: true
  attr :searching, :boolean, required: true
  attr :subtitle_search_results, :list, required: true
  attr :downloading_subtitle, :boolean, default: false
  attr :selected_languages, :list, default: ["en"]

  def subtitle_search_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <div class="flex items-center justify-between mb-4">
          <h3 class="font-bold text-lg">Search Subtitles</h3>
          <button
            type="button"
            phx-click="close_subtitle_search_modal"
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Language selection --%>
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text">Select Languages</span>
          </label>
          <select
            class="select select-bordered"
            multiple
            phx-change="update_subtitle_languages"
            name="languages[]"
          >
            <option value="en" selected={Enum.member?(@selected_languages, "en")}>
              English
            </option>
            <option value="es" selected={Enum.member?(@selected_languages, "es")}>
              Spanish
            </option>
            <option value="fr" selected={Enum.member?(@selected_languages, "fr")}>
              French
            </option>
            <option value="de" selected={Enum.member?(@selected_languages, "de")}>
              German
            </option>
            <option value="it" selected={Enum.member?(@selected_languages, "it")}>
              Italian
            </option>
            <option value="pt" selected={Enum.member?(@selected_languages, "pt")}>
              Portuguese
            </option>
            <option value="ru" selected={Enum.member?(@selected_languages, "ru")}>
              Russian
            </option>
            <option value="ja" selected={Enum.member?(@selected_languages, "ja")}>
              Japanese
            </option>
            <option value="zh" selected={Enum.member?(@selected_languages, "zh")}>
              Chinese
            </option>
            <option value="ar" selected={Enum.member?(@selected_languages, "ar")}>
              Arabic
            </option>
          </select>
        </div>

        <button
          type="button"
          phx-click="perform_subtitle_search"
          class="btn btn-primary btn-block mb-4"
          disabled={@searching}
        >
          <%= if @searching do %>
            <span class="loading loading-spinner loading-sm"></span> Searching...
          <% else %>
            <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Search Subtitles
          <% end %>
        </button>

        <%!-- Search results --%>
        <%= if @searching do %>
          <div class="flex items-center justify-center py-8">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        <% else %>
          <%= if length(@subtitle_search_results) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Language</th>
                    <th>Format</th>
                    <th>Rating</th>
                    <th>Downloads</th>
                    <th>HI</th>
                    <th>Score</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for result <- @subtitle_search_results do %>
                    <tr>
                      <td>{result.language}</td>
                      <td>
                        <span class="badge badge-ghost badge-sm">{result.format}</span>
                      </td>
                      <td>
                        <%= if result[:rating] do %>
                          <div class="flex items-center gap-1">
                            <.icon name="hero-star-solid" class="w-3 h-3 text-warning" />
                            <span class="text-xs">{result.rating}/10</span>
                          </div>
                        <% else %>
                          <span class="text-base-content/50">—</span>
                        <% end %>
                      </td>
                      <td>
                        <%= if result[:download_count] do %>
                          <span class="text-xs">{result.download_count}</span>
                        <% else %>
                          <span class="text-base-content/50">—</span>
                        <% end %>
                      </td>
                      <td>
                        <%= if result[:hearing_impaired] do %>
                          <.icon name="hero-check-circle-solid" class="w-4 h-4 text-success" />
                        <% else %>
                          <span class="text-base-content/50">—</span>
                        <% end %>
                      </td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          result.score >= 150 && "badge-success",
                          result.score >= 100 && result.score < 150 && "badge-warning",
                          result.score < 100 && "badge-ghost"
                        ]}>
                          {result.score}
                        </span>
                      </td>
                      <td>
                        <button
                          type="button"
                          phx-click="download_subtitle_result"
                          phx-value-file-id={result.file_id}
                          phx-value-language={result.language}
                          phx-value-format={result.format}
                          phx-value-subtitle-hash={result.subtitle_hash}
                          phx-value-rating={result[:rating]}
                          phx-value-download-count={result[:download_count]}
                          phx-value-hearing-impaired={result[:hearing_impaired] || false}
                          class="btn btn-primary btn-xs"
                          disabled={@downloading_subtitle}
                        >
                          <%= if @downloading_subtitle do %>
                            <span class="loading loading-spinner loading-xs"></span>
                          <% else %>
                            <.icon name="hero-arrow-down-tray" class="w-3 h-3" /> Download
                          <% end %>
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>No subtitles found. Try searching with different languages.</span>
            </div>
          <% end %>
        <% end %>

        <div class="modal-action">
          <button type="button" phx-click="close_subtitle_search_modal" class="btn btn-ghost">
            Close
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_subtitle_search_modal"></div>
    </div>
    """
  end

  @doc """
  Trailer modal for viewing embedded YouTube trailer.
  """
  attr :trailer_url, :string, required: true
  attr :title, :string, required: true

  def trailer_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl p-0 overflow-hidden relative">
        <button
          type="button"
          phx-click="hide_trailer_modal"
          class="btn btn-circle btn-sm absolute top-2 right-2 z-10 bg-black/50 border-0 hover:bg-black/70"
        >
          <.icon name="hero-x-mark" class="w-5 h-5 text-white" />
        </button>
        <div class="aspect-video bg-black">
          <iframe
            src={@trailer_url <> "?rel=0&modestbranding=1&autoplay=1"}
            title="Trailer"
            class="w-full h-full"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
            allowfullscreen
          >
          </iframe>
        </div>
      </div>
      <div class="modal-backdrop bg-black/80" phx-click="hide_trailer_modal"></div>
    </div>
    """
  end

  # Private helper component for score breakdown rows
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :score, :float, default: nil
  attr :weight, :integer, required: true

  defp score_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2">
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <span class="text-base-content/70 whitespace-nowrap">{@label}:</span>
        <span class="font-medium truncate">
          {display_value(@value)}
        </span>
      </div>
      <div class="flex items-center gap-1.5 flex-shrink-0">
        <span class={[
          "font-mono font-semibold w-8 text-right",
          score_color(@score)
        ]}>
          {format_score(@score)}
        </span>
        <span class="text-base-content/50 text-[10px] w-8">
          ({@weight}%)
        </span>
      </div>
    </div>
    """
  end

  defp display_value(nil), do: "-"
  defp display_value(value), do: value

  defp format_score(nil), do: "-"
  defp format_score(score) when is_float(score), do: trunc(score)
  defp format_score(score), do: score

  defp score_color(nil), do: "text-base-content/50"
  defp score_color(score) when score >= 80, do: "text-success"
  defp score_color(score) when score >= 50, do: "text-warning"
  defp score_color(_score), do: "text-error"
end
