{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

melpaBuild (finalAttrs: {
  pname = "nixos";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  packageRequires = [ emacsPackages.nix-mode ];

  turnCompilationWarningToError = true;

  checkPhase = ''
    runHook preCheck
    ${emacs}/bin/emacs --batch -L . \
      -l nixos-tests.el \
      -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Browse NixOS options and packages from Emacs";
    longDescription = ''
      Provides interactive completing-read interfaces for browsing
      NixOS options and Nix packages.  Options are read from a JSON
      file produced by the NixOS manual; packages are read from the
      JSON output of `nix search'.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/nixos.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
})
