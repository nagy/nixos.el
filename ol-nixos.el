;;; ol-nixos.el --- Org links to NixOS options and packages -*- lexical-binding: t -*-

;; Copyright (C) 2025-2026  Daniel Nagy

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
;;
;; Loaded automatically via `with-eval-after-load' in nixos.el.

;;; Code:

(require 'ol)
(require 'nixos)


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


(provide 'ol-nixos)
;;; ol-nixos.el ends here
