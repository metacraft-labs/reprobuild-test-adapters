{
  description = "Shared types for building reprobuild test-runner adapters";

  # WHY THIS FILE EXISTS AT ALL, given that every consumer of this repository
  # takes it as a BARE SOURCE TREE (`flake = false`).
  #
  # The `direnv-nix-flake-overrides` plugin the workspace repos load from their
  # `.envrc` refuses to emit an `--override-input` for a sibling checkout that
  # has no `flake.nix` — it logs
  #
  #     warn sibling '…/reprobuild-test-adapters' has no flake.nix; skipping
  #
  # and moves on. The consequence is not "no override": it is a dev shell that
  # silently builds this package from the consumer's `flake.lock` pin while the
  # checkout sitting beside it moves, with nothing anywhere saying the two
  # disagree. That is exactly how reprobuild's `just test` came to be unable to
  # compile at all — `libs/repro_generic_test_recorder` called
  # `testExecutionDeclaration()`, this repository's `dev` had defined it since
  # `af0749a`, the checkout beside reprobuild had it, and reprobuild's pin
  # (`517a484`) did not. Every route into the build agreed with the pin;
  # `.github/workflows/release.yml` had already been taught to override this
  # input to the sibling BY HAND for the same reason, which is the workaround
  # this file retires.
  #
  # So the flake's job is to be a real, evaluable flake that names this source
  # tree. Consumers still declare the input `flake = false` and still get only
  # the tree; the flake is what makes the plugin willing to point at it.

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{ flake-parts, nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nixos-modules.modules.flake.git-hooks
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          # Single-sourced from the nimble file rather than restated here or in
          # a `version.txt`: this package has exactly one version and a second
          # copy of it is a thing that can drift. (`nim-stackable-hooks` and
          # `io-mon` read a `version.txt`; this repository has never had one,
          # and the nimble file is the declaration that already exists.)
          nimbleVersionLines = builtins.filter (line: builtins.match "version[[:space:]]*=.*" line != null) (
            pkgs.lib.splitString "\n" (builtins.readFile ./repro_test_adapters.nimble)
          );
          version = builtins.elemAt (builtins.match "version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*" (builtins.head nimbleVersionLines)) 0;
        in
        {
          # `check-license`, which the comparable `nim-stackable-hooks` and
          # `io-mon` flakes enable here, is deliberately NOT enabled: this
          # repository ships no LICENSE file (the nimble metadata says MIT).
          # Adding one is a licensing decision with an owner, not a build fix,
          # and a hook that fails on every commit from the day it lands is not
          # a gate anybody keeps.
          pre-commit.settings.hooks = {
            shellcheck.enable = true;
            nixfmt.enable = true;
          };

          packages.default = pkgs.stdenv.mkDerivation {
            pname = "repro_test_adapters";
            inherit version;
            src = ./.;

            # A source-only package, like `nim-stackable-hooks`'. There is
            # nothing to compile: `srcDir = "src"` in the nimble file, and every
            # consumer puts `$out/src` on Nim's `--path`.
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r src "$out/src"
              runHook postInstall
            '';
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = [
              pkgs.just
              pkgs.nim2
              pkgs.nimble
              pkgs.git
              pkgs.nixfmt
            ];
          };
        };
    };
}
