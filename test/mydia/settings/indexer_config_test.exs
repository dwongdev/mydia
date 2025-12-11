defmodule Mydia.Settings.IndexerConfigTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.IndexerConfig

  describe "changeset/2" do
    @valid_attrs %{
      name: "Test Prowlarr",
      type: :prowlarr,
      base_url: "http://192.168.68.66:9696",
      api_key: "test-api-key"
    }

    test "accepts valid URL with scheme" do
      changeset = IndexerConfig.changeset(%IndexerConfig{}, @valid_attrs)
      assert changeset.valid?
      assert get_change(changeset, :base_url) == "http://192.168.68.66:9696"
    end

    test "normalizes URL without scheme by prepending http://" do
      attrs = Map.put(@valid_attrs, :base_url, "192.168.68.66:9696")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :base_url) == "http://192.168.68.66:9696"
    end

    test "normalizes URL with localhost" do
      attrs = Map.put(@valid_attrs, :base_url, "localhost:9696")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :base_url) == "http://localhost:9696"
    end

    test "preserves https scheme" do
      attrs = Map.put(@valid_attrs, :base_url, "https://secure.example.com:443")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :base_url) == "https://secure.example.com:443"
    end

    test "rejects port number over 65535" do
      attrs = Map.put(@valid_attrs, :base_url, "http://localhost:80192")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      refute changeset.valid?
      assert "port must be between 1 and 65535" in errors_on(changeset).base_url
    end

    test "rejects port number of 0" do
      attrs = Map.put(@valid_attrs, :base_url, "http://localhost:0")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      refute changeset.valid?
      assert "port must be between 1 and 65535" in errors_on(changeset).base_url
    end

    test "accepts valid port at boundary (65535)" do
      attrs = Map.put(@valid_attrs, :base_url, "http://localhost:65535")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
    end

    test "accepts valid port at boundary (1)" do
      attrs = Map.put(@valid_attrs, :base_url, "http://localhost:1")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
    end

    test "rejects invalid scheme" do
      attrs = Map.put(@valid_attrs, :base_url, "ftp://example.com:21")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      refute changeset.valid?
      assert "must use http or https scheme" in errors_on(changeset).base_url
    end

    test "trims whitespace from URL" do
      attrs = Map.put(@valid_attrs, :base_url, "  http://localhost:9696  ")
      changeset = IndexerConfig.changeset(%IndexerConfig{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :base_url) == "http://localhost:9696"
    end
  end
end
