defmodule MetadataRelay.Relay.ClaimTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Relay.Claim

  describe "generate_code/1" do
    test "generates 8 character code by default" do
      code = Claim.generate_code()
      assert String.length(code) == 8
    end

    test "generates code with custom length" do
      code = Claim.generate_code(6)
      assert String.length(code) == 6

      code = Claim.generate_code(10)
      assert String.length(code) == 10
    end

    test "uses only allowed characters" do
      # Generate multiple codes and verify all characters are valid
      alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

      for _ <- 1..100 do
        code = Claim.generate_code()

        code
        |> String.graphemes()
        |> Enum.each(fn char ->
          assert String.contains?(alphabet, char),
                 "Code contains invalid character: #{char}"
        end)
      end
    end

    test "generates unique codes (cryptographic randomness)" do
      # Generate 1000 codes and verify no collisions
      codes =
        1..1000
        |> Enum.map(fn _ -> Claim.generate_code() end)
        |> MapSet.new()

      assert MapSet.size(codes) == 1000,
             "Generated codes are not sufficiently random - found duplicates"
    end

    test "character distribution is roughly uniform" do
      # Generate many codes and check distribution
      # Each character should appear roughly equally often
      alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
      alphabet_size = String.length(alphabet)

      char_counts =
        1..500
        |> Enum.flat_map(fn _ ->
          Claim.generate_code() |> String.graphemes()
        end)
        |> Enum.frequencies()

      # 500 codes * 8 chars = 4000 total chars
      # Expected per char: 4000 / 31 = ~129
      # Allow 40% variance for statistical fluctuation
      expected_avg = 4000 / alphabet_size

      Enum.each(char_counts, fn {char, count} ->
        deviation = abs(count - expected_avg) / expected_avg

        assert deviation < 0.4,
               "Character '#{char}' count #{count} deviates too much from expected #{round(expected_avg)} (#{round(deviation * 100)}%)"
      end)
    end

    test "excludes ambiguous characters (O, 0, I, 1)" do
      # Generate many codes and verify ambiguous chars are never present
      ambiguous = ["O", "0", "I", "1"]

      for _ <- 1..100 do
        code = Claim.generate_code()

        Enum.each(ambiguous, fn char ->
          refute String.contains?(code, char),
                 "Code contains ambiguous character: #{char}"
        end)
      end
    end
  end

  describe "expired?/1" do
    test "returns false for unexpired claim" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      }

      refute Claim.expired?(claim)
    end

    test "returns true for expired claim" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      assert Claim.expired?(claim)
    end
  end

  describe "consumed?/1" do
    test "returns false for unconsumed claim" do
      claim = %Claim{consumed_at: nil}
      refute Claim.consumed?(claim)
    end

    test "returns true for consumed claim" do
      claim = %Claim{consumed_at: DateTime.utc_now()}
      assert Claim.consumed?(claim)
    end
  end

  describe "valid?/1" do
    test "returns true for valid claim (not expired, not consumed)" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        consumed_at: nil
      }

      assert Claim.valid?(claim)
    end

    test "returns false for expired claim" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
        consumed_at: nil
      }

      refute Claim.valid?(claim)
    end

    test "returns false for consumed claim" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        consumed_at: DateTime.utc_now()
      }

      refute Claim.valid?(claim)
    end
  end
end
