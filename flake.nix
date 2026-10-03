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
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            # The installer moves each Reprobuild hook dispatcher aside to
            # `<hook>.legacy` and puts pre-commit's shim in its slot, so the managed
            # hook (for pre-push, the publication gate) runs only by accident. Put the
            # dispatcher back and chain the shim as `<hook>.repro-local`, which the
            # dispatcher runs: the layout `repro hooks ensure --vcs` produces.
            _hooks="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
            for _legacy in "$_hooks"/*.legacy; do
              [ -f "$_legacy" ] && grep -q 'reprobuild hook dispatcher' "$_legacy" || continue
              _slot="''${_legacy%.legacy}"
              if [ -f "$_slot" ] && grep -q 'reprobuild hook dispatcher' "$_slot"; then
                rm -f "$_legacy"
              elif [ ! -e "$_slot" ] || grep -Eq '^# File generated by (pre-commit|prek)' "$_slot"; then
                if [ -f "$_slot.repro-local" ] && ! grep -Eq '^# File generated by (pre-commit|prek)' "$_slot.repro-local"; then
                  echo "git-hooks: $_slot.repro-local is your own hook; run 'repro hooks ensure --vcs' to reconcile." >&2
                  continue
                fi
                if [ -e "$_slot" ]; then mv -f "$_slot" "$_slot.repro-local"; fi
                mv -f "$_legacy" "$_slot"
              else
                echo "git-hooks: $_slot is not a pre-commit shim; run 'repro hooks ensure --vcs' to reconcile." >&2
              fi
            done
            unset _hooks _legacy _slot
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
            # Not `inputsFrom = [ config.pre-commit.devShell ]`: that shell's
            # hook installs the git hooks without `ownRepoOnly`.
            shellHook = ownRepoOnly config.pre-commit.installationScript;
            packages = config.pre-commit.settings.enabledPackages ++ [
              config.pre-commit.settings.package
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
