;;; nixos.el --- Browse NixOS options and packages  -*- lexical-binding: t; -*-

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

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, unix
;; URL: https://github.com/nagy/nixos.el
;; Package-Requires: ((emacs "30.1") (magit-section "3.0.0") (nix-mode "0"))

;;; Commentary:

;; This package provides interactive `completing-read' interfaces for
;; browsing NixOS options and Nix packages.
;;
;; Data sources are configurable via `defcustom':
;;
;;   - `nixos-options-json-file'  -- NixOS option descriptions
;;     (from the NixOS manual; flake.nix derives it from an empty
;;     NixOS evaluation and bakes the store path in).
;;
;;   - `nixos-search-json-file'   -- output of `nix search --json'
;;     (flake.nix builds it from the same nixpkgs as the evaluation).
;;
;; Commands:
;;
;;   M-x nixos-option   -- browse NixOS options
;;   M-x nixos-package  -- browse Nix packages
;;   M-x nixos-browse-options / nixos-browse-packages -- table views
;;   M-x nixos-package-local / nixos-package-url -- local/remote pkgs
;;
;; Both commands use the standard completion framework, so they work
;; with icomplete, vertico, fido-mode, etc.  Annotation support is
;; provided out of the box.
;;
;; Deep integration:
;;
;;   - `nixos-browse-mode' (major mode) powers the detail buffer with
;;     bookmark support and a `b' key to open search.nixos.org.
;;
;;   - Browse tables: `nixos-browse-options' / `nixos-browse-packages'
;;     display sortable `tabulated-list-mode' tables with refresh
;;     (`g'), bookmark support, and Embark export targets.
;;
;;   - `thingatpt' integration: in `nix-mode' buffers, point on a
;;     dotted identifier like `services.foo.enable' yields it via
;;     (thing-at-point 'nixos-option).  Call (nixos-thing-at-point-setup)
;;     from `nix-mode-hook' to enable.
;;
;;   - Completion metadata includes `category' for Embark actions.
;;
;; Usage:
;;
;;   (with-eval-after-load 'nix-mode
;;     (add-hook 'nix-mode-hook #'nixos-thing-at-point-setup))
;; Org link types (nixos-package:, nixos-option:, ...) are provided
;; by the separate opt-in module ol-nixos.el:
;;
;;   (with-eval-after-load 'org
;;     (require 'ol-nixos))

;;; Code:

(require 'json)
(require 'goto-addr)
(require 'magit-section)
(require 'tabulated-list)
(require 'thingatpt)
(require 'cl-lib)

;; Forward-declare; nix-mode is optional at compile time.
(defvar nix-instantiate-executable)
(defvar nix-executable)
(declare-function display-buffer-other-window "window")
;; Tired and buffer-url are optional: `nixos--display-path' and
;; `nixos--display-url' guard on `fboundp'.
(declare-function tired-shorten-path "tired-core")
(declare-function buffer-url-pretty-print "buffer-url")

(defgroup nixos nil
  "Browse NixOS options and packages."
  :group 'tools
  :prefix "nixos-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/nixos.el"))

(defcustom nixos-options-json-file "/etc/nixos-options.json"
  "Path to the NixOS options JSON file.
This file should contain a flat JSON object where each key is a
dotted option path (e.g. \"services.postgresql.enable\") and each
value is an object with at least a \"description\" field.

NixOS can populate this via `environment.etc'.  A package build
substitutes the path with a Nix store path, as the `postPatch' of
flake.nix does."
  :type 'file
  :group 'nixos)

(defcustom nixos-search-json-file "/etc/nixos-search.json"
  "Path to the Nix package search JSON file.
This file should contain the output of `nix search --json'.
Keys typically look like \"legacyPackages.x86_64-linux.htop\".

See the `postPatch' of flake.nix, which builds such a file from
this flake's nixpkgs and substitutes the store path into this
default."
  :type 'file
  :group 'nixos)

(defcustom nixos-annotation-width 70
  "Maximum width of the description annotation shown during completion."
  :type 'integer
  :group 'nixos)

(defcustom nixos-option-search-url-template
  "https://search.nixos.org/options?channel=unstable&query=%s"
  "URL template for browsing an option on search.nixos.org.
%s is replaced with the option name."
  :type 'string
  :group 'nixos)

(defcustom nixos-package-search-url-template
  "https://search.nixos.org/packages?channel=unstable&query=%s"
  "URL template for browsing a package on search.nixos.org.
%s is replaced with the package name."
  :type 'string
  :group 'nixos)

(defcustom nixos-option-groups t
  "Non-nil if the options table groups rows by top-level attribute.
A non-nil value splits the table into one block per first dotted
segment, as in \"services\" or \"programs\", and sorts inside each
block.  A name without a dot lands in its own block.  Set it to nil
for one flat table, then press \\[revert-buffer] in the table buffer."
  :type 'boolean
  :group 'nixos)

(defcustom nixos-display-buffer-action nil
  "Display action for nixos detail buffers.
nil keeps the `pop-to-buffer' default, which selects the new
window.  Set it to `display-buffer-other-window' to open details in
another window.  The table mouse and context menu commands bind
this option for one call."
  :type '(choice (const :tag "Selected window" nil) function)
  :group 'nixos)

(defcustom nixos-browse-table-name-min-width 20
  "Smallest name column width of a narrow table buffer.
The table shrinks its columns when the window cannot hold them, and
the name column stops here."
  :type 'integer
  :group 'nixos)

(defcustom nixos-browse-table-description-min-width 30
  "Width that the last table column keeps when the columns shrink.
The last column takes the remaining space, so this value decides
how much the columns before it must give up."
  :type 'integer
  :group 'nixos)

(defcustom nixos-browse-table-version-max-width 28
  "Widest Version column of a package table.
The column grows to the longest visible version, up to this width,
so an unstable suffix stays readable."
  :type 'integer
  :group 'nixos)

(defcustom nixos-option-sections-hook
  '(nixos-insert-option-title
    nixos-insert-option-fields
    nixos-insert-option-declarations)
  "Functions that insert the sections of an option detail buffer.
`nixos--display-option' runs the entries in order through
`magit-run-section-hook'.  Drop an entry to drop a section, or
reorder the entries to reorder the sections.

An entry takes no arguments and inserts through
`magit-insert-section'.  It reads the data of the buffer from
`nixos--browse-data' and the other `nixos--browse-' locals.  See
`nixos-insert-option-fields' for the shape of an entry."
  :type '(repeat function)
  :group 'nixos)

(defcustom nixos-package-sections-hook
  '(nixos-insert-package-title
    nixos-insert-package-fields
    nixos-insert-package-maintainers
    nixos-insert-package-build-inputs
    nixos-insert-package-native-build-inputs)
  "Functions that insert the sections of a package detail buffer.
`nixos--display-package' runs the entries in order through
`magit-run-section-hook'.  Drop an entry to drop a section, or
reorder the entries to reorder the sections.  An entry reads the
`nixos--package-meta' alist from `nixos--browse-data'.

An entry takes no arguments and inserts through
`magit-insert-section'.  See `nixos-insert-package-fields' for the
shape of an entry."
  :type '(repeat function)
  :group 'nixos)

(defcustom nixos-flake-sections-hook
  '(nixos-insert-flake-title
    nixos-insert-flake-fields)
  "Functions that insert the sections of a flake node buffer.
`nixos--display-flake' runs the entries in order through
`magit-run-section-hook'.  An entry reads the leaf hash table of
`nix flake show --json' from `nixos--browse-data'."
  :type '(repeat function)
  :group 'nixos)

(defcustom nixos-flake-overview-sections-hook
  '(nixos-insert-flake-metadata
    nixos-insert-flake-inputs
    nixos-insert-flake-outputs)
  "Functions that insert the sections of a flake overview buffer.
`nixos--display-flake-overview' runs the entries in order through
`magit-run-section-hook'.  An entry reads a plist of `:ref',
`:cache', `:meta' and `:inputs' from `nixos--browse-data'."
  :type '(repeat function)
  :group 'nixos)



;;; Faces

(defface nixos-package-name
  '((t :inherit (package-name bold) :height 1.2))
  "Face for option and package names in nixos detail buffers.
Inherits from `package-name' when available, otherwise `bold'."
  :group 'nixos)

(defface nixos-field-label
  '((t :inherit (package-help-section-name bold)))
  "Face for field labels in nixos detail buffers.
Inherits from `package-help-section-name' when available."
  :group 'nixos)

(defface nixos-description
  '((t :inherit (package-description default)))
  "Face for descriptions in nixos detail buffers.
Inherits from `package-description' when available."
  :group 'nixos)

(defface nixos-version
  '((t :inherit (magit-tag)))
  "Face for package versions in nixos detail and table buffers."
  :group 'nixos)

(defface nixos-license
  '((t :inherit (shadow)))
  "Face for licenses in nixos detail buffers."
  :group 'nixos)

(defface nixos-date
  '((t :inherit (org-date shadow)))
  "Face for the date part of timestamps in nixos detail buffers.
Inherits from `org-date', so a date looks the same as in an Org
buffer, and from `shadow' when Org does not define its face.  Org
stays optional, because Emacs ignores an undefined parent face.

Customize this if you want dates to stand out differently from
regular text; the default is a muted `shadow' style."
  :group 'nixos)

(defface nixos-revision
  '((t :inherit (magit-hash)))
  "Face for the revision/hash value in nixos detail buffers.
Inherits from `magit-hash', so the `Revision:' flake field reads like
the commit object name of a Magit log line."
  :group 'nixos)


;;; Cache

(defvar nixos--options-cache nil
  "Cached hash table of NixOS options.
Keys are dotted option paths; values are alists with keys like
description, type, default, etc.")

(defvar nixos--packages-cache nil
  "Cached hash table of Nix packages.
Keys are full attribute paths (e.g.
\"legacyPackages.x86_64-linux.htop\"); values are alists with
keys like pname, version, description, etc.")

(defvar nixos--packages-keys nil
  "Cached list of short package names (prefix stripped).")

(defvar nixos--package-key-prefix nil
  "The system attribute prefix of the loaded nix search JSON.
E.g. \"legacyPackages.x86_64-linux.\".  Derived from the first key of
`nixos-search-json-file' in `nixos--packages-load', so the package is
correct on every Nix platform.  Nil until the package data is loaded.")

(defvar nixos--package-meta-cache nil
  "Hash table memoizing `nixos--package-meta' results.
Keys are package names, values are alists with keys `meta',
`outPath', `version', `buildInputs' and `nativeBuildInputs'.
Memoized because nix store paths are immutable — the metadata
for a given package name never changes.")

(defvar nixos--nixpkgs-root nil
  "Cached nixpkgs source root, discovered from NIX_PATH on first use.
Set by `nixos--ensure-nixpkgs-root' via nix-instantiate.
Since store paths are immutable, this cache never expires.")

(defvar nixos--flake-cache nil
  "Cached hash table of flake leaves from `nixos-flake'.
Keys are full dotted output paths (e.g.
\"packages.x86_64-linux.hello\"); values are the leaf hash tables
from `nix flake show --json'.")

(defvar nixos--flake-ref nil
  "The flake reference currently loaded into `nixos--flake-cache'.")

(defun nixos--options-load ()
  "Load NixOS options from `nixos-options-json-file' into cache.
Returns the cached hash table."
  (unless nixos--options-cache
    (if (file-readable-p nixos-options-json-file)
        (with-temp-buffer
          (insert-file-contents nixos-options-json-file)
          (goto-char (point-min))
          (setq nixos--options-cache (json-parse-buffer)))
      (setq nixos--options-cache (make-hash-table :test 'equal))))
  nixos--options-cache)

(defconst nixos--package-output-re
  "\\`\\(?:legacyPackages\\|packages\\)\\.\\([a-z0-9_-]+\\)\\."
  "Regexp matching the output prefix of a `nix search' key.
`nix search' emits keys like \"legacyPackages.x86_64-linux.htop\"
and, for a flake whose packages live in `packages', like
\"packages.x86_64-linux.htop\".")

(defun nixos--packages-load ()
  "Load Nix packages from `nixos-search-json-file' into cache.
Returns the cached hash table."
  (unless nixos--packages-cache
    (if (file-readable-p nixos-search-json-file)
        (let ((table (with-temp-buffer
                       (insert-file-contents nixos-search-json-file)
                       (goto-char (point-min))
                       (json-parse-buffer))))
          (let* ((keys (hash-table-keys table))
                 ;; Derive the prefix from the first key that carries
                 ;; an output prefix, and strip each key by its own
                 ;; match, so a JSON that mixes `legacyPackages' and
                 ;; `packages' leaks neither.
                 (prefix (or (car (sort (delete-dups
                                         (delq nil
                                               (mapcar
                                                (lambda (key)
                                                  (when (string-match
                                                         nixos--package-output-re
                                                         key)
                                                    (substring key 0 (match-end 0))))
                                                keys)))
                                    #'string<))
                            "")))
            (setq nixos--package-key-prefix prefix
                  nixos--packages-cache table
                  nixos--packages-keys
                  (sort (mapcar (lambda (key)
                                  (if (string-match nixos--package-output-re key)
                                      (substring key (match-end 0))
                                    key))
                                keys)
                        #'string<))))
      (setq nixos--packages-cache (make-hash-table :test 'equal)
            nixos--packages-keys nil
            nixos--package-key-prefix "")))
  nixos--packages-cache)

(defun nixos-refresh-cache ()
  "Discard cached option and package data.
The next `nixos-option' or `nixos-package' invocation will reload
from the JSON files.

Clears the options, packages and package-metadata caches.
`nixos--nixpkgs-root' is intentionally NOT cleared: the nixpkgs
store path never changes within a session, so re-discovering it
would be wasted work (see `nixos--ensure-nixpkgs-root')."
  (interactive)
  (setq nixos--options-cache nil
        nixos--packages-cache nil
        nixos--packages-keys nil
        nixos--package-key-prefix nil
        nixos--package-meta-cache nil
        nixos--flake-cache nil
        nixos--flake-ref nil)
  (message "nixos: cache cleared"))

(defun nixos--ensure-nixpkgs-root ()
  "Ensure `nixos--nixpkgs-root' is set from NIX_PATH.
Calls nix-instantiate once to query `builtins.nixPath',
then extracts the first `<nixpkgs>' entry.  Result is cached
permanently since Nix store paths are immutable.

Unlike `nixos-refresh-cache', this cache is deliberately never
cleared: nixpkgs store paths never change within a session, so a
cleared cache would only mean re-running nix-instantiate for the
same value.  When the nixpkgs channel changes (e.g. a NixOS
upgrade), the Emacs session is restarted anyway."
  (unless nixos--nixpkgs-root
    (when (and (boundp 'nix-instantiate-executable)
               (stringp nix-instantiate-executable))
      (condition-case err
          (with-temp-buffer
            (when (zerop (call-process nix-instantiate-executable nil t nil
                                       "--json" "--eval" "--expr"
                                       "builtins.nixPath"))
              (goto-char (point-min))
              (let ((entries (json-parse-buffer)))
                (when (vectorp entries)
                  (catch 'found
                    (dotimes (i (length entries))
                      (let ((entry (aref entries i)))
                        (when (and (hash-table-p entry)
                                   (equal (gethash "prefix" entry) "nixpkgs"))
                          (setq nixos--nixpkgs-root (gethash "path" entry))
                          (throw 'found t)))))))))
        (file-missing (ignore err)))))
  nixos--nixpkgs-root)


;;; Helpers

(defun nixos--slurp-description (inner)
  "Extract a one-line description string from INNER (a hash table)."
  (declare (pure t) (side-effect-free t))
  (let ((desc (and (hash-table-p inner) (gethash "description" inner)))
        (pname (and (hash-table-p inner) (gethash "pname" inner))))
    (or desc pname "")))

(defun nixos--trim-description (desc)
  "Collapse newlines in DESC and truncate to `nixos-annotation-width' columns."
  (when (and desc (not (string-empty-p desc)))
    (truncate-string-to-width (string-replace "\n" " " desc)
                              nixos-annotation-width)))

(defun nixos--annotate (description)
  "Return a right-aligned annotation string for DESCRIPTION."
  (when-let* ((trimmed (nixos--trim-description description)))
    (concat (propertize " " 'display '(space :align-to center))
            trimmed)))

(defun nixos--search-names (type term)
  "Return names of TYPE matching TERM as a substring.
TYPE is `option' or `package'.  Matches against the loaded
cache; package names are the short attribute names (system
prefix stripped).  Shared by table bookmarks and the Org
`nixos-*-search:' link types."
  (let ((re (regexp-quote term)))
    (cl-case type
      (option
       (cl-remove-if-not (lambda (name) (string-match-p re name))
                         (hash-table-keys (nixos--options-load))))
      (package
       (nixos--packages-load)
       (cl-remove-if-not (lambda (name) (string-match-p re name))
                         nixos--packages-keys))
      (t (user-error "Unknown type %s" type)))))

(defun nixos--search-names-or-error (type term)
  "Return the names of TYPE that TERM matches, or signal a `user-error'.
A nil name list means no filter at all, so an empty result would
open the whole table under a buffer name that claims a search."
  (or (nixos--search-names type term)
      (user-error "No %s matches `%s'"
                  (if (eq type 'option) "NixOS option" "Nix package")
                  term)))


;;; Options

(defun nixos--option-annotate (candidate)
  "Return the completion annotation for NixOS option CANDIDATE."
  (nixos--annotate
   (nixos--slurp-description
    (gethash candidate (nixos--options-load)))))

(defun nixos--option-collection (string predicate action)
  "Return the completion collection for NixOS options.
See `completing-read' for the meaning of STRING, PREDICATE and
ACTION."
  (pcase action
    ('metadata
     '(metadata
       (category . nixos-option)
       (annotation-function . nixos--option-annotate)))
    (_
     (complete-with-action action
                           (hash-table-keys (nixos--options-load))
                           string predicate))))


;;; Packages

(defun nixos--package-annotate (candidate)
  "Return the completion annotation for Nix package CANDIDATE."
  (let ((full-key (concat nixos--package-key-prefix candidate)))
    (nixos--annotate
     (nixos--slurp-description
      (gethash full-key (nixos--packages-load))))))

(defun nixos--package-collection (string predicate action)
  "Return the completion collection for Nix packages.
See `completing-read' for the meaning of STRING, PREDICATE and
ACTION."
  (pcase action
    ('metadata
     '(metadata
       (category . nixos-package)
       (annotation-function . nixos--package-annotate)))
    (_
     (nixos--packages-load)              ; ensure nixos--packages-keys exists
     (complete-with-action action
                           nixos--packages-keys
                           string predicate))))


;;; Browse Major Mode

(defvar-keymap nixos-browse-mode-map
  :doc "Keymap for `nixos-browse-mode'.
The fold keys, the section motions and the visibility levels come
from `magit-section-mode-map'."
  :parent magit-section-mode-map
  "b" #'nixos-browse-search-url
  "r" #'nixos-browse-show-requisites
  "w" #'nixos-browse-copy-store-path)

(define-derived-mode nixos-browse-mode magit-section-mode "NixOS-Browse"
  "Major mode for browsing NixOS option / package details.

\\{nixos-browse-mode-map}
The buffer is a tree of sections, so it answers like a Magit buffer:
\\[magit-section-toggle] folds the section at point, `n' and `p' move
between sections, `^' goes to the parent section and `1' to `4' show
that many levels.  The section hooks decide which sections appear;
see `nixos-option-sections-hook'."
  :interactive nil
  (setq-local bookmark-make-record-function #'nixos--bookmark-make-record)
  (setq-local revert-buffer-function #'nixos-browse-refresh)
  (setq-local imenu-create-index-function #'nixos--browse-imenu-index)
  ;; A renderer points `default-directory' at a store path or at the
  ;; nixpkgs root, so the directory of the buffer is not the directory
  ;; that the mode body sees.
  (setq-local list-buffers-directory nil)
  ;; A marker per section end makes a render quadratic in the number of
  ;; sections, and a flake overview holds one section per output.  The
  ;; buffer inserts once and then only reads, so plain positions serve
  ;; until the next render rebuilds them.  A heading therefore writes
  ;; its count into its own text, before the children exist, and never
  ;; ends with a colon: `magit-insert-child-count' rewrites such a
  ;; heading after its children have recorded their positions.
  (setq-local magit-section-inhibit-markers t)
  ;; A display line can shorten a path or a URL, so a text property
  ;; keeps the real value.  `thing-at-point' reads that property
  ;; through the providers, and so does an Embark target finder.
  (setq-local thing-at-point-provider-alist
              (append '((url . nixos--url-at-point)
                        (filename . nixos--path-at-point))
                      thing-at-point-provider-alist))
  ;; A description, an example and a flake description can hold a URL.
  ;; `goto-address-mode' marks it with an overlay, so the text of the
  ;; buffer stays plain and the URL opens with its own keys.
  (goto-address-mode 1))

(defvar-local nixos--browse-type nil
  "The type of item in the current browse buffer: `option' or `package'.")

(defvar-local nixos--browse-name nil
  "The name of the option or package in the current browse buffer.")

(defvar-local nixos--browse-out-path nil
  "Store path of the package in the current browse buffer, if any.")

(defvar-local nixos--browse-source nil
  "Where the package in the current browse buffer came from.
nil for a nixpkgs package (or an option); (local . DIR) for a
package evaluated from DIR/default.nix; (url . URL) for a
package evaluated from a tarball at URL.  Used by
`nixos-browse-refresh' and bookmarks to re-evaluate the same
source.

A non-nil source also means that the renderer does not point
`default-directory' at the store path: the buffer shows a local
project or a remote tarball, not an installed package.  Extend
this enum for a new origin.  Do not add a parallel boolean flag.")

(defvar-local nixos--browse-flake-ref nil
  "The flake reference for the node in the current browse buffer.
Used by `nixos-browse-refresh' and bookmarks to re-run
`nix flake show' for the same flake.")

(defvar-local nixos--browse-position nil
  "Source position (`meta.position') of the package in the current buffer.
The value is a string of the form \"/nix/store/.../package.nix:LINE\",
or nil when the package has no such field.")

(defvar-local nixos--browse-data nil
  "The data that the section inserters of the current buffer read.
An option buffer holds the option hash table, a package buffer the
`nixos--package-meta' alist, a flake node buffer the leaf hash table
of `nix flake show --json', and a flake overview buffer a plist of
`:ref', `:cache', `:meta' and `:inputs'.")

(defun nixos--browse-setup (type name &optional out-path source position)
  "Configure the current buffer for browsing TYPE (option or package) NAME.
OUT-PATH is the package store path, if any.  SOURCE is the
package origin as understood by `nixos--browse-source'.
POSITION is the package's `meta.position' string, if any."
  (setq nixos--browse-type type
        nixos--browse-name name
        nixos--browse-out-path out-path
        nixos--browse-source source
        nixos--browse-position position))


;;; Sections

;; A detail buffer is a tree of `magit-section' sections, so it folds,
;; highlights and moves like a Magit buffer.  Every section carries a
;; value that a later render finds again, and `magit-section' restores
;; the folds of a reader through `magit-section-visibility-cache'.  A
;; value therefore stays stable across renders and unique among its
;; siblings: the module path of a flake input and not its bare name,
;; because one lock node can sit under two parents.  The
;; section hooks below decide which sections a buffer holds, so a user
;; reorders or drops a section with `setopt' instead of editing the
;; package.

(defun nixos--field-key (label)
  "Return LABEL without its padding and its trailing colon."
  (declare (pure t) (side-effect-free t))
  (string-trim-right label "[ \t:]+"))

(defun nixos--propertize (string face)
  "Return STRING painted with FACE under both face properties.
`face' names FACE for a caller that reads a text property, and
`font-lock-face' keeps the paint.  `magit-section-mode' sets
`font-lock-defaults', so `font-lock-mode' turns on in a detail
buffer, and fontification removes a plain `face' property."
  (declare (pure t) (side-effect-free t))
  (propertize string 'face face 'font-lock-face face))

(defconst nixos--field-label-width 14
  "Width of a field label, in columns.
The labels line up with their values, so `Version:' and
`Description:' keep their values in the same column.")

(defun nixos--field-label (label &optional width)
  "Return LABEL padded to WIDTH columns, plus a separating space.
WIDTH defaults to `nixos--field-label-width', and a caller that
needs more room, such as a flake overview that holds a
`Last modified:' label, passes a wider value."
  (format (format "%%-%ds" (or width nixos--field-label-width)) label))

(defun nixos--heading (text &optional count)
  "Return TEXT as the heading of a group section.
COUNT is the number of items of the group.  A positive COUNT goes
into the heading when `magit-section-show-child-count' is non-nil,
under the `magit-section-child-count' face, as a Magit heading
paints its count.  A caller inserts the result before its children,
so the number never shifts a position.

The face of TEXT is the one every Magit heading carries, so a group
reads like a section of a Magit buffer.  Both `face' and
`font-lock-face' name it, as a Magit heading is painted.  TEXT
carries no colon, because a Magit heading carries none either: a
field label ends with one and a heading does not."
  (concat (nixos--propertize text 'magit-section-heading)
          (if (and count (> count 0) magit-section-show-child-count)
              (nixos--propertize (format " (%d)" count)
                                 'magit-section-child-count)
            "")))

(defun nixos--node-heading (text)
  "Return TEXT as the heading of a node section.
The face is `default', so a node reads as plain content of the group
above it.  A node folds, but it is not a bold section heading."
  (nixos--propertize text 'default))

(defun nixos--insert-group-heading (label count)
  "Insert the heading of a group section for LABEL.
COUNT is the number of items in the group.  The heading carries the
number when `magit-section-show-child-count' is non-nil, and the
number goes in before the children exist, so no position shifts."
  (magit-insert-heading (nixos--heading label count)))

(defun nixos--insert-title (label &rest parts)
  "Insert the title section with imenu LABEL and heading PARTS.
PARTS are strings that carry their own face.  A blank line follows
the title, so the title reads as the header of the fields below it."
  (magit-insert-section (nixos-title label)
    (magit-insert-heading (apply #'concat parts)))
  (insert "\n"))

(defun nixos--render (type hook)
  "Render the current browse buffer as a tree of TYPE sections.
HOOK names the variable that lists the inserters, for example
`nixos-option-sections-hook'.  Records the line of point before the
erase and restores it afterwards, and keeps the folds of a reader,
because `magit-section' keeps the visibility of a section by its
value."
  (let ((record (nixos--point-record)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-insert-section (nixos-detail type)
        (magit-run-section-hook hook))
      (set-buffer-modified-p nil))
    ;; Show the root section with the visibility cache off, so the cache
    ;; holds an entry only for a section that a reader folded, and the
    ;; hook that reads the cache stays cheap.
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (nixos--restore-record record)))

(defun nixos--browse-imenu-index ()
  "Return an imenu index of the title, the fields and the groups.
The nodes of a flake overview stay out of the index, because a big
flake holds one section per output and the menu would flood."
  (let (index)
    (magit-map-sections
     (lambda (section)
       (when (memq (oref section type) '(nixos-title nixos-field nixos-group))
         (push (cons (oref section value) (oref section start)) index))))
    (sort index (lambda (a b) (< (cdr a) (cdr b))))))


;;; Option sections

(defun nixos-insert-option-title ()
  "Insert the title section of an option buffer."
  (nixos--insert-title nixos--browse-name
                       (nixos--propertize nixos--browse-name 'nixos-package-name)))

(defun nixos-insert-option-fields ()
  "Insert the fields of an option buffer."
  (let ((data nixos--browse-data))
    (nixos--field "Type:" (gethash "type" data))
    (nixos--field "Default:"
                  (nixos--value-to-string (gethash "default" data)))
    (let ((desc (gethash "description" data)))
      (when (and desc (not (eq desc :null)))
        (nixos--field "Description:" desc 'nixos-description)))
    (nixos--field "Example:"
                  (nixos--value-to-string (gethash "example" data)))))

(defun nixos-insert-option-declarations ()
  "Insert the Declared by section of an option buffer."
  (let ((decls (gethash "declarations" nixos--browse-data)))
    (when (and decls (not (eq decls :null)))
      ;; The declaration list can run long, so it folds.
      (let ((list (if (vectorp decls) (append decls nil) decls)))
        (magit-insert-section (nixos-group "Declared by")
          (nixos--insert-group-heading "Declared by" (length list))
          (dolist (d list)
            (insert "  " d "\n")))))))


;;; Package sections

(defun nixos-insert-package-title ()
  "Insert the title section of a package buffer."
  (nixos--insert-title "Name"
                       (nixos--propertize (nixos--field-label "Name:")
                                          'nixos-field-label)
                       (nixos--propertize nixos--browse-name
                                          'nixos-package-name)))

(defun nixos--store-path-face (path)
  "Return the face of PATH, by its status on disk."
  (declare (side-effect-free t))
  (cond ((file-directory-p path) 'dired-directory)
        ((file-exists-p path) nil)
        (t 'error)))

(defun nixos--license-string (license)
  "Return the display string of LICENSE from the metadata of a package."
  (cond ((hash-table-p license) (gethash "fullName" license))
        ((vectorp license)
         (mapconcat (lambda (l) (or (gethash "fullName" l) "")) license ", "))
        ((stringp license) license)
        (t (nixos--value-to-string license))))

(defun nixos-insert-package-fields ()
  "Insert the fields of a package buffer."
  (let* ((info nixos--browse-data)
         (meta (alist-get 'meta info))
         (out-path (alist-get 'outPath info))
         (position (alist-get 'position info)))
    (when out-path
      (nixos--field "Store path:"
                    (nixos--propertize
                     (nixos--display-path out-path)
                     (nixos--store-path-face out-path)))
      (when (and (null nixos--browse-source) (file-directory-p out-path))
        (setq default-directory (file-name-as-directory out-path))))
    (when meta
      (let ((desc (gethash "description" meta)))
        (when (and desc (not (eq desc :null)))
          (nixos--field "Description:" desc 'nixos-description)))
      (nixos--field "Version:"
                    (or (gethash "version" meta)
                        (alist-get 'version info)
                        "")
                    'nixos-version)
      (let ((homepage (gethash "homepage" meta)))
        (when (and homepage (not (eq homepage :null)))
          (nixos--link "Homepage:" homepage)))
      (let ((repo (alist-get 'repository info)))
        (when (and repo (stringp repo) (not (string-empty-p repo)))
          (nixos--link "Repository:" repo)))
      (when (and position (stringp position) (not (string-empty-p position)))
        ;; A position is long, so it takes a line of its own.
        (magit-insert-section (nixos-field "Position")
          (insert (nixos--propertize (nixos--field-label "Position:")
                                     'nixos-field-label)
                  "\n")
          (insert-text-button (nixos--display-position position)
                              'action (lambda (_) (find-file-at-point position))
                              'follow-link t
                              'help-echo (format "Visit source: %s" position))
          (insert "\n")))
      (let ((license (gethash "license" meta)))
        (when license
          (nixos--field "License:" (nixos--license-string license)
                        'nixos-license))))))

(defun nixos-insert-package-maintainers ()
  "Insert the Maintainers section of a package buffer."
  (let* ((meta (alist-get 'meta nixos--browse-data))
         (maintainers (and meta (gethash "maintainers" meta))))
    (when (and maintainers (not (eq maintainers :null)))
      ;; The maintainer list can run long, so it folds.
      (let ((list (if (vectorp maintainers)
                      (append maintainers nil)
                    maintainers)))
        (magit-insert-section (nixos-group "Maintainers")
          (nixos--insert-group-heading "Maintainers" (length list))
          (dolist (m list)
            (when (hash-table-p m)
              (insert "  " (or (gethash "name" m) "") "\n"))))))))

(defun nixos--build-input-width (info)
  "Return the width of the widest build input name of INFO.
Both input lists share one width, so the store paths of the two
sections line up."
  (declare (side-effect-free t))
  (let ((width 0))
    (dolist (key '(buildInputs nativeBuildInputs))
      (let ((deps (alist-get key info)))
        (when (vectorp deps)
          (dolist (dep (append deps nil))
            (when-let* ((name (gethash "name" dep)))
              (setq width (max width (string-width name))))))))
    width))

(defun nixos--insert-build-inputs (key label)
  "Insert the input list KEY of a package buffer under LABEL."
  (let ((deps (alist-get key nixos--browse-data)))
    (when (and deps (vectorp deps) (> (length deps) 0))
      (insert "\n")
      ;; The input list can run long, so it folds.
      (magit-insert-section (nixos-group label)
        (nixos--insert-group-heading label (length deps))
        (let ((width (nixos--build-input-width nixos--browse-data)))
          (dolist (dep (append deps nil))
            (let ((dep-name (gethash "name" dep))
                  (dep-store (gethash "storePath" dep)))
              (if dep-name
                  (progn
                    (insert-text-button dep-name
                                        'action
                                        (lambda (_) (nixos-package dep-name))
                                        'follow-link t
                                        'face 'link
                                        'font-lock-face 'link
                                        'help-echo
                                        (format "Browse package: %s" dep-name))
                    (when dep-store
                      (insert (make-string
                               (+ (- width (string-width dep-name)) 2)
                               ?\s))
                      (insert (nixos--propertize
                               (nixos--display-path dep-store)
                               (nixos--store-path-face dep-store)))))
                (insert "???")))
            (insert "\n")))))))

(defun nixos-insert-package-build-inputs ()
  "Insert the Build Inputs section of a package buffer."
  (nixos--insert-build-inputs 'buildInputs "Build Inputs"))

(defun nixos-insert-package-native-build-inputs ()
  "Insert the Native Build Inputs section of a package buffer."
  (nixos--insert-build-inputs 'nativeBuildInputs "Native Build Inputs"))


;;; Flake sections

(defun nixos-insert-flake-title ()
  "Insert the title section of a flake node buffer."
  (nixos--insert-title nixos--browse-name
                       (nixos--propertize nixos--browse-name 'nixos-package-name)))

(defun nixos-insert-flake-fields ()
  "Insert the fields of a flake node buffer."
  (let ((data nixos--browse-data)
        (ref nixos--browse-flake-ref))
    (when-let* ((type (gethash "type" data)))
      (nixos--field "Type:" type))
    (nixos--field "Path:" nixos--browse-name)
    (let ((node-name (gethash "name" data)))
      (when (and node-name (not (eq node-name :null)))
        (nixos--field "Name:" node-name)))
    (let ((desc (gethash "description" data)))
      (when (and desc (not (eq desc :null)) (not (string-empty-p desc)))
        (nixos--field "Description:" desc 'nixos-description)))
    (when ref
      (nixos--field "Flake:" (nixos--display-url ref)))))


;;; Flake overview sections

(defun nixos--flake-label-width (fields)
  "Return the label width of a flake overview buffer.
FIELDS is the metadata alist.  The width holds the longest label
plus one space, so every value starts on the same column."
  (1+ (apply #'max
             (mapcar #'string-width
                     (cons "Flake:" (mapcar #'car fields))))))

(defun nixos-insert-flake-metadata ()
  "Insert the Flake title and the metadata fields of an overview buffer."
  (let* ((data nixos--browse-data)
         (fields (nixos--flake-metadata-fields (plist-get data :meta)))
         (width (nixos--flake-label-width fields)))
    (nixos--insert-title "Flake"
                         (nixos--propertize (nixos--field-label "Flake:" width)
                                            'nixos-field-label)
                         (nixos--propertize
                          (nixos--display-url (plist-get data :ref))
                          'nixos-package-name))
    (dolist (field fields)
      (nixos--field (car field) (cdr field) nil width))))

(defun nixos-insert-flake-inputs ()
  "Insert the Inputs section of a flake overview buffer."
  (when-let* ((nodes (plist-get nixos--browse-data :inputs)))
    (insert "\n")
    ;; The input tree can run long, so it folds.
    (magit-insert-section (nixos-group "Inputs")
      (nixos--insert-group-heading "Inputs" (length nodes))
      (nixos-insert-flake-input-nodes nodes "" 0))))

(defun nixos-insert-flake-input-nodes (nodes path depth)
  "Insert the flake input NODES under section PATH at DEPTH.
Each node is (NAME SOURCE CHILDREN...), and a node that follows
another input is (NAME follows TEXT).  The value of a section is the
full path of its node, so a fold survives a render."
  (dolist (node nodes)
    (let* ((name (car node))
           (source (cadr node))
           (identity (if (string-empty-p path) name (concat path "/" name))))
      (magit-insert-section (nixos-input identity)
        (magit-insert-heading
         (nixos--node-heading
          (concat (make-string (* 2 depth) ?\s)
                  (if (eq source 'follows)
                      (format "%s follows input '%s'" name (nth 2 node))
                    (if source (concat name ": " source) name)))))
        (unless (eq source 'follows)
          (nixos-insert-flake-input-nodes (cddr node) identity (1+ depth)))))))

(defun nixos-insert-flake-outputs ()
  "Insert the Outputs section of a flake overview buffer."
  (let* ((data nixos--browse-data)
         (cache (plist-get data :cache))
         (ref (plist-get data :ref))
         (names (sort (hash-table-keys cache) #'string<))
         (max-path (if names
                       (apply #'max (mapcar #'string-width names))
                     0))
         (max-type (apply #'max
                          0
                          (mapcar (lambda (name)
                                    (let ((type (gethash "type"
                                                         (gethash name cache))))
                                      (if type (string-width type) 0)))
                                  names))))
    (insert "\n")
    ;; The count changes with the flake, so the heading shows it and
    ;; the section keeps a plain value, so a fold survives a new output.
    (magit-insert-section (nixos-group "Outputs")
      (nixos--insert-group-heading "Outputs" (length names))
      (dolist (name names)
        (magit-insert-section (nixos-output name)
          (let* ((node (gethash name cache))
                 (type (gethash "type" node))
                 (desc (nixos--trim-description (nixos--slurp-description node))))
            (insert-text-button name
                                'action
                                (lambda (_)
                                  (nixos--display-flake name node ref))
                                'follow-link t
                                'face 'link
                                'font-lock-face 'link
                                'help-echo (format "View output: %s" name)
                                'button-data name)
            (insert (make-string (+ 1 (- max-path (string-width name))) ?\s))
            (when type
              (insert (nixos--propertize type 'nixos-field-label))
              (when desc
                (insert (make-string (+ 1 (- max-type (string-width type)))
                                     ?\s))))
            (when desc
              (insert (nixos--propertize desc 'nixos-description)))
            (insert "\n")))))))


;;; Point keeping

;; A render erases the buffer, so `nixos--render' records the line of
;; point before the render and restores it after the render.  The record
;; names a section and not a buffer position: the section of the line,
;; the distance from its start and the column.  `magit-section' finds
;; the section again through its value, so a render that changes the
;; text above point still lands on the same line.  A line that a reader
;; must keep needs a section of its own.

(defun nixos--point-record (&optional position)
  "Return a record of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the section at
POSITION, the number of lines from the start of that section and the
column.  Return nil when the line sits in no section, because then
the buffer holds no place to keep."
  (let ((position (or position (point))))
    (when-let* ((section (magit-section-at position)))
      (list :section section
            :line (- (line-number-at-pos position)
                     (line-number-at-pos (oref section start)))
            :column (- position
                       (save-excursion
                         (goto-char position)
                         (line-beginning-position)))))))

(defun nixos--restore-record (record)
  "Move point to the line that RECORD names.
A nil RECORD, or a record of a section that the render dropped,
leaves point at the start of the buffer."
  (goto-char (or (when-let* ((section (plist-get record :section)))
                   (save-excursion
                     (when (magit-section-goto-successor
                            section
                            (plist-get record :line)
                            (plist-get record :column))
                       (point))))
                 (point-min))))


;;; Render skip

(defvar-local nixos--browse-rendered nil
  "The data of the last render of the current browse buffer.
Each display function compares it with the data that it receives,
so a refresh that fetched the same data keeps the buffer text, its
point, its folds and its overlays.")

(defmacro nixos--unless-rendered (key &rest body)
  "Compare KEY with the last render data and run BODY on a mismatch.
KEY names the kind and the data of the buffer.  KEY becomes the
data of the render when BODY runs.  `equal' compares the data
itself and ignores the text properties of a string, so a fetch
that returns the same JSON skips the render and keeps the point,
the folds and the overlays.

Call the macro around the whole render and not around one field.
It runs neither the `nixos--browse-setup' call nor the
buffer-local assignment, so a skipped render leaves them as they
were."
  (declare (indent 1))
  `(unless (equal ,key nixos--browse-rendered)
     ,@body
     (setq-local nixos--browse-rendered ,key)))

(defun nixos-browse-show-requisites ()
  "Open the store path of the current package in `nix-store-path-mode'.
This shows requisites, references, derivers, etc."
  (interactive)
  (unless (eq nixos--browse-type 'package)
    (user-error "Requisites view only available for packages"))
  (unless nixos--browse-out-path
    (user-error "No store path available for this package"))
  (require 'nix-store nil t)
  (if (fboundp 'nix-store-show-path)
      (nix-store-show-path nixos--browse-out-path)
    (user-error "Requires the nix-store-mode package; install nix-mode")))

(defun nixos-browse-copy-store-path ()
  "Copy the store path of the current package to the kill ring."
  (interactive)
  (unless (eq nixos--browse-type 'package)
    (user-error "Store path only available for packages"))
  (unless nixos--browse-out-path
    (user-error "No store path available for this package"))
  (kill-new nixos--browse-out-path)
  (message "Copied: %s" nixos--browse-out-path))


;;; Display helpers

(defun nixos--value-to-string (value)
  "Convert a parsed JSON VALUE to a human-readable string."
  (cond
   ((eq value :null) nil)
   ((stringp value) value)
   ((numberp value) (number-to-string value))
   ((memq value '(t :json-false))
    (if (eq value t) "true" "false"))
   ((or (hash-table-p value) (vectorp value))
    (json-serialize value))
   (t (prin1-to-string value))))

(defun nixos--search-url (template name)
  "Return the search URL that TEMPLATE builds for NAME.
TEMPLATE is one of the `nixos-*-search-url-template' defcustoms.
NAME is URL-encoded, so a name that carries `+', `&', `#' or a
space reaches search.nixos.org intact."
  (declare (pure t) (side-effect-free t))
  (format template (url-hexify-string name)))

(defun nixos-browse-search-url ()
  "Open the current option or package on search.nixos.org."
  (interactive)
  (when (eq nixos--browse-type 'flake)
    (user-error "Flake nodes are not on search.nixos.org"))
  (unless nixos--browse-name
    (user-error "No option or package in this buffer"))
  (browse-url (nixos--search-url (if (eq nixos--browse-type 'option)
                                    nixos-option-search-url-template
                                  nixos-package-search-url-template)
                                 nixos--browse-name)))

(defun nixos-browse-refresh (&rest _ignored)
  "Refresh the current browse buffer.
Optional IGNORED args accommodate `revert-buffer-function' calling
convention.  A render keeps the folds and the line of point, so the
refresh itself only fetches the data again."
  (interactive)
  (unless nixos--browse-name
    (user-error "Nothing to refresh"))
  (cl-case nixos--browse-type
    (option (nixos-option nixos--browse-name))
    (package (pcase nixos--browse-source
               (`(url . ,url) (nixos-package-url url))
               (`(local . ,dir)
                (let ((default-directory dir))
                  (nixos-package-local)))
               (_ (nixos-package nixos--browse-name))))
    (flake (let ((data (and nixos--flake-cache
                            (gethash nixos--browse-name nixos--flake-cache))))
             (if data
                 (nixos--display-flake
                  nixos--browse-name data nixos--browse-flake-ref)
               (user-error "Flake node `%s' no longer cached"
                           nixos--browse-name))))
    (t (user-error "Unknown browse type %s" nixos--browse-type))))

(defun nixos--field (label value &optional face width)
  "Insert a field section LABEL with VALUE on one line.
VALUE may be nil (an empty value) or a string, and optional FACE
applies to it.  LABEL is padded to WIDTH columns, which defaults to
`nixos--field-label-width'.  The section carries the trimmed label
as its value, so a render keeps point on the field and
`nixos--browse-imenu-index' lists it."
  (magit-insert-section (nixos-field (nixos--field-key label))
    (insert (nixos--propertize (nixos--field-label label width)
                               'nixos-field-label))
    (when (and value (not (string-empty-p value)))
      (insert (if face (nixos--propertize value face) value)))
    (insert "\n")))

(defun nixos--link (label url)
  "Insert a clickable field section LABEL for URL."
  (magit-insert-section (nixos-field (nixos--field-key label))
    (insert (nixos--propertize (nixos--field-label label) 'nixos-field-label))
    (when url
      ;; The label shortens, the action keeps the real URL.
      (insert-text-button (nixos--display-url url)
                          'action (lambda (_) (browse-url url))
                          'follow-link t
                          'help-echo (format "Browse %s" url)))
    (insert "\n")))

(defun nixos--display-option (name data)
  "Create a formatted detail buffer for NixOS option NAME with DATA."
  (let ((buf (get-buffer-create (format "*nixos-option %s*" name)))
        (key (list 'option name data)))
    (with-current-buffer buf
      (nixos--unless-rendered key
        (nixos-browse-mode)
        (nixos--browse-setup 'option name)
        (setq-local nixos--browse-data data)
        (nixos--render 'option 'nixos-option-sections-hook)
        ;; Point default-directory at the nixpkgs root so
        ;; embark-dwim / find-file-at-point can resolve relative
        ;; declaration paths like "nixos/modules/programs/htop.nix".
        (when-let* ((decls (gethash "declarations" data))
                    ((vectorp decls))
                    ((> (length decls) 0))
                    (first (aref decls 0))
                    (root (nixos--ensure-nixpkgs-root))
                    (full (expand-file-name first root))
                    ((file-exists-p full)))
          (setq default-directory root))))
    (pop-to-buffer buf nixos-display-buffer-action)))

(defun nixos--display-package (name info &optional source)
  "Create a formatted detail buffer for Nix package NAME with INFO.
INFO is an alist from `nixos--package-meta'.  Its `meta' key holds
a hash table of package metadata, `outPath' a string store path,
`version' a string, `buildInputs' and `nativeBuildInputs' vectors
of dep attrsets with `name' and `storePath' keys, `pname' a string,
and `repository' a URL string.

SOURCE is the package origin as understood by
`nixos--browse-source': nil for a nixpkgs package, (local . DIR)
or (url . URL) otherwise.  When SOURCE is non-nil, the renderer
does not point `default-directory' at the store path, because the
buffer is for a local project or a remote tarball and not an
installed Nix package."
  (let ((buf (get-buffer-create (format "*nixos-package %s*" name)))
        (key (list 'package name info source)))
    (with-current-buffer buf
      (nixos--unless-rendered key
        (nixos-browse-mode)
        (nixos--browse-setup 'package name (alist-get 'outPath info) source
                             (alist-get 'position info))
        (setq-local nixos--browse-data info)
        (nixos--render 'package 'nixos-package-sections-hook)))
    (pop-to-buffer buf nixos-display-buffer-action)))


;;; Flakes

(defun nixos--display-flake (name data &optional ref)
  "Create a formatted detail buffer for flake node NAME with DATA.
DATA is the leaf hash table from `nix flake show --json'.  REF is
the flake reference the leaf came from, if known.

Only the data that `flake show --json' emits is shown: the node
type, full path, the derivation name and a description.  There is
no store path, so the requisites view and copy-store-path actions
are unavailable here."
  (let ((buf (get-buffer-create (format "*nixos-flake %s*" name)))
        (key (list 'flake name data ref)))
    (with-current-buffer buf
      (nixos--unless-rendered key
        (nixos-browse-mode)
        (nixos--browse-setup 'flake name)
        (setq-local nixos--browse-flake-ref ref)
        (setq-local nixos--browse-data data)
        (nixos--render 'flake 'nixos-flake-sections-hook)))
    (pop-to-buffer buf nixos-display-buffer-action)))

(defun nixos--flake-leaf-p (node)
  "Return non-nil if NODE is a flake show leaf.
A leaf is a hash table carrying a \"type\" key; intermediate
grouping attrsets and empty system subtrees do not."
  (declare (pure t) (side-effect-free t))
  (and (hash-table-p node) (gethash "type" node)))

(defun nixos--flake-flatten (json)
  "Flatten `nix flake show --json' JSON into a path-keyed hash table.
JSON is the parsed top-level hash table.  Returns a hash table
mapping full dotted paths (e.g. \"packages.x86_64-linux.hello\")
to the leaf hash table.

Recurses through every attrset: top-level output attrs, the
optional system level, and any deeper grouping.  A node is a leaf
iff it carries a \"type\" key; nodes without one are descended
into rather than shown."
  (declare (pure t) (side-effect-free t))
  (let ((table (make-hash-table :test 'equal)))
    (cl-labels ((walk (path node)
                  (cond
                   ((vectorp node)
                    (dotimes (i (length node))
                      (walk path (aref node i))))
                   ((hash-table-p node)
                    (if (nixos--flake-leaf-p node)
                        (puthash path node table)
                      (maphash
                       (lambda (key child)
                         (let ((seg (if (stringp key) key (prin1-to-string key))))
                           (walk (if (string-empty-p path)
                                     seg
                                   (concat path "." seg))
                                 child)))
                       node))))))
      (walk "" json))
    table))

(defun nixos--call-flake-show (ref)
  "Run `nix flake show --json' for REF, return (JSON . ERROR).
JSON is the parsed hash table on success; ERROR is the stderr on
failure.  Returns nil entirely if the `nix' executable is missing.
REF is passed through `expand-file-name' so a leading `~' resolves
before `nix' sees it (Nix does not expand `~' in flake refs)."
  (let ((ref (if (string-prefix-p "~" ref) (expand-file-name ref) ref))
        (nix-exe (if (and (boundp 'nix-executable)
                          (stringp nix-executable))
                     nix-executable
                   "nix")))
    (condition-case err
        (let* ((stderr-file (make-temp-file "nixos-flake-stderr-"))
               (args (list nix-exe nil (list t stderr-file) nil
                           "--extra-experimental-features"
                           "nix-command flakes"
                           "flake" "show" "--json" ref)))
          (unwind-protect
              (with-temp-buffer
                (let ((exit-code (apply 'call-process args)))
                  (if (zerop exit-code)
                      (cons (progn
                              (goto-char (point-min))
                              (json-parse-buffer))
                            "")
                    (cons nil (with-temp-buffer
                                (insert-file-contents stderr-file)
                                (buffer-string))))))
            (delete-file stderr-file)))
      (file-missing (ignore err) nil))))

(defun nixos--call-flake-metadata (ref)
  "Run `nix flake metadata --json' for REF, return (DATA . ERROR).
DATA is the parsed hash table on success; ERROR is the stderr on
failure.  Returns nil entirely if the `nix' executable is missing.
Unlike `nixos--call-flake-show', this needs no evaluation and
provides flake-level fields (description, path, url, revision,
lastModified, inputs)."
  (let ((ref (if (string-prefix-p "~" ref) (expand-file-name ref) ref))
        (nix-exe (if (and (boundp 'nix-executable)
                          (stringp nix-executable))
                     nix-executable
                   "nix")))
    (condition-case err
        (let* ((stderr-file (make-temp-file "nixos-flake-metadata-stderr-"))
               (args (list nix-exe nil (list t stderr-file) nil
                           "--extra-experimental-features"
                           "nix-command flakes"
                           "flake" "metadata" "--json" ref)))
          (unwind-protect
              (with-temp-buffer
                (let ((exit-code (apply 'call-process args)))
                  (if (zerop exit-code)
                      (cons (progn
                              (goto-char (point-min))
                              (json-parse-buffer))
                            "")
                    (cons nil (with-temp-buffer
                                (insert-file-contents stderr-file)
                                (buffer-string))))))
            (delete-file stderr-file)))
      (file-missing (ignore err) nil))))

(defvar-keymap nixos-flake-overview-mode-map
  :doc "Keymap for `nixos--display-flake-overview' buffers."
  :parent nixos-browse-mode-map
  "RET" #'nixos-flake-visit-output)

(defun nixos-flake-visit-output ()
  "Display details for the flake output at point.
Intended for `nixos--display-flake-overview' buffers, where each
output line is an `insert-text-button' that carries its node path as
`button-data'.  Opens that node's detail buffer."
  (interactive)
  (let ((btn (button-at (point))))
    (if btn
        (let ((name (button-get btn 'button-data)))
          (nixos--display-flake name (gethash name nixos--flake-cache)
                                nixos--flake-ref))
      (user-error "No flake output on this line"))))

(defun nixos--flake-input-source (node)
  "Return a display string for an input NODE: source (and date), or nil.
The source is formatted from the node's \"locked\"/\"original\"
attrsets.  For github inputs this is \"github:OWNER/REPO/REV\"; for
local path/file inputs the URL is abbreviated.  When a lastModified
timestamp is present, the date is appended in parens, matching the
official `nix flake metadata' input tree."
  (when (hash-table-p node)
    (let* ((locked (gethash "locked" node))
           (orig (gethash "original" node))
           (type (or (and (hash-table-p locked) (gethash "type" locked))
                     (and (hash-table-p orig) (gethash "type" orig))))
           (owner (and (hash-table-p locked) (gethash "owner" locked)))
           (repo (and (hash-table-p locked) (gethash "repo" locked)))
           (rev (and (hash-table-p locked) (gethash "rev" locked)))
           (url (or (and (hash-table-p locked) (gethash "url" locked))
                    (and (hash-table-p orig) (gethash "url" orig))))
           (last (and (hash-table-p locked) (gethash "lastModified" locked)))
           (src (cond
                 ((and (equal type "github") owner repo rev)
                  (format "github:%s/%s/%s" owner repo rev))
                 ((stringp url)
                  ;; Local file/path inputs: strip a file:// prefix and
                  ;; hand the filesystem path to `nixos--display-path'.
                  (if (string-prefix-p "file://" url)
                      (url-unhex-string (substring url 7))
                    url))
                 (t nil))))
      (when src
        (let ((src (nixos--display-path src)))
          (if (and last (not (eq last :null)))
              (concat src " ("
                      (nixos--propertize
                       (format-time-string "%Y-%m-%d %H:%M:%S"
                                           (seconds-to-time last))
                       'nixos-date)
                      ")")
            src))))))

(defun nixos--flake-input-tree (nodes root)
  "Return the input tree of NODES rooted at ROOT.
NODES is the \"locks.nodes\" hash table and ROOT the node id of the
flake itself.  Each node is (NAME SOURCE CHILDREN...), where SOURCE
is the original URL of the input or nil, and each child has the same
shape.  An input that follows another input renders as (NAME follows
PATH), where PATH names every component of the lock entry that the
input follows.  The tree carries no display text, so the caller owns
the indentation and the faces."
  (cl-labels ((inputs-of (node)
                (and (hash-table-p node) (gethash "inputs" node)))
              (names-of (inputs)
                (and inputs
                     (sort (let (names)
                             (maphash (lambda (name _) (push name names))
                                      inputs)
                             names)
                           #'string<)))
              (walk (node-id visited)
                (let* ((inputs (inputs-of (gethash node-id nodes)))
                       (names (names-of inputs)))
                  (mapcar
                   (lambda (name)
                     (let ((value (gethash name inputs)))
                       (if (vectorp value)
                           (list name 'follows
                                 (mapconcat #'identity value "/"))
                         (let ((child (gethash value nodes)))
                           (append (list name (nixos--flake-input-source child))
                                   (unless (or (null value)
                                               (member value visited))
                                     (walk value (cons value visited))))))))
                   names))))
    (walk root (list root))))

(defun nixos--flake-inputs (meta)
  "Return the input tree of the flake metadata META, or nil."
  (and (hash-table-p meta)
       (let ((locks (gethash "locks" meta)))
         (and (hash-table-p locks)
              (nixos--flake-input-tree (gethash "nodes" locks)
                                       (gethash "root" locks))))))

(defun nixos--flake-metadata-fields (meta)
  "Return an alist of ((LABEL . VALUE) ...) from flake metadata META.
META is the hash table from `nix flake metadata --json', or nil.
Only human-meaningful scalar fields are extracted: description, path,
url, revision and last-modified.  Sparse values are omitted.  The
input tree comes from `nixos--flake-inputs', because it folds."
  (and (hash-table-p meta)
       (let ((desc (gethash "description" meta))
             (path (gethash "path" meta))
             (url (gethash "url" meta))
             (rev (gethash "revision" meta))
             (last (gethash "lastModified" meta)))
         (delq nil
               (list
                (when (and desc (not (string-empty-p desc)))
                  (cons "Description:"
                        (nixos--propertize desc 'nixos-description)))
                (when (and path (not (string-empty-p path)))
                  ;; A flake source path always names a directory, so it
                  ;; takes the Dired face even when it is not on disk.
                  (cons "Path:" (nixos--propertize
                                 (nixos--display-path path)
                                 'dired-directory)))
                (when (and url (not (string-empty-p url)))
                  (cons "URL:" (nixos--display-url url)))
                (when (and rev (not (string-empty-p rev)))
                  (cons "Revision:"
                        (nixos--propertize rev 'nixos-revision)))
                (when (and last (not (eq last :null)))
                  (cons "Last modified:"
                        (nixos--propertize
                         (format-time-string "%Y-%m-%d %H:%M"
                                             (seconds-to-time last))
                         'nixos-date))))))))

(defun nixos--abbreviate-path (path)
  "Abbreviate a filesystem PATH for display, or return it unchanged.
Only absolute local paths (starting with a slash or a tilde) are sent
through `abbreviate-file-name'; URLs and flake references such as
\"github:...\" are left untouched."
  (if (and (stringp path) (string-match-p "\\`[/~]" path))
      (abbreviate-file-name path)
    path))

(defconst nixos--flake-forge-hosts
  '(("github" . "https://github.com")
    ("gitlab" . "https://gitlab.com")
    ("sourcehut" . "https://git.sr.ht"))
  "Forge prefixes of a flake reference, as (NAME . HOST) conses.")

(defun nixos--forge-ref-url (ref)
  "Return the web URL of flake reference REF, or nil.
REF names an input, as `github:OWNER/REPO', with an optional pinned
REV as a third path segment.  GitHub, GitLab and sourcehut expand,
and a pin points at the commit page of its forge.  A REF with another
prefix, a query, or a wrong shape returns nil, so the caller keeps the
literal reference."
  (when (and (stringp ref) (not (string-search "?" ref)))
    (let* ((colon (string-search ":" ref))
           (forge (and colon (substring ref 0 colon)))
           (host (cdr (assoc forge nixos--flake-forge-hosts)))
           (parts (and colon (split-string (substring ref (1+ colon)) "/"))))
      (when (and host
                 (memq (length parts) '(2 3))
                 (not (cl-some #'string-empty-p parts)))
        (let ((owner (nth 0 parts))
              (repo (nth 1 parts))
              (rev (nth 2 parts))
              (tree (if (equal forge "gitlab") "-/tree/" "tree/")))
          (if rev
              (format "%s/%s/%s/%s%s" host owner repo tree rev)
            (format "%s/%s/%s" host owner repo)))))))

(defun nixos--display-url (url)
  "Return URL shortened for display, or URL unchanged.
A forge flake reference becomes its web URL first.  When buffer-url is
loaded, `buffer-url-pretty-print' then applies
`buffer-url-shorten-alist', so a reader sees the short label of a host.

The result is display text alone, and the `nixos-url' text property
names the real URL.  A button action, a command and every
`nixos--browse-' local keep the real URL too, so a shortened value
never reaches `browse-url'."
  (let ((real (or (nixos--forge-ref-url url) url)))
    (cond
     ((not (stringp real)) real)
     ((fboundp 'buffer-url-pretty-print)
      (propertize (buffer-url-pretty-print real) 'nixos-url real))
     (t real))))

(defun nixos--display-path (path)
  "Return PATH shortened for display, or PATH unchanged.
A URL and a forge flake reference go through `nixos--display-url'.  A
local absolute path goes through `abbreviate-file-name' first, so a
shorthand rule matches the text that the reader sees.  When tired is
loaded, `tired-shorten-path' then applies `tired-shorthand-rules', so
a rule that a reader sets for a link target reaches a store path too.

The result is display text alone, and the `nixos-path' text property
names the real path.  A command, a bookmark and every `nixos--browse-'
local keep the real path too, so a shortened value never reaches the
file system."
  (cond
   ((and (stringp path) (string-match-p "\\`https?://" path))
    (nixos--display-url path))
   ((nixos--forge-ref-url path) (nixos--display-url path))
   ((not (stringp path)) path)
   (t
    (let ((abbreviated (nixos--abbreviate-path path)))
      (propertize (if (fboundp 'tired-shorten-path)
                      (tired-shorten-path abbreviated)
                    abbreviated)
                  'nixos-path path)))))

(defun nixos--position-file (position)
  "Return the file that POSITION names, or POSITION itself.
POSITION is a `FILE:LINE[:COLUMN]' string from `meta.position'."
  (if (and (stringp position)
           (string-match "\\`\\(.+?\\):[0-9]+\\(?::[0-9]+\\)?\\'" position))
      (match-string 1 position)
    position))

(defun nixos--display-position (position)
  "Return POSITION shortened for display, with its file as the path.
The text covers the whole value, and its `nixos-path' property names
the file alone, so a file action reaches the file and skips the line
number."
  (when-let* ((display (nixos--display-path position)))
    (add-text-properties 0 (length display)
                         (list 'nixos-path (nixos--position-file position))
                         display)
    display))

(defun nixos--url-at-point ()
  "Return the real URL of the display text at point, or nil.
The `nixos-url' text property holds the URL that a shortened label
stands for.  `thing-at-point-provider-alist' calls this function in a
browse buffer."
  (get-text-property (point) 'nixos-url))

(defun nixos--path-at-point ()
  "Return the real path of the display text at point, or nil.
The `nixos-path' text property holds the path that a shortened label
stands for.  `thing-at-point-provider-alist' calls this function in a
browse buffer."
  (get-text-property (point) 'nixos-path))

(defun nixos--flake-overview-refresh (&rest _ignored)
  "Refresh the flake overview buffer.
Optional IGNORED args accommodate `revert-buffer-function' calling
convention.  A refresh runs `nix flake show' again on the reference
of the buffer, and the render keeps the folds of the reader and the
line of point."
  (interactive)
  (let ((ref nixos--browse-flake-ref))
    (unless ref
      (user-error "No flake reference in this buffer"))
    (nixos-flake ref)))

(defun nixos--display-flake-overview (ref cache &optional meta)
  "Create a whole-flake detail buffer for REF from CACHE.
CACHE is the path-keyed leaf hash table from
`nixos--flake-flatten'.  META is optional data from
`nix flake metadata --json' shown as flake-level fields above the
output list.  Pressing RET (or clicking) on a line opens the node's
detail buffer via `nixos--display-flake'."
  (let* ((buf-name (format "*nixos-flake %s*"
                           (nixos--abbreviate-path ref)))
         (buf (get-buffer-create buf-name))
         (key (list 'flake-overview ref cache meta)))
    (with-current-buffer buf
      (nixos--unless-rendered key
        (nixos-browse-mode)
        (use-local-map nixos-flake-overview-mode-map)
        ;; The overview buffer is not bookmarkable (node-only bookmarks),
        ;; and regenerating it re-runs `nix flake show' on the ref.
        (setq-local bookmark-make-record-function nil)
        (setq-local revert-buffer-function #'nixos--flake-overview-refresh)
        (nixos--browse-setup 'flake ref)
        (setq-local nixos--browse-flake-ref ref)
        (setq-local nixos--browse-name ref)
        (setq-local nixos--browse-data
                    (list :ref ref
                          :cache cache
                          :meta meta
                          :inputs (nixos--flake-inputs meta)))
        (nixos--render 'flake 'nixos-flake-overview-sections-hook)))
    (pop-to-buffer buf nixos-display-buffer-action)))

;;;###autoload
(defun nixos-flake (&optional flake-ref)
  "Show the outputs of a Nix flake in a detail buffer.
Runs `nix flake show --json' on FLAKE-REF and presents a whole-flake
overview: the reference plus a clickable list of every leaf node,
such as derivations, apps, NixOS configurations and templates, with
its full dotted path.  Pressing \[nixos-flake-visit-output] or clicking
on a node opens that node's detail buffer.

Called interactively without a prefix, FLAKE-REF defaults to the
project root when it is a flake (contains flake.nix); otherwise it
is prompted for.  With \[universal-argument] it is always prompted
for, defaulting to the current directory.

When FLAKE-REF is non-nil it is used directly (as a programmatic
argument or from a bookmark)."
  (interactive "P")
  (let* ((ref (cond
               ((stringp flake-ref) flake-ref)
               (flake-ref (nixos--read-flake-ref))
               ((nixos--project-flake-ref))
               (t (nixos--read-flake-ref))))
         (ref (if (string-prefix-p "~" ref) (expand-file-name ref) ref)))
    (let ((show (nixos--call-flake-show ref)))
      (cond
       ((and (consp show) (car show))
        (let* ((json (car show))
               (cache (nixos--flake-flatten json))
               (meta (car (nixos--call-flake-metadata ref))))
          (setq nixos--flake-cache cache
                nixos--flake-ref ref)
          (nixos--display-flake-overview ref cache meta)))
       ((consp show)
        (user-error "Flake show failed:\n%s" (cdr show)))
       (t (user-error "`nix' executable not found (check `nix-executable')"))))))

(defun nixos--read-flake-ref ()
  "Prompt for a flake reference, defaulting to the current directory."
  (let ((r (read-string "nix flake show> " default-directory)))
    (if (string-prefix-p "~" r) (expand-file-name r) r)))

(defun nixos--project-flake-ref ()
  "Return the project root when it is a flake, else nil.
The root is the directory returned by `project-current' (via
`project-root'); it qualifies only when it contains a flake.nix."
  (let ((root (and (fboundp 'project-current)
                   (fboundp 'project-root)
                   (let ((pr (project-current t)))
                     (and pr (project-root pr))))))
    (when root
      (let ((flake-file (expand-file-name "flake.nix" root)))
        (when (file-exists-p flake-file)
          root)))))


;;; Bookmarks

(defconst nixos--package-expr-tail
  (concat
   "  depInfo = deps: map (d:"
   "    { name = d.pname or d.name or \"unknown\";"
   "      storePath = d.outPath;"
   "    }) deps;"
   " in [ pkg.meta pkg.outPath pkg.version"
   "     (depInfo (pkg.buildInputs or []))"
   "     (depInfo (pkg.nativeBuildInputs or []))"
   "     (pkg.pname or \"\")"
   "     (pkg.src.meta.homepage or pkg.src.url or \"\")"
   "     (pkg.meta.position or \"\") ]")
  "Tail of a nix-instantiate expression that extracts one package.
The value yields a JSON array of the metadata, the store path, the
version, the build inputs, the native build inputs, the pname, the
homepage URL and the source position.  Shared by the nixpkgs, the
local and the URL package paths.

The expression emits an array and not an attrset.  Nix treats an
attrset key named `outPath' as the value of the attrset itself, so
a mixed attrset collapses under `--strict' and a dependency uses
`storePath'.  The trap shows up only under `--strict'.")

(defun nixos--parse-package-result (result)
  "Parse the JSON RESULT vector from nix-instantiate into an alist.
RESULT is the parsed JSON vector:
  [meta outPath version buildInputs nativeBuildInputs pname repository]
Returns a cons cell (ALIST . \"\") on success, or (nil . ERROR-MSG)."
  (declare (pure t) (side-effect-free t))
  (if (not (vectorp result))
      (cons nil (format "Unexpected JSON type (expected array): %S" result))
    (let ((meta (and (>= (length result) 1) (aref result 0)))
          (out (and (>= (length result) 2) (aref result 1)))
          (ver (and (>= (length result) 3) (aref result 2)))
          (build (and (>= (length result) 4) (aref result 3)))
          (native (and (>= (length result) 5) (aref result 4)))
          (pname (and (>= (length result) 6) (aref result 5)))
          (repo (and (>= (length result) 7) (aref result 6)))
          (pos (and (>= (length result) 8) (aref result 7))))
      (cons (list (cons 'meta (and meta (not (eq meta :null)) meta))
                  (cons 'outPath (and out (not (eq out :null)) out))
                  (cons 'version (and ver (not (eq ver :null)) ver))
                  (cons 'buildInputs (and build (vectorp build) (not (eq build :null)) build))
                  (cons 'nativeBuildInputs (and native (vectorp native) (not (eq native :null)) native))
                  (cons 'pname (and pname (not (eq pname :json-false)) pname))
                  (cons 'repository (and repo (not (eq repo :json-false)) (not (string-empty-p repo)) repo))
                  (cons 'position (and pos (not (eq pos :json-false)) (not (string-empty-p pos)) pos)))
            ""))))

(defun nixos--call-nix-package-expr (expr &rest extra-args)
  "Call nix-instantiate with EXPR and EXTRA-ARGS, return (RESULT . STDERR).
EXTRA-ARGS are passed directly to `call-process' before \"-E\".

Stderr goes to a temp file and not to a buffer: `call-process' with
a buffer as the stderr destination kills that buffer on a non-zero
exit in Emacs 31, and the next read signals `stringp, #<killed
buffer>'.

Returns a cons cell (ALIST . STDERR): on success ALIST is the
parsed package alist and STDERR is an empty string.  On failure
ALIST is nil and STDERR contains the error output.  Returns nil
entirely if nix-instantiate is unavailable."
  (when (and (boundp 'nix-instantiate-executable)
             (stringp nix-instantiate-executable))
    (condition-case err
        (let* ((stderr-file (make-temp-file "nixos-stderr-"))
               (args (append (list nix-instantiate-executable nil (list t stderr-file) nil)
                             extra-args
                             (list "--strict" "--json" "--eval" "-E" expr))))
          (unwind-protect
              (with-temp-buffer
                (let ((exit-code (apply 'call-process args)))
                  (if (zerop exit-code)
                      (progn
                        (goto-char (point-min))
                        (nixos--parse-package-result (json-parse-buffer)))
                    (cons nil (with-temp-buffer
                                (insert-file-contents stderr-file)
                                (buffer-string))))))
            (delete-file stderr-file)))
      (file-missing (ignore err) nil))))

(defun nixos--call-nix-url-expr (url)
  "Call nix-instantiate with a tarball URL, return (RESULT . STDERR).
Downloads the tarball at URL via builtins.fetchTarball, imports
it with pkgs.callPackage, and extracts package metadata.

Uses --impure since the tarball is fetched without a pinned hash.
Returns the same format as `nixos--call-nix-package-expr'."
  (nixos--call-nix-package-expr
   (concat "{url}: let"
           "  pkgs = import <nixpkgs> {};"
           "  pkg = pkgs.callPackage"
           "    (builtins.fetchTarball url) {};"
           nixos--package-expr-tail)
   "--impure" "--argstr" "url" url))

(defun nixos--package-meta (package-name)
  "Fetch metadata, outPath, version and build deps for PACKAGE-NAME.
Returns an alist with keys `meta' (hash table), `outPath' (string),
`version' (string), `buildInputs' (vector of dep attrsets), and
`nativeBuildInputs' (vector of dep attrsets), or nil if
nix-instantiate is not available.

Results are memoized: since Nix store paths are immutable, the
metadata for a given package is stable forever."
  (unless nixos--package-meta-cache
    (setq nixos--package-meta-cache (make-hash-table :test 'equal)))
  (with-memoization (gethash package-name nixos--package-meta-cache)
    (car (nixos--call-nix-package-expr
          (concat "{cand}: let"
                  "  pkgs = import <nixpkgs> {};"
                  "  segments = builtins.filter builtins.isString"
                  "    (builtins.split \"\\\\.\" cand);"
                  "  pkg = builtins.foldl' (s: seg:"
                  "    builtins.getAttr seg s) pkgs segments;"
                  nixos--package-expr-tail)
          "--argstr" "cand" package-name))))


;;; Bookmarks

(defvar nixos--browse-name-list)
(defvar nixos--browse-name-prefix)

(defun nixos--browse-table-bookmark-make-record ()
  "Create a bookmark record for the current browse-table buffer.
Intended for use as `bookmark-make-record-function' in
`nixos-browse-options-mode' and `nixos-browse-packages-mode'."
  (let* ((type (cond ((derived-mode-p 'nixos-browse-options-mode) 'option)
                     ((derived-mode-p 'nixos-browse-packages-mode) 'package)
                     (t 'package)))
         (label (pcase type
                  ('option "option search")
                  ('package "package search")))
         (name-prefix nixos--browse-name-prefix))
    `(,(format "NixOS %s: %s" label (or name-prefix "all"))
      (type . ,type)
      (name-prefix . ,name-prefix)
      (sort-key . ,tabulated-list-sort-key)
      (widths . ,(nixos--browse-table-column-widths))
      (handler . nixos--bookmark-jump))))

(defun nixos--browse-table-restore-state (bookmark)
  "Restore the sort key and column widths that BOOKMARK holds.
A sort key that names no column and a width list that does not
match the table are ignored, so an old bookmark still opens.
Restoring a saved width makes it the width that a later fit starts
from.  The table reprints only when a value lands."
  (let ((sort-key (alist-get 'sort-key bookmark))
        (widths (alist-get 'widths bookmark))
        (columns (append tabulated-list-format nil))
        (restored nil))
    (when (derived-mode-p 'tabulated-list-mode)
      (when (and (consp sort-key)
                 (member (car sort-key) (mapcar #'car columns)))
        (setq tabulated-list-sort-key (cons (car sort-key) (cdr sort-key))
              restored t))
      (when (and (listp widths)
                 (cl-every #'integerp widths)
                 (= (length widths) (length columns)))
        (setq tabulated-list-format
              (nixos--browse-table-format-widths
               tabulated-list-format widths)
              restored t)
        (setq-local nixos--browse-table-canonical-widths widths))
      (when restored
        (tabulated-list-init-header)
        (tabulated-list-print t)))))

(defun nixos--bookmark-make-record ()
  "Create a bookmark record for the current browse buffer.
Intended for use as `bookmark-make-record-function'."
  (unless nixos--browse-name
    (user-error "No option or package to bookmark"))
  `(,(format "NixOS %s: %s"
             (pcase nixos--browse-type
               ('option "option")
               ('package "package")
               ('flake "flake"))
             nixos--browse-name)
    (type . ,nixos--browse-type)
    (name . ,nixos--browse-name)
    (handler . nixos--bookmark-jump)
    (source . ,(if (eq nixos--browse-type 'flake)
                   nixos--browse-flake-ref
                 nixos--browse-source))))

;;;###autoload
(defun nixos--bookmark-jump (bookmark)
  "Restore a nixos BOOKMARK.
Called by the bookmark system."
  (let ((type (alist-get 'type bookmark))
        (name (alist-get 'name bookmark))
        (name-prefix (alist-get 'name-prefix bookmark)))
    (if (assq 'name-prefix bookmark)
        ;; Table (search) bookmark — re-derive filtered name-list
        ;; from current cache, so new results appear on reopen.
        (cl-case type
          (option (nixos-browse-options
                   (and name-prefix
                        (nixos--search-names-or-error 'option name-prefix))
                   name-prefix)
                  (nixos--browse-table-restore-state bookmark))
          (package (nixos-browse-packages
                    (and name-prefix
                         (nixos--search-names-or-error 'package name-prefix))
                    name-prefix)
                   (nixos--browse-table-restore-state bookmark))
          (t (user-error "Unknown bookmark type %s" type)))
      ;; Detail bookmark.
      (cl-case type
        (option (nixos-option name))
        (package (pcase (alist-get 'source bookmark)
                   (`(url . ,url) (nixos-package-url url))
                   (`(local . ,dir)
                    (let ((default-directory dir))
                      (nixos-package-local)))
                   (_ (nixos-package name))))
        (flake (let ((ref (alist-get 'source bookmark)))
                 (let ((data (and nixos--flake-cache
                                  (gethash name nixos--flake-cache))))
                   (if data
                       (nixos--display-flake name data ref)
                     (let ((json (and ref (car (nixos--call-flake-show ref))))
                           cache)
                       (when (hash-table-p json)
                         (setq cache (nixos--flake-flatten json)))
                       (let ((data (and cache (gethash name cache))))
                         (if data
                             (nixos--display-flake name data ref)
                           (user-error "Flake node `%s' not found" name))))))))
        (t (user-error "Unknown bookmark type %s" type))))))


;;; Interactive commands

;;;###autoload
(defun nixos-option (&optional option-name)
  "Browse NixOS options, then display the selected one.
When called interactively, prompt with completion.  When
OPTION-NAME is provided non-interactively, display that option
directly."
  (interactive)
  (let ((cand (or option-name
                  (completing-read "nixos-option> "
                                   #'nixos--option-collection))))
    (let ((data (gethash cand (nixos--options-load))))
      (if data
          (nixos--display-option cand data)
        (user-error "Option `%s' not found" cand)))))

;;;###autoload
(defun nixos-package (&optional package-name)
  "Browse Nix packages, then display the selected one.
When called interactively, prompt with completion.  When
PACKAGE-NAME is provided non-interactively, display that package
directly.

Package metadata (including the store path for requisites view)
is obtained from `nix-instantiate' when available; otherwise the
contents of `nixos-search-json-file' are shown."
  (interactive)
  (let ((cand (or package-name
                  (completing-read "nix-pkg> "
                                   #'nixos--package-collection))))
    (let ((info (nixos--package-meta cand)))
      (if info
          (nixos--display-package cand info)
        ;; Fall back to the search JSON data.  The load runs first,
        ;; because it is what derives `nixos--package-key-prefix'.
        (let* ((items (nixos--packages-load))
               (full-key (concat nixos--package-key-prefix cand))
               (data (gethash full-key items)))
          (if data
              (nixos--display-package
               cand
               (list (cons 'meta data)))
            (user-error "Package `%s' not found" cand)))))))

;;;###autoload
(defun nixos-package-local ()
  "Display the Nix package defined by ./default.nix in `default-directory'.
Evaluates with `pkgs.callPackage ./default.nix {}'.

No memoization — intended for local development where
`default.nix' changes between invocations."
  (interactive)
  (let* ((full-dir (expand-file-name default-directory))
         (display-name (abbreviate-file-name full-dir))
         (default-directory full-dir))
    (unless (file-exists-p "default.nix")
      (user-error "No default.nix in %s" display-name))
    (message "Evaluating %sdefault.nix..." display-name)
    (pcase-let ((`(,info . ,stderr)
                 (nixos--call-nix-package-expr
                  (concat "let"
                          "  pkgs = import <nixpkgs> {};"
                          "  pkg = pkgs.callPackage ./default.nix {};"
                          nixos--package-expr-tail))))
      (if info
          (nixos--display-package (or (alist-get 'pname info) display-name)
                                  info (cons 'local full-dir))
        (user-error "%sdefault.nix:\n%s" display-name stderr)))))

;;;###autoload
(defun nixos-package-url (url)
  "Display the Nix package defined by a tarball at URL.
Downloads and evaluates the tarball via
`builtins.fetchTarball' + `pkgs.callPackage'.

Only point this at URLs you trust: evaluation uses --impure, so
the tarball's Nix code can read local files and environment
variables, and trigger import-from-derivation builds.

No memoization — intended for remote development where the
tarball may change between invocations."
  (interactive "sNix package URL: ")
  (let ((display-name (file-name-base (file-name-sans-extension (url-unhex-string url)))))
    (message "Evaluating %s..." url)
    (pcase-let ((`(,info . ,stderr)
                 (nixos--call-nix-url-expr url)))
      (if info
          (nixos--display-package (or (alist-get 'pname info) display-name)
                                  info (cons 'url url))
        (user-error "URL %s:\n%s" url stderr)))))


;;; Thing-At-Point

(defconst nixos--id-chars (string-to-list "-A-Za-z0-9_'\.")
  "Characters that can appear in a dotted NixOS identifier.
A list of chars with the hyphen first (so it is literal in both
`skip-chars-forward' and `rx' char sets).  Shared by
`nixos--dotted-identifier-re' and `nixos--option-bounds'.")

(defconst nixos--dotted-identifier-re
  (let ((any-chars (cons 'any nixos--id-chars)))
    (rx-to-string
     (list 'seq 'bos
           any-chars
           (list '* any-chars)
           "."
           (list '* any-chars)
           'eos)))
  "Regexp matching a dotted NixOS option or package identifier.
Must contain at least one dot and match Nix identifier rules.")

(defun nixos--option-at-point ()
  "Return the NixOS option reference around point, or nil.
Works in `nix-mode' buffers when point is on a dotted
identifier like \"services.postgresql.enable\"."
  (when (derived-mode-p 'nix-mode)
    (let ((bounds (nixos--option-bounds)))
      (when bounds
        (buffer-substring-no-properties (car bounds) (cdr bounds))))))

(defun nixos--option-bounds ()
  "Return the bounds of a NixOS option reference around point."
  (when (derived-mode-p 'nix-mode)
    (let* ((p (point))
           (id-chars (concat nixos--id-chars))
           start end)
      (save-excursion
        ;; Scan backward to the start.
        (skip-chars-backward id-chars)
        (setq start (point))
        ;; Scan forward to the end.
        (goto-char p)
        (skip-chars-forward id-chars)
        (setq end (point))
        (when (and (> end start)
                   (string-match-p nixos--dotted-identifier-re
                                   (buffer-substring-no-properties start end)))
          (cons start end))))))

(put 'nixos-option 'bounds-of-thing-at-point #'nixos--option-bounds)
(put 'nixos-option 'thing-at-point #'nixos--option-at-point)

;;;###autoload
(defun nixos-thing-at-point-setup ()
  "Enable `thingatpt' integration for `nixos-option' in the current buffer.
Add this to `nix-mode-hook' for automatic setup:

  (add-hook \\='nix-mode-hook #\\='nixos-thing-at-point-setup)"
  (interactive)
  (setq-local thing-at-point-provider-alist
              (cons '(nixos-option . nixos--option-at-point)
                    thing-at-point-provider-alist)))


(defvar-local nixos--browse-name-list nil
  "Buffer-local list of item names that the browse buffer is filtered to.
When nil, all items are shown.  Set by browse-table commands
and used by refresh to preserve the filter.")
(put 'nixos--browse-name-list 'permanent-local t)

(defvar-local nixos--browse-name-prefix nil
  "Buffer-local search term used for naming the browse buffer.
When non-nil, the buffer name includes this term (e.g.
\"*Nix Packages: htop*\").  Used by bookmarks to recreate
the buffer with the original name.")
(put 'nixos--browse-name-prefix 'permanent-local t)


;;; Browse table helpers

(defconst nixos--browse-table-mouse-help
  "mouse-2: open in another window, mouse-3: menu"
  "Help text that every table row carries.")

(defvar-local nixos--browse-table-visit-function nil
  "Function that displays the detail buffer of one table entry.
`nixos-option' for an option table, `nixos-package' for a package
table.  The table modes set it.")

(defvar-local nixos--browse-table-type nil
  "Type of the entries in this table buffer: `option' or `package'.
The table modes set it, and the export commands read it.")

(defvar-local nixos--browse-table-entries-function nil
  "Function that builds `tabulated-list-entries' for this buffer.
It takes the buffer-local name-list filter, so a reload keeps the
filter.  The table modes set it.")

(defvar-local nixos--browse-table-canonical-widths nil
  "Column widths that the table mode declares, before any window fit.
A fit starts from these widths, so a wide window gets them back
and a manual resize is undone by the next fit.  A bookmark may
replace them with the widths that it saved.")

(defvar-local nixos--browse-table-declared-widths nil
  "Column widths of the table mode itself.
Neither a fit nor a bookmark changes this list, so it stays the
source for a width function.")

(defvar-local nixos--browse-table-width-function nil
  "Function that widens declared columns to their content.
It takes the entry list and the declared widths, and returns the
widths that a fit starts from.")

(defvar-local nixos--browse-table-fit-timer nil
  "Pending timer that refits this table after a window resize.")

(defvar-local nixos--browse-table-last-entries nil
  "Entries of the last reload of this table, before a print.
A print sorts `tabulated-list-entries' in place, so the reload
keeps a copy of its own order.  A revert compares the two lists
and skips the print when the entries did not change.")

(defun nixos--browse-table-reload ()
  "Rebuild `tabulated-list-entries' from the buffer-local filter.
The `tabulated-list-revert-hook' of a table buffer calls this, so
`g' keeps the filter.  The function also records the order that
it built, for the change test of `nixos--browse-table-revert'."
  (when nixos--browse-table-entries-function
    (setq tabulated-list-entries
          (funcall nixos--browse-table-entries-function
                   nixos--browse-name-list))
    (setq nixos--browse-table-last-entries
          (copy-sequence tabulated-list-entries))))

(defun nixos--browse-table-revert (&rest _ignored)
  "Reload the table and reprint it only when the entries changed.
`tabulated-list-revert', the default `revert-buffer-function',
always reprints, which erases the point, the tags and the group
headers of a table whose data did not change.  A cache refresh
that adds an entry changes the list, so the print happens then."
  (unless (derived-mode-p 'tabulated-list-mode)
    (error "The current buffer is not a Tabulated List mode"))
  (let ((entries nixos--browse-table-last-entries))
    (run-hooks 'tabulated-list-revert-hook)
    (unless (equal entries nixos--browse-table-last-entries)
      (tabulated-list-print t))))

(defconst nixos--option-group-other "(top level)"
  "Group title for an option name without a dot.")

(defun nixos--option-group-name (name)
  "Return the table group of option NAME.
The group is the first dotted segment, so \"services.nginx.enable\"
lands under \"services\".  A name without a dot gets its own group."
  (declare (pure t) (side-effect-free t))
  (if-let* ((dot (string-search "." name)))
      (substring name 0 dot)
    nixos--option-group-other))

(defun nixos--group-entries (entries group-function)
  "Split ENTRIES into the groups of variable `tabulated-list-groups'.
ENTRIES has the shape of `tabulated-list-entries'.  GROUP-FUNCTION
takes an entry ID and returns a group name.  Groups follow group
name order, and `tabulated-list-print' sorts each group on its own."
  (declare (pure t) (side-effect-free t))
  (let ((buckets (make-hash-table :test #'equal))
        names)
    (dolist (entry entries)
      (let ((group (funcall group-function (car entry))))
        (unless (gethash group buckets)
          (push group names)
          (puthash group nil buckets))
        (puthash group (cons entry (gethash group buckets)) buckets)))
    (mapcar (lambda (group)
              (cons (nixos--propertize group 'nixos-field-label)
                    (nreverse (gethash group buckets))))
            (sort names #'string<))))

(defun nixos--browse-table-cell-text (cell)
  "Return table CELL as a plain string.
A cell holds a string or a cons of a label and button properties."
  (declare (pure t) (side-effect-free t))
  (cond ((stringp cell) (substring-no-properties cell))
        ((consp cell) (format "%s" (car cell)))
        (t "")))

(defun nixos--browse-table-longest-cell (entries column)
  "Return the width of the widest ENTRIES cell of COLUMN.
ENTRIES has the shape of `tabulated-list-entries'."
  (declare (pure t) (side-effect-free t))
  (let ((longest 0))
    (dolist (entry entries longest)
      (setq longest
            (max longest
                 (string-width
                  (nixos--browse-table-cell-text
                   (aref (cadr entry) column))))))))

(defun nixos--package-canonical-widths (entries declared)
  "Fit the Version column of ENTRIES into DECLARED widths.
ENTRIES decides how wide the Version column must be, up to
`nixos-browse-table-version-max-width'.  DECLARED is the base,
and the header width is the floor, so the label never truncates."
  (let ((widths (append declared nil)))
    (setcar (nthcdr 1 widths)
            (min nixos-browse-table-version-max-width
                 (max (string-width (car (aref tabulated-list-format 1)))
                      (nixos--browse-table-longest-cell entries 1))))
    widths))

(defun nixos--package-version-lessp (a b)
  "Return non-nil when the version of entry A sorts before entry B.
A and B have the shape of `tabulated-list-entries'.  The Version
column compares versions here instead of the strings it prints,
so \"1.9\" lands before \"1.10\".  An entry without a version sorts
after one that has a version.  Fall back to `string<' when
`version<' rejects a value."
  (declare (pure t) (side-effect-free t))
  (let ((a-version (nixos--browse-table-cell-text (aref (cadr a) 1)))
        (b-version (nixos--browse-table-cell-text (aref (cadr b) 1))))
    (cond ((and (string-empty-p a-version) (string-empty-p b-version)) nil)
          ((string-empty-p a-version) nil)
          ((string-empty-p b-version) t)
          (t (condition-case nil
                 (version< a-version b-version)
               (error (string< a-version b-version)))))))

(defun nixos--browse-table-print-entry (id columns)
  "Print one table row for ID and COLUMNS, then add its mouse help.
`tabulated-list-print' calls this through `tabulated-list-printer'
for every entry.  Group header lines bypass it and stay plain.  The
whole row explains the mouse, and the name cell carries
`mouse-face', so the pointer highlights the name alone.  ID is nil
on a row without an entry, and such a row gets no properties.  The
span of the name counts characters, because a buffer position does,
and not display columns."
  (let ((beg (point)))
    (tabulated-list-print-entry id columns)
    (when id
      (let* ((end (1- (point)))
             (text (nixos--browse-table-cell-text (aref columns 0)))
             (name-start (+ beg tabulated-list-padding))
             (name-end (min (+ name-start (length text)) end)))
        (add-text-properties beg end
                             (list 'help-echo
                                   nixos--browse-table-mouse-help))
        (when (< name-start name-end)
          (add-text-properties name-start name-end
                               '(mouse-face highlight)))))))

(defun nixos--browse-table-click-selects-row (&rest _ignored)
  "Return nil, so one click selects a row and follows no link.
`tabulated-list-mode-map' binds `follow-link' to `mouse-face', and
that value turns a click on a marked cell into a `mouse-2' event.
The name cell carries `mouse-face', so this predicate keeps the
click from opening a detail buffer.  The middle button opens one."
  nil)

(defun nixos--browse-table-name-at-event (event)
  "Return the entry name of the table row under the mouse click EVENT."
  (let* ((start (event-start event))
         (window (posn-window start))
         (position (posn-point start)))
    (when (and (windowp window) (integer-or-marker-p position))
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char position)
          (tabulated-list-get-id))))))

(defun nixos--browse-table-display (name action)
  "Display the detail buffer of table entry NAME with display ACTION."
  (unless (and (derived-mode-p 'tabulated-list-mode)
               nixos--browse-table-visit-function)
    (user-error "Not a nixos table buffer"))
  (unless name
    (user-error "No entry on this line"))
  (let ((nixos-display-buffer-action action))
    (funcall nixos--browse-table-visit-function name)))

(defun nixos-browse-table-other-window ()
  "Open the detail buffer of the entry at point in another window."
  (interactive)
  (nixos--browse-table-display (tabulated-list-get-id)
                              #'display-buffer-other-window))

(defun nixos-browse-table-other-window-mouse (event)
  "Open the table row under the mouse click EVENT in another window.
The clicked window decides the entry type, so a click in an option
table opens an option even when another table holds the selection."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start)))
    (unless (windowp window)
      (user-error "No entry under the mouse"))
    (with-current-buffer (window-buffer window)
      (nixos--browse-table-display (nixos--browse-table-name-at-event event)
                                  #'display-buffer-other-window))))

(defun nixos-browse-table-copy-name ()
  "Copy the name of the table entry at point to the kill ring."
  (interactive)
  (let ((name (or (tabulated-list-get-id)
                  (user-error "No entry on this line"))))
    (kill-new name)
    (message "Copied %s" name)))

(defun nixos--browse-table-resize-column (n)
  "Widen the column under point by N, or narrow it when N is negative.
`tabulated-list-widen-current-column' reads the entry at point, so
it signals on a group header line, which holds none.  This wrapper
reports that case as a user error."
  (interactive "p")
  (unless (tabulated-list-get-entry)
    (user-error "Put point on a row to resize a column"))
  (tabulated-list-widen-current-column n))

(defun nixos--browse-table-narrow-column (n)
  "Narrow the column under point by N."
  (interactive "p")
  (nixos--browse-table-resize-column (- n)))

(defun nixos--browse-table-column-widths ()
  "Return the current width of every table column."
  (mapcar (lambda (column) (nth 1 column))
          (append tabulated-list-format nil)))

(defun nixos--browse-table-fit-widths (widths budget)
  "Return WIDTHS shrunk to fit BUDGET columns.
WIDTHS holds one width per column, and the last column takes the
remaining space, so `nixos-browse-table-description-min-width'
bounds its share.  A column before the last shrinks to 8, and the
name column stops at `nixos-browse-table-name-min-width'.  The
result keeps every value when the columns already fit."
  (let* ((last (1- (length widths)))
         (fitted (append widths nil))
         (fixed (lambda ()
                  (let ((total tabulated-list-padding))
                    (dotimes (index last)
                      (setq total (+ total (nth index fitted) 1)))
                    total)))
         (over (- (+ (funcall fixed)
                     nixos-browse-table-description-min-width)
                  budget))
         (shrink (lambda (index floor)
                   (when (> over 0)
                     (let* ((room (max (- (nth index fitted) floor) 0))
                            (take (min room over)))
                       (setcar (nthcdr index fitted)
                               (- (nth index fitted) take))
                       (setq over (- over take)))))))
    (let ((index (1- last)))
      (while (>= index 1)
        (funcall shrink index 8)
        (setq index (1- index))))
    (when (> last 0)
      (funcall shrink 0 nixos-browse-table-name-min-width))
    fitted))

(defun nixos--browse-table-format-widths (format widths)
  "Return a copy of FORMAT with the widths of WIDTHS.
`tabulated-list-format' may share constant lists across buffers, so
copy a column before it changes."
  (declare (pure t) (side-effect-free t))
  (apply #'vector
         (cl-mapcar (lambda (column width)
                      (let ((copy (copy-sequence column)))
                        (setcar (cdr copy) width)
                        copy))
                    (append format nil)
                    widths)))

(defun nixos--browse-table-fit (window)
  "Return a `tabulated-list-format' that fits WINDOW, or nil.
The fit starts from `nixos--browse-table-canonical-widths', so a
resize in either direction reaches the right widths.  Return nil
when the current widths already equal the fitted ones."
  (when (and (windowp window) nixos--browse-table-canonical-widths)
    (let* ((current (mapcar (lambda (column) (nth 1 column))
                            (append tabulated-list-format nil)))
           (target (nixos--browse-table-fit-widths
                    nixos--browse-table-canonical-widths
                    (window-width window))))
      (unless (equal target current)
        (nixos--browse-table-format-widths tabulated-list-format target)))))

(defun nixos--browse-table-base-widths ()
  "Return the widths that a fit starts from.
A mode may widen a declared column to its content through
`nixos--browse-table-width-function', which takes the entry list
and the declared widths."
  (let ((declared (or nixos--browse-table-declared-widths
                      nixos--browse-table-canonical-widths
                      (nixos--browse-table-column-widths))))
    (if nixos--browse-table-width-function
        (funcall nixos--browse-table-width-function
                 tabulated-list-entries declared)
      declared)))

(defun nixos--browse-table-fit-format ()
  "Fit `tabulated-list-format' to the selected window, without a reprint.
The browse command runs this before its first print, because that
print lands in the selected window.  The fit also refreshes the
base widths, so a content-fitted column follows the visible rows."
  (setq-local nixos--browse-table-canonical-widths
              (nixos--browse-table-base-widths))
  (when-let* ((fitted (nixos--browse-table-fit (selected-window))))
    (setq tabulated-list-format fitted)
    (tabulated-list-init-header)))

(defun nixos--browse-table-refit (window)
  "Fit the columns of WINDOW to WINDOW, and reprint on a change."
  (when (and (window-live-p window)
             (buffer-live-p (window-buffer window)))
    (with-current-buffer (window-buffer window)
      (setq nixos--browse-table-fit-timer nil)
      (when-let* ((fitted (nixos--browse-table-fit window)))
        (setq tabulated-list-format fitted)
        (tabulated-list-init-header)
        (tabulated-list-print t)))))

(defun nixos--browse-table-schedule-refit (buffer window)
  "Refit BUFFER for WINDOW after the current redisplay.
Redisplay runs the window size hook, so the reprint waits for a
timer.  One pending timer per buffer is enough."
  (when (and (buffer-live-p buffer)
             (not (timerp (buffer-local-value
                           'nixos--browse-table-fit-timer buffer))))
    (with-current-buffer buffer
      (setq nixos--browse-table-fit-timer
            (run-at-time 0 nil #'nixos--browse-table-refit window)))))

(defun nixos--browse-table-cancel-fit ()
  "Cancel a pending resize refit of the current table buffer."
  (when (timerp nixos--browse-table-fit-timer)
    (cancel-timer nixos--browse-table-fit-timer)
    (setq nixos--browse-table-fit-timer nil)))

(defun nixos--browse-table-window-size-changed (frame)
  "Refit the nixos tables shown in the windows of FRAME.
A resize changes the space that the last column needs, and the
other columns give way when the window is too narrow."
  (dolist (window (window-list frame 'nomini))
    (when (buffer-local-value 'nixos--browse-table-canonical-widths
                              (window-buffer window))
      (nixos--browse-table-schedule-refit (window-buffer window) window))))

(add-hook 'window-size-change-functions
          #'nixos--browse-table-window-size-changed)

(defun nixos--browse-table-rows ()
  "Return the rows of the current table buffer in display order.
Each row is a cons of its entry ID and its column vector.  A group
header line holds no entry, so it adds no row."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (when-let* ((columns (tabulated-list-get-entry)))
          (push (cons (tabulated-list-get-id) columns) rows))
        (forward-line 1))
      (nreverse rows))))

(defun nixos--export-cell (cell)
  "Return table CELL as one line of plain text.
A cell holds a string or a cons of a label and button properties.
The face of a cell goes away with the properties."
  (declare (pure t) (side-effect-free t))
  (let ((text (cond ((stringp cell) cell)
                    ((consp cell) (format "%s" (car cell)))
                    (t ""))))
    (string-trim
     (replace-regexp-in-string "[ \t\n\r]+" " "
                               (nixos--browse-table-cell-text text)))))

(defun nixos--export-markdown (rows)
  "Return ROWS as a Markdown table.
ROWS comes from `nixos--browse-table-rows'.  The header names the
columns of `tabulated-list-format'.  A pipe inside a cell is
escaped, so the table keeps its shape."
  (let* ((labels (mapcar (lambda (column)
                           (nixos--export-cell
                            (if (consp column) (car column) column)))
                         (append tabulated-list-format nil)))
         (line (lambda (cells)
                 (concat "| "
                         (mapconcat (lambda (text)
                                      (string-replace "|" "\\|" text))
                                    cells " | ")
                         " |")))
         (header (funcall line labels))
         (separator (concat "|"
                            (mapconcat (lambda (_label) " --- |")
                                       labels "")))
         (body '()))
    (dolist (row rows)
      (push (funcall line (mapcar #'nixos--export-cell
                                  (append (cdr row) nil)))
            body))
    (concat (mapconcat #'identity
                       (cons header (cons separator (nreverse body)))
                       "\n")
            "\n")))

(defconst nixos--nix-identifier-re
  "\\`[a-zA-Z_][a-zA-Z0-9_'-]*\\'"
  "Regexp matching one bare Nix attribute name.")

(defun nixos--nix-attribute-segment (segment)
  "Return Nix attribute SEGMENT, quoted when it is no identifier.
The quoted form escapes the interpolation opener, so an attribute
name that carries one stays a literal name."
  (declare (pure t) (side-effect-free t))
  (if (string-match-p nixos--nix-identifier-re segment)
      (concat "." segment)
    (concat ".\""
            (replace-regexp-in-string "[\\\"]\\|\\${" "\\\\\\&" segment)
            "\"")))

(defun nixos--export-nix (rows)
  "Return ROWS as a Nix list of attributes below `pkgs'.
A segment that is no Nix identifier is quoted, so an attribute path
with a leading digit stays valid."
  (declare (pure t) (side-effect-free t))
  (concat "[\n"
          (mapconcat (lambda (row)
                       (concat "  pkgs"
                               (mapconcat #'nixos--nix-attribute-segment
                                          (split-string (car row) "\\.")
                                          "")))
                     rows "\n")
          "\n]\n"))

(defun nixos--export-buffer (label text)
  "Show the read-only export buffer that LABEL names with TEXT.
A repeat export of the same format and table reuses the buffer."
  (let ((buffer (get-buffer-create
                 (format "*Nix %s export: %s*"
                         (or nixos--browse-table-type 'table) label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (special-mode)
        (setq-local default-directory
                    (or (nixos--ensure-nixpkgs-root)
                        default-directory))
        (set-buffer-modified-p nil)))
    (pop-to-buffer buffer nixos-display-buffer-action)))

(defun nixos-browse-export-markdown ()
  "Export the visible table rows to a read-only Markdown buffer.
The export follows the current sort, the filter and the groups."
  (interactive)
  (unless (derived-mode-p 'tabulated-list-mode)
    (user-error "Not a nixos table buffer"))
  (nixos--export-buffer "markdown"
                        (nixos--export-markdown
                         (nixos--browse-table-rows))))

(defun nixos-browse-export-nix ()
  "Export the visible package rows as a Nix list below `pkgs'.
The text pastes into `environment.systemPackages'."
  (interactive)
  (unless (derived-mode-p 'tabulated-list-mode)
    (user-error "Not a nixos table buffer"))
  (unless (eq nixos--browse-table-type 'package)
    (user-error "Only a package table exports as a Nix list"))
  (nixos--export-buffer "nix"
                        (nixos--export-nix
                         (nixos--browse-table-rows))))

(defvar-keymap nixos-browse-table-export-map
  :doc "Export keymap for nixos table buffers."
  "m" #'nixos-browse-export-markdown
  "n" #'nixos-browse-export-nix)

(defun nixos--browse-table-context-command (position buffer function)
  "Return a command that moves point to POSITION in BUFFER and calls FUNCTION.
A context menu click leaves point alone, and the menu command can
run in another buffer, so the command restores both first."
  (lambda ()
    (interactive)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (integer-or-marker-p position)
          (goto-char (min position (point-max))))
        (funcall function)))))

(defun nixos-browse-table-context-menu (menu click)
  "Fill MENU with the table commands for the row under CLICK.
A click below the last row adds nothing, so the plain Emacs menu
stays.  A table mode adds this function to
`context-menu-functions' buffer-locally."
  (let* ((start (event-start click))
         (position (posn-point start))
         (buffer (current-buffer))
         (name (nixos--browse-table-name-at-event click)))
    (when (and name (derived-mode-p 'tabulated-list-mode))
      (let ((command (lambda (function)
                       (nixos--browse-table-context-command position buffer
                                                           function))))
        (define-key-after menu [nixos-browse-table-open]
          (list 'menu-item "Open Details"
                (funcall command
                         (lambda ()
                           (nixos--browse-table-display
                            name nixos-display-buffer-action)))))
        (define-key-after menu [nixos-browse-table-open-other-window]
          (list 'menu-item "Open in Other Window"
                (funcall command
                         (lambda ()
                           (nixos--browse-table-display
                            name #'display-buffer-other-window)))))
        (define-key-after menu [nixos-browse-table-copy-name]
          (list 'menu-item "Copy Name"
                (funcall command #'nixos-browse-table-copy-name)))
        (define-key-after menu [nixos-browse-table-export-markdown]
          (list 'menu-item "Export as Markdown"
                #'nixos-browse-export-markdown))
        (define-key-after menu [nixos-browse-table-export-nix]
          (list 'menu-item "Export as Nix List"
                #'nixos-browse-export-nix
                :enable (eq nixos--browse-table-type 'package)))
        (define-key-after menu [nixos-browse-table-refresh-separator]
          menu-bar-separator)
        (define-key-after menu [nixos-browse-table-refresh]
          '(menu-item "Refresh" revert-buffer))))
    menu))


;;; Tabulated Browse Mode (shared macro)

(cl-defmacro nixos--define-browse-mode (type &key mode-label buffer-name
                                             columns sort-key
                                             extract-fields
                                             visit-fn url-fmt cache-fn
                                             key-fn group-fn width-fn)
  "Define a tabulated-list browse mode for TYPE (a symbol, e.g. option).
TYPE names the mode, its keymap, its command and its helper
functions.  MODE-LABEL is the mode line indicator.  BUFFER-NAME is
the name of the table buffer.  COLUMNS is the value of
`tabulated-list-format', and SORT-KEY the initial sort key.
EXTRACT-FIELDS holds one form per column after the name, and
VISIT-FN is the command that opens a detail buffer.  URL-FMT is the
URL template of the search command.  CACHE-FN returns the cache
hash table, and KEY-FN shortens a cache key to an entry name.
GROUP-FN, when non-nil, takes an entry ID and returns the group
name of that entry.  WIDTH-FN, when non-nil, takes the entries and
the declared column widths and returns the widths that a window
fit starts from.  Internal use only."
  (declare (indent 1))
  (let* ((typestr (symbol-name type))
         (mode (intern (format "nixos-browse-%ss-mode" typestr)))
         (mode-map (intern (format "nixos-browse-%ss-mode-map" typestr)))
         (visit (intern (format "nixos-browse-%ss-visit" typestr)))
         (search-url (intern (format "nixos-browse-%ss-search-url" typestr)))
         (cmd (intern (format "nixos-browse-%ss" typestr)))
         (entry-fn (intern (format "nixos-browse-%ss--entry" typestr)))
         (entries-fn (intern (format "nixos-browse-%ss--entries" typestr)))
         (current-name-fn (intern (format "nixos-browse-%ss--current-name" typestr))))
    `(progn
       (defvar-keymap ,mode-map
         :doc ,(format "Keymap for `%s'." mode)
         :parent tabulated-list-mode-map
         "RET" #',visit
         "o" #'nixos-browse-table-other-window
         "w" #'nixos-browse-table-copy-name
         "e" nixos-browse-table-export-map
         "<remap> <nix-mode>" #'nixos-browse-export-nix
         "<remap> <nix-ts-mode>" #'nixos-browse-export-nix
         "<remap> <markdown-ts-mode>" #'nixos-browse-export-markdown
         "{" #'nixos--browse-table-narrow-column
         "}" #'nixos--browse-table-resize-column
         "<mouse-2>" #'nixos-browse-table-other-window-mouse
         "<follow-link>" #'nixos--browse-table-click-selects-row
         ,@(if url-fmt
               `("b"   #',search-url)
             nil))

       (define-derived-mode ,mode tabulated-list-mode
         ,mode-label
         ,(format "Major mode for browsing Nix %s in a sortable table.

\\{%s}" typestr mode-map)
         :interactive nil
         (setq tabulated-list-format ,columns)
         (setq tabulated-list-padding 2)
         (setq tabulated-list-sort-key ',sort-key)
         (setq-local tabulated-list-groups
                     ,(if group-fn
                          `(lambda ()
                             (when nixos-option-groups
                               (nixos--group-entries
                                (,entries-fn nixos--browse-name-list)
                                ,group-fn)))
                        nil))
         (tabulated-list-init-header)
         (hl-line-mode 1)
         (setq-local nixos--browse-table-canonical-widths
                     (mapcar (lambda (column) (nth 1 column))
                             (append tabulated-list-format nil)))
         (setq-local nixos--browse-table-declared-widths
                     nixos--browse-table-canonical-widths)
         (setq-local nixos--browse-table-width-function ,width-fn)
         (setq-local nixos--browse-table-entries-function #',entries-fn)
         (add-hook 'tabulated-list-revert-hook
                   #'nixos--browse-table-reload nil t)
         (setq-local revert-buffer-function #'nixos--browse-table-revert)
         (add-hook 'kill-buffer-hook
                   #'nixos--browse-table-cancel-fit nil t)
         (setq-local tabulated-list-printer
                     #'nixos--browse-table-print-entry)
         (setq-local nixos--browse-table-visit-function #',visit-fn)
         (setq-local nixos--browse-table-type ',type)
         (setq-local bookmark-make-record-function
                     #'nixos--browse-table-bookmark-make-record)
         (when (boundp 'context-menu-functions)
           (add-hook 'context-menu-functions
                     #'nixos-browse-table-context-menu nil t)))

       (defun ,entry-fn (name data)
         ,(format "Return a `tabulated-list' entry for %s NAME with DATA." typestr)
         (list name (vector (nixos--propertize name 'nixos-package-name) ,@extract-fields)))

       (defun ,entries-fn (&optional name-list)
         ,(format "Generate `tabulated-list-entries' for %s.
When NAME-LIST is non-nil, only include entries whose names
appear in the list." typestr)
         (let ((items (,cache-fn))
               entries)
           (if (= (hash-table-count items) 0)
               (user-error "No %s loaded (check the JSON file)" ,typestr)
             (maphash
              (lambda (raw-key data)
                (let ((name ,(if key-fn `(funcall ,key-fn raw-key) 'raw-key)))
                  (when (or (null name-list) (member name name-list))
                    (push (,entry-fn name data) entries))))
              items)
             (nreverse entries))))

       (defun ,current-name-fn ()
         ,(format "Return the %s name at point, or signal an error." typestr)
         (or (tabulated-list-get-id)
             (user-error "No %s on this line" ,typestr)))

       (defun ,visit ()
         ,(format "Display details for the %s at point." typestr)
         (interactive)
         (,visit-fn (,current-name-fn)))

       ,(if url-fmt
            `(defun ,search-url ()
               ,(format "Open the current %s on search.nixos.org." typestr)
               (interactive)
               (browse-url (nixos--search-url ,url-fmt (,current-name-fn))))
          nil)

       ;;;###autoload
       (defun ,cmd (&optional name-list name-prefix)
         ,(format "Display Nix %s in a browsable table.
%s are shown with sortable columns.
\<%s>
\\[%s] on an entry to view full details,
\\[%s] to open on search.nixos.org,
\\[revert-buffer] to reload the data.
The `e' prefix exports the visible rows.

When NAME-LIST is non-nil (a list of names), only those entries
are displayed.  This is used by Embark export.

When NAME-PREFIX is non-nil, it is appended to the buffer name
(e.g. \"*NixOS Options: htop*\"), allowing multiple searches
to coexist in separate buffers.

Emacs' built-in narrowing (\\[narrow-to-defun] etc.) can be used
to filter the view in-place." typestr typestr mode-map visit search-url)
         (interactive)
         (let ((buf-name (if name-prefix
                             (concat (substring ,buffer-name 0 -1)
                                     ": " name-prefix "*")
                           ,buffer-name)))
           (let ((buf (get-buffer-create buf-name)))
             (with-current-buffer buf
               (,mode)
               (setq-local nixos--browse-name-list name-list)
               (setq-local nixos--browse-name-prefix name-prefix)
               (setq-local default-directory
                           (or (nixos--ensure-nixpkgs-root)
                               default-directory))
               (nixos--browse-table-reload)
               (nixos--browse-table-fit-format)
               (tabulated-list-print))
             (switch-to-buffer buf)))))))

;; Options table

(nixos--define-browse-mode option
  :mode-label "NixOS-Options"
  :buffer-name "*NixOS Options*"
  :columns [("Option" 50 t) ("Type" 20 t) ("Description" 0 nil)]
  :sort-key ("Option" . nil)
  :group-fn #'nixos--option-group-name
  :extract-fields ((or (gethash "type" data) "")
                   (nixos--propertize
                    (or (nixos--trim-description
                         (nixos--slurp-description data)) "")
                    'nixos-description))
  :visit-fn nixos-option
  :url-fmt nixos-option-search-url-template
  :cache-fn nixos--options-load
  :key-fn nil)


;;; Eldoc

(defun nixos-eldoc-function (callback &rest _ignored)
  "Return eldoc documentation for the NixOS option at point.
Call CALLBACK with the option description when point is on a
NixOS option reference in `nix-mode'.  Only returns docs when the
options cache is already populated (does not trigger a load)."
  (when (and (derived-mode-p 'nix-mode)
             nixos--options-cache)
    (when-let* ((opt (nixos--option-at-point))
                (data (gethash opt nixos--options-cache))
                (desc (nixos--slurp-description data)))
      (funcall callback desc))))

;;;###autoload
(defun nixos-eldoc-setup ()
  "Enable eldoc support for NixOS options in the current buffer.
Add this alongside `nixos-thing-at-point-setup' in
`nix-mode-hook' for full integration:

  (add-hook \\='nix-mode-hook #\\='nixos-thing-at-point-setup)
  (add-hook \\='nix-mode-hook #\\='nixos-eldoc-setup)"
  (add-hook 'eldoc-documentation-functions
            #'nixos-eldoc-function nil t))


;;; Package Browse Mode

(nixos--define-browse-mode package
  :mode-label "NixOS-Packages"
  :buffer-name "*Nix Packages*"
  :columns [("Package" 40 t)
            ("Version" 15 nixos--package-version-lessp :right-align t)
            ("Description" 0 nil)]
  :sort-key ("Package" . nil)
  :width-fn #'nixos--package-canonical-widths
  :extract-fields ((nixos--propertize (or (gethash "version" data) "")
                                      'nixos-version)
                   (nixos--propertize
                    (or (nixos--trim-description
                         (nixos--slurp-description data)) "")
                    'nixos-description))
  :visit-fn nixos-package
  :url-fmt nixos-package-search-url-template
  :cache-fn nixos--packages-load
  :key-fn (lambda (k) (string-remove-prefix nixos--package-key-prefix k)))


;; The browse-table commands are defined inside the macro above; the
;; ;;;###autoload cookie sits indented in the macro body so the
;; loaddefs scraper never sees it.  Emit explicit autoloads so the
;; commands are available before the package loads.
(autoload 'nixos-browse-options "nixos" nil t)
(autoload 'nixos-browse-packages "nixos" nil t)


;;; Embark

;; Value-less defvars: silence the byte-compiler without binding the
;; variables, so embark's own `defcustom' defaults survive when
;; nixos.el loads first.
(defvar embark-exporters-alist)
(defvar embark-keymap-alist)
(defvar embark-general-map)
(defvar embark-target-finders)

(defun nixos--embark-export-option (candidates)
  "Export the NixOS option CANDIDATES to a browse table."
  (nixos-browse-options candidates))

(defun nixos--embark-export-package (candidates)
  "Export the Nix package CANDIDATES to a browse table."
  (nixos-browse-packages candidates))

(defun nixos--embark-browse-option-url (cand)
  "Open CAND on search.nixos.org options."
  (browse-url (nixos--search-url nixos-option-search-url-template cand)))

(defun nixos--embark-browse-package-url (cand)
  "Open CAND on search.nixos.org packages."
  (browse-url (nixos--search-url nixos-package-search-url-template cand)))

(defvar-keymap nixos-embark-option-map
  :doc "Embark actions for NixOS option candidates.
The parent is set to `embark-general-map' once Embark loads."
  "RET" #'nixos-option
  "b"   #'nixos--embark-browse-option-url
  "i"   #'insert)

(defvar-keymap nixos-embark-package-map
  :doc "Embark actions for Nix package candidates.
The parent is set to `embark-general-map' once Embark loads."
  "RET" #'nixos-package
  "b"   #'nixos--embark-browse-package-url
  "i"   #'insert)

(defun nixos--property-bounds (property)
  "Return the bounds of PROPERTY around point, or nil.
The bounds cover the display text that carries PROPERTY, the way
Embark finds the extent of a `shr-url'."
  (when (get-text-property (point) property)
    (cons (previous-single-property-change
           (min (1+ (point)) (point-max)) property nil (point-min))
          (next-single-property-change (point) property nil (point-max)))))

(defun nixos--embark-target-url-at-point ()
  "Target the real URL of the display text at point.
`embark-target-url-at-point' reads the URL through `thing-at-point'
and its bounds through `thing-at-point-bounds-of-url-at-point'.  The
value then comes from the `nixos-url' property while the bounds cover
whatever the URL regexp matches in the shortened label, so a short
label gives a span that starts inside the label or holds no text at
all.  This finder reads the property for both, and returns nil
outside a browse buffer."
  (when-let* ((url (get-text-property (point) 'nixos-url))
              (bounds (nixos--property-bounds 'nixos-url)))
    (cons 'url (cons url bounds))))

(defun nixos--embark-target-file-at-point ()
  "Target the real path of the display text at point.
`embark-target-file-at-point' asks `ffap-file-at-point' about the
buffer text, so a shortened path answers nothing.  This finder reads
the `nixos-path' text property instead, and returns nil outside a
browse buffer."
  (when-let* ((path (get-text-property (point) 'nixos-path))
              (bounds (nixos--property-bounds 'nixos-path)))
    (cons 'file (cons path bounds))))

(with-eval-after-load 'embark
  ;; `defvar-keymap :parent' is evaluated once, at definition time,
  ;; when `embark-general-map' may not exist yet — wire it up here.
  (set-keymap-parent nixos-embark-option-map embark-general-map)
  (set-keymap-parent nixos-embark-package-map embark-general-map)
  (add-to-list 'embark-exporters-alist
               '(nixos-option . nixos--embark-export-option))
  (add-to-list 'embark-exporters-alist
               '(nixos-package . nixos--embark-export-package))
  (add-to-list 'embark-keymap-alist
               '(nixos-option . nixos-embark-option-map))
  (add-to-list 'embark-keymap-alist
               '(nixos-package . nixos-embark-package-map))
  ;; A shortened path defeats `ffap-file-at-point' and a shortened URL
  ;; label defeats the URL regexp, so finders of our own read the text
  ;; property.  They return nil elsewhere, and they run before the
  ;; builtin finders because `add-hook' prepends by default.
  (add-hook 'embark-target-finders #'nixos--embark-target-file-at-point)
  (add-hook 'embark-target-finders #'nixos--embark-target-url-at-point))

(provide 'nixos)
;;; nixos.el ends here
