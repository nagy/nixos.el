;;; evil-nixos-test.el --- Tests for evil-nixos  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;; To run these tests:
;;
;;   (require 'evil-nixos-test)
;;   (require 'ert)
;;
;; Then: M-x ert RET evil-nixos

;;; Code:

(require 'evil)
(require 'evil-nixos)
(require 'ert)
(require 'cl-lib)

(declare-function evil-get-auxiliary-keymap "evil-core")


;;; Helpers

(defun evil-nixos-test--aux (keymap)
  "Return the normal state auxiliary KEYMAP of KEYMAP."
  (evil-get-auxiliary-keymap keymap 'normal))

(defun evil-nixos-test--hash (&rest pairs)
  "Build a hash table from PAIRS of key and value."
  (let ((table (make-hash-table :test 'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) table))
    table))


;;; State

(ert-deftest evil-nixos-initial-state-is-normal ()
  "The browse modes start in the Evil normal state."
  (dolist (mode '(nixos-browse-mode
                  nixos-browse-options-mode
                  nixos-browse-packages-mode))
    (should (eq (evil-initial-state mode) 'normal))))


;;; Detail keys

(ert-deftest evil-nixos-detail-keys ()
  "A detail buffer keeps its own keys in the normal state."
  (let ((aux (evil-nixos-test--aux nixos-browse-mode-map)))
    (should (eq (lookup-key aux (kbd "gr")) #'nixos-browse-refresh))
    (should (eq (lookup-key aux (kbd "gb")) #'nixos-browse-search-url))
    (should (eq (lookup-key aux (kbd "gR")) #'nixos-browse-show-requisites))
    (should (eq (lookup-key aux (kbd "gd")) #'evil-nixos-goto-definition))
    (should (eq (lookup-key aux (kbd "w")) #'nixos-browse-copy-store-path))
    (should (eq (lookup-key aux (kbd "TAB")) #'nixos-browse-toggle-section))
    ;; The `q', `r' and `b' keys stay with Evil.
    (should-not (lookup-key aux (kbd "q")))
    (should-not (lookup-key aux (kbd "r")))
    (should-not (lookup-key aux (kbd "b")))))

(ert-deftest evil-nixos-detail-g-prefix-keeps-evil-keys ()
  "The `g' prefix of a detail buffer still reaches `gg', `gf' and `gJ'."
  (let ((g (lookup-key (evil-nixos-test--aux nixos-browse-mode-map)
                       (kbd "g"))))
    (should (eq (lookup-key g (kbd "g")) #'evil-goto-first-line))
    (should (eq (lookup-key g (kbd "f")) #'find-file-at-point))
    (should (eq (lookup-key g (kbd "J")) #'evil-join-whitespace))))

(ert-deftest evil-nixos-flake-overview-keys ()
  "The flake overview binds RET to its own visit command."
  (let ((aux (evil-nixos-test--aux nixos-flake-overview-mode-map)))
    (should (eq (lookup-key aux (kbd "RET")) #'nixos-flake-visit-output))
    (should (eq (lookup-key aux (kbd "gr")) #'nixos-browse-refresh))
    (should (eq (lookup-key aux (kbd "w")) #'nixos-browse-copy-store-path))))


;;; Table keys

(ert-deftest evil-nixos-table-keys ()
  "A table keeps its own keys in the normal state."
  (let ((aux (evil-nixos-test--aux nixos-browse-options-mode-map)))
    (should (eq (lookup-key aux (kbd "RET")) #'nixos-browse-options-visit))
    (should (eq (lookup-key aux (kbd "o"))
                #'nixos-browse-table-other-window))
    (should (eq (lookup-key aux (kbd "w")) #'nixos-browse-table-copy-name))
    (should (eq (lookup-key aux (kbd "b"))
                #'nixos-browse-options-search-url))
    (should (eq (lookup-key aux (kbd "{"))
                #'nixos--browse-table-narrow-column))
    (should (eq (lookup-key aux (kbd "}"))
                #'nixos--browse-table-resize-column))
    (should (eq (lookup-key aux (kbd "gr")) #'revert-buffer))
    (should (keymapp (lookup-key aux (kbd "e"))))
    (should (eq (lookup-key aux (kbd "gg")) #'evil-goto-first-line))))

(ert-deftest evil-nixos-package-table-keys ()
  "The package table binds its own visit and search commands."
  (let ((aux (evil-nixos-test--aux nixos-browse-packages-mode-map)))
    (should (eq (lookup-key aux (kbd "RET")) #'nixos-browse-packages-visit))
    (should (eq (lookup-key aux (kbd "b"))
                #'nixos-browse-packages-search-url))
    (should (keymapp (lookup-key aux (kbd "e"))))))


;;; Definition

(ert-deftest evil-nixos-goto-definition-uses-the-position ()
  "`evil-nixos-goto-definition' visits the Position field when present."
  (let ((position nil)
        (source (make-temp-file "evil-nixos-" nil ".nix")))
    (unwind-protect
        (progn
          (write-region "" nil source)
          (with-temp-buffer
            (setq-local nixos--browse-position (format "%s:12" source))
            (cl-letf (((symbol-function 'find-file-at-point)
                       (lambda (file) (setq position file))))
              (evil-nixos-goto-definition)
              (should (equal position (format "%s:12" source))))))
      (delete-file source))))

(ert-deftest evil-nixos-goto-definition-falls-back ()
  "Without a Position field, the fallback runs `evil-goto-definition'."
  (let ((fallback nil))
    (with-temp-buffer
      (setq-local nixos--browse-position nil)
      (cl-letf (((symbol-function 'evil-goto-definition)
                 (lambda () (interactive) (setq fallback t))))
        (evil-nixos-goto-definition)
        (should fallback)))))


;;; End to end

(ert-deftest evil-nixos-gr-refreshes-the-buffer ()
  "The `gr' key runs the refresh command in a detail buffer."
  (let ((nixos--options-cache (evil-nixos-test--hash))
        (nixos--nixpkgs-root nil)
        (refreshed nil))
    (let ((data (evil-nixos-test--hash
                 "description" "Enable foo"
                 "declarations" ["nixos/modules/foo.nix"])))
      (puthash "services.foo.enable" data nixos--options-cache)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &optional _action) (set-buffer buf))))
        (nixos--display-option "services.foo.enable" data)
        (evil-local-mode 1)
        (goto-char (point-min))
        (should (eq (key-binding (kbd "gr")) #'nixos-browse-refresh))
        (cl-letf (((symbol-function 'nixos-option)
                   (lambda (_name) (setq refreshed t))))
          (call-interactively (key-binding (kbd "gr"))))
        (should refreshed)
        (kill-buffer)))))

(ert-deftest evil-nixos-tab-folds-the-section ()
  "`TAB' folds the section around point in the normal state."
  (let ((nixos--options-cache (evil-nixos-test--hash))
        (nixos--nixpkgs-root nil))
    (let ((data (evil-nixos-test--hash
                 "description" "Enable foo"
                 "declarations" ["nixos/modules/foo.nix"])))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &optional _action) (set-buffer buf))))
        (nixos--display-option "services.foo.enable" data)
        (evil-local-mode 1)
        (goto-char (point-min))
        (search-forward "nixos/modules/foo.nix")
        (should (eq (key-binding (kbd "TAB")) #'nixos-browse-toggle-section))
        (call-interactively (key-binding (kbd "TAB")))
        (should (equal (nixos--browse-collapsed-sections) '("Declared by")))
        (kill-buffer)))))

(provide 'evil-nixos-test)

;;; evil-nixos-test.el ends here
