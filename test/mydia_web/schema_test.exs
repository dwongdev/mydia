defmodule MydiaWeb.SchemaTest do
  use ExUnit.Case

  alias Absinthe.Schema

  describe "GraphQL Schema" do
    test "schema compiles and introspects successfully" do
      assert {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]
    end

    test "has Query type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]["queryType"]
      assert introspection.data["__schema"]["queryType"]["name"] == "RootQueryType"
    end

    test "has Mutation type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]["mutationType"]
      assert introspection.data["__schema"]["mutationType"]["name"] == "RootMutationType"
    end

    test "defines Movie type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      movie_type = Enum.find(types, fn t -> t["name"] == "Movie" end)
      assert movie_type
      assert movie_type["kind"] == "OBJECT"

      field_names = Enum.map(movie_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "title" in field_names
      assert "year" in field_names
      assert "overview" in field_names
      assert "artwork" in field_names
      assert "files" in field_names
      assert "progress" in field_names
    end

    test "defines TvShow type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      tv_show_type = Enum.find(types, fn t -> t["name"] == "TvShow" end)
      assert tv_show_type
      assert tv_show_type["kind"] == "OBJECT"

      field_names = Enum.map(tv_show_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "title" in field_names
      assert "seasons" in field_names
      assert "nextEpisode" in field_names
    end

    test "defines Episode type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      episode_type = Enum.find(types, fn t -> t["name"] == "Episode" end)
      assert episode_type
      assert episode_type["kind"] == "OBJECT"

      field_names = Enum.map(episode_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "seasonNumber" in field_names
      assert "episodeNumber" in field_names
      assert "title" in field_names
      assert "files" in field_names
      assert "progress" in field_names
      assert "show" in field_names
    end

    test "defines Season type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      season_type = Enum.find(types, fn t -> t["name"] == "Season" end)
      assert season_type
      assert season_type["kind"] == "OBJECT"

      field_names = Enum.map(season_type["fields"], & &1["name"])
      assert "seasonNumber" in field_names
      assert "episodeCount" in field_names
      assert "episodes" in field_names
    end

    test "defines MovieConnection for pagination" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      connection_type = Enum.find(types, fn t -> t["name"] == "MovieConnection" end)
      assert connection_type
      assert connection_type["kind"] == "OBJECT"

      field_names = Enum.map(connection_type["fields"], & &1["name"])
      assert "edges" in field_names
      assert "pageInfo" in field_names
      assert "totalCount" in field_names
    end

    test "defines enum types" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      assert Enum.find(types, fn t -> t["name"] == "MediaType" end)
      assert Enum.find(types, fn t -> t["name"] == "SortField" end)
      assert Enum.find(types, fn t -> t["name"] == "SortDirection" end)
    end

    test "has browse query fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      query_type = Enum.find(types, fn t -> t["name"] == "RootQueryType" end)
      field_names = Enum.map(query_type["fields"], & &1["name"])

      assert "movie" in field_names
      assert "tvShow" in field_names
      assert "episode" in field_names
      assert "movies" in field_names
      assert "tvShows" in field_names
      assert "seasonEpisodes" in field_names
    end

    test "has discovery query fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      query_type = Enum.find(types, fn t -> t["name"] == "RootQueryType" end)
      field_names = Enum.map(query_type["fields"], & &1["name"])

      assert "continueWatching" in field_names
      assert "recentlyAdded" in field_names
      assert "upNext" in field_names
      assert "search" in field_names
    end

    test "has mutation fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      mutation_type = Enum.find(types, fn t -> t["name"] == "RootMutationType" end)
      field_names = Enum.map(mutation_type["fields"], & &1["name"])

      assert "updateMovieProgress" in field_names
      assert "updateEpisodeProgress" in field_names
      assert "markMovieWatched" in field_names
      assert "markMovieUnwatched" in field_names
      assert "markEpisodeWatched" in field_names
      assert "markEpisodeUnwatched" in field_names
      assert "markSeasonWatched" in field_names
    end

    test "defines Node interface with hierarchical fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      # Check for Node interface
      node_interface = Enum.find(types, fn t -> t["name"] == "Node" end)
      assert node_interface
      assert node_interface["kind"] == "INTERFACE"

      # Check interface fields
      field_names = Enum.map(node_interface["fields"], & &1["name"])
      assert "id" in field_names
      assert "parent" in field_names
      assert "children" in field_names
      assert "ancestors" in field_names
      assert "isPlayable" in field_names
    end

    test "Movie implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      movie_type = Enum.find(types, fn t -> t["name"] == "Movie" end)
      movie_interfaces = Enum.map(movie_type["interfaces"], & &1["name"])
      assert "Node" in movie_interfaces

      # Verify Movie has all interface fields
      field_names = Enum.map(movie_type["fields"], & &1["name"])
      assert "parent" in field_names
      assert "children" in field_names
      assert "ancestors" in field_names
      assert "isPlayable" in field_names
    end

    test "TvShow implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      tv_show_type = Enum.find(types, fn t -> t["name"] == "TvShow" end)
      tv_show_interfaces = Enum.map(tv_show_type["interfaces"], & &1["name"])
      assert "Node" in tv_show_interfaces
    end

    test "Episode implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      episode_type = Enum.find(types, fn t -> t["name"] == "Episode" end)
      episode_interfaces = Enum.map(episode_type["interfaces"], & &1["name"])
      assert "Node" in episode_interfaces
    end

    test "Season implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      season_type = Enum.find(types, fn t -> t["name"] == "Season" end)
      season_interfaces = Enum.map(season_type["interfaces"], & &1["name"])
      assert "Node" in season_interfaces

      # Verify Season now has an id field
      field_names = Enum.map(season_type["fields"], & &1["name"])
      assert "id" in field_names
    end

    test "LibraryPath implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      library_path_type = Enum.find(types, fn t -> t["name"] == "LibraryPath" end)
      library_path_interfaces = Enum.map(library_path_type["interfaces"], & &1["name"])
      assert "Node" in library_path_interfaces
    end
  end
end
