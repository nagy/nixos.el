# AGENTS.md — nixos.el

## Overview

Single-package Emacs project (`nixos.el`) providing interactive
`completing-read` and `tabulated-list-mode` interfaces for browsing
NixOS options and Nix packages.  Built via `default.nix` (melpaBuild,
AGPL3+).

## Build & test

```sh
nix-build --no-out-link default.nix          # build + run tests
emacs --batch -L . -l nixos-tests.el -f ert-run-tests-batch-and-exit
```

`turnCompilationWarningToError = true` — any byte-compiler warning
fails the build.

## Architecture

Single file (`nixos.el`), sections roughly:

1. defgroup / defcustom
2. Cache (hash-table vars, load functions, `nixos-refresh-cache`)
3. Helpers (`nixos--slurp-description`, `nixos--package-expr-tail`,
   `nixos--call-nix-package-expr`)
4. Options / Packages collection + annotation
5. Browse modes (`nixos-browse-mode`, `nixos--define-browse-mode`
   macro for browse-options/packages)
6. `nixos-package` / `nixos-package-local` interactive commands
7. Bookmarks, thingatpt, eldoc
8. Marginalia annotators, Embark export + actions

## Conventions

### Byte-compiler silencing

External vars/faces from optional deps (marginalia, embark) are
declared with `(defvar <var> <val>)` **with an explicit value**
(usually `nil`).  `(defvar foo)` without a value does NOT bind the
variable, so `symbol-value` still errors.

```elisp
(defvar marginalia-annotator-registry nil)  ;; correct
(defvar embark-general-map nil)             ;; correct
(defvar foo)                                ;; wrong — still void
```

### Build-time data baking

`defcustom` defaults (`nixos-options-json-file`, `nixos-search-json-file`)
point to `/etc/` paths.  `default.nix` substitutes them with Nix
store paths via `substituteInPlace` in `postPatch`.

`nixosOptionsJson` defaults to evaluating an empty NixOS
configuration to extract the options JSON from the manual build.
This derivation hits the NixOS binary cache, so no local build
is needed on a hit.  Pass `nixosOptionsJson = "/etc/nixos-options.json"`
to skip the eval.

### Memoization

`nixos--package-meta` uses `with-memoization` on `(gethash key hash)`.
Nix store paths are immutable, so results never go stale.  Nil results
are intentionally NOT cached — transient failures retry.

```elisp
(with-memoization (gethash key cache)
  expensive-computation...)
```

### Avoid `let-alist` on hash tables

`let-alist` expands to `(cdr (assq …))` — it works only on alists.
`json-parse-buffer` returns hash tables (the default).  Use
`gethash` directly when the source is a hash table.

```elisp
;; Wrong — json-parse-buffer returns a hash table, not an alist
(let-alist (json-parse-buffer) …)

;; Correct
(let ((result (json-parse-buffer)))
  (gethash "key" result) …)
```

### Nix expression gotcha: attrset with meta + outPath

When calling `nix-instantiate --strict --json --eval`, never
construct an attrset mixing `pkg.meta` (attrset) with `pkg.outPath`
(string with derivation context):

```nix
# Wrong — Nix collapses the attrset to just the derivation's store path
{ meta = pkg.meta; outPath = pkg.outPath; }

# Correct — output a JSON array instead
[ pkg.meta pkg.outPath ]
```

This is because `pkg.outPath` carries string context from the
derivation, and when combined with `pkg.meta` in one attrset, Nix
recognizes the pattern and returns the derivation itself, which
`--strict` forces to its output path.

**Bonus gotcha: `outPath` is a magic key name.**  Nix uses
`outPath` for `toString` / string interpolation on derivations.
If _any_ attrset has a key literally named `outPath`, Nix
collapses the entire attrset to that value when `--strict`
evaluates it — even for sub-attrsets deep in a list
(e.g. `{name="foo"; outPath=pkg.outPath;}` per dependency).
Rename the key to something else (`storePath`, `path`, etc.) to
preserve the full attrset.

**Dotted attribute paths with digit segments.**  Package names
like `chickenPackages_5.chickenEggs.7off` contain segments
starting with a digit, which is invalid Nix attribute-path
syntax.  Use `builtins.foldl'` with `builtins.getAttr` instead
of `${cand}` interpolation:

```nix
{cand}: let
  pkgs = import <nixpkgs> {};
  segments = builtins.filter builtins.isString
    (builtins.split "\\." cand);
  pkg = builtins.foldl' (s: seg:
    builtins.getAttr seg s) pkgs segments;
in …
```

### Tabulated-list conventions

- Entry format: `(id [id col1 col2...])`
- `--current-name` wraps `tabulated-list-get-id` with a user-error
- `--entries` accepts optional `name-list` to support Embark export
- Mode map inherits from `tabulated-list-mode-map`
- `hl-line-mode 1` enabled by default

### Test conventions

- `nixos-test--options-hash` / `nixos-test--packages-hash` build
  mock hash tables from plists.  Keyword keys (`:description`) are
  converted to strings by stripping the leading colon.
- `nixos-test--with-options` / `nixos-test--with-packages` macros
  bind the cache vars directly (no JSON file needed).
- Mock `switch-to-buffer` / `pop-to-buffer` with `cl-letf` to test
  display without UI.
- Mock `nixos--package-meta`, `nixos--call-nix-package-expr`, or
  `browse-url` when side-effects are undesirable.
- When testing `nixos--package-meta` memoization, mock
  `nixos--call-nix-package-expr` to return a cons `(ALIST . "")`.
  Mocking `call-process` directly is fragile: `apply` in
  `lexical-binding: t` files on Emacs 31 doesn't reliably pick up
  `cl-letf` on `(symbol-function 'call-process)`.
- Tests that need `nix-mode` use `(skip-unless (fboundp 'nix-mode))`.
- When testing `nixos--package-meta` memoization without loading
  `nix-mode`, use `(setq nix-instantiate-executable "nix-instantiate")`
  — `defvar` alone leaves it void, and `let` creates a lexical binding
  in `lexical-binding: t` files, invisible to `boundp`.

### `let*` for sequential bindings

In `lexical-binding: t`, plain `let` evaluates all init forms in the
outer scope — later bindings cannot reference earlier ones.
Use `let*` when one binding's init form depends on a prior binding.

```elisp
;; Wrong — args can't see stderr-file
(let ((stderr-file (make-temp-file "stderr-"))
      (args (list stderr-file)))
  …)

;; Correct
(let* ((stderr-file (make-temp-file "stderr-"))
       (args (list stderr-file)))
  …)
```

### Stderr capture via temp file

`call-process` with a buffer as stderr destination (`(list t buffer)`)
causes `stringp, #<killed buffer>` errors in Emacs 31 when the
command exits non-zero.  Use a temp file for stderr instead:

```elisp
(let* ((stderr-file (make-temp-file "nixos-stderr-"))
       (args (list program nil (list t stderr-file) nil …)))
  (unwind-protect
      (with-temp-buffer
        (let ((exit-code (apply 'call-process args)))
          (if (zerop exit-code)
              …parse stdout…
            (cons nil (with-temp-buffer
                        (insert-file-contents stderr-file)
                        (buffer-string)))))
    (delete-file stderr-file)))
```

### Package display layout

`nixos--display-package` uses local `cl-labels` closures (`field`,
`link`) to right-pad all field labels to 14 characters.

Store paths are face-colored by on-disk status:
`dired-directory` (exists, is a dir), default (exists, is a file),
`error` (missing / GC'd).  Homepage URLs use the `link` face.

Build and native build inputs are shown below maintainers with
clickable package names and store paths aligned to a global
column.  Package names are `insert-text-button` widgets navigating
to `nixos-package`.

### Functional purity

Keep side-effecting code in interactive commands.  Internal functions
should be pure where possible — makes them testable without mocking.

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `defvar-keymap`, `with-memoization` |
| nix-mode | soft | `nix-instantiate-executable` for package metadata |
| marginalia | soft | annotator registry |
| embark | soft | export + actions |

### Faces

Three custom faces (`nixos-package-name`, `nixos-field-label`,
`nixos-description`) inherit from `package.el` faces when
available, with built-in fallbacks (`bold`, `default`).  No
`(require 'package)` needed — the `:inherit` list resolves
left-to-right, skipping undefined faces.

## TODO

- **Batch package metadata** — `nixos--package-meta` evaluates
  `nix-instantiate` per-package, importing `<nixpkgs>` each time.
  Even with memoization, the first lookup for each package is slow.
  Options: (a) evaluate multiple packages in a single Nix call,
  (b) precompute a metadata JSON at build time (like options/search
  already do).

- **Display build phase hooks** — Show non-default pre/post hooks
  (prePatch, postPatch, preBuild, postBuild, preConfigure,
  postConfigure, preInstall, postInstall, preCheck, postCheck,
  preFixup, postFixup) in the package detail buffer, fontified with
  `bash-ts-mode` (tree-sitter).  Empty hooks = standard package,
  non-empty hooks = customization signal.

  **Design decisions:**
  - Only hook phases, not full phases (`configurePhase` etc.) — full
    phases always have content and are noisy.
  - Stdenv defaults for hooks are empty strings, so no comparison
    logic needed; just show non-empty values.
  - Extract alongside existing metadata in the same
    `nix-instantiate` JSON array (no extra Nix evaluations).
  - Fontification: `bash-ts-mode` with `sh-mode` fallback.  Insert
    into a temp buffer, font-lock, copy with text properties.
  - Long-term: rebase display onto `magit-section` for collapsible
    sections (larger refactor, not scoped to this task).

  **Nix side (~10 lines):**
  ```nix
  # Extend the JSON array with hooks:
  [ pkg.meta pkg.outPath pkg.version
    (depInfo (pkg.buildInputs or []))
    (depInfo (pkg.nativeBuildInputs or []))
    (pkg.prePatch or "")
    (pkg.postPatch or "")
    (pkg.preBuild or "")
    (pkg.postBuild or "")
    ... ]
  ```
  `or ""` handles non-stdenv packages gracefully.

  **Elisp side (~40-70 lines):**
  - Parse new array elements in `nixos--package-meta`.
  - In `nixos--display-package`, iterate non-empty hooks and insert
    fontified blocks using `bash-ts-mode` / `sh-mode`.
  - Update test mocks for the extended array.

- **Rust crate integration** — Detect `buildRustPackage` derivations
  and offer a keybinding to jump to a `Cargo.lock`-based buffer
  (provided by an external crates major mode).

  **Detection:** check `(pkg ? cargoDeps)` or `pkg.cargoDeps or null`
  in the `nix-instantiate` JSON array.  If non-null, the derivation
  uses the Rust builder.

  **Jump target:**
  - Local projects (`nixos-package-local`): trivial — the project
    directory is already known via `nixos--browse-local-dir`,
    so `(expand-file-name "Cargo.lock" nixos--browse-local-dir)`
    gives the lock-file location.
  - Nixpkgs packages: harder — need the source store path.  The
    lock-file path (`./Cargo.lock` in the source tree) resolves to
    a store path at eval time, but the source may not be on disk
    unless already fetched.  Could extract `pkg.src` from the
    derivation attributes.
