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
      self,
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

          # Emacs with Evil, for the opt-in Evil layer.  The package itself
          # needs no Evil: evil-nixos.el byte-compiles without it and
          # loads it only when a user does.
          emacsWithEvil = pkgs.emacs.pkgs.withPackages (epkgs: [
            epkgs.evil
            epkgs.nix-mode
          ]);
        in
        {
          packages.nixos = melpaBuild {
            pname = "nixos";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>,
            # where the date is the last commit touching the source.
            # Derive the date from the flake self-reference. Fall back to
            # the epoch when the source is not a git checkout.
            version =
              let
                d = self.lastModifiedDate or "19700101000000";
              in
              "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

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
              # melpaBuild stages only root-level files into the build
              # directory, so the test tree comes back from the store.
              # A drop first keeps a second copy out at ./test/test, and
              # --no-preserve=mode drops the read-only store bits.
              rm -rf ./test
              cp -r --no-preserve=mode ${./test} ./test
              # Every test runs under the Evil-capable Emacs, so one glob
              # covers the suite and a new test file needs no flake edit.
              # The package itself never loads Evil.
              emacs=${emacsWithEvil}/bin/emacs
              $emacs --batch -L . -L test \
                --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile evil-nixos.el test/*-test.el
              # printf repeats "-l %s" per match, which turns the glob
              # into -l <file> pairs.  failglob makes an empty glob a
              # shell error, so the guard fires even without `set -e'.
              # Restore default glob semantics right after: the unquoted
              # $test_args below relies on them.
              shopt -s failglob
              test_args=$(printf -- "-l %s " test/*-test.elc) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
              shopt -u failglob
              $emacs --batch -L . -L test \
                $test_args \
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

          # Lint gate for the files the byte compiler does not judge:
          # headers, docstrings and prefix rules.  test/ stays inside the
          # lint surface, so tests follow the rules of the code.
          checks.lint =
            pkgs.runCommand "nixos-lint"
              {
                # package-lint reads ELPA headers, so it needs an Emacs that
                # can see the package metadata.
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (epkgs: [ epkgs.package-lint ]))
                  # Gives Emacs a writable HOME, so the builder needs no
                  # `export HOME=$TMPDIR' line and no two checks share a
                  # home directory.
                  pkgs.writableTmpDirAsHomeHook
                ];
                src = config.packages.nixos.src;
              }
              ''
                # src is pre-filtered, so copy the whole tree explicitly
                # instead of relying on what melpaBuild staged.
                cp -r "$src"/. .
                # Warnings print but do not fail: nix-mode ships MELPA date
                # versions, so no honest version pin exists, and Embark has
                # no load-time hook other than `with-eval-after-load'.
                emacs --batch -l package-lint \
                  --eval '(setq package-lint-batch-fail-on-warnings nil)' \
                  --eval '(setq package-lint-main-file "nixos.el")' \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|nixos\\|evil-nixos"))' \
                  --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote nix-mode) (list (package-desc-create :name (quote nix-mode) :version (quote (20240101 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                  -f package-lint-batch-and-exit \
                  *.el test/*.el
                # checkdoc exits 0 on findings, so gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
                  *.el test/*.el 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

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
            # Evil and nix-mode come with it, so the opt-in Evil layer
            # loads without extra setup.
            packages = [ emacsWithEvil ];
          };
        };
    };
}
