{
  description = "Mydia Player - Flutter media player client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # Android SDK configuration
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "34.0.0" "35.0.0" "36.0.0" ];
          platformVersions = [ "34" "35" "36" ];
          abiVersions = [ "arm64-v8a" "x86_64" ];
          includeNDK = true;
          ndkVersions = [ "28.0.13004108" ];
          cmakeVersions = [ "3.22.1" ];
          includeEmulator = false;
        };

        androidSdk = androidComposition.androidsdk;

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
          ] ++ linuxBuildDeps;

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = "${pkgs.jdk17}";

          shellHook = ''
            export PATH="${androidSdk}/libexec/android-sdk/platform-tools:$PATH"
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
