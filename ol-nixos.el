;;; ol-nixos.el --- Org links to NixOS options and packages  -*- lexical-binding: t; -*-

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
;; Opt-in, like Org's own ol-* modules.  To enable, add to your init:
;;
;;   (with-eval-after-load 'org
;;     (require 'ol-nixos))

;;; Code:

(require 'ol)
(require 'nixos)


;;; Shared export helper

(declare-function org-html-encode-plain-text "ox-html" (text))
(declare-function org-latex-plain-text "ox-latex" (text info))

(defun nixos-org--export (url-template path description backend info)
  "Export an Org link that uses URL-TEMPLATE for PATH.
URL-TEMPLATE is a format string with one %s for the query, PATH
is the link target, DESCRIPTION is the link text, BACKEND is the
export backend and INFO the export plist.

Org transcodes a supplied DESCRIPTION before it reaches an
exporter, so only the link target that stands in for a missing
DESCRIPTION is escaped here."
  (let ((url (nixos--search-url url-template path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url
                     (or description
                         (org-html-encode-plain-text path))))
      ('latex (format "\\href{%s}{%s}" url
                      (or description
                          (org-latex-plain-text path info))))
      (_ (or description path)))))


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

(defun nixos-org-package-export (path description backend info)
  "Export a `nixos-package:' link to search.nixos.org.
PATH is the package name, DESCRIPTION is the link text,
BACKEND is the export backend and INFO the export plist."
  (nixos-org--export nixos-package-search-url-template
                     path description backend info))

(org-link-set-parameters "nixos-package"
                         :follow #'nixos-org-package-open
                         :export #'nixos-org-package-export)


;;; nixos-option: link

(defun nixos-org-option-open (path)
  "Open a `nixos-option:' Org link for PATH."
  (nixos-option path))

(defun nixos-org-option-export (path description backend info)
  "Export a `nixos-option:' link to search.nixos.org.
PATH is the option name, DESCRIPTION is the link text,
BACKEND is the export backend and INFO the export plist."
  (nixos-org--export nixos-option-search-url-template
                     path description backend info))

(org-link-set-parameters "nixos-option"
                         :follow #'nixos-org-option-open
                         :export #'nixos-org-option-export)


;;; nixos-package-search: link

(defun nixos-org-package-search-open (path)
  "Open a `nixos-package-search:' Org link for PATH (search term).
Opens the browse-packages tabulated list filtered to packages
whose names contain PATH as a substring, and signals when no
package matches."
  (nixos-browse-packages (nixos--search-names-or-error 'package path) path))

(defun nixos-org-package-search-export (path description backend info)
  "Export a `nixos-package-search:' link to search.nixos.org.
PATH is the search term, DESCRIPTION is the link text,
BACKEND is the export backend and INFO the export plist."
  (nixos-org--export nixos-package-search-url-template
                     path description backend info))

(org-link-set-parameters "nixos-package-search"
                         :follow #'nixos-org-package-search-open
                         :export #'nixos-org-package-search-export)


;;; nixos-option-search: link

(defun nixos-org-option-search-open (path)
  "Open a `nixos-option-search:' Org link for PATH (search term).
Opens the browse-options tabulated list filtered to options
whose names contain PATH as a substring, and signals when no
option matches."
  (nixos-browse-options (nixos--search-names-or-error 'option path) path))

(defun nixos-org-option-search-export (path description backend info)
  "Export a `nixos-option-search:' link to search.nixos.org.
PATH is the search term, DESCRIPTION is the link text,
BACKEND is the export backend and INFO the export plist."
  (nixos-org--export nixos-option-search-url-template
                     path description backend info))

(org-link-set-parameters "nixos-option-search"
                         :follow #'nixos-org-option-search-open
                         :export #'nixos-org-option-search-export)


(provide 'ol-nixos)
;;; ol-nixos.el ends here
