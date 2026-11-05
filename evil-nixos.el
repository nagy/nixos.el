;;; evil-nixos.el --- Evil bindings for nixos  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Keywords: tools, unix
;; Package-Requires: ((emacs "30.1") (nixos "0") (evil "0"))

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

;;; Commentary:

;; Opt-in Evil bindings for the nixos browse buffers, in the spirit of an
;; `ol-*' module: nixos.el never loads this file and never requires Evil.
;; Enable it with:
;;
;;   (with-eval-after-load 'evil (require 'evil-nixos))
;;
;; An Evil state keymap takes precedence over a major mode keymap, so an
;; nixos command that must keep its key goes into the auxiliary keymap of
;; the mode.  The detail buffers and the tables start in the normal state
;; instead of the motion state that `special-mode' gets from Evil.
;;
;; A key that opens the `g' prefix goes into a prefix keymap of its own.
;; Drawing on Evil's `g' prefix inside this new prefix would drop the
;; keys of the other state, and copying only one of them would drop `gg'.
;; `evil-nixos--g-prefix' therefore inherits the normal state `g' prefix
;; and adds the motion state keys that it lacks.
;;
;; The shared `w', `o', `{', `}' and `e' keys keep their nixos meaning in
;; a table, and `w' keeps its meaning in a detail buffer.  The detail keys
;; `q', `r' and `b' stay with Evil, and the browser and the requisites view
;; live under the `g' prefix instead.

;;; Code:

(require 'nixos)
(require 'evil nil t)

;; The file byte-compiles without Evil, so the package build needs no
;; Evil dependency.  It still loads Evil when the user did not.
(unless (featurep 'evil)
  (error "Load Evil before evil-nixos"))

;; Value-less defvars: silence the byte-compiler without binding the
;; variables, so Evil's own keymaps survive when Evil loads later.
(defvar evil-normal-state-map)
(defvar evil-motion-state-map)

(declare-function evil-define-key* "evil")
(declare-function evil-set-initial-state "evil")
(declare-function evil-goto-definition "evil")


;;; Point

(defun evil-nixos-goto-definition ()
  "Visit the source position of the buffer, or the definition at point.
A package detail buffer carries the position of its source file in
`nixos--browse-position'.  A buffer without that field falls through
to `evil-goto-definition', which follows the package name or the link
under point."
  (interactive)
  (let ((position (and (boundp 'nixos--browse-position)
                       nixos--browse-position)))
    (if (and position
             (file-exists-p (car (split-string position ":"))))
        (find-file-at-point position)
      (evil-goto-definition))))


;;; Bindings

(defun evil-nixos--g-prefix (bindings)
  "Return a `g' prefix keymap that carries BINDINGS.
BINDINGS is an alist of key string to command.  The keymap inherits
the `g' prefix of the normal state and copies the keys that the `g'
prefix of the motion state adds, so `gg' and `gd' keep their commands
beside the nixos ones."
  (let ((map (make-sparse-keymap))
        (normal-g (and (boundp 'evil-normal-state-map)
                       (lookup-key evil-normal-state-map (kbd "g"))))
        (motion-g (and (boundp 'evil-motion-state-map)
                       (lookup-key evil-motion-state-map (kbd "g")))))
    (when (keymapp normal-g)
      (set-keymap-parent map normal-g))
    (when (keymapp motion-g)
      (map-keymap (lambda (event definition)
                    (unless (lookup-key map (vector event))
                      (define-key map (vector event) definition)))
                  motion-g))
    (dolist (binding bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defun evil-nixos--bind (keymap bindings)
  "Bind BINDINGS into KEYMAP for the normal state.
BINDINGS is an alist of key string to command or keymap."
  (dolist (binding bindings)
    (evil-define-key* 'normal keymap (kbd (car binding)) (cdr binding))))

(defconst evil-nixos-detail-g-bindings
  '(("r" . nixos-browse-refresh)
    ("b" . nixos-browse-search-url)
    ("R" . nixos-browse-show-requisites)
    ("d" . evil-nixos-goto-definition))
  "The `g' prefix keys that a detail buffer adds to Evil's own.")

(defconst evil-nixos-detail-bindings
  '(("w" . nixos-browse-copy-store-path)
    ("TAB" . nixos-browse-toggle-section))
  "The single keys that a detail buffer keeps from its Emacs map.")

(defconst evil-nixos-table-g-bindings
  '(("r" . revert-buffer))
  "The `g' prefix keys that a table adds to Evil's own.")

(defun evil-nixos--setup-detail (keymap)
  "Give KEYMAP the Evil bindings of a detail buffer."
  (evil-define-key* 'normal keymap (kbd "g")
                    (evil-nixos--g-prefix evil-nixos-detail-g-bindings))
  (evil-nixos--bind keymap evil-nixos-detail-bindings)
  keymap)

(defun evil-nixos--setup-table (keymap visit search-url)
  "Give KEYMAP the Evil bindings of a browse table.
VISIT opens the entry of the row at point, and SEARCH-URL opens that
entry on search.nixos.org."
  (evil-define-key* 'normal keymap (kbd "g")
                    (evil-nixos--g-prefix evil-nixos-table-g-bindings))
  (evil-nixos--bind keymap
                    `(("RET" . ,visit)
                      ("o" . nixos-browse-table-other-window)
                      ("w" . nixos-browse-table-copy-name)
                      ("e" . ,nixos-browse-table-export-map)
                      ("{" . nixos--browse-table-narrow-column)
                      ("}" . nixos--browse-table-resize-column)
                      ("b" . ,search-url)))
  keymap)

(evil-set-initial-state 'nixos-browse-mode 'normal)
(evil-set-initial-state 'nixos-browse-options-mode 'normal)
(evil-set-initial-state 'nixos-browse-packages-mode 'normal)

(evil-nixos--setup-detail nixos-browse-mode-map)
;; The overview shows its own keymap through `use-local-map', so it needs
;; its own bindings, and its RET opens the output of the line.
(evil-nixos--setup-detail nixos-flake-overview-mode-map)
(evil-define-key* 'normal nixos-flake-overview-mode-map
  (kbd "RET") #'nixos-flake-visit-output)
(evil-nixos--setup-table nixos-browse-options-mode-map
                         #'nixos-browse-options-visit
                         #'nixos-browse-options-search-url)
(evil-nixos--setup-table nixos-browse-packages-mode-map
                         #'nixos-browse-packages-visit
                         #'nixos-browse-packages-search-url)

(provide 'evil-nixos)

;;; evil-nixos.el ends here
