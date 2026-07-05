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
3. Helpers (`nixos--slurp-description`)
4. Options / Packages collection + annotation
5. Browse modes (`nixos-browse-mode`, `nixos--define-browse-mode` macro for browse-options/packages)
6. Bookmarks, thingatpt, eldoc
7. Marginalia annotators, Embark export + actions

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
- Mock `nixos--package-meta` or `browse-url` when side-effects are
  undesirable.
- Mock `call-process` to simulate `nix-instantiate` output when
  testing `nixos--package-meta` directly.  Use the JSON array
  format `[{…},"store-path"]` (see Nix expression gotcha above).
- Tests that need `nix-mode` use `(skip-unless (fboundp 'nix-mode))`.
- When testing `nixos--package-meta` memoization without loading
  `nix-mode`, use `(setq nix-instantiate-executable "nix-instantiate")`
  — `defvar` alone leaves it void, and `let` creates a lexical binding
  in `lexical-binding: t` files, invisible to `boundp`.

### Package display layout

`nixos--display-package` uses local `cl-labels` closures (`field`,
`link`) to right-pad all field labels to 14 characters.  This keeps
the shared helpers (`nixos--insert-field`, `nixos--insert-link`)
untouched for option display.  The local `link` closure superseded
`nixos--insert-link` — that function is now dead code and can be
removed.

The store path is face-colored by its on-disk status:
`dired-directory` (exists, is a dir), default (exists, is a file),
`error` (missing / GC'd).  The homepage URL uses the `link` face.

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
| evil / evil-collections | soft | see evil-collections — not bundled here |

## TODO
- **Batch package metadata** — `nixos--package-meta` evaluates
  `nix-instantiate` per-package, importing `<nixpkgs>` each time.
  Even with memoization, the first lookup for each package is slow.
  Options: (a) evaluate multiple packages in a single Nix call,
  (b) precompute a metadata JSON at build time (like options/search
  already do).
