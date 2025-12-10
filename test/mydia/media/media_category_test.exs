defmodule Mydia.Media.MediaCategoryTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaCategory

  describe "all/0" do
    test "returns all 6 categories" do
      categories = MediaCategory.all()

      assert length(categories) == 6
      assert :movie in categories
      assert :anime_movie in categories
      assert :cartoon_movie in categories
      assert :tv_show in categories
      assert :anime_series in categories
      assert :cartoon_series in categories
    end
  end

  describe "movie_categories/0" do
    test "returns all movie categories" do
      categories = MediaCategory.movie_categories()

      assert length(categories) == 3
      assert :movie in categories
      assert :anime_movie in categories
      assert :cartoon_movie in categories
    end

    test "does not include series categories" do
      categories = MediaCategory.movie_categories()

      refute :tv_show in categories
      refute :anime_series in categories
      refute :cartoon_series in categories
    end
  end

  describe "series_categories/0" do
    test "returns all series categories" do
      categories = MediaCategory.series_categories()

      assert length(categories) == 3
      assert :tv_show in categories
      assert :anime_series in categories
      assert :cartoon_series in categories
    end

    test "does not include movie categories" do
      categories = MediaCategory.series_categories()

      refute :movie in categories
      refute :anime_movie in categories
      refute :cartoon_movie in categories
    end
  end

  describe "animation_categories/0" do
    test "returns all animation categories" do
      categories = MediaCategory.animation_categories()

      assert length(categories) == 4
      assert :anime_movie in categories
      assert :cartoon_movie in categories
      assert :anime_series in categories
      assert :cartoon_series in categories
    end

    test "does not include non-animated categories" do
      categories = MediaCategory.animation_categories()

      refute :movie in categories
      refute :tv_show in categories
    end
  end

  describe "anime_categories/0" do
    test "returns only anime categories" do
      categories = MediaCategory.anime_categories()

      assert length(categories) == 2
      assert :anime_movie in categories
      assert :anime_series in categories
    end

    test "does not include cartoon or regular categories" do
      categories = MediaCategory.anime_categories()

      refute :movie in categories
      refute :cartoon_movie in categories
      refute :tv_show in categories
      refute :cartoon_series in categories
    end
  end

  describe "valid?/1" do
    test "returns true for valid categories" do
      for category <- MediaCategory.all() do
        assert MediaCategory.valid?(category) == true
      end
    end

    test "returns false for invalid atoms" do
      refute MediaCategory.valid?(:invalid)
      refute MediaCategory.valid?(:unknown)
      refute MediaCategory.valid?(:documentary)
    end

    test "returns false for non-atom values" do
      refute MediaCategory.valid?("movie")
      refute MediaCategory.valid?(123)
      refute MediaCategory.valid?(nil)
    end
  end

  describe "movie?/1" do
    test "returns true for movie categories" do
      assert MediaCategory.movie?(:movie)
      assert MediaCategory.movie?(:anime_movie)
      assert MediaCategory.movie?(:cartoon_movie)
    end

    test "returns false for series categories" do
      refute MediaCategory.movie?(:tv_show)
      refute MediaCategory.movie?(:anime_series)
      refute MediaCategory.movie?(:cartoon_series)
    end
  end

  describe "series?/1" do
    test "returns true for series categories" do
      assert MediaCategory.series?(:tv_show)
      assert MediaCategory.series?(:anime_series)
      assert MediaCategory.series?(:cartoon_series)
    end

    test "returns false for movie categories" do
      refute MediaCategory.series?(:movie)
      refute MediaCategory.series?(:anime_movie)
      refute MediaCategory.series?(:cartoon_movie)
    end
  end

  describe "animated?/1" do
    test "returns true for animation categories" do
      assert MediaCategory.animated?(:anime_movie)
      assert MediaCategory.animated?(:cartoon_movie)
      assert MediaCategory.animated?(:anime_series)
      assert MediaCategory.animated?(:cartoon_series)
    end

    test "returns false for non-animated categories" do
      refute MediaCategory.animated?(:movie)
      refute MediaCategory.animated?(:tv_show)
    end
  end

  describe "anime?/1" do
    test "returns true for anime categories" do
      assert MediaCategory.anime?(:anime_movie)
      assert MediaCategory.anime?(:anime_series)
    end

    test "returns false for non-anime categories" do
      refute MediaCategory.anime?(:movie)
      refute MediaCategory.anime?(:cartoon_movie)
      refute MediaCategory.anime?(:tv_show)
      refute MediaCategory.anime?(:cartoon_series)
    end
  end

  describe "label/1" do
    test "returns human-readable labels for all categories" do
      assert MediaCategory.label(:movie) == "Movie"
      assert MediaCategory.label(:anime_movie) == "Anime Movie"
      assert MediaCategory.label(:cartoon_movie) == "Cartoon Movie"
      assert MediaCategory.label(:tv_show) == "TV Show"
      assert MediaCategory.label(:anime_series) == "Anime Series"
      assert MediaCategory.label(:cartoon_series) == "Cartoon Series"
    end
  end

  describe "badge_color/1" do
    test "returns badge color classes for all categories" do
      assert MediaCategory.badge_color(:movie) == "badge-primary"
      assert MediaCategory.badge_color(:anime_movie) == "badge-secondary"
      assert MediaCategory.badge_color(:cartoon_movie) == "badge-accent"
      assert MediaCategory.badge_color(:tv_show) == "badge-primary"
      assert MediaCategory.badge_color(:anime_series) == "badge-secondary"
      assert MediaCategory.badge_color(:cartoon_series) == "badge-accent"
    end
  end

  describe "for_library_type/1" do
    test "returns movie categories for :movies library type" do
      categories = MediaCategory.for_library_type(:movies)

      assert categories == [:movie, :anime_movie, :cartoon_movie]
    end

    test "returns series categories for :series library type" do
      categories = MediaCategory.for_library_type(:series)

      assert categories == [:tv_show, :anime_series, :cartoon_series]
    end

    test "returns all categories for :mixed library type" do
      categories = MediaCategory.for_library_type(:mixed)

      assert categories == MediaCategory.all()
    end

    test "returns empty list for unsupported library types" do
      assert MediaCategory.for_library_type(:music) == []
      assert MediaCategory.for_library_type(:books) == []
      assert MediaCategory.for_library_type(:adult) == []
      assert MediaCategory.for_library_type(:unknown) == []
      assert MediaCategory.for_library_type(nil) == []
    end
  end
end
