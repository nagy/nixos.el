# AGENTS.md — nixos.el

## Purpose

`nixos.el` is an Emacs package that browses NixOS options, Nix packages and
Nix flake outputs.  It serves `completing-read` and `tabulated-list-mode`
front ends, and it renders details as `magit-section` trees.  Two opt-in
layers add Org links and Evil bindings.  Emacs 30.1 is the floor.  The
license is AGPL3+, and the package is named `nixos`.

The user-facing feature list, the key tables and the short-display behavior
live in `README.org`.

## Layout

- `nixos.el`: caches, Nix callers, browse mode, detail buffers, flake
  browser, tables, Embark glue.
- `ol-nixos.el`: Org link types.  Opt-in, the user loads it.
- `evil-nixos.el`: Evil bindings.  Opt-in, the user loads it.
- `test/`: ERT suites, one file per source unit.
- `flake.nix`: package, baked JSON files, checks, devShell, treefmt.
- `emacs-screenshot.nix`: reproducible screenshot of a browse buffer.

## Build and test

- Run `nix build` before you commit.
- Run `nix flake check`.  It evaluates the package but does not build it.
- Run `nix fmt` after an edit.  It runs treefmt through the flake.  Do not
  run `nixfmt` alone.
- Run one suite in the shell with `emacs --batch -L . -L test -l
  test/nixos-test.el -f ert-run-tests-batch-and-exit`.  The Evil suite needs
  the `nix develop` shell, because a bare Emacs has no Evil.

## Architecture

A command fills a cache, a display function stores the fetched data in a
`nixos--browse-` local, and `nixos--render` rebuilds the buffer as a
`magit-section` tree from one section hook.

### Detail buffers

`nixos--render` erases the buffer, opens one `nixos-detail` root section and
runs a section hook through `magit-run-section-hook`.  Four defcustoms list
the inserters, one per buffer kind.  A user reorders or drops a section with
`setopt`.  Do not add a second knob that lists sections.

A section value must stay stable across renders and unique among its
siblings.  Point keeping and the fold cache both key on it.  Use the module
path of an input and not its bare name, because one lock node can sit under
two parents.

### Point keeping and folds

`nixos--render` records the section at point, the line offset inside that
section and the column.  `nixos--restore-record` hands the record to
`magit-section-goto-successor`.  A render that dropped the section leaves
point at `point-min`.  A line that a reader must keep needs a section of its
own.  A line added inside a section moves the reader to the line that now
sits on the recorded offset.  A line added above a section moves nothing.

`magit-section-visibility-cache` carries the folds, keyed by the section
value, so a render restores them without extra code.

### Render skip

`nixos--unless-rendered` compares a key with `nixos--browse-rendered`.  A
refresh that fetched equal data keeps the buffer text, the point, the folds
and the overlays.  Wrap the whole render in the macro.  Do not wrap one
field, and do not pass a key that leaves the data out.

### Package origin

`nixos--browse-source` holds nil, `(local . DIR)` or `(url . URL)`.  Refresh,
bookmarks and the `default-directory` rule all dispatch on it.  Extend that
enum for a new origin.  Do not add a parallel boolean.

A flake does not use it.  A flake buffer carries `nixos--browse-flake-ref`.

### Display text

`nixos--display-path` and `nixos--display-url` return shortened text, and
they keep the real value in the `nixos-path` and `nixos-url` text
properties.  Every command, bookmark, button action and `nixos--browse-`
local reads the real value.  Never read a path or a URL from the buffer
text.  A URL inside a description belongs to `goto-address-mode`, which
marks it with an overlay.

### Optional integrations

`tired`, `buffer-url`, `embark`, `org` and `evil` stay out of
`Package-Requires`.  Guard a call with `fboundp`, guard a hook with
`with-eval-after-load`, and guard a test with `skip-unless`.

## Rules

- Keep the literal `/etc/nixos-options.json` and `/etc/nixos-search.json` in
  the two defcustoms.  `flake.nix` replaces them in `postPatch`.
- Keep `nixos.el` free of a load of `ol-nixos.el` or `evil-nixos.el`.  The
  user loads both.  A load from inside `nixos.el` runs before its `provide`
  and raises a recursive load error.
- Keep `evil-nixos.el` byte-compiling without Evil.  Keep `nixos.el`
  byte-compiling without Embark.  `checkPhase` turns every warning into an
  error.
- Declare an external variable that a soft dependency owns with a
  value-less `(defvar var)`.  A value would replace the `defcustom` of the
  package that owns the variable when `nixos.el` loads first.
- Paint buffer text through `nixos--propertize` only.  `magit-section-mode`
  turns on fontification, and fontification drops a bare `face` property.
- Keep `nixos--package-output-re` on both `legacyPackages` and `packages`.
  A narrower regexp leaks the other prefix into an entry name and into the
  Nix export.
- A heading carries no colon.  `magit-insert-child-count` rewrites a colon
  heading after its children recorded their positions, and that shifts the
  positions.  Write the count into the heading text before the children
  exist.
## Conventions

- Follow checkdoc: an imperative summary under 80 columns, the body on the
  next line, and an empty line only before a later paragraph or a
  `\\{...}` listing.  Quote a symbol as `` `symbol' ``.
- Add `(declare (pure t) (side-effect-free t))` only when the result depends
  on the arguments alone.  A helper that reads a cache or a defcustom takes
  neither declaration.
- Keep side effects in interactive commands.
- Read a hash table from `json-parse-buffer` with `gethash`.  `let-alist`
  reads alists only.
- Read the `nixos--define-browse-mode` macro and the `nixos--browse-table-`
  defvars before you change a table.

## Testing

- `test/nixos-test.el` covers `nixos.el` and `ol-nixos.el`.
  `test/evil-nixos-test.el` covers `evil-nixos.el`.
- `checkPhase` loads `test/*-test.elc` by glob, so a new file needs no flake
  edit.  A behavior change ships a test.
- A section test reads the tree through `magit-current-section`, `(oref
  section type)`, `(oref section value)` and `(oref section hidden)`.  It
  does not read the buffer text.  A fold hides its body, so `search-forward`
  skips it.
- Mock `nixos--package-meta`, `nixos--call-nix-package-expr` and
  `nixos--call-nix-url-expr`.  Do not mock `call-process`.
- After an edit, compare `(length (ert-select-tests t t))` with the number
  of `ert-deftest` forms.  A missing parenthesis nests the later tests and
  the suite still passes.  `check-parens` catches it.

## Dependencies

| Dependency | Required | Why |
|---|---|---|
| Emacs 30.1 | yes | `json-parse-buffer`, `defvar-keymap`, `with-memoization` |
| magit-section | yes | the detail buffers are its section trees |
| nix-mode | yes, install only | `nix-instantiate-executable` and `nix-executable`.  Every runtime use guards on `boundp` |
| nix CLI | optional | `nix flake show` and `nix flake metadata` |
| org-mode | optional | `ol-nixos.el` |
| evil | optional | `evil-nixos.el` |
| tired | optional | `tired-shorten-path` in `nixos--display-path` |
| buffer-url | optional | `buffer-url-pretty-print` in `nixos--display-url` |
| embark | optional | export targets and actions |
