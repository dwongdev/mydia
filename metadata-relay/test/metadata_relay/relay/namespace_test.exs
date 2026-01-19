defmodule MetadataRelay.Relay.NamespaceTest do
  use ExUnit.Case, async: true
  alias MetadataRelay.Relay.Namespace

  describe "namespace derivation" do
    test "derives consistent namespace for same code and epoch" do
      code = "ABC12345"
      ns1 = Namespace.derive_namespace(code)
      ns2 = Namespace.derive_namespace(code)
      assert ns1 == ns2
      assert String.starts_with?(ns1, "mydia-claim:")
    end

    test "derives different namespaces for different codes" do
      ns1 = Namespace.derive_namespace("CODE1")
      ns2 = Namespace.derive_namespace("CODE2")
      assert ns1 != ns2
    end

    test "valid_namespace? accepts current epoch" do
      code = "VALIDCODE"
      ns = Namespace.derive_namespace(code)
      assert Namespace.valid_namespace?(code, ns)
    end

    test "valid_namespace? accepts previous epoch" do
      code = "OLDCODE"
      # Manually derive for previous epoch
      token = Namespace.derive_token(code, System.os_time(:second) |> div(3600) |> Kernel.-(1))
      ns = "mydia-claim:#{token}"

      assert Namespace.valid_namespace?(code, ns)
    end

    test "valid_namespace? rejects older epochs" do
      code = "ANCIENTCODE"
      # Manually derive for 2 epochs ago
      token = Namespace.derive_token(code, System.os_time(:second) |> div(3600) |> Kernel.-(2))
      ns = "mydia-claim:#{token}"

      refute Namespace.valid_namespace?(code, ns)
    end

    test "valid_namespace? rejects invalid token" do
      code = "SOMECODE"
      ns = "mydia-claim:invalidtoken"
      refute Namespace.valid_namespace?(code, ns)
    end

    test "valid_namespace? rejects invalid format" do
      code = "SOMECODE"
      refute Namespace.valid_namespace?(code, "badformat")
    end
  end
end
