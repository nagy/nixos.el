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
  (setq nixos--options-cache (make-hash-table :test 'equal)
        nixos--packages-cache (make-hash-table :test 'equal)
        nixos--packages-keys '("a"))
  (nixos-refresh-cache)
  (should-not nixos--options-cache)
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

(provide 'nixos-tests)
;;; nixos-tests.el ends here
