let
  inherit
    (builtins)
    currentSystem
    fromJSON
    readFile
    ;
  getFlake = name:
    with (fromJSON (readFile ./flake.lock)).nodes.${name}.locked; {
      inherit rev;
      outPath = fetchTarball {
        url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
        sha256 = narHash;
      };
    };
in
  {
    system ? currentSystem,
    pkgs ? import (getFlake "nixpkgs") {localSystem = {inherit system;};},
    lib ? pkgs.lib,
    crane,
    cranix,
    fenix,
    stdenv ? pkgs.stdenv,
    ...
  }: let
    # fenix: rustup replacement for reproducible builds
    # toolchain = fenix.${system}.fromToolchainFile { dir = ./..; };
    toolchain = fenix.${system}.fromToolchainFile {
      file = ./rust-toolchain.toml;
      sha256 = "sha256-e4mlaJehWBymYxJGgnbuCObVlqMlQSilZ8FljG9zPHY=";
    };
    # crane: cargo and artifacts manager
    craneLib = crane.${system}.overrideToolchain toolchain;
    # cranix: extends crane building system with workspace bin building and Mold + Cranelift integrations
    cranixLib = craneLib.overrideScope' (cranix.${system}.craneOverride);

    # buildInputs for Examples
    buildInputs = with pkgs; [
      stdenv.cc.cc.lib
      alsa-lib
      udev
      libxkbcommon
      libxkbcommon.dev
      wayland
      wayland-protocols
      xorg.libX11
      xorg.libXcursor
      xorg.libXrandr
      xorg.libXi
      vulkan-loader
    ];

    # Base args, need for build all crate artifacts and caching this for late builds
    deps = {
      nativeBuildInputs = with pkgs;
        [
          pkg-config
          autoPatchelfHook
        ]
        ++ lib.optionals stdenv.buildPlatform.isDarwin [
          pkgs.libiconv
        ]
        ++ lib.optionals stdenv.buildPlatform.isLinux [
          pkgs.libxkbcommon.dev
        ];
      runtimeDependencies = with pkgs;
        lib.optionals stdenv.isLinux [
          wayland
          libGL
          libxkbcommon
        ];
      inherit buildInputs;
    };

    # Lambda for build packages with cached artifacts
    commonArgs = targetName:
      deps
      // {
        src = lib.cleanSourceWith {
          src = craneLib.path ./.;
          filter = craneLib.filterCargoSources;
        };
        doCheck = false;
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "${stdenv.cc.targetPrefix}cc";
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER = "qemu-aarch64";
        HOST_CC = "${stdenv.cc.nativePrefix}cc";
        pname = targetName;
        cargoExtraArgs = "-F dev --example ${targetName}";
      };
      customSkipApp = cranixLib.buildCranixBundle (commonArgs "custom_skip");
      layoutsApp = cranixLib.buildCranixBundle (commonArgs "layouts");
      screensApp = cranixLib.buildCranixBundle (commonArgs "screens");
      simpleApp = cranixLib.buildCranixBundle (commonArgs "simple");
  in {
    # `nix run`
    apps = rec {
      simple = simpleApp.app;
      layouts= layoutsApp.app;
      screens = screensApp.app;
      customSkip = customSkipApp.app;
      default = simple;
    };
    # `nix develop`
    devShells.default = cranixLib.devShell {
      packages = with pkgs;
        [
          toolchain
          pkg-config
          cargo-release
        ]
        ++ buildInputs;
      LD_LIBRARY_PATH = lib.makeLibraryPath buildInputs;
    };
  }
