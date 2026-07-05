{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  # Path to the NixOS options JSON.  Defaults to the JSON from a
  # minimal NixOS evaluation (empty config).  Pass
  # "/etc/nixos-options.json" to skip the eval and keep the runtime
  # /etc/ fallback instead.
  nixosOptionsJson ? null,
  # Path to the nixpkgs source tree for building the package search
  # JSON offline.  Defaults to <nixpkgs>.
  nixpkgsPath ? pkgs.path,
}:

let
  nixosOptionsJsonFinal =
    if nixosOptionsJson != null
    then nixosOptionsJson
    else
      let
        emptyEval = import <nixpkgs/nixos/lib/eval-config.nix> {
          modules = [{ system.stateVersion = "25.05"; }];
        };
      in
        "${emptyEval.config.system.build.manual.optionsJSON}/share/doc/nixos/options.json";

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
          search path:${nixpkgsPath} --json "" | jq --sort-keys > $out
      '';

  postPatch = ''
    substituteInPlace nixos.el \
              --replace-fail '/etc/nixos-options.json' ${nixosOptionsJsonFinal}
    substituteInPlace nixos.el \
              --replace-fail '/etc/nixos-search.json' ${nixosSearchJson}
  '';
in
melpaBuild (finalAttrs: {
  pname = "nixos";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  packageRequires = [ emacsPackages.nix-mode ];

  inherit postPatch;

  turnCompilationWarningToError = true;

  checkPhase = ''
    runHook preCheck
    emacs --batch -L . \
      -l nixos-tests.el \
      -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Browse NixOS options and packages from Emacs";
    longDescription = ''
      Provides interactive completing-read interfaces for browsing
      NixOS options and Nix packages.  Data sources are baked in at
      build time via Nix store paths, so no runtime configuration is
      needed when built via default.nix.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/nixos.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
})
