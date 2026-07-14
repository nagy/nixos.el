;;; nixos-tests.el --- Tests for nixos -*- lexical-binding: t -*-

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

;; To run these tests:
;;
;;   (require 'nixos)
;;   (require 'ert)
;;
;; Then: M-x ert RET nixos

(require 'nixos)
(require 'ol-nixos)
(require 'ert)
(require 'cl-lib)

(defvar nix-instantiate-executable)
(declare-function nix-mode "nix-mode")


;;; Helpers

(cl-defun nixos-test--options-hash (&rest entries)
  "Build a hash table of mock NixOS options or Nix packages.
ENTRIES are (KEY . PLIST) pairs where PLIST is a flat plist
containing at least :description.  Keyword keys (:foo) are
converted to strings by stripping the leading colon."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e entries table)
      (let ((inner (make-hash-table :test 'equal)))
        (cl-loop for (prop val) on (cdr e) by #'cddr
                 do (puthash (substring (symbol-name prop) 1) val inner))
        (puthash (car e) inner table)))))

(defalias 'nixos-test--packages-hash #'nixos-test--options-hash)

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

(ert-deftest nixos-ensure-nixpkgs-root ()
  "`nixos--ensure-nixpkgs-root' discovers the nixpkgs root from NIX_PATH."
  (let ((nixos--nixpkgs-root nil))
    (let ((nix-instantiate-executable "nix-instantiate"))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (_program &optional _infile destination _display &rest _args)
                   (when (eq destination t)
                     (insert "[{\"path\":\"/nix/store/nixpkgs-source\",\"prefix\":\"nixpkgs\"}]"))
                   0)))
        (should (equal (nixos--ensure-nixpkgs-root)
                       "/nix/store/nixpkgs-source"))
        ;; Second call uses cache, doesn't invoke call-process.
        (let ((called nil))
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest _) (setq called t) 0)))
            (nixos--ensure-nixpkgs-root)
            (should-not called)))))))

(ert-deftest nixos-display-option-sets-default-directory ()
  "`nixos--display-option' sets `default-directory' to first declaration."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable"
         :description "Enable foo"
         :declarations ["nixos/modules/services/foo.nix"]))
    ;; Create a fake nixpkgs tree and point the nixpkgs root at it.
    (let* ((tmp-root (make-temp-file "nixos-test-nixpkgs-" t))
           (expected-file (expand-file-name
                           "nixos/modules/services/foo.nix" tmp-root)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory expected-file) t)
            (write-region "" nil expected-file)
            (let ((nixos--nixpkgs-root tmp-root))
              (cl-letf (((symbol-function 'pop-to-buffer)
                         (lambda (buf) (set-buffer buf))))
                (nixos--display-option
                 "services.foo.enable"
                 (gethash "services.foo.enable" nixos--options-cache))
                (should (equal tmp-root default-directory))
                (kill-buffer))))
        (delete-directory tmp-root t)))))

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
      (cl-letf (((symbol-function 'pop-to-buffer)
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
      (cl-letf (((symbol-function 'pop-to-buffer)
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

(ert-deftest nixos-package-noninteractive-with-meta ()
  "`nixos-package' displays package metadata when `nixos--package-meta' succeeds."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.5.1" :description "process viewer"))
    (let ((displayed nil)
          (meta-ht (make-hash-table :test 'equal)))
      (puthash "description" "Interactive process viewer" meta-ht)
      (puthash "version" "3.5.1" meta-ht)
      (puthash "homepage" "https://htop.dev/" meta-ht)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf) (setq displayed buf)))
                ;; Mock nixos--package-meta to return metadata with outPath.
                ((symbol-function 'nixos--package-meta)
                 (lambda (_)
                   (list (cons 'meta meta-ht)
                         (cons 'outPath
                               "/nix/store/fmnh7ka0srnsnh7ccykyb0ml548d14hl-htop-3.5.1")))))
        (nixos-package "htop")
        (should displayed)
        (should (buffer-live-p displayed))
        (with-current-buffer displayed
          (let ((content (buffer-string)))
            ;; Title
            (should (string-match-p "htop" content))
            ;; Store path is displayed
            (should (string-match-p "Store path:" content))
            (should (string-match-p "fmnh7ka0srnsnh7ccykyb0ml548d14hl-htop-3.5.1" content))
            ;; Description
            (should (string-match-p "Interactive process viewer" content))
            ;; Version
            (should (string-match-p "3.5.1" content))
            ;; Homepage
            (should (string-match-p "https://htop.dev/" content))
            ;; Browse metadata is set
            (should (eq nixos--browse-type 'package))
            (should (equal nixos--browse-name "htop"))
            (should (equal nixos--browse-out-path
                          "/nix/store/fmnh7ka0srnsnh7ccykyb0ml548d14hl-htop-3.5.1"))))
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
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf))))
        (nixos-option "services.foo.enable")
        (should (eq major-mode 'nixos-browse-mode))
        (should (eq nixos--browse-type 'option))
        (should (equal nixos--browse-name "services.foo.enable"))
        (kill-buffer))))

(ert-deftest nixos-browse-mode-package-buffer ()
  "Package display buffer stores correct browse metadata."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :description "viewer"))
    (cl-letf (((symbol-function 'pop-to-buffer)
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
      (cl-letf (((symbol-function 'pop-to-buffer)
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
      (cl-letf (((symbol-function 'pop-to-buffer)
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
      (cl-letf (((symbol-function 'pop-to-buffer)
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
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf))))
      (nixos-option "services.foo.enable")
      (let ((rec (nixos--bookmark-make-record)))
        (should (stringp (car rec)))
        (should (eq (alist-get 'type rec) 'option))
        (should (equal (alist-get 'name rec) "services.foo.enable"))
        (should (eq (alist-get 'handler rec) 'nixos--bookmark-jump))
        (should-not (alist-get 'local rec))
        (should-not (alist-get 'local-dir rec)))
      (kill-buffer))))

(ert-deftest nixos-bookmark-jump-option ()
  "`nixos--bookmark-jump' calls `nixos-option' with the stored name."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :description "bar"))
    (let ((called-name nil))
      (cl-letf (((symbol-function 'pop-to-buffer)
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
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-package)
                 (lambda (name) (setq called-name name))))
        (nixos--bookmark-jump '((type . package)
                                (name . "htop")))
        (should (equal called-name "htop"))))))

(ert-deftest nixos-bookmark-jump-package-local ()
  "`nixos--bookmark-jump' calls `nixos-package-local' for local bookmarks."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :description "viewer"))
    (let ((called-dir nil))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-package-local)
                 (lambda () (setq called-dir default-directory))))
        (nixos--bookmark-jump '((type . package)
                                (name . "htop")
                                (local . t)
                                (local-dir . "/tmp/my-project/")))
        (should (equal called-dir "/tmp/my-project/"))))))


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
               (lambda (names &optional _prefix) (setq called names))))
      (nixos--embark-export-option '("a" "b"))
      (should (equal called '("a" "b"))))))

(ert-deftest nixos-embark-export-package ()
  "Embark package export calls `nixos-browse-packages' with candidates."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-browse-packages)
               (lambda (names &optional _prefix) (setq called names))))
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

;;; Memoization

(ert-deftest nixos-package-meta-memoized ()
  "`nixos--package-meta' memoizes per-package and distinguishes keys."
  (let ((nixos--package-meta-cache nil)
        (call-count 0))
    (cl-letf (((symbol-function 'nixos--call-nix-package-expr)
               (lambda (_expr &rest _extra-args)
                 (setq call-count (1+ call-count))
                 ;; Return a cons (ALIST . "") matching the expected format.
                 (let* ((meta (make-hash-table :test 'equal))
                        (pkg (if (= call-count 1) "htop" "neovim")))
                   (puthash "description" (format "%s viewer" pkg) meta)
                   (puthash "version" (if (string= pkg "htop") "3.5.1" "0.10") meta)
                   (cons (list (cons 'meta meta)
                               (cons 'outPath (format "/nix/store/%s-path" pkg))
                               (cons 'version (if (string= pkg "htop") "3.5.1" "0.10"))
                               (cons 'buildInputs [])
                               (cons 'nativeBuildInputs [])
                               (cons 'pname pkg)
                               (cons 'repository (format "https://github.com/org/%s" pkg)))
                         "")))))
      (unwind-protect
          (progn
            ;; First call: htop, should compute.
            (let ((result (nixos--package-meta "htop")))
              (should result)
              (should (hash-table-p (alist-get 'meta result)))
              (should (equal (alist-get 'outPath result) "/nix/store/htop-path"))
              (should (= call-count 1)))
            ;; Second call: htop again, should be cached.
            (let ((result (nixos--package-meta "htop")))
              (should result)
              (should (equal (alist-get 'outPath result) "/nix/store/htop-path"))
              (should (= call-count 1)))
            ;; Third call: neovim, should compute fresh (different key).
            (let ((result (nixos--package-meta "neovim")))
              (should result)
              (should (equal (alist-get 'outPath result) "/nix/store/neovim-path"))
              (should (= call-count 2)))
            ;; Fourth call: neovim cached.
            (let ((result (nixos--package-meta "neovim")))
              (should result)
              (should (equal (alist-get 'outPath result) "/nix/store/neovim-path"))
              (should (= call-count 2))))
        (setq nix-instantiate-executable nil)))))

(ert-deftest nixos-package-meta-cache-cleared ()
  "`nixos-refresh-cache' clears the package meta cache."
  (setq nixos--package-meta-cache (make-hash-table :test 'equal))
  (puthash "foo" "cached" nixos--package-meta-cache)
  (nixos-refresh-cache)
  (should-not nixos--package-meta-cache))


;;; URL package support

(ert-deftest nixos-parse-package-result-valid ()
  "`nixos--parse-package-result' parses a valid result vector."
  (let* ((meta (make-hash-table :test 'equal))
         (vec (vector meta "/nix/store/pkg" "1.0" [] [] nil nil)))
    (puthash "description" "Test package" meta)
    (puthash "version" "1.0" meta)
    (let ((result (nixos--parse-package-result vec)))
      (should (consp result))
      (should (string= (cdr result) ""))
      (let ((alist (car result)))
        (should (equal (alist-get 'outPath alist) "/nix/store/pkg"))
        (should (eq (alist-get 'meta alist) meta))
        (should (equal (alist-get 'version alist) "1.0"))))))

(ert-deftest nixos-parse-package-result-invalid ()
  "`nixos--parse-package-result' returns an error for non-vectors."
  (let ((result (nixos--parse-package-result "not-a-vector")))
    (should (consp result))
    (should-not (car result))
    (should (string-match-p "Unexpected JSON type" (cdr result)))
    (should (string-match-p "expected array" (cdr result)))))

(ert-deftest nixos-parse-package-result-null-fields ()
  "`nixos--parse-package-result' handles null fields gracefully."
  (let* ((meta (make-hash-table :test 'equal))
         (vec (vector meta :null :null [] [] :json-false :json-false)))
    (puthash "description" "Null-safe" meta)
    (let ((result (nixos--parse-package-result vec)))
      (should (consp result))
      (should (string= (cdr result) ""))
      (let ((alist (car result)))
        (should-not (alist-get 'outPath alist))
        (should-not (alist-get 'version alist))
        (should-not (alist-get 'pname alist))
        (should-not (alist-get 'repository alist))))))

(ert-deftest nixos-package-url-noninteractive ()
  "`nixos-package-url' displays package metadata from a mock URL."
  (let ((displayed nil)
        (meta-ht (make-hash-table :test 'equal)))
    (puthash "description" "A URL package" meta-ht)
    (puthash "version" "2.0" meta-ht)
    (puthash "homepage" "https://example.com/" meta-ht)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (setq displayed buf) (set-buffer buf)))
              ((symbol-function 'nixos--call-nix-url-expr)
               (lambda (_url)
                 (let ((vec (vector meta-ht
                                    "/nix/store/urlpkg"
                                    "2.0"
                                    '[] '[]
                                    "urlpkgname"
                                    nil)))
                   (nixos--parse-package-result vec)))))
      (nixos-package-url "https://example.com/archive.tar.gz")
      (should displayed)
      (should (buffer-live-p displayed))
      (with-current-buffer displayed
        (let ((content (buffer-string)))
          (should (string-match-p "urlpkgname" content))
          (should (string-match-p "A URL package" content))
          (should (string-match-p "2.0" content))
          (should (string-match-p "https://example.com/" content))
          (should (string-match-p "/nix/store/urlpkg" content))
          ;; Browse metadata is set
          (should (eq nixos--browse-type 'package))
          (should (equal nixos--browse-name "urlpkgname"))
          (should (equal nixos--browse-out-path "/nix/store/urlpkg"))
          ;; URL state is set
          (should nixos--browse-url)
          (should (equal nixos--browse-url-str "https://example.com/archive.tar.gz"))
          ;; not local
          (should-not nixos--browse-local)))
      (kill-buffer displayed))))

(ert-deftest nixos-package-url-error ()
  "`nixos-package-url' signals an error when nix-instantiate fails."
  (cl-letf (((symbol-function 'nixos--call-nix-url-expr)
             (lambda (_url) (cons nil "fetch failed"))))
    (should-error (nixos-package-url "https://example.com/bad.tar.gz"))))

(ert-deftest nixos-browse-refresh-url ()
  "`nixos-browse-refresh' re-evaluates the URL for URL packages."
  (let ((browse-buf nil)
        (refreshed nil)
        (meta-ht (make-hash-table :test 'equal)))
    (puthash "description" "refresh test" meta-ht)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (setq browse-buf buf) (set-buffer buf)))
              ((symbol-function 'nixos--call-nix-url-expr)
               (lambda (_url)
                 (let ((vec (vector meta-ht "/nix/store/ref" "1.0" '[] '[] "refpkg" nil)))
                   (nixos--parse-package-result vec)))))
      (nixos-package-url "https://example.com/pkg.tar.gz")
      (should (equal nixos--browse-url-str "https://example.com/pkg.tar.gz"))
      (cl-letf (((symbol-function 'nixos-package-url)
                 (lambda (url) (setq refreshed url))))
        (nixos-browse-refresh)
        (should (equal refreshed "https://example.com/pkg.tar.gz")))
      (kill-buffer browse-buf))))

(ert-deftest nixos-bookmark-url ()
  "Bookmark records for URL packages include the URL state."
  (let ((meta-ht (make-hash-table :test 'equal)))
    (puthash "description" "url-pkg" meta-ht)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf)))
              ((symbol-function 'nixos--call-nix-url-expr)
               (lambda (_url)
                 (let ((vec (vector meta-ht "/nix/store/u" "3.0" '[] '[] "urlpkg" nil)))
                   (nixos--parse-package-result vec)))))
      (nixos-package-url "https://example.com/bkmk.tar.gz")
      (let ((rec (nixos--bookmark-make-record)))
        (should (eq (alist-get 'type rec) 'package))
        (should (equal (alist-get 'name rec) "urlpkg"))
        (should (eq (alist-get 'handler rec) 'nixos--bookmark-jump))
        (should (eq (alist-get 'browse-url rec) t))
        (should (equal (alist-get 'browse-url-str rec) "https://example.com/bkmk.tar.gz")))
      (kill-buffer))))

(ert-deftest nixos-bookmark-jump-url ()
  "`nixos--bookmark-jump' calls `nixos-package-url' for URL bookmarks."
  (let ((called-url nil))
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf)))
              ((symbol-function 'nixos-package-url)
               (lambda (url) (setq called-url url))))
      (nixos--bookmark-jump '((type . package)
                              (name . "somepkg")
                              (browse-url . t)
                              (browse-url-str . "https://example.com/from-bookmark.tar.gz")))
      (should (equal called-url "https://example.com/from-bookmark.tar.gz")))))

(ert-deftest nixos-package-url-fallback-name ()
  "`nixos-package-url' uses the URL basename when pname is absent."
  (let ((displayed nil)
        (meta-ht (make-hash-table :test 'equal)))
    (puthash "description" "No pname" meta-ht)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (setq displayed buf) (set-buffer buf)))
              ((symbol-function 'nixos--call-nix-url-expr)
               (lambda (_url)
                 (let ((vec (vector meta-ht "/nix/store/nm" "1.2" '[] '[] :json-false nil)))
                   (nixos--parse-package-result vec)))))
      (nixos-package-url "https://example.com/my-package.tar.gz")
      (should displayed)
      (with-current-buffer displayed
        ;; Fallback to URL basename (without extension)
        (should (string-match-p "my-package" (buffer-string)))
        (should (equal nixos--browse-name "my-package")))
      (kill-buffer displayed))))


;;; Org link tests

(ert-deftest nixos-org-package-open-package ()
  "`nixos-org-package-open' dispatches plain name to `nixos-package'."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-package)
               (lambda (name) (setq called (cons 'package name)))))
      (nixos-org-package-open "htop")
      (should (equal called '(package . "htop"))))))

(ert-deftest nixos-org-package-open-url ()
  "`nixos-org-package-open' dispatches URL to `nixos-package-url'."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-package-url)
               (lambda (url) (setq called (cons 'url url)))))
      (nixos-org-package-open "https://example.com/pkg.tar.gz")
      (should (equal called '(url . "https://example.com/pkg.tar.gz"))))))

(ert-deftest nixos-org-package-open-local ()
  "`nixos-org-package-open' dispatches local path to `nixos-package-local'."
  (let ((called nil))
    (cl-letf (((symbol-function 'nixos-package-local)
               (lambda () (setq called 'local))))
      (nixos-org-package-open "~/my-project/")
      (should (eq called 'local)))))

(ert-deftest nixos-org-package-export-html ()
  "`nixos-org-package-export' produces an HTML link."
  (let ((result (nixos-org-package-export "htop" "htop" 'html nil)))
    (should (string-match-p "search.nixos.org/packages" result))
    (should (string-match-p "htop" result))))

(ert-deftest nixos-org-package-export-plain ()
  "`nixos-org-package-export' falls back to plain text for unknown backend."
  (let ((result (nixos-org-package-export "htop" nil 'ascii nil)))
    (should (equal result "htop"))))


;;; Org package-search link tests

(ert-deftest nixos-org-package-search-open-filters ()
  "`nixos-org-package-search-open' filters packages by substring."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.0" :description "viewer")
       '("legacyPackages.x86_64-linux.neovim"
         :pname "neovim" :version "0.10" :description "editor")
       '("legacyPackages.x86_64-linux.python3Packages.neovim"
         :pname "python-neovim" :version "0.5" :description "client"))
    (let ((called nil) (called-prefix nil))
      (cl-letf (((symbol-function 'nixos-browse-packages)
                 (lambda (names &optional prefix)
                   (setq called names called-prefix prefix))))
        (nixos-org-package-search-open "neovim")
        (should (= (length called) 2))
        (should (member "neovim" called))
        (should (member "python3Packages.neovim" called))
        (should-not (member "htop" called))
        (should (equal called-prefix "neovim"))))))

(ert-deftest nixos-org-package-search-open-no-match ()
  "`nixos-org-package-search-open' returns empty list when nothing matches."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.0" :description "viewer"))
    (let ((called :sentinel) (called-prefix :sentinel))
      (cl-letf (((symbol-function 'nixos-browse-packages)
                 (lambda (names &optional prefix)
                   (setq called names called-prefix prefix))))
        (nixos-org-package-search-open "zzznotfound")
        (should (and (listp called) (null called)))
        (should (equal called-prefix "zzznotfound"))))))

(ert-deftest nixos-org-package-search-export-html ()
  "`nixos-org-package-search-export' produces an HTML link."
  (let ((result (nixos-org-package-search-export "htop" "htop search" 'html nil)))
    (should (string-match-p "search.nixos.org/packages" result))
    (should (string-match-p "htop" result))))

(ert-deftest nixos-org-package-search-export-plain ()
  "`nixos-org-package-search-export' falls back to plain text."
  (let ((result (nixos-org-package-search-export "htop" nil 'ascii nil)))
    (should (equal result "htop"))))


;;; Org option-search link tests

(ert-deftest nixos-org-option-search-open-filters ()
  "`nixos-org-option-search-open' filters options by substring."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.htop.enable" :type "boolean" :description "Htop")
       '("programs.htop.enable" :type "boolean" :description "Htop")
       '("services.foo.enable" :type "boolean" :description "Foo"))
    (let ((called nil) (called-prefix nil))
      (cl-letf (((symbol-function 'nixos-browse-options)
                 (lambda (names &optional prefix)
                   (setq called names called-prefix prefix))))
        (nixos-org-option-search-open "htop")
        (should (= (length called) 2))
        (should (member "services.htop.enable" called))
        (should (member "programs.htop.enable" called))
        (should-not (member "services.foo.enable" called))
        (should (equal called-prefix "htop"))))))

(ert-deftest nixos-org-option-search-open-no-match ()
  "`nixos-org-option-search-open' returns empty list when nothing matches."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.htop.enable" :type "boolean" :description "Htop"))
    (let ((called :sentinel) (called-prefix :sentinel))
      (cl-letf (((symbol-function 'nixos-browse-options)
                 (lambda (names &optional prefix)
                   (setq called names called-prefix prefix))))
        (nixos-org-option-search-open "zzznotfound")
        (should (and (listp called) (null called)))
        (should (equal called-prefix "zzznotfound"))))))

(ert-deftest nixos-org-option-search-export-html ()
  "`nixos-org-option-search-export' produces an HTML link."
  (let ((result (nixos-org-option-search-export "htop" "htop search" 'html nil)))
    (should (string-match-p "search.nixos.org/options" result))
    (should (string-match-p "htop" result))))

(ert-deftest nixos-org-option-search-export-plain ()
  "`nixos-org-option-search-export' falls back to plain text."
  (let ((result (nixos-org-option-search-export "htop" nil 'ascii nil)))
    (should (equal result "htop"))))



;;; Table bookmark tests

(ert-deftest nixos-browse-table-bookmark-make-record-options ()
  "Table bookmark record for options with search term."
  (with-temp-buffer
    (nixos-browse-options-mode)
    (setq-local nixos--browse-name-prefix "htop")
    (let ((rec (nixos--browse-table-bookmark-make-record)))
      (should (stringp (car rec)))
      (should (string-match-p "htop" (car rec)))
      (should (eq (alist-get 'type rec) 'option))
      (should-not (alist-get 'name-list rec))
      (should (equal (alist-get 'name-prefix rec) "htop"))
      (should (eq (alist-get 'handler rec) 'nixos--bookmark-jump)))))

(ert-deftest nixos-browse-table-bookmark-make-record-packages ()
  "Table bookmark record for packages without search term."
  (with-temp-buffer
    (nixos-browse-packages-mode)
    (setq-local nixos--browse-name-prefix nil)
    (let ((rec (nixos--browse-table-bookmark-make-record)))
      (should (string-match-p "all" (car rec)))
      (should (eq (alist-get 'type rec) 'package))
      (should-not (alist-get 'name-list rec))
      (should-not (alist-get 'name-prefix rec))
      (should (eq (alist-get 'handler rec) 'nixos--bookmark-jump)))))

(ert-deftest nixos-bookmark-jump-table-option ()
  "`nixos--bookmark-jump' calls `nixos-browse-options' for table bookmarks."
  (nixos-test--with-options
      (nixos-test--options-hash
       '("services.foo.enable" :type "boolean" :description "foo"))
    (let ((called-names nil) (called-prefix :sentinel))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-browse-options)
                 (lambda (names &optional prefix)
                   (setq called-names names called-prefix prefix))))
        (nixos--bookmark-jump '((type . option)
                                (name-prefix . "foo")))
        (should (equal called-names '("services.foo.enable")))
        (should (equal called-prefix "foo"))))))

(ert-deftest nixos-bookmark-jump-table-package ()
  "`nixos--bookmark-jump' calls `nixos-browse-packages' for table bookmarks."
  (nixos-test--with-packages
      (nixos-test--packages-hash
       '("legacyPackages.x86_64-linux.htop"
         :pname "htop" :version "3.0" :description "viewer"))
    (let ((called-names nil) (called-prefix :sentinel))
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (buf) (set-buffer buf)))
                ((symbol-function 'nixos-browse-packages)
                 (lambda (names &optional prefix)
                   (setq called-names names called-prefix prefix))))
        (nixos--bookmark-jump '((type . package)
                                (name-prefix . nil)))
        (should-not called-names)
        (should-not called-prefix)))))


(provide 'nixos-tests)
;;; nixos-tests.el ends here
