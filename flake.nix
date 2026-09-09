{
  description = "Browse NixOS options and packages from Emacs (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch (and darwin if the deps exist there).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          lib,
          config,
          ...
        }:
        let
          inherit (pkgs.emacsPackages) melpaBuild;

          # Options JSON from a minimal NixOS evaluation (empty config).
          # The derivation hits the NixOS binary cache, so no local build
          # is needed on a hit.  Evaluated against this flake's nixpkgs
          # input (pkgs.path) instead of <nixpkgs>, since flakes have no
          # NIX_PATH lookup.
          nixosOptionsJson =
            let
              emptyEval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
                inherit system;
                modules = [ { system.stateVersion = "25.05"; } ];
              };
            in
            "${emptyEval.config.system.build.manual.optionsJSON}/share/doc/nixos/options.json";

          # Offline package-search index built from the same nixpkgs, so
          # the baked-in store paths always agree with the evaluated
          # package metadata.
          nixosSearchJson =
            pkgs.runCommandLocal "nix-search.json"
              {
                nativeBuildInputs = [
                  pkgs.nixVersions.latest
                  pkgs.writableTmpDirAsHomeHook
                  pkgs.jq
                ];
              }
              ''
                echo '{"flakes":[],"version":2}' > empty-registry.json
                nix --offline --store ./. \
                  --extra-experimental-features 'nix-command flakes' \
                  --option flake-registry $PWD/empty-registry.json \
                  search path:${pkgs.path} --json "" | jq --sort-keys > $out
              '';
        in
        {
          packages.nixos = melpaBuild {
            pname = "nixos";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<date of
            # last commit touching the source>.
            version = "0.1.0-unstable-2026-09-06";

            src = lib.cleanSource ./.;

            packageRequires = [ pkgs.emacsPackages.nix-mode ];

            # Bake the store paths of the options/search JSON into the
            # defcustom defaults, so no runtime configuration is needed.
            postPatch = ''
              substituteInPlace nixos.el \
                --replace-fail '/etc/nixos-options.json' ${nixosOptionsJson}
              substituteInPlace nixos.el \
                --replace-fail '/etc/nixos-search.json' ${nixosSearchJson}
            '';

            # Byte-compilation warnings fail the build. Keep it on: it is
            # the cheapest lint the package will ever get.
            turnCompilationWarningToError = true;

            checkPhase = ''
              runHook preCheck
              emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile nixos-tests.el
              emacs --batch -L . \
                -l nixos-tests.elc \
                -f ert-run-tests-batch-and-exit
              runHook postCheck
            '';

            doCheck = true;

            meta = {
              description = "Browse NixOS options and packages from Emacs";
              longDescription = ''
                Provides interactive completing-read interfaces for
                browsing NixOS options and Nix packages.

                Data sources are baked in at build time via Nix store
                paths, so no runtime configuration is needed when built
                via this flake.
              '';
              license = lib.licenses.agpl3Plus;
              homepage = "https://github.com/nagy/nixos.el";
              maintainers = with lib.maintainers; [ nagy ];
              platforms = lib.platforms.unix;
            };
          };

          packages.default = config.packages.nixos;

          # `nix fmt` formats the flake (and any future sources) via
          # treefmt, never the formatters standalone.
          formatter = treefmt-nix.lib.mkWrapper pkgs {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          devShells.default = pkgs.mkShell {
            # A real Emacs for interactive testing of the built package:
            #   nix build
            #   emacs -l result/share/emacs/site-lisp/elpa/nixos-*/nixos-autoloads.el
            packages = [ pkgs.emacs ];
          };
        };
    };
}
