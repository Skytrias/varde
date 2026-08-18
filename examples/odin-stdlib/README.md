# Odin standard-library preview

This sample builds one offline Varde site from an Odin checkout's `core`,
`vendor`, and `base` collections. It preserves those collection names as the
top-level package routes, matching the navigation shape used by
[`pkg.odin-lang.org`](https://pkg.odin-lang.org/core/).

```sh
make sample-odin-stdlib ODIN_ROOT=/path/to/Odin
```

The generated site is written to `dist/varde-stdlib` inside the Odin checkout.
Set `OUT` to choose another relative output directory:

```sh
make sample-odin-stdlib ODIN_ROOT=/path/to/Odin OUT=dist/varde-preview
```

The sample uses Varde's native source mode and therefore passes
`--allow-incomplete`. It is useful for rendering, navigation, and scale
testing, but it is not yet compiler-equivalent documentation: unresolved types
and unsupported source constructs are diagnosed rather than fabricated. For a
format-faithful build, feed compiler-produced `.odin-doc` artifacts into
`varde build --doc` instead.
