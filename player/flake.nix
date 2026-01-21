{
  description = "Mydia Player - Flutter media player client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # Android SDK configuration with NDK
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "30.0.3" "33.0.1" "34.0.0" "35.0.0" "36.0.0" ];
          platformVersions = [ "30" "33" "34" "35" "36" ];
          abiVersions = [ "arm64-v8a" "armeabi-v7a" "x86_64" ];
          includeNDK = true;
          ndkVersions = [ "27.0.12077973" "28.2.13676358" ];
          cmakeVersions = [ "3.22.1" ];
          includeEmulator = false;
        };

        androidSdk = androidComposition.androidsdk;
        ndkPath = "${androidSdk}/libexec/android-sdk/ndk/28.2.13676358";

        # Rust toolchain with Android targets
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [
            "aarch64-linux-android"
            "armv7-linux-androideabi"
            "x86_64-linux-android"
            "i686-linux-android"
          ];
        };

        # Linux build dependencies for Flutter plugins
        linuxBuildDeps = with pkgs; [
          # Build tools
          cmake
          ninja
          pkg-config
          clang

          # GTK3 for Flutter Linux
          gtk3
          gtk3.dev

          # flutter_secure_storage
          libsecret

          # volume_controller (ALSA)
          alsa-lib
          alsa-lib.dev

          # media_kit (video playback)
          mpv
          libass

          # General Linux deps
          pcre2
          util-linux
          libselinux
          libsepol
          libthai
          libdatrie
          xorg.libXdmcp
          libxkbcommon
          libepoxy
        ];

      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.flutter
            androidSdk
            pkgs.jdk17
            rustToolchain
          ] ++ linuxBuildDeps;

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          ANDROID_NDK_HOME = ndkPath;
          NDK_HOME = ndkPath;
          JAVA_HOME = "${pkgs.jdk17}";

          # Cargo configuration for Android cross-compilation
          CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang";
          CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang";
          CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang";
          CARGO_TARGET_I686_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/i686-linux-android21-clang";

          # CC for Android targets
          CC_aarch64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang";
          CC_armv7_linux_androideabi = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang";
          CC_x86_64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang";
          CC_i686_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/i686-linux-android21-clang";

          # AR for Android targets
          AR_aarch64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_armv7_linux_androideabi = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_x86_64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_i686_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";

          shellHook = ''
            export PATH="${androidSdk}/libexec/android-sdk/platform-tools:$PATH"
            # Note: Do NOT add NDK toolchain to PATH - it interferes with Linux builds.
            # Rust cross-compilation uses the CARGO_TARGET_* env vars instead.

            # Delete stale local.properties that may have wrong SDK paths
            rm -f android/local.properties 2>/dev/null || true

            echo ""
            echo "Flutter + Rust Android development shell"
            echo ""
            echo "Rust targets installed:"
            rustup target list --installed 2>/dev/null || rustc --print target-list | grep android | head -4
            echo ""
            echo "To build for Android: flutter run"
            echo "To build APK: flutter build apk"
            echo ""
          '';
        };

        packages.default = pkgs.flutter.buildFlutterApplication {
          pname = "mydia-player";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = linuxBuildDeps;

          pubspecLock = pkgs.lib.importJSON ./pubspec.lock.json;
        };
      }
    );
}
