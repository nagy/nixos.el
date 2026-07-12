{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

rec {

  mkEmacsScreenshot =
    {
      # Emacs Lisp code to run before taking the screenshot
      emacsCode,
      # change this if you want another format
      name ? "emacs-screenshot.png",
      emacs ? pkgs.emacs,
      light ? true,
      ...
    }:
    let
      nixosEl = pkgs.callPackage ./default.nix { };
    in
    pkgs.runCommandLocal name
      {
        NIX_PATH = "nixpkgs=${pkgs.path}";
        NIX_STATE_DIR = "/build/nix-state";
        nativeBuildInputs = [
          (emacs.pkgs.withPackages (e: [
            e.magit-section
            e.modus-themes
            e.marginalia
            nixosEl
          ]))
          pkgs.xvfb-run
          pkgs.iosevka
          pkgs.nixVersions.latest
          pkgs.htop # so the store path exists on disk → blue dired-directory face
        ];
        emacsCodeFile = pkgs.writeText "emacscode.el" emacsCode;
        screenshotScript = pkgs.writeText "script.el" ''
          (run-at-time 10 nil (lambda () (kill-emacs 1)))   ; fallback killing
          (load-theme 'modus-${if light then "operandi" else "vivendi"} t)
          (menu-bar-mode -1)
          (tool-bar-mode -1)
          (toggle-scroll-bar -1)
          (fringe-mode -1)
          (message nil)                            ; clear out echo area
          (defun screenshot-capture ()
            "Export the selected frame as PNG and exit."
            (let ((data (x-export-frames (selected-frame) 'png)))
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert data)
                (write-region (point-min) (point-max) (getenv "out")))
              (kill-emacs 0)))
        '';
      }
      ''
        mkdir -p "$NIX_STATE_DIR"
        HOME=$PWD \
          xvfb-run --server-args="-screen 0 1920x1080x24" \
            emacs --quick --eval="(defalias (quote display-warning) (quote ignore))" \
            -f package-initialize --fullscreen \
            -l modus-themes \
            --font Iosevka\ 21 \
            -l $screenshotScript \
            -l $emacsCodeFile
      '';

  emacsNixosScreenshot =
    {
      light ? true,
    }:
    mkEmacsScreenshot {
      inherit light;
      emacsCode = ''
        (require 'dired)        ; for dired-directory face on store path
        (require 'marginalia)   ; for marginalia-version face on version
        (require 'nix-mode)
        (require 'nixos)
        (add-to-list 'display-buffer-alist
                     '("\\*nixos-" display-buffer-same-window))
        (defun screenshot-poll ()
          "Poll until the target buffer is displayed, then capture."
          (when (get-buffer "*Warnings*")
            (kill-buffer "*Warnings*"))
          (if (and (get-buffer "*nixos-package htop*")
                   (get-buffer-window "*nixos-package htop*"))
              (progn
                (redisplay t)
                (screenshot-capture))
            (run-at-time 0.05 nil #'screenshot-poll)))
        (run-at-time 1 nil (lambda ()
                             (nixos-package "htop")
                             (run-at-time 0.2 nil #'screenshot-poll)))
      '';
    };

  finalizePng =
    image:
    pkgs.runCommandLocal image.name
      {
        inherit image;
        nativeBuildInputs = [
          pkgs.imagemagick
          pkgs.pngquant
        ];
      }
      ''
        magick "$image" \
          -gravity Northwest \
          -bordercolor black -border 1 \
          -mosaic +repage \
          \( +clone -background black -shadow "80x3+3+3" \) \
          +swap \
          -background none -mosaic +repage tmp.png
        pngquant --speed 1 --force --output $out tmp.png
      '';

  svgDualTheme =
    lightImg: darkImg:
    pkgs.runCommandLocal "emacs-screenshot.svg"
      {
        inherit lightImg darkImg;
        template = pkgs.writeText "template.svg" ''
          <?xml version="1.0" encoding="utf-8"?>
          <svg version="1.1" xmlns="http://www.w3.org/2000/svg" x="0px" y="0px"
               viewBox="0 0 1920 1080" xml:space="preserve">
            <defs>
              <style type="text/css">
                  image.light { display: inherit; }
                  image.dark { display: none; }
                  @media ( prefers-color-scheme:dark ) {
                      image.light { display: none; }
                      image.dark { display: inherit; }
                  }
              </style>
            </defs>
            <image class="light" height="1080" width="1920" href="data:image/png;base64,@lightThemeB64@" ></image>
            <image class="dark" height="1080" width="1920" href="data:image/png;base64,@darkThemeB64@" ></image>
          </svg>
        '';
      }
      ''
        lightThemeB64=$(base64 -w0 < $lightImg)
        darkThemeB64=$(base64 -w0 < $darkImg)
        substitute $template $out \
          --subst-var lightThemeB64 \
          --subst-var darkThemeB64
      '';

  png = finalizePng (emacsNixosScreenshot {
    light = true;
  });

  svg =
    svgDualTheme
      (finalizePng (emacsNixosScreenshot {
        light = true;
      }))
      (
        finalizePng (emacsNixosScreenshot {
          light = false;
        })
      );

  gitrepo = pkgs.nur.repos.nagy.lib.mkGitRepository svg;

}
