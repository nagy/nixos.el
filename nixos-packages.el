;;; nixos-packages.el --- My local config -*- lexical-binding: t -*-
;; Package-Requires: ((emacs "30.1"))

(eval-and-compile
  (require 'subr-x))

;; NIX-EMACS-PACKAGE: ht
(require 'ht)

;; NIX-EMACS-PACKAGE: nix-mode
(require 'nix-mode)

;; (eval-and-compile
;;   (defun nix-search--parsed ()
;;     (eval-when-compile
;;       (with-temp-buffer
;;         (if (file-exists-p "/etc/nix-search.json")
;;             (insert-file-contents "/etc/nix-search.json")
;;           (insert "{}"))
;;         (goto-char (point-min))
;;         (json-parse-buffer)))))
(defvar nix-search--parsed (eval-when-compile (json-parse-file "/etc/nix-search.json")))

(defun nixos-packages--annotate (cand)
  "Annotate STYLE with CITATION preview."
  (concat (propertize " " 'display '(space :align-to center))
          (string-replace "\n" " "
                          (string-limit (ht-get* nix-search--parsed (concat "legacyPackages.x86_64-linux." cand) "description") 70))))

(defun nixos-packages--collection (str pred action)
  "Completion collection for use in `completing-read'."
  ;; (message "%S %S %S" str pred action)
  (pcase action
    ('metadata '(metadata
                 (annotation-function . nixos-packages--annotate)))
    (_ (complete-with-action action
                             (eval-when-compile
                               (nreverse
                                (--map (string-remove-prefix "legacyPackages.x86_64-linux." it)
                                       (hash-table-keys nix-search--parsed))))
                             str pred))))

(defun nixos-packages-update (cand)
  (interactive (list (completing-read
                      ;; cannot use "package" in the prompt because of `marginalia'
                      "nix-pkg> "
                      #'nixos-packages--collection)))
  (with-current-buffer (get-buffer-create (format "Nixos-Package: %s" cand))
    (atomic-change-group
      (erase-buffer)
      ;; (insert (json-serialize (ht-get* (nix-search--parsed) cand)))
      ;; (insert (shell-command-to-string ""))
      ;; (setq cand (substring cand (length "legacyPackages.x86_64-linux.")))
      (save-excursion
        (cl-assert (zerop
                    (call-process nix-instantiate-executable nil t nil
                                  "--strict" "--json" "--eval" "--argstr" "cand" cand "-E" "{cand}: (import <nixpkgs> {}).${cand}.meta"))))
      ;; from nagy-web package
      (let ((inhibit-message t))
        (jq-format-buffer))
      (dollar "y")
      )
    ;; (cd "/nix/store/5w3dp0m37794iffsbm9vd9f1xmmhda6i-source")
    ;; (js-json-mode)
    (yaml-mode)
    (switch-to-buffer (current-buffer))))

(provide 'nixos-packages)
;;; nixos-packages.el ends here
