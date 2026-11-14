# AGENTS.md — nixos.el

## Overview

Emacs package providing interactive `completing-read` and
`tabulated-list-mode` interfaces for browsing NixOS options, Nix
packages and Nix flake outputs.  Three source files: `nixos.el`
(core), `ol-nixos.el` (Org link types) and `evil-nixos.el` (Evil
bindings).  Built via `flake.nix` (melpaBuild, AGPL3+).  Tests live
in `test/`, one file per source unit that needs one:
`test/nixos-test.el` and `test/evil-nixos-test.el`.

## Build & test

```sh
nix build                                # build + run tests
nix flake check                          # package + checks.lint
nix build .#checks.x86_64-linux.lint     # checkdoc + package-lint
emacs --batch -L . -L test -l test/nixos-test.el -f ert-run-tests-batch-and-exit
emacs --batch -L . -L test -l test/evil-nixos-test.el -f ert-run-tests-batch-and-exit
```

The Evil test file needs Evil, so `checkPhase` runs the whole suite
with the `emacsWithEvil` wrapper of the flake.  The package itself
never loads Evil, and `evil-nixos.el` byte-compiles without it.

To skip the NixOS options JSON eval, pass an existing JSON file to the
builder (see flake.nix; the old `nixosOptionsJson ? "/etc/..."`
default.nix argument is gone — the flake always evaluates an empty
config, which hits the binary cache).

## Architecture

### nixos.el (core, ~2760 lines)

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
6. Browse Major Mode (`nixos-browse-mode`, derived from
   `magit-section-mode`)
7. Sections (the four `nixos-*-sections-hook` defcustoms, the inserters
   `nixos-insert-*`, `nixos--render`, `nixos--browse-imenu-index`) and
   Point keeping
8. Display helpers (`nixos--field`, `nixos--link`, `nixos--display-option`,
   `nixos--display-package`, `nixos--display-flake`,
   `nixos--display-flake-overview`)
9. Bookmarks (detail + table)
10. Interactive commands (`nixos-package` / `nixos-package-local` /
    `nixos-package-url`, `nixos-option`, `nixos-flake`)
11. Thing-At-Point, Tabulated Browse Mode (shared macro), Eldoc
12. Completion metadata, Package Browse Mode, Embark export + actions

### ol-nixos.el (Org link types, ~130 lines)

Provides four Org link types:
- `nixos-package:` / `nixos-package-local:` (path) / URL variant
- `nixos-option:`
- `nixos-package-search:` / `nixos-option-search:` (filtered browse)

Opt-in module, like Org's own `ol-*` modules: it does a plain
`(require 'ol)` + `(require 'nixos)` and users enable it with
`(with-eval-after-load 'org (require 'ol-nixos))` in their config.
nixos.el does not know it exists.

### evil-nixos.el (Evil bindings, ~210 lines)

Opt-in module with the same shape as `ol-nixos.el`: it does
`(require 'nixos)` and the user enables it with
`(with-eval-after-load 'evil (require 'evil-nixos))`.  `nixos.el`
never loads it.

The file byte-compiles without Evil, so the package build needs no
Evil dependency.  It declares the Evil functions with
`declare-function` and the two state keymaps with value-less
`defvar`, and it uses `evil-define-key*` (a function) rather than the
`evil-define-key` macro.  A `(require 'evil nil t)` at the top loads
Evil when a user did not, and an explicit error reports a missing
Evil instead of a void function.

## Conventions

### Evil bindings

An Evil state keymap takes precedence over a major mode keymap, so
every nixos command that must keep its key goes into the auxiliary
keymap of the mode through `evil-define-key*`.  The three browse modes
start in the normal state, through `evil-set-initial-state`.

A key that opens Evil's `g` prefix goes into a prefix keymap of its
own, built by `evil-nixos--g-prefix`.  That keymap takes the normal
state `g` prefix as its parent and copies the motion state keys that
the parent lacks.  Without the parent, `gg` and `gf` break.  Without
the copy, `gg` breaks, because it lives in the motion state prefix.

`nixos-flake-overview-mode-map` installs itself with `use-local-map`,
so it is the active local map of its buffer.  Evil finds no
`nixos-browse-mode-map` binding there, and its auxiliary keymap does
not inherit the auxiliary keymap of the parent.  The file therefore
binds the overview map on its own.

`evil-nixos-goto-definition` reads `nixos--browse-position` and falls
back to `evil-goto-definition`.

`TAB` in a detail buffer is `magit-section-toggle`, and the file adds
the `nixos-browse-mode` entry that `evil-fold-list` lacks: the list
holds an `outline-minor-mode` entry only, and `evil--mode-p` compares
the major mode name itself.  The actions wrap `magit-section-toggle`,
`magit-section-show`, `magit-section-hide` and
`magit-section-show-children` in a lambda, because those commands take
the section as an argument.

`test/evil-nixos-test.el` asserts the bindings of every auxiliary keymap
and the behaviour of `TAB`, `gr` and `gd`.  `execute-kbd-macro` does
not reach an Evil state keymap in batch mode, so the tests take the
command from `key-binding` and call it.

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

`nixos-browse-mode` derives from `magit-section-mode`, which derives
from `special-mode`: read-only buffers, `q`, `g` → `revert-buffer`, and
the whole `magit-section` key set come for free.  Refresh goes through
`revert-buffer-function` (`nixos-browse-refresh`); no explicit
`read-only-mode` calls and no `TAB` binding of our own.

The mode body turns one `magit-section` default off.
`magit-section-inhibit-markers` is t, because a marker per section end
makes a render quadratic in the number of sections, and a flake
overview holds one section per output.  A detail buffer inserts once
and then only reads, so plain positions serve until the next render
rebuilds them.  Because the positions stay plain, no heading may end
with a colon: `magit-insert-child-count` rewrites such a heading
*after* its children recorded their positions, and that shifts those
positions.  A group heading therefore writes its item count into the
heading text through `nixos--heading` before the children exist, so
`magit-section-show-child-count` stays the reader's option and a
count never moves a section.

`list-buffers-directory` is nil: a renderer points `default-directory`
at a store path or at the nixpkgs root, so the directory of the mode is
not the directory of the buffer.

`truncate-lines` stays t, the `magit-section-mode` default, so a long
description clips at the window edge instead of folding the layout.

The mode enables `goto-address-mode`, so a URL inside a description,
an example value or a flake description becomes a link.  The link is
an overlay, so the text of the buffer stays plain, and
`goto-address-mode` brings its own keys.  Do not insert a text
button for a URL that a description already holds.

### Detail buffer sections

A detail buffer is a tree of `magit-section` sections.  Every display
function sets `nixos--browse-data` and calls

```elisp
(nixos--render 'option 'nixos-option-sections-hook)
```

`nixos--render` erases the buffer, opens one `nixos-detail` root
section and runs the hook through `magit-run-section-hook`.  The root
value is the kind of buffer (`option`, `package` or `flake`), so the
sections of the four buffer kinds never share an ident.

Four defcustoms list the inserters, one per buffer kind:
`nixos-option-sections-hook`, `nixos-package-sections-hook`,
`nixos-flake-sections-hook` and
`nixos-flake-overview-sections-hook`.  A user reorders or drops a
section with `setopt` or `add-hook`, the way a Magit user edits
`magit-status-sections-hook`.  Do not add a second knob that lists
sections.

An inserter is a top-level function that takes no arguments, reads the
`nixos--browse-` locals and inserts through `magit-insert-section`.  It guards its own data, so a
hook entry stays safe when the data lacks the field:

```elisp
(defun nixos-insert-package-maintainers ()
  (let* ((meta (alist-get 'meta nixos--browse-data))
         (maintainers (and meta (gethash "maintainers" meta))))
    (when (and maintainers (not (eq maintainers :null)))
      (magit-insert-section (nixos-group "Maintainers")
        (nixos--insert-group-heading "Maintainers" (length maintainers))
        ...))))
```

Section types and values:

| Type | Value | Where |
|---|---|---|
| `nixos-detail` | the buffer kind | root, one per render |
| `nixos-title` | the imenu label | title line of every buffer |
| `nixos-field` | `nixos--field-key` of the label | one section per field line |
| `nixos-group` | the label without colon | Declared by, Maintainers, Build Inputs, Native Build Inputs, Inputs, Outputs |
| `nixos-input` | the full input path | one per lock node |
| `nixos-output` | the node path | one per flake output |

A value must stay stable across renders and unique among its siblings.
The module path of an input and not its bare name, because a lock node
can appear under two parents.  `nixos-insert-flake-outputs` shows the
node count in the heading text and keeps it out of the value, so a
fold survives a new output.

`nixos--field` and `nixos--link` open one `nixos-field` section each,
so a field carries its own identity and a render keeps point on it.
`nixos--insert-title` opens `nixos-title` and adds the blank line after
it.  `nixos--heading` paints a group heading with
`magit-section-heading`; field labels keep `nixos-field-label`.
A node heading paints with `nixos--node-heading', which names the
`default` face, so a flake input node reads as plain content of the
`Inputs` group and not as a bold section of its own.  A node still
folds: it has a section and a heading.

A heading carries no colon.  A field label carries one, the way
`Head:` and `Merge:` do in a Magit status buffer, so the reader tells a
field from a foldable group at a glance.  `nixos--insert-group-heading`
inserts a group heading and writes the item count of the group into
the heading string, before the children exist, and only when
`magit-section-show-child-count` is non-nil.  The label carries
`magit-section-heading` and the count carries
`magit-section-child-count`, as the heading of a Magit buffer does, so
`Outputs (5)` shows two faces and no colon.

`nixos--browse-imenu-index` walks the section tree through
`magit-map-sections` and lists the title, the fields and the groups in
buffer order.  The nodes of a flake overview stay out, because a big
flake holds one section per output and the menu would flood.

Faces come from `nixos--propertize`, which names the face in both the
`face` and the `font-lock-face` text property.  Both are required:
`magit-section-mode` sets `font-lock-defaults`, so `font-lock-mode`
turns on in a detail buffer, and `font-lock-default-unfontify-region`
removes a plain `face` property.  A `face` that names the face alone
therefore shows nothing in an interactive session and still looks
correct in batch, where no fontification runs.  Never paint buffer
text with a bare `(propertize STRING 'face FACE)` in this package.
A button takes `'font-lock-face` beside `'face`, because a button
face is a text property too.

Pass an already propertized string to
`magit-insert-heading`; when the string carries a face, Magit inserts
it unchanged instead of painting `magit-section-heading`.

`nixos--heading` paints the label with `magit-section-heading` and the
count with `magit-section-child-count`, the way
`magit--propertize-face` paints a Magit heading.  `nixos--node-heading`
does the same with the `default` face.  Set both properties: a caller
that inspects a heading looks for `font-lock-face`, and the explicit
`face` names the face that a test or a user command reads.

### Point keeping across a refresh

`nixos--render` erases the buffer, so it records the line of point
before the erase and restores it after the render.  The record names a
section and not a buffer position: the section at point, the number of
lines from the start of that section, and the column.

`nixos--restore-record` hands the record to
`magit-section-goto-successor`, which finds the section again through
`magit-section-ident` (type and value, plus the lineage) and moves down
by the recorded number of lines and columns.  A section that the render
dropped leaves point at `point-min`.

The line offset counts from the section start, so a line added inside
the same section moves the reader to the line that now sits on that
offset, while a line added above the section moves nothing.  Give a
line its own section when it needs its own identity; that is why every
field line carries one.

Folds need no code: `magit-section` keeps the visibility of a section
in `magit-section-visibility-cache`, keyed by the section value, and
`nixos--render` ends with

```elisp
(let ((magit-section-cache-visibility nil))
  (magit-section-show magit-root-section))
```

The binding keeps the cache small: an entry appears only for a section
that a reader folded or unfolded, so the hook that reads the cache
stays cheap.

### Render skip

Each detail display function wraps its body in
`nixos--unless-rendered`, with a key that names the kind of the
buffer and the data it renders.  The macro compares the key with
`nixos--browse-rendered`, and it records the key when the body runs.
A refresh that fetched the same data therefore erases nothing, so
the point, the folds, the overlays and the section objects stay.  The key holds the data
itself, and `equal` compares hash tables and ignores the text
properties of a string, so a fetch that returns the same JSON skips
the render.

Call the macro around the whole render and not around one field.
It does not run the `-browse-setup` call or the buffer-local
assignment, so a skipped render leaves them as they were.

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
- `revert-buffer-function` is `nixos--browse-table-revert`.
  It runs `tabulated-list-revert-hook`, which reloads the entries,
  and reprints only when the entry list changed.  A revert of an
  unchanged table therefore keeps the point, the tags and the group
  headers.  `nixos--browse-table-reload` records the order that it
  built in `nixos--browse-table-last-entries`, because
  `tabulated-list-print` sorts `tabulated-list-entries` in place.
  The change test compares two lists of entries, and `equal`
  ignores the text properties of a cell, so a face change alone
  never triggers a reprint.  Do not compare the printed buffer.
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
- Both table maps remap the `nix-mode`, `nix-ts-mode` and
  `markdown-ts-mode` commands to the export commands.  A user key
  that runs one of those major modes elsewhere runs
  `nixos-browse-export-nix` or `nixos-browse-export-markdown` while
  point sits in a table.  The remap target names a symbol, so every
  mode stays optional.
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
(the `nixos--browse-source` value, serialized as-is; a flake detail
bookmark stores the flake reference instead, because
`nixos--browse-source` stays nil for a flake).

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
  Description, Path, URL, Revision and Last modified.  Sparse/empty
  values — and a nil META when the command fails — are omitted
  gracefully.  The input tree comes from `nixos--flake-inputs`, which
  walks `locks.nodes` through `nixos--flake-input-tree` and returns
  data, not display text: a node is `(NAME SOURCE CHILD...)` and a
  follow relationship is `(NAME follows TEXT)`.  `nixos-insert-flake-
  inputs` opens one `nixos-input` section per node, indents by two
  spaces per level and writes `NAME: SOURCE`, so a reader folds one
  input subtree.  Sources are formatted from each node's
  locked/original attrsets (`github:OWNER/REPO/REV` for github inputs,
  abbreviated local paths for file inputs) with a `(YYYY-MM-DD
  HH:MM:SS)` date when a lastModified timestamp exists; narHashes are
  omitted.  The source formatting lives in `nixos--flake-input-source`.
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
  re-runs `nixos-flake` on the ref.  `revert-buffer` calls a
  `revert-buffer-function` with two arguments, so a refresh function
  takes `&rest _ignored`, as `nixos-browse-refresh` and
  `nixos--browse-table-revert` do.  Each node line is an
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

### Docstrings

`emacs --batch -l checkdoc --eval '(checkdoc-arguments-in-order-flag t)' --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' *.el test/*.el`
reports no finding for the source and the test files.  Keep it that
way: `checks.lint` fails on any finding.

- A function summary starts with an imperative verb.  A variable,
  face or group summary starts with a noun phrase.  A boolean
  `defcustom` starts with "Non-nil if ...".
- The summary is one sentence that stands alone, ends with a period,
  and fits in less than 80 columns.
- The body follows the summary line directly.  An empty line comes
  before a later paragraph only, and before a `\\{...}` keymap
  listing.
- A line of the body must not start with `(` in column 0.  checkdoc
  reads such a line as a new top-level form.
- Quote a Lisp symbol with a plain backtick and apostrophe
  (`` `symbol' ``).  Inside an Elisp string the `=' sequence keeps
  the apostrophe only: write `\\='` for a quoted symbol in a code
  sample, because `\='` renders as `='` and loses the quote.

### Test conventions

- Tests live in `test/` (singular), one file per source unit that
  needs one, named `<unit>-test.el`: `test/nixos-test.el`,
  `test/evil-nixos-test.el`.  Shared fixtures go in
  `test/nixos-test-helper.el`, which never matches `*-test.el`, so the
  glob loader stays a test-only list.  `ol-nixos.el` tests live in
  `test/nixos-test.el`, because they load that module through the
  core feature.
- `checkPhase` loads the suite by glob, not by name:
  `printf -- "-l %s " test/*-test.elc` under `failglob`.  A new test
  file therefore needs no flake edit.  The guard on the substitution
  is load-bearing: without it an empty glob passes with zero tests.
- The package tarball never holds the test tree: the default
  package-build `:files` spec does not descend into subdirectories,
  and it also excludes root `*-test.el` and `*-tests.el`.  Do not add
  a `files` attribute to `melpaBuild`.
- `checks.lint` runs `package-lint` (with `package-lint-main-file`,
  `package-lint--sane-prefixes`, and an offline `nix-mode` stub) and
  `checkdoc` over `*.el test/*.el`.  Keep the test tree inside that
  glob, so tests obey the same header and docstring rules.
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
- A section test reads the tree, not the text: `magit-current-section`,
  `(oref section type)`, `(oref section value)` and
  `(oref section hidden)`.  The helpers are
  `nixos-test--section` (a section by type and value),
  `nixos-test--root-values` (the values under the root, in order) and
  `nixos-test--render-groups` (a small tree in a temp buffer).
- A fold hides its body, so point moves to the heading and
  `search-forward` skips invisible text.  Assert a fold through
  `(oref section hidden)` and `invisible-p`, and reach a section
  through its visible heading.
- A point-keeping test asserts the section semantics: a line added
  above a section moves nothing, a line added inside it moves the
  reader to the line that now sits on the recorded offset.
- When testing `nixos--package-meta` memoization without loading
  `nix-mode`, use `(setq nix-instantiate-executable "nix-instantiate")`
  — `defvar` alone leaves it void, and `let` creates a lexical binding
  in `lexical-binding: t` files, invisible to `boundp`.
- A `call-process` mock runs for a destination of `(list t STDERR-FILE)`,
  because the package captures stderr through a temp file.  Test for
  `(eq (car-safe destination) t)` and not for `(eq destination t)`.
- Read an alist that holds string keys with `assoc` or
  `(alist-get KEY ALIST nil nil #'equal)`.  A plain `alist-get` compares
  with `eq`, so a string key never matches.
- The suite defines one test per `ert-deftest` form.  After an edit,
  compare `(length (ert-select-tests t t))` with the number of
  `ert-deftest` forms: a missing parenthesis nests the later tests and
  `ert` runs fewer of them without an error.  `check-parens` in
  `emacs-lisp-mode` catches the case.

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

### Path display

`nixos--display-path` is the one path that a body line shows.  It
abbreviates a local path through `nixos--abbreviate-path`, so a rule
matches the `~/...` text that the reader sees, and then sends the
result through `tired-shorten-path` when tired is loaded.  That
function applies `tired-shorthand-rules`, so the rule that a reader
sets for a Dired link target reaches a store path, a flake `Path:`
field, a `Flake:` reference, an input source and a `Position:` value.
Tired stays optional: the helper guards on `fboundp`, the package
declares the function, and nothing loads tired.

The result is display text alone.  `nixos--browse-out-path`,
`nixos--browse-name`, the bookmarks, `nixos-browse-copy-out-path` and
`nixos--store-path-face` keep the real path, so a shortened value
never reaches the file system.  A button label shortens while its
action closes over the real string, as the `Position:` field does.
A Title section and a buffer name keep the plain abbreviation, because
a rule must not rename a buffer, and the buffer name is the identity
of a flake ref.

### Package display layout

`nixos--field` and `nixos--link` open one `nixos-field` section per
line and right-pad every label to `nixos--field-label-width` (14
columns).  A caller that needs a wider column passes the width, as
`nixos-insert-flake-metadata` does for `Last modified:`.

Store paths are face-colored by on-disk status through
`nixos--store-path-face`: `dired-directory` (exists, is a dir),
default (exists, is a file), `error` (missing / GC'd).  The face
reads the real path, and the printed value goes through
`nixos--display-path` first.  Homepage URLs use the `link` face.

Build and native build inputs are two sections, each inserted by its
own function, with clickable package names and store paths aligned to
one column.  `nixos--build-input-width` reads both lists, so the two
sections line up even though they are separate hook entries.  Package
names are `insert-text-button` widgets navigating to `nixos-package`.

A `Position:` field shows the package's `meta.position` when present,
as a clickable `insert-text-button` calling `find-file-at-point`.  The
value goes on a line of its own, inside the `nixos-field` section of
the field.  The value is also stored in the buffer-local
`nixos--browse-position` var.

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
| magit-section | yes | the detail buffers are `magit-section` trees: folds, section motions, the current-section highlight and the section lists of four hooks |
| nix-mode | install: hard (Package-Requires); runtime: soft (guarded) | `nix-instantiate-executable` for package metadata; the value-less `defvar` makes the nix paths inert until nix-mode (or the user) sets the executable |
| nix (CLI) | soft (guarded) | `nix-executable` (from nix-mode) for `nix flake show --json`; `nixos--call-flake-show` guards on `boundp` + `stringp` |
| org-mode | soft | `ol-nixos.el` Org link types (opt-in `(require 'ol-nixos)`) |
| evil | soft | `evil-nixos.el` bindings (opt-in `(require 'evil-nixos)`) |
| tired | soft (guarded) | `tired-shorten-path` applies the reader's `tired-shorthand-rules` to a printed path; `nixos--display-path` guards on `fboundp` |
| embark | soft | export + actions |

### Faces

Three custom faces (`nixos-package-name`, `nixos-field-label`,
`nixos-description`) inherit from `package.el` faces when
available, with built-in fallbacks (`bold`, `default`).  Group and node
headings paint with `magit-section-heading`, the face of every Magit
heading, so a group reads like a section of a Magit buffer.  Field
labels keep `nixos-field-label`, because a field line shows a value and
is not a folded block.

Faces come from `nixos--propertize` and not from font-lock keywords.
That helper names the face in both the `face` and the `font-lock-face`
property, so the paint survives the fontification of a detail buffer.
A propertized string passed to
`magit-insert-heading` keeps its face, because Magit inserts a heading
that already carries one unchanged.  `nixos-version`
and `nixos-revision` inherit from `shadow`, a plain built-in.
`nixos-date` inherits `(org-date shadow)`, so a timestamp in the
flake input tree looks the same as in an Org buffer and stays muted
when Org does not define its face.
`nixos-revision` inherits `shadow` too with a background-adapting
foreground (light/dark) for the `Revision:` flake hash, in the spirit
of `magit-hash`.  No `(require 'package)` or `(require 'org)` needed —
the `:inherit` list resolves left-to-right, skipping undefined faces.
`nixos-date` is applied to the per-input dates of the flake input
tree and to the `Last modified:` flake field, so every date in a flake
buffer reads the same.  Do not paint these with `magit-log-date`:
that face lives in `magit-log.el`, and the package requires
`magit-section` alone.  Emacs ignores an unknown face in a `face`
property, so the text shows in the default face and the build reports
nothing.  The flake overview
`Description:` field uses `nixos-description`, and its `Path:` field
takes `dired-directory`, because a flake source path always names a
directory even when it is not on disk.  The package `Store path:`
keeps the on-disk-status scheme of `nixos--store-path-face` (see
`nixos--display-package`).
