# Varde

Varde is an experimental, compiler-free Odin documentation toolchain and
static API-site builder. It reads compatible `.odin-doc` artifacts and has an
early source-mode extractor that can build a self-contained site suitable for
opening from `file://`.

This is a work in progress, not a stable tool or compatibility promise.

## AI authorship

Varde is an AI-authored project. Its maintainer directs the work, product
decisions, and releases, but did not manually write the implementation code.
That provenance is stated plainly so users can evaluate the project on its
actual code, tests, documentation, and release practice.

## What currently works

- Read, validate, write, and deterministically merge `.odin-doc` format 0.3.2
  artifacts.
- Build offline, `file://`-compatible static documentation sites from
  compatible artifacts, with directory-style package routes.
- Discover target-appropriate Odin source files using build tags and trailing
  platform suffixes such as `_js.odin` and `_linux_amd64.odin`.
- Resolve direct aliases and re-exports through discovered relative and
  collection-qualified imports, retaining their target declaration graph.
- Lower documented structs, enums, unions, bit sets, bit fields, array and
  pointer type declarations, procedure-typed fields, and procedure groups into
  structured document data. Member documentation, inline comments, enum
  values, indentation, and source positions are retained where the source
  syntax establishes them.
- Render those structured declarations as readable source-like signatures,
  including `proc()` function fields, function parameters and results, and
  procedure groups such as `load :: proc{load_from_bytes, load_from_file}`.
- Organize package pages by declaration kind (types, constants, variables,
  procedures, and procedure groups), alphabetize entries inside each group,
  and provide grouped in-page navigation with offline fuzzy search.
- Syntax-highlight declaration signatures with safe cross-links: actual
  references can link to documented declarations, while struct-field and
  parameter labels remain plain text.
- Build a site directly from source when all required facts can be established
  without compiler execution, or emit an explicitly incomplete site with
  `--allow-incomplete`.

## Important limitations

Source mode is experimental and is not compiler-equivalent. It does not yet
cover the full Odin grammar, semantic resolution, complete visibility and
attribute handling, aliases/re-exports from dependencies outside the selected
source root, or complete import and collection behaviour. Varde reports facts
it cannot establish and refuses incomplete output unless `--allow-incomplete`
is supplied.

The project intentionally does not invoke, download, bundle, or discover an
Odin executable at Varde runtime. Odin is needed only to compile Varde itself.

## Repository layout

- `runtime/` contains the Varde package: static-site generation, documentation
  markup, document adaptation, and the in-process build façade.
- `doc_format/` implements the validated `.odin-doc` reader, writer, and
  deterministic merge layer.
- `extractor/` contains the compiler-free source discovery and lowering path,
  along with its fixtures.
- `cli/` is the thin command-line caller of those library packages.

## Local development

An Odin compiler must be on `PATH`.

```sh
make test
make build-cli

# Build an offline site from this source tree.
./dist/varde build --source . --allow-incomplete --out .varde-preview/site

# Inspect or render a compatible document artifact.
./dist/varde inspect path/to/project.odin-doc
./dist/varde build --doc path/to/project.odin-doc --out dist/varde
```

## Source links

Source links are opt-in because Varde cannot safely infer a public repository
or revision from an arbitrary local folder. Add a `varde.json` to the project
workspace when the source is available at a stable HTTPS location:

```json
{
  "include_source_links": true,
  "source_url_prefix": "https://github.com/owner/repository/blob/<commit>"
}
```

Varde appends the workspace-relative file path and declaration line number to
that prefix. Use an immutable commit or release tag for published sites; leave
the setting off for local-only projects.

## Local preview

For development convenience, Python is used temporarily to serve the generated
site; it is not a Varde runtime dependency. This will build once and serve the
site at `http://127.0.0.1:1314`:

```sh
make preview
make preview PREVIEW_PORT=8787
```

`preview` builds and serves documentation for the current local workspace.

To build and serve the pinned multi-project Varde showcase instead, use:

```sh
make showcase-preview PREVIEW_PORT=8787
```

It fetches the showcase repositories, builds each through Varde's incomplete
source mode, and creates a timestamped ignored output directory under
`.varde-preview/`. Set `SHOWCASE_PREVIEW_OUT` to retain a specific output
path; the target refuses to overwrite an existing directory.

When editing only the showcase catalog, use the fast preview:

```sh
make showcase-preview-fast PREVIEW_PORT=8787
```

It refreshes only `showcase/catalog/` in `.varde-preview/showcase`, verifies
that its existing project sites are complete, and then serves it. Use the full
`showcase-preview` target to create or rebuild that retained output.

To rebuild after source changes, use the standard-library Python watcher:

```sh
make preview-watch
```

The watcher keeps serving the last successful staged build if a rebuild fails.
It will be replaced by a native command only when Odin has suitable HTTP
support.

On Windows, with Odin on `PATH`:

```bat
test.bat
make_cli.bat
```

`examples/odin-stdlib` is an optional local smoke-test helper for building
preview documentation from an existing Odin checkout:

```sh
make sample-odin-stdlib ODIN_ROOT=/path/to/Odin
```

## License and upstream attribution

Varde is licensed under the [zlib license](LICENSE). Its `.odin-doc` support
includes modified/adapted material from the Odin project; see
[third-party notices](THIRD_PARTY_NOTICES.md).
