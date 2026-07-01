;;; nixos-tests.el --- Tests for nixos -*- lexical-binding: t -*-

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

;; To run these tests:
;;
;;   (require 'nixos)
;;   (require 'ert)
;;
;; Then: M-x ert RET nixos

(require 'nixos)
(require 'ert)
(require 'cl-lib)


;;; Helpers

(cl-defun nixos-test--options-hash (&rest entries)
  "Build a hash table of mock NixOS options.
ENTRIES are (KEY . PLIST) pairs where PLIST is a flat plist
containing at least :description."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e entries table)
      (let ((inner (make-hash-table :test 'equal)))
        (cl-loop for (prop val) on (cdr e) by #'cddr
                 do (puthash (substring (symbol-name prop) 1) val inner))
        (puthash (car e) inner table)))))

(cl-defun nixos-test--packages-hash (&rest entries)
  "Build a hash table of mock Nix packages.
ENTRIES are (KEY . PLIST) pairs.  The KEY should be the full
attribute path (e.g. \"legacyPackages.x86_64-linux.foo\")."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e entries table)
      (let ((inner (make-hash-table :test 'equal)))
        (cl-loop for (prop val) on (cdr e) by #'cddr
                 do (puthash (substring (symbol-name prop) 1) val inner))
        (puthash (car e) inner table)))))

(defmacro nixos-test--with-options (options &rest body)
  "Evaluate BODY with `nixos--options-cache' bound to OPTIONS."
  (declare (indent 1))
  `(let ((nixos--options-cache ,options))
     ,@body))

(defmacro nixos-test--with-packages (packages &rest body)
  "Evaluate BODY with `nixos--packages-cache' and
`nixos--packages-keys' bound from PACKAGES."
  (declare (indent 1))
  `(let* ((nixos--packages-cache ,packages)
          (nixos--packages-keys
           (sort (mapcar (lambda (k)
                           (string-remove-prefix
                            "legacyPackages.x86_64-linux." k))
                         (hash-table-keys nixos--packages-cache))
                 #'string<)))
     ,@body))


;;; Unit tests

(ert-deftest nixos-hash-ref-shallow ()
  "Single-key lookup with `nixos--hash-ref'."
  (let ((table (nixos-test--options-hash
                '("foo" :description "a foo option"))))
    (let ((inner (nixos--hash-ref table "foo")))
      (should (hash-table-p inner))
      (should (equal (gethash "description" inner) "a foo option")))))

(ert-deftest nixos-hash-ref-missing-key ()
  "`nixos--hash-ref' returns nil for missing keys."
  (let ((table (make-hash-table :test 'equal)))
    (should-not (nixos--hash-ref table "nonexistent"))))

(ert-deftest nixos-slurp-description-from-hash ()
  "`nixos--slurp-description' extracts description from a hash table."
  (let ((inner (make-hash-table :test 'equal)))
    (puthash "description" "A test option" inner)
    (should (equal (nixos--slurp-description inner) "A test option"))))

(ert-deftest nixos-slurp-description-falls-back-to-pname ()
  "`nixos--slurp-description' uses pname when description is missing."
  (let ((inner (make-hash-table :test 'equal)))
    (puthash "pname" "testpkg" inner)
    (should (equal (nixos--slurp-description inner) "testpkg"))))

(ert-deftest nixos-slurp-description-empty ()
  "`nixos--slurp-description' returns \"\" for empty objects."
  (let ((inner (make-hash-table :test 'equal)))
    (should (equal (nixos--slurp-description inner) ""))))


;;; Annotation

(ert-deftest nixos-annotate-string ()
  "`nixos--annotate' produces a propertized string."
  (let ((ann (nixos--annotate "A description")))
    (should (stringp ann))
    (should (string-match-p "A description" ann))
    (should (text-property-not-all 0 (length ann) 'display nil ann))))

(ert-deftest nixos-annotate-empty ()
  "`nixos--annotate' returns nil for empty string."
  (should-not (nixos--annotate "")))


;;; Options collection & annotation

(ert-deftest nixos-option-annotate ()
  "Annotation for a NixOS option shows its description."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable"
         :description "Whether to enable foo."))
    (let ((ann (nixos--option-annotate "services.foo.enable")))
      (should (stringp ann))
      (should (string-match-p "Whether to enable foo" ann)))))

(ert-deftest nixos-option-annotate-missing-key ()
  "Annotation returns nil for a key not in the cache."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("foo" :description "bar"))
    (should-not (nixos--option-annotate "nonexistent"))))

(ert-deftest nixos-option-collection-metadata ()
  "The metadata action returns an annotation-function entry."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "foo"))
    (let ((meta (nixos--option-collection "" t 'metadata)))
      (should (consp meta))
      (should (eq (car meta) 'metadata))
      (should (assq 'annotation-function (cdr meta))))))

(ert-deftest nixos-option-collection-completion ()
  "Completion action returns matching candidates."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "foo")
       '("services.bar.enable" :description "bar")
       '("system.stateVersion" :description "version"))
    (let ((cands (nixos--option-collection "services" nil t)))
      (should (equal (sort (copy-sequence cands) #'string<)
                     '("services.bar.enable" "services.foo.enable"))))))

(ert-deftest nixos-option-collection-empty ()
  "Completion returns nil when no candidates match."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("foo" :description "bar"))
    (should-not (nixos--option-collection "zzz" nil t))))


;;; Package collection & annotation

(ert-deftest nixos-package-annotate ()
  "Annotation for a Nix package shows its description."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop"
         :description "Interactive process viewer"))
    (let ((ann (nixos--package-annotate "htop")))
      (should (stringp ann))
      (should (string-match-p "Interactive process viewer" ann)))))

(ert-deftest nixos-package-collection-keys ()
  "Package collection returns short names."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop")
       '("legacyPackages.x86_64-linux.neovim"
         :pname "neovim"))
    (let ((cands (nixos--package-collection "" nil t)))
      (should (equal (sort (copy-sequence cands) #'string<)
                     '("htop" "neovim"))))))

(ert-deftest nixos-package-collection-filter ()
  "Package collection respects prefix filter."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.python3" :pname "python3")
       '("legacyPackages.x86_64-linux.python39" :pname "python39")
       '("legacyPackages.x86_64-linux.htop" :pname "htop"))
    (let ((cands (nixos--package-collection "python" nil t)))
      (should (equal (sort (copy-sequence cands) #'string<)
                     '("python3" "python39"))))))


;;; Cache

(ert-deftest nixos-refresh-cache-clears-both ()
  "`nixos-refresh-cache' resets all caches."
  (setq nixos--options-cache nil
        nixos--package-meta-cache nil
        nixos--packages-cache (make-hash-table :test 'equal)
        nixos--packages-keys '("a"))
  (nixos-refresh-cache)
  (should-not nixos--options-cache)
  (should-not nixos--package-meta-cache)
  (should-not nixos--packages-cache)
  (should-not nixos--packages-keys))

(ert-deftest nixos-load-missing-file ()
  "Loading from a nonexistent file returns an empty hash table."
  (setq nixos--options-cache nil)
  (let ((nixos-options-json-file "/nonexistent/path/options.json"))
    (let ((result (nixos--options-load)))
      (should (hash-table-p result))
      (should (= (hash-table-count result) 0))))
  (setq nixos--packages-cache nil)
  (let ((nixos-search-json-file "/nonexistent/path/search.json"))
    (let ((result (nixos--packages-load)))
      (should (hash-table-p result))
      (should (= (hash-table-count result) 0))
      (should (null nixos--packages-keys)))))


;;; Non-interactive commands

(ert-deftest nixos-option-noninteractive ()
  "`nixos-option' with a non-nil argument works without prompting."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "Enable foo"))
    (let ((displayed nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (setq displayed buf))))
        (nixos-option "services.foo.enable")
        (should displayed)
        (should (buffer-live-p displayed))
        (with-current-buffer displayed
          (should (string-match-p "Enable foo" (buffer-string))))
        (kill-buffer displayed)))))

(ert-deftest nixos-option-noninteractive-missing ()
  "`nixos-option' signals an error for a missing option."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("foo" :description "bar"))
    (should-error (nixos-option "nonexistent"))))

(ert-deftest nixos-package-noninteractive-no-nix-instantiate ()
  "`nixos-package' falls back to search JSON when nix-instantiate is absent."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop"
         :version "3.0"
         :description "process viewer"))
    (let ((displayed nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (setq displayed buf)))
                ;; Ensure nix-instantiate doesn't run.
                ((symbol-function 'nixos--package-meta)
                 (lambda (_) nil)))
        (nixos-package "htop")
        (should displayed)
        (should (buffer-live-p displayed))
        (with-current-buffer displayed
          (should (string-match-p "htop" (buffer-string))))
        (kill-buffer displayed)))))

(ert-deftest nixos-package-noninteractive-missing ()
  "`nixos-package' signals an error for a missing package."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.foo" :pname "foo"))
    (should-error (nixos-package "nonexistent"))))


;;; Metadata (Marginalia category)

(ert-deftest nixos-metadata-option-category ()
  "Option metadata includes the nixos-option category."
  (let ((meta (nixos--option-collection "" nil 'metadata)))
    (should (eq (alist-get 'category (cdr meta)) 'nixos-option))))

(ert-deftest nixos-metadata-package-category ()
  "Package metadata includes the nixos-package category."
  (let ((meta (nixos--package-collection "" nil 'metadata)))
    (should (eq (alist-get 'category (cdr meta)) 'nixos-package))))


;;; Thing-at-point

(ert-deftest nixos-thing-at-point-in-nix-mode ()
  "`thing-at-point' for 'nixos-option returns a dotted identifier in nix-mode."
  (skip-unless (fboundp 'nix-mode))
  (with-temp-buffer
    (nix-mode)
    (insert "services.postgresql.enable = true;")
    (goto-char (point-min))
    (search-forward "services")
    (goto-char (match-beginning 0))
    (should (equal (thing-at-point 'nixos-option)
                   "services.postgresql.enable"))))

(ert-deftest nixos-thing-at-point-no-dot ()
  "`thing-at-point' returns nil for identifiers without a dot."
  (skip-unless (fboundp 'nix-mode))
  (with-temp-buffer
    (nix-mode)
    (insert "foo = true;")
    (goto-char (point-min))
    (search-forward "foo")
    (goto-char (match-beginning 0))
    (should-not (thing-at-point 'nixos-option))))

(ert-deftest nixos-thing-at-point-not-nix-mode ()
  "`thing-at-point' for 'nixos-option returns nil outside nix-mode."
  (with-temp-buffer
    (fundamental-mode)
    (insert "services.foo.enable")
    (goto-char (point-min))
    (should-not (thing-at-point 'nixos-option))))

(ert-deftest nixos-thing-at-point-bounds ()
  "Bounds of 'nixos-option span the whole dotted identifier."
  (skip-unless (fboundp 'nix-mode))
  (with-temp-buffer
    (nix-mode)
    (insert "{ services.postgresql.enable = true; }")
    (goto-char (point-min))
    (search-forward "services")
    (let ((bounds (bounds-of-thing-at-point 'nixos-option)))
      (should bounds)
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     "services.postgresql.enable")))))

(ert-deftest nixos-thing-at-point-provider-alist ()
  "`nixos-thing-at-point-setup' adds to `thing-at-point-provider-alist'."
  (skip-unless (fboundp 'nix-mode))
  (with-temp-buffer
    (nix-mode)
    (nixos-thing-at-point-setup)
    (let ((entry (assq 'nixos-option thing-at-point-provider-alist)))
      (should entry)
      (should (eq (cdr entry) 'nixos--option-at-point)))))


;;; Browse mode

(ert-deftest nixos-browse-mode-option-buffer ()
  "Option display buffer uses `nixos-browse-mode' and stores metadata."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "Enable foo"))
    (let ((buf-name nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (setq buf-name (buffer-name buf))
                   (set-buffer buf))))
        (nixos-option "services.foo.enable")
        (should (eq major-mode 'nixos-browse-mode))
        (should (eq nixos--browse-type 'option))
        (should (equal nixos--browse-name "services.foo.enable"))
        (kill-buffer)))))

(ert-deftest nixos-browse-mode-package-buffer ()
  "Package display buffer stores correct browse metadata."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :description "viewer"))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buf) (set-buffer buf))))
      (nixos-package "htop")
      (should (eq major-mode 'nixos-browse-mode))
      (should (eq nixos--browse-type 'package))
      (should (equal nixos--browse-name "htop"))
      (kill-buffer))))

(ert-deftest nixos-browse-search-url-option ()
  "`nixos-browse-search-url' opens the correct option URL."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "bar"))
    (let ((url-called nil)
          (url-arg nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'browse-url)
                 (lambda (url) (setq url-called t url-arg url))))
        (nixos-option "services.foo.enable")
        (nixos-browse-search-url)
        (should url-called)
        (should (string-match-p "services.foo.enable" url-arg))
        (should (string-match-p "options" url-arg))
        (kill-buffer)))))

(ert-deftest nixos-browse-search-url-package ()
  "`nixos-browse-search-url' opens the correct package URL."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :description "viewer"))
    (let ((url-called nil)
          (url-arg nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'browse-url)
                 (lambda (url) (setq url-called t url-arg url))))
        (nixos-package "htop")
        (nixos-browse-search-url)
        (should url-called)
        (should (string-match-p "htop" url-arg))
        (should (string-match-p "packages" url-arg))
        (kill-buffer)))))

(ert-deftest nixos-browse-refresh-option ()
  "`nixos-browse-refresh' re-displays the option."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "foo"))
    (let ((browse-buf nil)
          (refreshed nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (setq browse-buf buf) (set-buffer buf))))
        (nixos-option "services.foo.enable")
        (should (equal nixos--browse-name "services.foo.enable"))
        ;; Now mock nixos-option and call refresh from the browse buffer.
        (cl-letf (((symbol-function 'nixos-option)
                   (lambda (name) (setq refreshed name))))
          (nixos-browse-refresh)
          (should (equal refreshed "services.foo.enable")))
        (kill-buffer browse-buf)))))


;;; Bookmarks

(ert-deftest nixos-bookmark-make-record ()
  "`nixos--bookmark-make-record' returns a bookmark record with the right handler."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "bar"))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buf) (set-buffer buf))))
      (nixos-option "services.foo.enable")
      (let ((rec (nixos--bookmark-make-record)))
        (should (stringp (car rec)))
        (should (eq (alist-get 'type rec) 'option))
        (should (equal (alist-get 'name rec) "services.foo.enable"))
        (should (eq (alist-get 'handler rec) 'nixos--bookmark-jump)))
      (kill-buffer))))

(ert-deftest nixos-bookmark-jump-option ()
  "`nixos--bookmark-jump' calls `nixos-option' with the stored name."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "bar"))
    (let ((called-name nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-option)
                 (lambda (name) (setq called-name name))))
        (nixos--bookmark-jump '((type . option)
                                (name . "services.foo.enable")))
        (should (equal called-name "services.foo.enable"))))))

(ert-deftest nixos-bookmark-jump-package ()
  "`nixos--bookmark-jump' calls `nixos-package' with the stored name."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :description "viewer"))
    (let ((called-name nil))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-package)
                 (lambda (name) (setq called-name name))))
        (nixos--bookmark-jump '((type . package)
                                (name . "htop")))
        (should (equal called-name "htop"))))))


;;; URL templates

(ert-deftest nixos-url-template-option ()
  "Option URL template substitutes correctly."
  (should (string-match-p
           "services.foo.enable"
           (format nixos-option-search-url-template "services.foo.enable"))))

(ert-deftest nixos-url-template-package ()
  "Package URL template substitutes correctly."
  (should (string-match-p
           "htop"
           (format nixos-package-search-url-template "htop"))))


;;; Tabulated browse mode

(ert-deftest nixos-browse-options-entry ()
  "`nixos-browse-options--entry' returns a proper tabulated-list entry."
  (let ((data (make-hash-table :test 'equal)))
    (puthash "type" "boolean" data)
    (puthash "description" "Enable something" data)
    (let ((entry (nixos-browse-options--entry "services.foo.enable" data)))
      (should (equal (car entry) "services.foo.enable"))
      (let ((cols (cadr entry)))
        (should (equal (aref cols 0) "services.foo.enable"))
        (should (equal (aref cols 1) "boolean"))
        (should (equal (aref cols 2) "Enable something"))))))

(ert-deftest nixos-browse-options-entries ()
  "`nixos-browse-options--entries' generates entries for all options."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :type "boolean" :description "Enable foo")
       '("services.bar.enable" :type "string" :description "Set bar"))
    (let ((entries (nixos-browse-options--entries)))
      (should (= (length entries) 2))
      (should (assoc "services.foo.enable" entries))
      (should (assoc "services.bar.enable" entries)))))

(ert-deftest nixos-browse-options-empty ()
  "`nixos-browse-options--entries' errors on empty cache."
  (setq nixos--options-cache (make-hash-table :test 'equal))
  (should-error (nixos-browse-options--entries)))

(ert-deftest nixos-browse-options-current-name ()
  "`nixos-browse-options--current-name' returns the entry at point."
  (cl-letf (((symbol-function 'tabulated-list-get-id)
             (lambda () "services.foo.enable")))
    (should (equal (nixos-browse-options--current-name)
                   "services.foo.enable")))
  ;; Error case
  (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () nil)))
    (should-error (nixos-browse-options--current-name))))

(ert-deftest nixos-browse-options-entries-loaded ()
  "Tabulated list entries are properly structured."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :type "boolean" :description "foo"))
    (let ((entries (nixos-browse-options--entries)))
      (should (= (length entries) 1))
      (should (equal (car (car entries)) "services.foo.enable")))))


;;; Eldoc

(ert-deftest nixos-eldoc-outside-nix-mode ()
  "Eldoc returns nil outside nix-mode."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "Enable foo"))
    (with-temp-buffer
      (fundamental-mode)
      (insert "services.foo.enable")
      (goto-char (point-min))
      (let ((called nil))
        (nixos-eldoc-function (lambda (s) (setq called s)))
        (should-not called)))))

(ert-deftest nixos-eldoc-no-option-at-point ()
  "Eldoc returns nil when point is not on an option."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "Enable foo"))
    (skip-unless (fboundp 'nix-mode))
    (with-temp-buffer
      (nix-mode)
      (insert "let x = 42; in x")
      (goto-char (point-min))
      (let ((called nil))
        (nixos-eldoc-function (lambda (s) (setq called s)))
        (should-not called)))))

(ert-deftest nixos-eldoc-option-at-point ()
  "Eldoc returns description when point is on a known option."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "Enable foo"))
    (skip-unless (fboundp 'nix-mode))
    (with-temp-buffer
      (nix-mode)
      (insert "services.foo.enable = true;")
      (goto-char (point-min))
      (search-forward "services")
      (goto-char (match-beginning 0))
      (let ((result nil))
        (nixos-eldoc-function (lambda (s) (setq result s)))
        (should (equal result "Enable foo"))))))

(ert-deftest nixos-eldoc-setup ()
  "`nixos-eldoc-setup' adds to `eldoc-documentation-functions'."
  (with-temp-buffer
    (nixos-eldoc-setup)
    (should (memq #'nixos-eldoc-function eldoc-documentation-functions))))


;;; Marginalia annotators

(ert-deftest nixos-marginalia-option-annotator ()
  "Option annotator shows type and description."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :type "boolean" :description "Enable foo"))
    (let ((ann (nixos--marginalia-option-annotator "services.foo.enable")))
      (should (stringp ann))
      (should (string-match-p "boolean" ann))
      (should (string-match-p "Enable foo" ann)))))

(ert-deftest nixos-marginalia-package-annotator ()
  "Package annotator shows version and description."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.3.0" :description "Interactive process viewer"))
    (let ((ann (nixos--marginalia-package-annotator "htop")))
      (should (stringp ann))
      (should (string-match-p "3.3.0" ann))
      (should (string-match-p "process viewer" ann)))))


;;; Package browse mode

(ert-deftest nixos-browse-packages-entry ()
  "`nixos-browse-packages--entry' returns a proper tabulated-list entry."
  (let ((data (make-hash-table :test 'equal)))
    (puthash "version" "3.3.0" data)
    (puthash "description" "process viewer" data)
    (let ((entry (nixos-browse-packages--entry "htop" data)))
      (should (equal (car entry) "htop"))
      (let ((cols (cadr entry)))
        (should (equal (aref cols 0) "htop"))
        (should (equal (aref cols 1) "3.3.0"))
        (should (equal (aref cols 2) "process viewer"))))))

(ert-deftest nixos-browse-packages-entries ()
  "`nixos-browse-packages--entries' generates entries with short names."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.0" :description "viewer")
       '("legacyPackages.x86_64-linux.neovim"
         :pname "neovim" :version "0.10" :description "editor"))
    (let ((entries (nixos-browse-packages--entries)))
      (should (= (length entries) 2))
      (should (assoc "htop" entries))
      (should (assoc "neovim" entries)))))

(ert-deftest nixos-browse-packages-filter ()
  "`nixos-browse-packages--entries' filters by name-list."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.0" :description "viewer")
       '("legacyPackages.x86_64-linux.neovim"
         :pname "neovim" :version "0.10" :description "editor"))
    (let ((entries (nixos-browse-packages--entries '("htop"))))
      (should (= (length entries) 1))
      (should (assoc "htop" entries)))))

(ert-deftest nixos-browse-options-filter ()
  "`nixos-browse-options--entries' filters by name-list."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :type "boolean" :description "foo")
       '("services.bar.enable" :type "string" :description "bar"))
    (let ((entries (nixos-browse-options--entries
                    '("services.foo.enable"))))
      (should (= (length entries) 1))
      (should (assoc "services.foo.enable" entries)))))


;;; Embark

(ert-deftest nixos-embark-export-option ()
  "Embark option export calls `nixos-browse-options' with candidates."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-browse-options)
               (lambda (names) (setq called names))))
      (nixos--embark-export-option '("a" "b"))
      (should (equal called '("a" "b"))))))

(ert-deftest nixos-embark-export-package ()
  "Embark package export calls `nixos-browse-packages' with candidates."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-browse-packages)
               (lambda (names) (setq called names))))
      (nixos--embark-export-package '("htop" "neovim"))
      (should (equal called '("htop" "neovim"))))))

(ert-deftest nixos-embark-browse-urls ()
  "Embark URL actions delegate to `browse-url'."
  (let ((url-called nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq url-called url))))
      (nixos--embark-browse-option-url "services.foo")
      (should (string-match-p "services.foo" url-called))
      (should (string-match-p "options" url-called))
      (setq url-called nil)
      (nixos--embark-browse-package-url "htop")
      (should (string-match-p "htop" url-called))
      (should (string-match-p "packages" url-called)))))

(ert-deftest nixos-embark-insert ()
  "`nixos--embark-insert-option' inserts the candidate at point."
  (with-temp-buffer
    (nixos--embark-insert-option "services.foo.enable")
    (should (equal (buffer-string) "services.foo.enable"))))


;;; Memoization

(ert-deftest nixos-package-meta-memoized ()
  "`with-memoization' using `gethash' caches results correctly."
  (let* ((h (make-hash-table :test 'equal))
         (compute-count 0))
    (cl-labels ((costly-computation ()
                  (cl-incf compute-count)
                  (format "data-%d" compute-count)))
      ;; First call: compute.
      (should (equal (with-memoization (gethash "a" h) (costly-computation))
                     "data-1"))
      (should (= compute-count 1))
      ;; Second call: cached.
      (should (equal (with-memoization (gethash "a" h) (costly-computation))
                     "data-1"))
      (should (= compute-count 1))
      ;; Different key: fresh compute.
      (should (equal (with-memoization (gethash "b" h) (costly-computation))
                     "data-2"))
      (should (= compute-count 2))
      ;; Nil results are NOT cached (retry each time).
      (let ((retry-count 0))
        (should-not (with-memoization (gethash "c" h)
                      (cl-incf retry-count)
                      nil))
        (should-not (with-memoization (gethash "c" h)
                      (cl-incf retry-count)
                      nil))
        (should (= retry-count 2))))))

(ert-deftest nixos-package-meta-cache-cleared ()
  "`nixos-refresh-cache' clears the package meta cache."
  (setq nixos--package-meta-cache (make-hash-table :test 'equal))
  (puthash "foo" "cached" nixos--package-meta-cache)
  (nixos-refresh-cache)
  (should-not nixos--package-meta-cache))

(provide 'nixos-tests)
;;; nixos-tests.el ends here
