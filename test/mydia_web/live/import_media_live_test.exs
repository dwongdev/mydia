defmodule MydiaWeb.ImportMediaLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.{Library, Settings}

  describe "session recovery" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "shows resume prompt when user has active import session", %{conn: conn, user: user} do
      # Create an active import session for the user
      {:ok, session} =
        Library.create_import_session(%{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          step: :review,
          scan_path: "/test/media/library",
          scan_stats: %{"total" => 100, "matched" => 80},
          status: :active
        })

      conn = log_in_user(conn, user)

      # Navigate to import page without session_id - should show resume prompt
      {:ok, _view, html} = live(conn, ~p"/import")

      # Should show the resume prompt
      assert html =~ "Resume Previous Import?"
      assert html =~ "Resume Session"
      assert html =~ "Start Fresh"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "start fresh button abandons session and starts new one", %{conn: conn, user: user} do
      # Create an active import session
      {:ok, session} =
        Library.create_import_session(%{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          step: :review,
          scan_path: "/test/media/library",
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import")

      # Click start fresh - push_patch will update the view in place
      html =
        view
        |> element("button", "Start Fresh")
        |> render_click()

      # Should now be on path selection step (not showing resume prompt)
      refute html =~ "Resume Session"
      assert html =~ "Select a Library to Scan"

      # Original session should be abandoned
      updated_session = Library.get_import_session(session.id)
      assert updated_session.status == :abandoned
    end

    test "resume button redirects to existing session", %{conn: conn, user: user} do
      # Create an active import session
      session_id = Ecto.UUID.generate()

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: "/test/media/library",
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import")

      # Click resume - push_patch will update the view in place
      html =
        view
        |> element("button", "Resume Session")
        |> render_click()

      # Should no longer show resume prompt (session was restored)
      refute html =~ "Resume Previous Import?"

      # The session should still be active
      updated_session = Library.get_import_session(session.id)
      assert updated_session.status == :active

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "no resume prompt when user has no active session", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      # Navigate to import page - should redirect to new session
      {:ok, _view, html} = live(conn, ~p"/import") |> follow_redirect(conn)

      # Should NOT show resume prompt - should show path selection
      refute html =~ "Resume Previous Import?"
      assert html =~ "Select a Library to Scan"
    end

    test "completed sessions do not trigger resume prompt", %{conn: conn, user: user} do
      # Create a completed session (not active)
      {:ok, session} =
        Library.create_import_session(%{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          step: :complete,
          scan_path: "/test/media/library",
          status: :completed
        })

      conn = log_in_user(conn, user)

      # Navigate to import page - should redirect to new session, not show resume
      {:ok, _view, html} = live(conn, ~p"/import") |> follow_redirect(conn)

      # Should NOT show resume prompt
      refute html =~ "Resume Previous Import?"
      assert html =~ "Select a Library to Scan"

      # Clean up
      Mydia.Repo.delete(session)
    end
  end

  describe "library type filtering" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "filter_by_library_type filters movies from series-only library", %{user: _user} do
      # Create mock matched files with different media types
      movie_file = %{
        file: %{path: "/media/tv/Movie.2024.mkv", size: 1000},
        match_result: %{
          title: "Test Movie",
          provider_id: "12345",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :movie}
        },
        import_status: :pending
      }

      tv_show_file = %{
        file: %{path: "/media/tv/Show.S01E01.mkv", size: 1000},
        match_result: %{
          title: "Test Show",
          provider_id: "67890",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
        },
        import_status: :pending
      }

      unmatched_file = %{
        file: %{path: "/media/tv/Unknown.mkv", size: 1000},
        match_result: nil,
        import_status: :pending
      }

      matched_files = [movie_file, tv_show_file, unmatched_file]

      # Create a series-only library path
      library_path = %{type: :series, path: "/media/tv"}

      # Call the filter function directly
      {compatible, filtered} = filter_by_library_type(matched_files, library_path)

      # Movies should be filtered out
      assert length(compatible) == 2
      assert length(filtered) == 1

      # The filtered file should be the movie
      assert hd(filtered).match_result.parsed_info.type == :movie

      # TV show and unmatched files should remain
      compatible_types =
        Enum.map(compatible, fn f ->
          if f.match_result, do: f.match_result.parsed_info.type, else: :unmatched
        end)

      assert :tv_show in compatible_types
      assert :unmatched in compatible_types
      refute :movie in compatible_types
    end

    test "filter_by_library_type filters tv shows from movies-only library", %{user: _user} do
      movie_file = %{
        file: %{path: "/media/movies/Movie.2024.mkv", size: 1000},
        match_result: %{
          title: "Test Movie",
          provider_id: "12345",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :movie}
        },
        import_status: :pending
      }

      tv_show_file = %{
        file: %{path: "/media/movies/Show.S01E01.mkv", size: 1000},
        match_result: %{
          title: "Test Show",
          provider_id: "67890",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
        },
        import_status: :pending
      }

      matched_files = [movie_file, tv_show_file]

      # Create a movies-only library path
      library_path = %{type: :movies, path: "/media/movies"}

      {compatible, filtered} = filter_by_library_type(matched_files, library_path)

      # TV shows should be filtered out
      assert length(compatible) == 1
      assert length(filtered) == 1

      # The filtered file should be the TV show
      assert hd(filtered).match_result.parsed_info.type == :tv_show

      # Movie should remain
      assert hd(compatible).match_result.parsed_info.type == :movie
    end

    test "filter_by_library_type allows all types for mixed library", %{user: _user} do
      movie_file = %{
        file: %{path: "/media/mixed/Movie.2024.mkv", size: 1000},
        match_result: %{
          title: "Test Movie",
          provider_id: "12345",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :movie}
        },
        import_status: :pending
      }

      tv_show_file = %{
        file: %{path: "/media/mixed/Show.S01E01.mkv", size: 1000},
        match_result: %{
          title: "Test Show",
          provider_id: "67890",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
        },
        import_status: :pending
      }

      matched_files = [movie_file, tv_show_file]

      # Create a mixed library path
      library_path = %{type: :mixed, path: "/media/mixed"}

      {compatible, filtered} = filter_by_library_type(matched_files, library_path)

      # Nothing should be filtered for mixed libraries
      assert length(compatible) == 2
      assert length(filtered) == 0
    end

    test "filter_by_library_type handles nil library_path gracefully", %{user: _user} do
      movie_file = %{
        file: %{path: "/media/Movie.2024.mkv", size: 1000},
        match_result: %{
          title: "Test Movie",
          provider_id: "12345",
          year: 2024,
          match_confidence: 0.9,
          parsed_info: %{type: :movie}
        },
        import_status: :pending
      }

      matched_files = [movie_file]

      # Nil library path should not filter anything
      {compatible, filtered} = filter_by_library_type(matched_files, nil)

      assert length(compatible) == 1
      assert length(filtered) == 0
    end

    # Helper function that mirrors the LiveView implementation
    defp filter_by_library_type(matched_files, nil), do: {matched_files, []}

    defp filter_by_library_type(matched_files, library_path) do
      case library_path.type do
        :mixed ->
          {matched_files, []}

        :series ->
          Enum.split_with(matched_files, fn matched_file ->
            case matched_file.match_result do
              nil -> true
              match -> match.parsed_info.type != :movie
            end
          end)

        :movies ->
          Enum.split_with(matched_files, fn matched_file ->
            case matched_file.match_result do
              nil -> true
              match -> match.parsed_info.type != :tv_show
            end
          end)

        _ ->
          {matched_files, []}
      end
    end
  end

  describe "import media live with library type filtering" do
    setup do
      user = user_fixture()

      # Create library paths of different types
      {:ok, series_path} =
        Settings.create_library_path(%{
          path: "/test/media/tv_#{System.unique_integer([:positive])}",
          type: :series,
          monitored: true
        })

      {:ok, movies_path} =
        Settings.create_library_path(%{
          path: "/test/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true
        })

      {:ok, mixed_path} =
        Settings.create_library_path(%{
          path: "/test/media/mixed_#{System.unique_integer([:positive])}",
          type: :mixed,
          monitored: true
        })

      %{
        user: user,
        series_path: series_path,
        movies_path: movies_path,
        mixed_path: mixed_path
      }
    end

    test "displays type mismatch stat when files are filtered", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      # The import page redirects to add a session_id, so we follow the redirect
      {:ok, view, _html} = live(conn, ~p"/import") |> follow_redirect(conn)

      # Initial state should not show type_filtered stat (0 filtered files)
      refute view
             |> element(".stat-title", "Type Mismatch")
             |> has_element?()
    end
  end

  describe "manual matching (issue #44)" do
    setup do
      user = user_fixture()

      # Create a movies library path
      {:ok, movies_path} =
        Settings.create_library_path(%{
          path: "/test/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true
        })

      %{user: user, movies_path: movies_path}
    end

    test "renders movie with empty metadata (manually matched file) without crashing", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      # This reproduces issue #44: manual matching of a movie crashes the importer
      # because the metadata is an empty map and accessing .poster_path raises KeyError

      session_id = Ecto.UUID.generate()

      # Create a manually matched movie file with empty metadata
      # This simulates what happens when a user manually matches an unmatched file
      manually_matched_movie = %{
        "file" => %{
          "path" => "#{movies_path.path}/Test.Movie.2024.mkv",
          "size" => 1_500_000_000
        },
        "match_result" => %{
          "title" => "Test Movie",
          "provider_id" => "12345",
          "year" => 2024,
          "match_confidence" => 1.0,
          "manually_edited" => true,
          # Empty metadata is the root cause of issue #44
          # When a file is manually matched, no metadata is fetched,
          # so metadata is set to %{} in the save_edit handler
          "metadata" => %{},
          "parsed_info" => %{
            "type" => "movie",
            "season" => nil,
            "episodes" => []
          }
        },
        "import_status" => "pending"
      }

      # Grouped file with index (required by the UI template)
      grouped_movie = Map.put(manually_matched_movie, "index", 0)

      # Create session with the manually matched file at review step
      session_data = %{
        "matched_files" => [manually_matched_movie],
        "grouped_files" => %{
          "series" => [],
          "movies" => [grouped_movie],
          "ungrouped" => [],
          "type_filtered" => []
        },
        "selected_files" => [0],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 1, "unmatched" => 0},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)

      # Navigate to the import page with the session_id
      # This should NOT crash - before the fix it would raise:
      # KeyError: key :poster_path not found in: %{}
      {:ok, view, html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Verify the page rendered successfully
      assert html =~ "Review Matches"
      assert html =~ "Test Movie"

      # Verify the movie is in the list and displays correctly
      # (without a poster since metadata is empty)
      assert has_element?(view, "#selection-toolbar")

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "save_edit creates match with empty metadata for unmatched file", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      # This test verifies the flow that leads to the crash:
      # 1. User has an unmatched file
      # 2. User clicks edit and searches for a match
      # 3. User selects a result and saves
      # 4. The match_result is created with metadata: %{}
      # 5. On next render, accessing match.metadata.poster_path crashes

      session_id = Ecto.UUID.generate()

      # Create an unmatched file
      unmatched_file = %{
        "file" => %{
          "path" => "#{movies_path.path}/Unknown.Movie.2024.mkv",
          "size" => 1_500_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      # Grouped file with index (required by the UI template)
      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click the edit button for the unmatched file
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Simulate selecting a search result (this updates the form)
      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-12345",
        "title" => "The Manual Match Movie",
        "year" => "2024",
        "type" => "movie"
      })

      # Save the edit - this creates a match with empty metadata
      # After the fix, this should not crash
      html =
        view
        |> element("form#edit-form-0")
        |> render_submit(%{
          "edit_form" => %{
            "title" => "The Manual Match Movie",
            "provider_id" => "movie-12345",
            "year" => "2024",
            "type" => "movie",
            "season" => "",
            "episodes" => ""
          }
        })

      # Verify the page didn't crash and shows the matched movie
      assert html =~ "The Manual Match Movie"
      assert html =~ "Match created successfully"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "save_edit includes provider_type when creating a new match (issue #52)", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      # This test verifies the fix for issue #52: provider_type must be included
      # when creating a new match for a previously unmatched file.
      # Without provider_type, MetadataEnricher.enrich/2 fails with:
      # "Invalid match result - missing provider_id or provider_type"

      session_id = Ecto.UUID.generate()

      unmatched_file = %{
        "file" => %{
          "path" => "#{movies_path.path}/Issue52.Test.Movie.mkv",
          "size" => 1_500_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click edit on the unmatched file
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Select a search result
      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-52",
        "title" => "Issue 52 Test",
        "year" => "2024",
        "type" => "movie"
      })

      # Save the edit
      view
      |> element("form#edit-form-0")
      |> render_submit(%{
        "edit_form" => %{
          "title" => "Issue 52 Test",
          "provider_id" => "movie-52",
          "year" => "2024",
          "type" => "movie",
          "season" => "",
          "episodes" => ""
        }
      })

      # Retrieve the updated session to verify the match result
      updated_session = Library.get_import_session(session_id)
      matched_files = updated_session.session_data["matched_files"]

      assert length(matched_files) == 1
      match_result = hd(matched_files)["match_result"]

      # Verify provider_type is set (this is the fix for issue #52)
      assert match_result["provider_type"] == "tmdb",
             "provider_type should be 'tmdb' but got: #{inspect(match_result["provider_type"])}"

      assert match_result["provider_id"] == "movie-52"
      assert match_result["title"] == "Issue 52 Test"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "editing an already matched movie to change the match", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      session_id = Ecto.UUID.generate()

      # Create an already matched movie file
      matched_movie = %{
        "file" => %{
          "path" => "#{movies_path.path}/Original.Movie.2023.mkv",
          "size" => 2_000_000_000
        },
        "match_result" => %{
          "title" => "Original Movie",
          "provider_id" => "movie-11111",
          "year" => 2023,
          "match_confidence" => 0.9,
          "manually_edited" => false,
          "metadata" => %{"poster_path" => "/original.jpg"},
          "parsed_info" => %{
            "type" => "movie",
            "season" => nil,
            "episodes" => []
          }
        },
        "import_status" => "pending"
      }

      grouped_movie = Map.put(matched_movie, "index", 0)

      session_data = %{
        "matched_files" => [matched_movie],
        "grouped_files" => %{
          "series" => [],
          "movies" => [grouped_movie],
          "ungrouped" => [],
          "type_filtered" => []
        },
        "selected_files" => [0],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 1, "unmatched" => 0},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Verify original movie is displayed
      assert html =~ "Original Movie"

      # Click the edit button for the matched movie
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # The edit form should show
      assert has_element?(view, "form#edit-form-0")

      # Select a different search result
      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-99999",
        "title" => "Updated Movie Title",
        "year" => "2024",
        "type" => "movie"
      })

      # Save the edit
      html =
        view
        |> element("form#edit-form-0")
        |> render_submit(%{
          "edit_form" => %{
            "title" => "Updated Movie Title",
            "provider_id" => "movie-99999",
            "year" => "2024",
            "type" => "movie",
            "season" => "",
            "episodes" => ""
          }
        })

      # Verify the movie was updated
      assert html =~ "Updated Movie Title"
      assert html =~ "Match updated successfully"
      # Should show the "Edited" badge
      assert html =~ "Edited"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "clearing a match moves file to unmatched section", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      session_id = Ecto.UUID.generate()

      # Create a matched movie file
      matched_movie = %{
        "file" => %{
          "path" => "#{movies_path.path}/Some.Movie.2024.mkv",
          "size" => 1_500_000_000
        },
        "match_result" => %{
          "title" => "Some Movie",
          "provider_id" => "movie-55555",
          "year" => 2024,
          "match_confidence" => 0.85,
          "manually_edited" => false,
          "metadata" => %{},
          "parsed_info" => %{
            "type" => "movie",
            "season" => nil,
            "episodes" => []
          }
        },
        "import_status" => "pending"
      }

      grouped_movie = Map.put(matched_movie, "index", 0)

      session_data = %{
        "matched_files" => [matched_movie],
        "grouped_files" => %{
          "series" => [],
          "movies" => [grouped_movie],
          "ungrouped" => [],
          "type_filtered" => []
        },
        "selected_files" => [0],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 1, "unmatched" => 0},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Verify the movie is shown as matched
      assert html =~ "Some Movie"
      assert html =~ "Movie"

      # Click the clear match button
      html =
        view
        |> element("button[phx-click='clear_match'][phx-value-index='0']")
        |> render_click()

      # Verify the file is now in the unmatched section
      assert html =~ "No Match"
      assert html =~ "Some.Movie.2024.mkv"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "canceling an edit preserves original state", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      session_id = Ecto.UUID.generate()

      # Create an unmatched file
      unmatched_file = %{
        "file" => %{
          "path" => "#{movies_path.path}/Unmatched.File.mkv",
          "size" => 1_000_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click the edit button
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Verify edit form is shown
      assert has_element?(view, "form#edit-form-0")

      # Select a search result (but don't save)
      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-77777",
        "title" => "Unsaved Movie",
        "year" => "2024",
        "type" => "movie"
      })

      # Click cancel in the edit form (trigger the event directly)
      html = render_click(view, "cancel_edit")

      # Verify we're back to normal view
      refute has_element?(view, "form#edit-form-0")

      # Verify the file is still unmatched (not the selected title)
      refute html =~ "Unsaved Movie"
      assert html =~ "Unmatched.File.mkv"
      assert html =~ "No Match"

      # Clean up
      Mydia.Repo.delete(session)
    end
  end

  describe "manual matching - TV shows" do
    setup do
      user = user_fixture()

      {:ok, series_path} =
        Settings.create_library_path(%{
          path: "/test/media/tv_#{System.unique_integer([:positive])}",
          type: :series,
          monitored: true
        })

      %{user: user, series_path: series_path}
    end

    test "manually matching an unmatched TV show file with season and episode", %{
      conn: conn,
      user: user,
      series_path: series_path
    } do
      session_id = Ecto.UUID.generate()

      # Create an unmatched TV show file
      unmatched_file = %{
        "file" => %{
          "path" => "#{series_path.path}/Some.Show.S02E05.mkv",
          "size" => 500_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: series_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click the edit button
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Select a TV show search result
      view
      |> render_click("select_search_result", %{
        "provider_id" => "tv-12345",
        "title" => "The Great Show",
        "year" => "2022",
        "type" => "tv_show"
      })

      # Save with season and episode info
      html =
        view
        |> element("form#edit-form-0")
        |> render_submit(%{
          "edit_form" => %{
            "title" => "The Great Show",
            "provider_id" => "tv-12345",
            "year" => "2022",
            "type" => "tv_show",
            "season" => "2",
            "episodes" => "5"
          }
        })

      # Verify the match was created successfully
      assert html =~ "The Great Show"
      assert html =~ "Match created successfully"
      assert html =~ "Edited"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "manually matching TV show with multiple episodes", %{
      conn: conn,
      user: user,
      series_path: series_path
    } do
      session_id = Ecto.UUID.generate()

      # Create an unmatched multi-episode file
      unmatched_file = %{
        "file" => %{
          "path" => "#{series_path.path}/Show.S01E01E02E03.mkv",
          "size" => 1_500_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: series_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click the edit button
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Select a TV show search result
      view
      |> render_click("select_search_result", %{
        "provider_id" => "tv-98765",
        "title" => "Multi-Episode Show",
        "year" => "2023",
        "type" => "tv_show"
      })

      # Save with comma-separated episodes
      html =
        view
        |> element("form#edit-form-0")
        |> render_submit(%{
          "edit_form" => %{
            "title" => "Multi-Episode Show",
            "provider_id" => "tv-98765",
            "year" => "2023",
            "type" => "tv_show",
            "season" => "1",
            "episodes" => "1, 2, 3"
          }
        })

      # Verify the match was created successfully
      assert html =~ "Multi-Episode Show"
      assert html =~ "Match created successfully"

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "editing an already matched TV episode to change season/episode", %{
      conn: conn,
      user: user,
      series_path: series_path
    } do
      session_id = Ecto.UUID.generate()

      # Create an already matched episode with wrong season/episode info
      matched_episode = %{
        "file" => %{
          "path" => "#{series_path.path}/Show.S01E01.mkv",
          "size" => 500_000_000
        },
        "match_result" => %{
          "title" => "Test Series",
          "provider_id" => "tv-11111",
          "year" => 2020,
          "match_confidence" => 0.85,
          "manually_edited" => false,
          "metadata" => %{},
          "parsed_info" => %{
            "type" => "tv_show",
            "season" => 1,
            "episodes" => [1]
          }
        },
        "import_status" => "pending"
      }

      # Group it properly in a series structure
      grouped_series = %{
        "title" => "Test Series",
        "year" => 2020,
        "provider_id" => "tv-11111",
        "seasons" => [
          %{
            "season_number" => 1,
            "episodes" => [Map.put(matched_episode, "index", 0)]
          }
        ]
      }

      session_data = %{
        "matched_files" => [matched_episode],
        "grouped_files" => %{
          "series" => [grouped_series],
          "movies" => [],
          "ungrouped" => [],
          "type_filtered" => []
        },
        "selected_files" => [0],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: series_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 1, "unmatched" => 0},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Verify original episode is displayed
      assert html =~ "Test Series"

      # Click the edit button
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Verify edit form shows
      assert has_element?(view, "form#edit-form-0")

      # Update to a different season and episode
      html =
        view
        |> element("form#edit-form-0")
        |> render_submit(%{
          "edit_form" => %{
            "title" => "Test Series",
            "provider_id" => "tv-11111",
            "year" => "2020",
            "type" => "tv_show",
            "season" => "2",
            "episodes" => "5"
          }
        })

      # Verify the match was updated
      assert html =~ "Match updated successfully"
      assert html =~ "Edited"

      # Clean up
      Mydia.Repo.delete(session)
    end
  end

  describe "manual matching - validation" do
    setup do
      user = user_fixture()

      {:ok, movies_path} =
        Settings.create_library_path(%{
          path: "/test/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true
        })

      %{user: user, movies_path: movies_path}
    end

    test "submit button is disabled until a search result is selected", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      session_id = Ecto.UUID.generate()

      unmatched_file = %{
        "file" => %{
          "path" => "#{movies_path.path}/Unmatched.mkv",
          "size" => 1_000_000_000
        },
        "match_result" => nil,
        "import_status" => "pending"
      }

      grouped_unmatched_file = Map.put(unmatched_file, "index", 0)

      session_data = %{
        "matched_files" => [unmatched_file],
        "grouped_files" => %{
          "series" => [],
          "movies" => [],
          "ungrouped" => [grouped_unmatched_file],
          "type_filtered" => []
        },
        "selected_files" => [],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 1, "matched" => 0, "unmatched" => 1},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Click the edit button
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      # Verify the submit button has the disabled attribute (for unmatched files)
      assert has_element?(view, "button[type='submit'][disabled]")

      # Select a search result
      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-12345",
        "title" => "Found Movie",
        "year" => "2024",
        "type" => "movie"
      })

      # Now the submit button should be enabled
      refute has_element?(view, "button[type='submit'][disabled]")

      # Clean up
      Mydia.Repo.delete(session)
    end

    test "matched file selection state is preserved after editing", %{
      conn: conn,
      user: user,
      movies_path: movies_path
    } do
      session_id = Ecto.UUID.generate()

      # Create multiple files, one selected and one not
      file1 = %{
        "file" => %{
          "path" => "#{movies_path.path}/Movie1.mkv",
          "size" => 1_000_000_000
        },
        "match_result" => %{
          "title" => "Movie One",
          "provider_id" => "movie-111",
          "year" => 2024,
          "match_confidence" => 0.9,
          "manually_edited" => false,
          "metadata" => %{},
          "parsed_info" => %{"type" => "movie", "season" => nil, "episodes" => []}
        },
        "import_status" => "pending"
      }

      file2 = %{
        "file" => %{
          "path" => "#{movies_path.path}/Movie2.mkv",
          "size" => 1_000_000_000
        },
        "match_result" => %{
          "title" => "Movie Two",
          "provider_id" => "movie-222",
          "year" => 2024,
          "match_confidence" => 0.9,
          "manually_edited" => false,
          "metadata" => %{},
          "parsed_info" => %{"type" => "movie", "season" => nil, "episodes" => []}
        },
        "import_status" => "pending"
      }

      grouped_file1 = Map.put(file1, "index", 0)
      grouped_file2 = Map.put(file2, "index", 1)

      session_data = %{
        "matched_files" => [file1, file2],
        "grouped_files" => %{
          "series" => [],
          "movies" => [grouped_file1, grouped_file2],
          "ungrouped" => [],
          "type_filtered" => []
        },
        # Only file at index 0 is selected
        "selected_files" => [0],
        "discovered_files" => [],
        "detailed_results" => []
      }

      {:ok, session} =
        Library.create_import_session(%{
          id: session_id,
          user_id: user.id,
          step: :review,
          scan_path: movies_path.path,
          session_data: session_data,
          scan_stats: %{"total" => 2, "matched" => 2, "unmatched" => 0},
          import_progress: %{"current" => 0, "total" => 0, "current_file" => nil},
          import_results: %{"success" => 0, "failed" => 0, "skipped" => 0},
          status: :active
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/import?session_id=#{session_id}")

      # Edit the selected file
      view
      |> element("button[phx-click='edit_file'][phx-value-index='0']")
      |> render_click()

      view
      |> render_click("select_search_result", %{
        "provider_id" => "movie-999",
        "title" => "Updated Movie One",
        "year" => "2024",
        "type" => "movie"
      })

      view
      |> element("form#edit-form-0")
      |> render_submit(%{
        "edit_form" => %{
          "title" => "Updated Movie One",
          "provider_id" => "movie-999",
          "year" => "2024",
          "type" => "movie",
          "season" => "",
          "episodes" => ""
        }
      })

      # Verify the file is still selected after editing
      # The checkbox for index 0 should be checked
      assert has_element?(
               view,
               "input[type='checkbox'][phx-value-index='0'][checked]"
             )

      # Clean up
      Mydia.Repo.delete(session)
    end
  end
end
