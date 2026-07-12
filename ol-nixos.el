;;; ol-nixos.el --- Org links to NixOS options and packages -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Org link types for nixos.el.
;;
;;   [[nixos-package:htop]]
;;   [[nixos-package:~/my-project/]]
;;   [[nixos-package:https://github.com/user/repo/archive/main.tar.gz]]
;;   [[nixos-option:programs.htop.enable]]
;;   [[nixos-package-search:htop]]
;;   [[nixos-option-search:programs.htop]]
;;
;; Loaded automatically via `with-eval-after-load' in nixos.el.

;;; Code:

(require 'ol)

(declare-function nixos-package "nixos")
(declare-function nixos-package-local "nixos")
(declare-function nixos-package-url "nixos")
(declare-function nixos-option "nixos")
(declare-function nixos--packages-load "nixos")
(declare-function nixos--options-load "nixos")
(declare-function nixos-browse-packages "nixos")
(declare-function nixos-browse-options "nixos")
(defvar nixos--packages-keys)
(defvar nixos-package-search-url-template)
(defvar nixos-option-search-url-template)


;;; nixos-package: link

(defun nixos-org-package-open (path)
  "Open a `nixos-package:' Org link for PATH.
If PATH looks like a URL, call `nixos-package-url'.
If PATH looks like a directory, call `nixos-package-local'.
Otherwise call `nixos-package'."
  (cond
   ((string-match-p "\\`https?://" path)
    (nixos-package-url path))
   ((string-match-p "\\`[/~.]" path)
    (let ((default-directory (expand-file-name path)))
      (nixos-package-local)))
   (t
    (nixos-package path))))

(defun nixos-org-package-export (path description backend _info)
  "Export a `nixos-package:' link to search.nixos.org.
PATH is the package name, DESCRIPTION is the link text,
BACKEND is the export backend."
  (let ((url (format nixos-package-search-url-template (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(org-link-set-parameters "nixos-package"
                         :follow #'nixos-org-package-open
                         :export #'nixos-org-package-export)


;;; nixos-option: link

(defun nixos-org-option-open (path)
  "Open a `nixos-option:' Org link for PATH."
  (nixos-option path))

(defun nixos-org-option-export (path description backend _info)
  "Export a `nixos-option:' link to search.nixos.org."
  (let ((url (format nixos-option-search-url-template (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(org-link-set-parameters "nixos-option"
                         :follow #'nixos-org-option-open
                         :export #'nixos-org-option-export)


;;; nixos-package-search: link

(defun nixos-org-package-search-open (path)
  "Open a `nixos-package-search:' Org link for PATH (search term).
Opens the browse-packages tabulated list filtered to packages
whose names contain PATH as a substring."
  (nixos--packages-load)
  (let ((matching (cl-remove-if-not
                   (lambda (name)
                     (string-match-p (regexp-quote path) name))
                   nixos--packages-keys)))
    (nixos-browse-packages matching path)))

(defun nixos-org-package-search-export (path description backend _info)
  "Export a `nixos-package-search:' link to search.nixos.org."
  (let ((url (format nixos-package-search-url-template (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(org-link-set-parameters "nixos-package-search"
                         :follow #'nixos-org-package-search-open
                         :export #'nixos-org-package-search-export)


;;; nixos-option-search: link

(defun nixos-org-option-search-open (path)
  "Open a `nixos-option-search:' Org link for PATH (search term).
Opens the browse-options tabulated list filtered to options
whose names contain PATH as a substring."
  (let ((matching (cl-remove-if-not
                   (lambda (name)
                     (string-match-p (regexp-quote path) name))
                   (hash-table-keys (nixos--options-load)))))
    (nixos-browse-options matching path)))

(defun nixos-org-option-search-export (path description backend _info)
  "Export a `nixos-option-search:' link to search.nixos.org."
  (let ((url (format nixos-option-search-url-template (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(org-link-set-parameters "nixos-option-search"
                         :follow #'nixos-org-option-search-open
                         :export #'nixos-org-option-search-export)


(provide 'ol-nixos)
;;; ol-nixos.el ends here
