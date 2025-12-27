defmodule Mydia.RemoteAccess.DirectUrlsTest do
  use ExUnit.Case, async: true

  alias Mydia.RemoteAccess.DirectUrls

  describe "build_sslip_url/2" do
    test "builds correct sslip.io URL from IP tuple" do
      assert DirectUrls.build_sslip_url({192, 168, 1, 100}, 4000) ==
               "https://192-168-1-100.sslip.io:4000"
    end

    test "handles different IP addresses" do
      assert DirectUrls.build_sslip_url({10, 0, 0, 1}, 8080) ==
               "https://10-0-0-1.sslip.io:8080"
    end

    test "handles different ports" do
      assert DirectUrls.build_sslip_url({192, 168, 1, 1}, 443) ==
               "https://192-168-1-1.sslip.io:443"
    end
  end

  describe "detect_local_urls/0" do
    test "returns list of URLs" do
      urls = DirectUrls.detect_local_urls()

      assert is_list(urls)
      # URLs should be strings
      Enum.each(urls, fn url ->
        assert is_binary(url)
        assert String.starts_with?(url, "https://")
        assert String.contains?(url, ".sslip.io:")
      end)
    end

    test "filters out loopback addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 127.x.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "127-")
             end)
    end

    test "filters out link-local addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 169.254.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "169-254-")
             end)
    end

    test "filters out docker bridge addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 172.17.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "172-17-")
             end)
    end
  end

  describe "detect_all/0" do
    setup do
      # Save original config
      original_config = Application.get_env(:mydia, :direct_urls, [])

      on_exit(fn ->
        # Restore original config
        Application.put_env(:mydia, :direct_urls, original_config)
      end)

      %{original_config: original_config}
    end

    test "includes local URLs" do
      Application.put_env(:mydia, :direct_urls, external_port: 4000)

      urls = DirectUrls.detect_all()

      assert is_list(urls)
      assert length(urls) > 0
    end

    test "includes external URL when configured" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: "https://example.com:443"
      )

      urls = DirectUrls.detect_all()

      assert "https://example.com:443" in urls
    end

    test "includes additional direct URLs when configured" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        additional_direct_urls: [
          "https://custom1.example.com:443",
          "https://custom2.example.com:443"
        ]
      )

      urls = DirectUrls.detect_all()

      assert "https://custom1.example.com:443" in urls
      assert "https://custom2.example.com:443" in urls
    end

    test "merges all URL sources without duplicates" do
      # Set up config with overlapping URLs
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: "https://example.com:443",
        additional_direct_urls: [
          # Duplicate of external_url
          "https://example.com:443",
          "https://custom.example.com:443"
        ]
      )

      urls = DirectUrls.detect_all()

      # Count occurrences of the duplicate URL
      duplicate_count =
        urls
        |> Enum.filter(&(&1 == "https://example.com:443"))
        |> length()

      # Should only appear once
      assert duplicate_count == 1
      assert "https://custom.example.com:443" in urls
    end

    test "filters out nil values" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: nil,
        additional_direct_urls: []
      )

      urls = DirectUrls.detect_all()

      refute nil in urls
      assert is_list(urls)
    end

    test "returns empty list when no URLs available" do
      # This is hard to test since we can't mock :inet.getifaddrs/0,
      # but we can at least verify it doesn't crash
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: nil,
        additional_direct_urls: []
      )

      urls = DirectUrls.detect_all()

      assert is_list(urls)
    end
  end
end
