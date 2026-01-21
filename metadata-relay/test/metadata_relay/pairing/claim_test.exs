defmodule MetadataRelay.Pairing.ClaimTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Pairing.Claim

  describe "generate_code/1" do
    test "generates 6 character code by default" do
      code = Claim.generate_code()
      assert String.length(code) == 6
    end

    test "generates code with custom length" do
      code = Claim.generate_code(8)
      assert String.length(code) == 8

      code = Claim.generate_code(4)
      assert String.length(code) == 4
    end

    test "uses only allowed characters" do
      # Alphabet without ambiguous characters
      alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

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
      codes =
        1..1000
        |> Enum.map(fn _ -> Claim.generate_code() end)
        |> MapSet.new()

      assert MapSet.size(codes) == 1000,
             "Generated codes are not sufficiently random - found duplicates"
    end

    test "excludes ambiguous characters (O, 0, I, 1, L)" do
      ambiguous = ["O", "0", "I", "1", "L"]

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

  describe "valid?/1" do
    test "returns true for valid claim (not expired)" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      }

      assert Claim.valid?(claim)
    end

    test "returns false for expired claim" do
      claim = %Claim{
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      refute Claim.valid?(claim)
    end
  end
end
