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
          config.allowUnfree = true;
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
          buildInputs = [ pkgs.flutter ] ++ linuxBuildDeps;

          shellHook = ''
            echo "Mydia Player development shell"
            echo "Flutter: $(flutter --version | head -1)"
            echo ""
            echo "Commands:"
            echo "  flutter build linux --release  # Build Linux app"
            echo "  flutter run -d linux           # Run Linux app"
            echo "  flutter pub get                # Get dependencies"
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
