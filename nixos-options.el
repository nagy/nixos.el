;;; nixos-options.el --- My local config -*- lexical-binding: t -*-
;; Package-Requires: ((emacs "30.1"))

;; NIX-EMACS-PACKAGE: ht
(require 'ht)

;; (eval-and-compile
;;   (defun nixos-option--parsed ()
;;     (eval-when-compile
;;       (with-temp-buffer
;;         (if (file-exists-p "/etc/nixos-options.json")
;;             (insert-file-contents "/etc/nixos-options.json")
;;           (insert "{}"))
;;         (goto-char (point-min))
;;         (json-parse-buffer)))))
(defvar nixos-option--parsed (eval-when-compile (json-parse-file "/etc/nixos-options.json")))

(defun nixos-options--annotate (cand)
  "Annotate STYLE with CITATION preview."
  (concat (propertize " " 'display '(space :align-to center))
          (string-replace "\n" " "
                          (string-limit (ht-get* nixos-option--parsed cand "description") 70))))

(defun nixos-options--collection (str pred action)
  "Completion collection for use in `completing-read'."
  (pcase action
    ('metadata '(metadata
                 (annotation-function . nixos-options--annotate)))
    (_ (complete-with-action action
                             (eval-when-compile
                               (nreverse (hash-table-keys nixos-option--parsed)))
                             str pred))))

(defun nixos-options-update ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*nixos-options*")
    (let ((nixpkgs-path (-->  (getenv "NIX_PATH")
                              (string-split it ":")
                              (--filter (string-prefix-p "nixpkgs=" it)
                                        it)
                              car
                              (string-remove-prefix "nixpkgs=" it))))
      (cd nixpkgs-path))
    (let ((cand (completing-read "nixos-option> " #'nixos-options--collection)))
      (atomic-change-group
        ;; (erase-buffer)
        (save-excursion
          (insert (json-serialize (ht-get* nixos-option--parsed cand))))
        ;; from nagy-web package
        (let ((inhibit-message t))
          (jq-format-buffer))
        (dollar "y")
        ))
    (read-only-mode 1)
    ;; (js-json-mode)
    (yaml-mode)
    (switch-to-buffer (current-buffer))))

;; (push (make-deriver "yqMP"
;;                     (b "*nixos-options*")
;;                     (b "*nixos-options-second*"))
;;       derivation--storage)

(provide 'nixos-options)
;;; nixos-options.el ends here
