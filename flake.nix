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
    mcl-standard-hook-source = {
      url = "github:metacraft-labs/devops-modules/c8ef41d446e211892fe9775182b43d5d517554ac";
      flake = false;
    };
    nixos-modules.url = "github:metacraft-labs/devops-modules";
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
        {
          pkgs,
          config,
          system,
          ...
        }:
        let
          legacyFlake = flake-parts.lib.mkFlake { inherit inputs; } {
            imports = [ nixos-modules.modules.flake.git-hooks ];
            systems = [ system ];
            perSystem =
              { config, ... }:
              {
                pre-commit.settings.hooks = {
                  shellcheck.enable = true;
                  nixfmt.enable = true;
                };
                legacyPackages.originalHookSettings = config.pre-commit.settings;
              };
          };
          legacySettings = legacyFlake.legacyPackages.${system}.originalHookSettings;
          nativeHookFactory =
            settings:
            pkgs.runCommand "adapters-native-hook-factory"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.bash
                  settings.package
                ];
              }
              ''
                export XDG_CACHE_HOME="$TMPDIR/adapters-native-factory-cache"
                export GIT_CONFIG_GLOBAL="$TMPDIR/adapters-native-factory-gitconfig"
                export GIT_CONFIG_NOSYSTEM=1
                : > "$GIT_CONFIG_GLOBAL"
                mkdir -p "$XDG_CACHE_HOME" fixture
                cd fixture
                git init --template= >/dev/null
                if git config --get core.hooksPath; then
                  echo 'Unexpected native factory hooksPath authority' >&2
                  exit 1
                fi
                test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
                ln -s ${settings.configFile} .pre-commit-config.yaml
                mkdir -p "$out"
                for hook in pre-commit pre-push; do
                  ${pkgs.lib.getExe settings.package} install -c .pre-commit-config.yaml -t "$hook"
                  install -m 0755 ".git/hooks/$hook" "$out/$hook"
                done
              '';
          expectedNativeHook = nativeHookFactory config.pre-commit.settings;
          expectedLegacyNativeHook = nativeHookFactory legacySettings;
          nativeInstaller = pkgs.writeShellScript "adapters-native-hook-installer" config.pre-commit.installationScript;
          guardedHookInstall = ''
            ${pkgs.python3}/bin/python3 ${./nix/hook-transaction.py} "$_own_repo_root" ${./nix/hook-ownership-guard.py} ${expectedNativeHook} ${pkgs.git}/share/git-core/templates ${expectedLegacyNativeHook} ${config.pre-commit.settings.configFile} ${legacySettings.configFile} ${nativeInstaller} ${pkgs.git}/bin/git ${pkgs.bash}/bin/bash >&2
            _adapter_hook_status=$?
            if [ "$_adapter_hook_status" -ne 0 ]; then
              unset _adapter_hook_status
              exit 1
            fi
            unset _adapter_hook_status
          '';
          # Single-sourced from the nimble file rather than restated here or in
          # a `version.txt`: this package has exactly one version and a second
          # copy of it is a thing that can drift. (`nim-stackable-hooks` and
          # `io-mon` read a `version.txt`; this repository has never had one,
          # and the nimble file is the declaration that already exists.)
          mclStandardHooks = import (inputs.mcl-standard-hook-source + "/git-hooks/standard-hooks.nix");
          nimbleVersionLines = builtins.filter (line: builtins.match "version[[:space:]]*=.*" line != null) (
            pkgs.lib.splitString "\n" (builtins.readFile ./repro_test_adapters.nimble)
          );
          version = builtins.elemAt (builtins.match "version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*" (builtins.head nimbleVersionLines)) 0;
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/this-repo` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            fi
            unset _own_repo_root
          '';
        in
        {
          # `check-license`, which the comparable `nim-stackable-hooks` and
          # `io-mon` flakes enable here, is deliberately NOT enabled: this
          # repository ships no LICENSE file (the nimble metadata says MIT).
          # Adding one is a licensing decision with an owner, not a build fix,
          # and a hook that fails on every commit from the day it lands is not
          # a gate anybody keeps.
          pre-commit.settings.hooks = pkgs.lib.mkMerge [
            (mclStandardHooks {
              inherit pkgs;
              lib = pkgs.lib;
              src = inputs.mcl-standard-hook-source;
            })
            {
              shellcheck.enable = true;
              lint = {
                enable = true;
                name = "Unfiltered adapter source lint";
                entry = "${pkgs.bash}/bin/bash scripts/lint.sh";
                language = "system";
                pass_filenames = false;
                always_run = true;
              };
            }
          ];

          packages.ci-receipt-python = pkgs.python3;

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
            # Not `inputsFrom = [ config.pre-commit.devShell ]`: that shell's
            # hook installs the git hooks without `ownRepoOnly`.
            shellHook = ownRepoOnly guardedHookInstall;
            packages = config.pre-commit.settings.enabledPackages ++ [
              config.pre-commit.settings.package
              pkgs.just
              pkgs.nim2
              pkgs.nimble
              pkgs.git
              pkgs.nixfmt
              pkgs.python3
              pkgs.bash
            ];
          };
        };
    };
}
