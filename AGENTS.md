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
- Mock `switch-to-buffer` with `cl-letf` to test display without UI.
- Mock `nixos--package-meta` or `browse-url` when side-effects are
  undesirable.
- Tests that need `nix-mode` use `(skip-unless (fboundp 'nix-mode))`.

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
