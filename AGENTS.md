# AGENTS.md — nixos.el

## Overview

Emacs package providing interactive `completing-read` and
`tabulated-list-mode` interfaces for browsing NixOS options, Nix
packages and Nix flake outputs.  Two source files: `nixos.el` (core)
and `ol-nixos.el` (Org link types).  Built via `default.nix`
(melpaBuild, AGPL3+).  Tests in `nixos-tests.el`.

## Build & test

```sh
nix build                                # build + run tests
nix flake check                          # also builds the package
emacs --batch -L . -l nixos-tests.el -f ert-run-tests-batch-and-exit
```

To skip the NixOS options JSON eval, pass an existing JSON file to the
builder (see flake.nix; the old `nixosOptionsJson ? "/etc/..."`
default.nix argument is gone — the flake always evaluates an empty
config, which hits the binary cache).

## Architecture

### nixos.el (core, ~1350 lines)

1. Faces (`nixos-package-name`, `nixos-field-label`, `nixos-description`,
   `nixos-version`, `nixos-date`, `nixos-revision`)
2. defgroup / defcustom (6 options incl. URL templates for search.nixos.org)
3. Cache (hash-table vars, load functions, `nixos--ensure-nixpkgs-root`,
   `nixos-refresh-cache`, plus `nixos--flake-cache`/`nixos--flake-ref`)
4. Helpers (`nixos--slurp-description`, `nixos--search-names`,
   `nixos--package-expr-tail`, `nixos--parse-package-result`,
   `nixos--call-nix-package-expr`, `nixos--call-nix-url-expr`,
   `nixos--flake-flatten`, `nixos--call-flake-show`,
   `nixos--call-flake-metadata`)
5. Options / Packages / Flakes collection + annotation
6. Browse Major Mode (`nixos-browse-mode`)
7. Display helpers (`nixos--display-option`, `nixos--display-package`,
   `nixos--display-flake`, `nixos--display-flake-overview`)
8. Bookmarks (detail + table)
9. Interactive commands (`nixos-package` / `nixos-package-local` /
   `nixos-package-url`, `nixos-option`, `nixos-flake`)
10. Thing-At-Point, Tabulated Browse Mode (shared macro), Eldoc
11. Completion metadata, Package Browse Mode, Embark export + actions

### ol-nixos.el (Org link types, ~130 lines)

Provides four Org link types:
- `nixos-package:` / `nixos-package-local:` (path) / URL variant
- `nixos-option:`
- `nixos-package-search:` / `nixos-option-search:` (filtered browse)

Opt-in module, like Org's own `ol-*` modules: it does a plain
`(require 'ol)` + `(require 'nixos)` and users enable it with
`(with-eval-after-load 'org (require 'ol-nixos))` in their config.
nixos.el does not know it exists.

## Conventions

### Byte-compiler silencing

External vars from optional deps (embark) are declared
with **value-less** `(defvar <var>)`.  A top-level value-less defvar
marks the symbol special for the whole file, which silences
"reference to free variable" warnings.  All actual accesses happen
inside `with-eval-after-load`, when the real package has bound the
variable, so nothing is ever void at runtime.

Never give these defvars a value:

```elisp
(defvar embark-general-map)               ;; correct
(defvar embark-general-map nil)           ;; WRONG — see below
```

`defcustom` does not override an already-bound variable — that is
the mechanism that lets users `setq` a variable before loading its
package.  So a `(defvar <var> nil)` in nixos.el would, whenever
nixos.el loads *before* embark, silently replace its defcustom
defaults with nil.

Corollary for keymaps: `defvar-keymap :parent` is evaluated once, at
definition time, when `embark-general-map` may not exist yet.  The
embark keymaps are therefore defined without `:parent` and wired up
via `set-keymap-parent` inside `with-eval-after-load 'embark`.

### ol-nixos.el: opt-in, plain require

`ol-nixos.el` is loaded by the *user*, never by `nixos.el`, so it
uses ordinary top-level requires — no `declare-function` stubs:

```elisp
(require 'ol)
(require 'nixos)
```

Do not reintroduce an auto-load of `ol-nixos` from `nixos.el`
(e.g. `(with-eval-after-load 'org (require 'ol-nixos))` at the end
of `nixos.el`).  If Org is already loaded, that hook fires while
`nixos.el` is still mid-load — before its `provide` — so the
`(require 'nixos)` in `ol-nixos.el` would trigger a recursive load
error, forcing the old declare-function-stub workaround.

### Build-time data baking

`defcustom` defaults (`nixos-options-json-file`, `nixos-search-json-file`)
point to `/etc/` paths.  `flake.nix` substitutes them with Nix
store paths via `substituteInPlace` in `postPatch`.

The search JSON comes from `nix search path:PKGS --json`.
`nix search` emits keys like `legacyPackages.x86_64-linux.htop`
**and** `packages.x86_64-linux.htop`, so
`nixos--package-output-re` covers both output kinds and
`nixos--packages-load` strips each key by its own match.  Deriving
one prefix string and removing it from every key leaked the other
kind into the ID, and then into the Nix export.  Do not narrow that
regexp to `legacyPackages`.

`nixosOptionsJson` defaults to evaluating an empty NixOS
configuration to extract the options JSON from the manual build.
This derivation hits the NixOS binary cache, so no local build
is needed on a hit.  Pass `nixosOptionsJson = "/etc/nixos-options.json"`
to skip the eval.

The package `version` comes from `self.lastModifiedDate`.  The flake
passes `self` into `outputs` and derives `0-unstable-YYYY-MM-DD` from
the source tree date.  No manual version bumps.  Falls back to the
epoch when the source is not a git checkout.

### Memoization

`nixos--package-meta` uses `with-memoization` on `(gethash key hash)`.
Nix store paths are immutable, so results never go stale.  Nil results
are intentionally NOT cached — transient failures retry.

Unavailable nix-instantiate is distinct: `nixos--call-nix-package-expr`
returns nil (rather than a `(nil . STDERR)` failure cons) when the
binary is missing.  `call-process` **signals** `file-missing` for a
missing program rather than returning an exit code, so the call site
wraps it in `condition-case`.

`nixos--ensure-nixpkgs-root` uses the same permanent-cache pattern:
the nixpkgs source root is discovered once from `builtins.nixPath`
via `nix-instantiate` and cached forever (store path never changes).
This lets option detail buffers and browse-table modes set
`default-directory` to the nixpkgs source tree, so `dired-jump`,
`find-file-at-point`, and Embark actions resolve relative
declaration paths correctly.
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

**URL package evaluation.**  `nixos-package-url` downloads and
evaluates a tarball URL via `builtins.fetchTarball` +
`pkgs.callPackage`.  Uses `--impure` since the tarball is fetched
without a pinned hash.  The expression passes the URL via
`--argstr` to avoid quoting issues:

```nix
{url}: let
  pkgs = import <nixpkgs> {};
  pkg = pkgs.callPackage (builtins.fetchTarball url) {};
  …
in [pkg.meta pkg.outPath …]
```

The same `nixos--package-expr-tail` constant is shared across all
three package evaluation paths (nixpkgs, local, URL).
`nixos--call-nix-url-expr` is a thin wrapper that delegates to
`nixos--call-nix-package-expr` with `--impure --argstr url URL`.
Result parsing is handled by `nixos--parse-package-result`, a shared
helper that parses the JSON vector into an alist.

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

### Package origin: `nixos--browse-source`

A single buffer-local encodes where a package came from:

- `nil` — nixpkgs package (or an option buffer)
- `(local . DIR)` — evaluated from DIR/default.nix
- `(url . URL)` — evaluated from a tarball at URL

It is passed as the third argument to `nixos--display-package`,
stored by `nixos--browse-setup`, dispatched with `pcase` in
`nixos-browse-refresh` and `nixos--bookmark-jump`, and serialized
into detail bookmarks as the `source` field.  A non-nil source also
means "do not point `default-directory` at the store path" — the
buffer is for a local project or remote tarball, not an installed
package.  Do not add parallel boolean flags for new origins; extend
the enum instead.

### Browse mode conventions

`nixos-browse-mode` derives from `special-mode`: read-only buffers,
`q`, and `g` → `revert-buffer` come for free.  Refresh goes through
`revert-buffer-function` (`nixos-browse-refresh`); no explicit
`read-only-mode` calls or custom `g` bindings.

### Detail buffer sections

`nixos-browse-mode` folds detail sections through `outline-minor-mode`.
A heading line carries the text property `nixos-section`, and
`outline-search-function` is `nixos--outline-search`, which wraps
`outline-search-text-property`.  No heading needs a special character.
Every section is top level, so `outline-level` answers one.

`nixos--insert-section` writes a heading with the `nixos-field-label`
face.  `nixos--mark-section` tags a line that the caller already
wrote.  Both store the name through `nixos--field-key`, which trims
padding and the trailing colon, so a fold survives a render that
changes the count of a heading such as `Outputs (12):`.

`nixos--field` and `nixos--link` tag their label with `nixos-field`.
`nixos--browse-imenu-index` lists the sections and the fields, and it
is the `imenu-create-index-function` of the mode.

`TAB` runs `nixos-browse-toggle-section` from any line of a section,
not only from its heading.  `nixos--browse-collapsed-sections` reads
the folded names before a render, and
`nixos--browse-restore-sections` folds them again afterwards.
`nixos-browse-refresh` and `nixos--flake-overview-refresh` do that.
Outline hiding edits a text property, so it runs under
`inhibit-read-only`.

### Tabulated-list conventions

- Entry format: `(id [id col1 col2...])`
- `--current-name` wraps `tabulated-list-get-id` with a user-error
- `--entries` accepts optional `name-list` to support Embark export
- A column sorts by the cell string when its SORT element is `t`.
  A SORT element may also be a predicate over entries, and the
  package Version column uses `nixos--package-version-lessp` so
  `1.9` sorts above `1.10` and an entry without a version sorts
  last.  The built-in arrow and header click keep working, and the
  predicate reads the entry, not the buffer.
- The options table groups rows by top-level attribute through
  `tabulated-list-groups`.  `nixos--group-entries` buckets the
  entries of `--entries`, and the group value is a closure, so
  every print re-reads the buffer-local `nixos--browse-name-list`
  filter.  A group header is a line with a nil ID, so
  `--current-name` keeps signalling on it.  `nixos-option-groups`
  nil turns grouping off at the next `g`.
- The browse-table commands accept an optional `name-prefix` that
  personalizes the buffer name (e.g. `*NixOS Options: htop*`),
  allowing multiple searches to coexist.  When non-nil, the filtered
  `name-list` and `name-prefix` are stored in buffer-local variables
  `nixos--browse-name-list` and `nixos--browse-name-prefix` so
  `refresh` (`g`) preserves the filter.
- Mode map inherits from `tabulated-list-mode-map`
- `hl-line-mode 1` enabled by default
- `tabulated-list-entries` holds a list, not a function.
  `tabulated-list-sort` walks that variable to record the original
  order for its restore path (`C-u -1 S`), and a function value breaks
  it silently.  The mode stores
  `nixos--browse-table-entries-function` instead, and
  `nixos--browse-table-reload` builds the list.  The mode adds that
  function to `tabulated-list-revert-hook` buffer-locally, so `g`
  keeps the filter.  The browse command calls it before the first
  print.  Do not turn the variable into a closure.
- No generated refresh function exists.  `revert-buffer-function`
  stays at the `tabulated-list-mode` default, so `g` calls
  `tabulated-list-revert`, which prints and re-reads the entries
  function.  Do not add a per-mode refresh defun back.
- The modes set `bookmark-make-record-function` to
  `nixos--browse-table-bookmark-make-record` for saving filtered
  table views.
- `tabulated-list-printer` is `nixos--browse-table-print-entry`.
  It paints `help-echo` on the whole row and `mouse-face` on the
  name cell alone.  A group header line bypasses the printer, so
  it stays plain.
- `<follow-link>` is `nixos--browse-table-click-selects-row`, which
  returns nil.  With the `tabulated-list-mode-map` default
  (`mouse-face`), the highlighted name would turn one click into a
  `mouse-2` event and open a detail buffer.
- `<mouse-2>` and `o` open the row in another window.  They bind
  `nixos-display-buffer-action` to `display-buffer-other-window`
  for that one call, and every display function passes the option
  to `pop-to-buffer`.  The mouse command reads the entry type from
  the clicked window's buffer, so a click in one table never uses
  the other table's visit function.  `w` copies the entry name.
- `context-menu-functions` carries `nixos-browse-table-context-menu`
  buffer-locally, guarded by `boundp`.  A menu click leaves point
  alone, so each menu command wraps `nixos--browse-table-context-command`,
  which restores the buffer and moves point before it runs.
- `nixos-browse-export-markdown` and `nixos-browse-export-nix` read
  the printed buffer, not the cache, so the export follows the
  current sort, filter and groups.  `nixos--browse-table-rows` walks
  the lines and skips a group header, which holds no entry.  The
  Markdown export escapes a pipe and strips text properties; the Nix
  export quotes a segment that is no identifier.  Both live under the
  `e` prefix keymap `nixos-browse-table-export-map`, and each writes
  a `special-mode` buffer through `nixos--export-buffer`.
- Both table maps remap the `nix-mode` and `markdown-ts-mode`
  commands to the export commands.  A user key that runs one of
  those major modes elsewhere runs `nixos-browse-export-nix` or
  `nixos-browse-export-markdown` while point sits in a table.  The
  remap target names a symbol, so both modes stay optional.
- A table refits its columns to the window.
  `nixos--browse-table-fit-widths` shrinks a middle column to 8 and
  then the name column to `nixos-browse-table-name-min-width`, so the
  last column keeps `nixos-browse-table-description-min-width`.  The
  mode stores the declared widths in
  `nixos--browse-table-canonical-widths`, and every fit starts there,
  so a resize in either direction lands right.  The browse command
  fits before its first print.  A frame resize schedules one refit
  per buffer through `run-at-time`, because
  `window-size-change-functions` runs inside redisplay, and the refit
  reprints only when a width changed.  `tabulated-list-format` is
  buffer-local, so one width serves every window, and a manual
  `{`/`}` resize lasts until the next frame resize.
- `{` and `}` go through `nixos--browse-table-resize-column`, which
  refuses a group header line: `tabulated-list-widen-current-column`
  reads the entry there and signals on the nil one.
- The package table widens its Version column to the longest visible
  version through the mode's `:width-fn`
  (`nixos--package-canonical-widths`), capped by
  `nixos-browse-table-version-max-width`.  The declared widths live
  in `nixos--browse-table-declared-widths`, so a width function never
  reads a fitted or a bookmarked value, and a narrow window still
  squeezes the column afterwards.  `nixos--browse-table-cell-text`
  is the one reader for a cell that may be a string or a `(LABEL .
  PROPS)` cons.

### Bookmarks

Two kinds of bookmarks are supported:

**Detail bookmarks** — set from `nixos-browse-mode` buffers
(single option/package).  Record fields: `type`, `name`, `source`
(the `nixos--browse-source` value, serialized as-is).

**Table bookmarks** — set from `nixos-browse-options-mode` /
`nixos-browse-packages-mode` buffers (filtered lists).  Record
fields: `type`, `name-prefix`, `sort-key` (a `(NAME . FLIP)` cons)
and `widths` (one integer per column).  On reopen, the filtered
`name-list` is re-derived from the live cache via
`nixos--search-names`, so new matching options/packages appear
automatically.  A nil `name-prefix` means "show all".
`nixos--browse-table-restore-state` applies the sort key and the
widths after the browse command returns; it ignores a sort key that
names no column and a width list of the wrong length, and it makes
the restored widths the base of a later fit.  The jump reprints once
when a value lands.

`nixos--search-names` is the single substring filter shared by
table bookmarks and the `nixos-*-search:` Org link types.

`nixos--bookmark-jump` dispatches by checking for `name-prefix`
via `assq` (table), then falling through to the detail handler,
which dispatches on the `source` field with `pcase`.

### Flake browsing (`nixos-flake`)

`nixos-flake` runs `nix flake show --json` and presents a
**whole-flake detail buffer** (not a table — there is no
`nixos-browse-flakes` table mode).  It flattens the JSON into a
path-keyed hash table and shows the reference plus a clickable list
of every leaf node; `RET`/click opens a node's own detail buffer.

- **Flake ref resolution.**  Called interactively without a prefix,
  the ref defaults to `nixos--project-flake-ref` — the project root
  when it is a flake (contains `flake.nix`) — else it falls through
  to a prompt.  With `C-u` it always prompts (`nixos--read-flake-ref`,
  defaulting to `default-directory`).  A string FLAKE-REF passed
  programmatically (or from a bookmark) is used directly.
- **`nixos--project-flake-ref`** returns the project root only when
  `project-current`/`project-root` yield a directory that contains
  `flake.nix`; otherwise nil (so the caller prompts).  Guards on
  `fboundp` so `project.el` is a soft dependency.
- **`nixos--flake-flatten`** recursively walks the parsed JSON,
  building a full dotted path per leaf.  A node is a leaf iff it
  carries a `"type"` key (matching what `flake show --json` emits);
  grouping attrsets — the system level and empty `legacyPackages`
  subtrees — are descended into, not shown.  Notably the system
  level is **optional**: `packages`/`apps`/`checks`/`devShells`/
  `formatter`/`legacyPackages` nest under a system attribute, while
  `nixosConfigurations` and `templates` do not.  `flake-flatten`
  handles both because it recurses on any non-leaf attrset.
- **`nixos--call-flake-show`** shells out to `nix` (the
  `nix-executable` variable, provided by nix-mode's `nix.el`) with
  `--extra-experimental-features nix-command flakes` before
  `flake show --json`.  This is separate from
  `nix-instantiate-executable`, which drives only package metadata.
  Uses the same temp-file stderr capture + `condition-case`
  `file-missing` pattern as `nixos--call-nix-package-expr`.
- **`nixos--call-flake-metadata`** shells out to `nix flake metadata
  --json` (same `nix-executable` / feature flags / stderr-capture
  pattern).  It runs **without evaluation**, so it never hits the
  user's `nixpkgs` overlays and needs no `--impure`.  `nixos-flake`
  calls it alongside `flake show`; the overview buffer renders
  flake-level fields via `nixos--flake-metadata-fields`:
  Description, Path, URL, Revision, Last modified, Inputs (from
  `locks.nodes`).  Sparse/empty values — and a nil META when the
  command fails — are omitted gracefully.  `Inputs` is returned as a
  list of tree display lines rendered as its own block under an
  `Inputs:` header, matching the official `nix flake metadata` input
  tree: `├───`/`└───` branch chars, sub-inputs indented, `NAME follows
  input 'X'` lines for follow relationships, and each input shown as a
  source label.  Sources are formatted from each node's locked/original
  attrsets (`github:OWNER/REPO/REV` for github inputs, abbreviated
  local paths for file inputs) with a `(YYYY-MM-DD HH:MM:SS)` date when
  a lastModified timestamp exists; narHashes are omitted.  The source
  formatting lives in `nixos--flake-input-source` and the tree walk in
  `nixos--flake-input-tree`.
- **`~` expansion in flake refs** — Nix does not expand `~` in flake
  references, so "~/my-flake" is treated as a literal relative path
  and fails ("No such file or directory" pointing at
  `.../~/my-flake`).  A flake ref is therefore passed through
  `expand-file-name` only when it begins with `~`.  Do **not** apply
  `expand-file-name` unconditionally: it mangles registry/URL refs
  (`github:nixos/nixpkgs` becomes a bogus relative path), so
  `-file-name` is guarded by a `string-prefix-p "~"` check.
- **Overview buffer** (`nixos--display-flake-overview`) derives
  `nixos-browse-mode` with `nixos-flake-overview-mode-map` (a
  keymap parented on `nixos-browse-mode-map` whose `RET` is
  `nixos-flake-visit-output`).  It is **not** bookmarkable
  (`bookmark-make-record-function` nil) and its `revert-buffer-function`
  re-runs `nixos-flake` on the ref.  Each node line is an
  `insert-text-button` carrying the node path as `button-data`.

  The flake-level fields and the node list are right-aligned to the
  longest label/path plus one column, so every value starts on the
  same column (same pattern as the build-input alignment in
  `nixos--display-package`).  Paths are abbreviated for display via
  `nixos--abbreviate-path`: local absolute paths (`/...`, `~/...`)
  are sent through `abbreviate-file-name`, while store paths
  (`/nix/store/...`), URLs and registry refs (`github:...`) are left
  unchanged.
- **Node detail buffer** (`nixos--display-flake`) shows only what
  `flake show --json` emits: Type, Path, Name, Description, Flake ref.
  There is no store path, so `r` (requisites) and `w` (copy-store-path)
  error naturally (the `nixos--browse-out-path` stays nil).  It sets
  `nixos--browse-name` to the node path and is bookmarkable; the
  detail bookmark stores `source` as the flake ref.
- **No web view.**  `search.nixos.org` does not index flake nodes, so
  `nixos-browse-search-url` errors on `nixos--browse-type` of `flake`.
- The `nixos--browse-source` enum is **not** extended for flakes.
  Flakes use the separate buffer-local `nixos--browse-flake-ref`
  instead; refresh and detail/bookmark dispatch on `flake` via the
  cached `nixos--flake-cache` (or a fresh `flake show` if evicted).  Only
  **node** bookmarks exist for flakes — there are no flake **table**
  bookmarks, so `nixos--bookmark-jump`'s `cl-case` has no `flake`
  table branch (removed with `nixos-browse-flakes`).

### Test conventions

- The test file is byte-compiled in `checkPhase` with
  `byte-compile-error-on-warn = t`, so all warnings are fatal.
- Forward-declare optional functions with
  `(declare-function nix-mode "nix-mode")` and optional vars
  with `(defvar nix-instantiate-executable)` (no value needed —
  the compiler just needs to know they exist).
- `nixos-test--options-hash` / `nixos-test--packages-hash` build
  mock hash tables from plists.  Keyword keys (`:description`) are
  converted to strings by stripping the leading colon.
- `nixos-test--with-options` / `nixos-test--with-packages` macros
  bind the cache vars directly (no JSON file needed).
- Mock `switch-to-buffer` / `pop-to-buffer` with `cl-letf` to test
  display without UI.
- Mock `nixos--package-meta`, `nixos--call-nix-package-expr`,
  `nixos--call-nix-url-expr`, or `browse-url` when side-effects
  are undesirable.
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

A `Position:` field shows the package's `meta.position` when
present, as a clickable `insert-text-button` calling
`find-file-at-point`.  The value is also stored in the
buffer-local `nixos--browse-position` var.

### Functional purity

Keep side-effecting code in interactive commands.  Internal functions
should be pure where possible — makes it testable without mocking.

A pure helper carries `(declare (pure t) (side-effect-free t))` as its
first body form, so the byte compiler can fold or drop a call.  Add the
declaration only when the result depends on the arguments alone: no
buffer access, no cache read, and no defcustom read.  A helper that
reads a user option takes neither declaration, because `pure` also
promises that the same arguments always give the same value.

```elisp
(defun nixos--option-group-name (name)
  "Return the table group of option NAME."
  (declare (pure t) (side-effect-free t))
  (if-let* ((dot (string-search "." name)))
      (substring name 0 dot)
    nixos--option-group-other))
```

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `defvar-keymap`, `with-memoization` |
| nix-mode | install: hard (Package-Requires); runtime: soft (guarded) | `nix-instantiate-executable` for package metadata; the value-less `defvar` makes the nix paths inert until nix-mode (or the user) sets the executable |
| nix (CLI) | soft (guarded) | `nix-executable` (from nix-mode) for `nix flake show --json`; `nixos--call-flake-show` guards on `boundp` + `stringp` |
| org-mode | soft | `ol-nixos.el` Org link types (opt-in `(require 'ol-nixos)`) |
| embark | soft | export + actions |

### Faces

Three custom faces (`nixos-package-name`, `nixos-field-label`,
`nixos-description`) inherit from `package.el` faces when
available, with built-in fallbacks (`bold`, `default`).  `nixos-version`
and `nixos-date` inherit from `shadow`, a plain built-in.  `nixos-revision`
inherits `shadow` too with a background-adapting foreground (light/dark)
for the `Revision:` flake hash, in the spirit of `magit-hash`.  No
`(require 'package)` needed — the `:inherit` list resolves
left-to-right, skipping undefined faces.  `nixos-date` is applied to
all rendered timestamps (the `Last modified:` flake field and the
per-input dates in the flake input tree); `nixos-revision` to the
`Revision:` value.  The flake overview `Description:` field uses
`nixos-description` and its `Path:` field reuses the same on-disk-status
face scheme as the package `Store path:` (see `nixos--display-package`).
