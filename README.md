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
- Build offline static documentation sites from compatible artifacts.
- Discover a focused subset of Odin source packages and declarations.
- Build a site directly from source when all required facts can be established
  without compiler execution.

## Important limitations

Source mode is experimental and is not compiler-equivalent. It does not yet
cover the full Odin grammar, semantic resolution, visibility, attributes,
aliases/re-exports, or complete import and collection behaviour. Varde reports
facts it cannot establish and refuses incomplete output unless
`--allow-incomplete` is supplied.

The project intentionally does not invoke, download, bundle, or discover an
Odin executable at Varde runtime. Odin is needed only to compile Varde itself.

## Local development

An Odin compiler must be on `PATH`.

```sh
make test
make build-cli

# Build an offline site from this source tree.
./dist/varde build --source . --out dist/varde

# Inspect or render a compatible document artifact.
./dist/varde inspect path/to/project.odin-doc
./dist/varde build --doc path/to/project.odin-doc --out dist/varde
```

## Local preview

For development convenience, Python is used temporarily to serve the generated
site; it is not a Varde runtime dependency. This will build once and serve the
site at `http://127.0.0.1:1314`:

```sh
make preview
make preview PREVIEW_PORT=8787
```

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
