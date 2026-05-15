# rules_nextjs

Bazel rules for [Next.js](https://nextjs.org/). Runs `next build` as a
hermetic Bazel action with the workspace's deps as explicit inputs and
the `.next/` tree as the declared output.

- **rule**: `next_build` — see [docs/defs.md](docs/defs.md).
- **provider**: `NextBuildInfo` — wraps the `.next` output tree so future rules (deploy targets, `oci_image` wrappers, doc-site extractors) can consume builds programmatically.

## Install

Add the registry to your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/fastverk/bazel-registry/main/
common --registry=https://bcr.bazel.build/
```

In your `MODULE.bazel`:

```python
bazel_dep(name = "rules_nextjs", version = "0.1.0")
```

You'll also need `aspect_rules_js` (or equivalent) to expose `next` as a `js_binary`-compatible target — this rule consumes the CLI via `next_bin`, doesn't bring its own.

## Quick start

```python
load("@rules_nextjs//next:defs.bzl", "next_build")

next_build(
    name = "build",
    srcs = glob(["src/**/*", "public/**/*"]) + [
        "next.config.ts",
        "tsconfig.json",
    ],
    deps = [
        "//packages/some-lib:lib",
        ":node_modules/next",
        ":node_modules/react",
        ":node_modules/react-dom",
    ],
    data = [
        # Runtime assets dropped into public/ before the build.
        "//db/migrations:bundle",
    ],
    next_bin = ":node_modules/next/dir",
)
```

`bazel build //:build` produces `bazel-bin/build.out/` containing the full
`.next/` tree (`standalone/`, `static/`, trace files).

## Hermeticity

The rule forces three Next.js env vars:

- `NEXT_TELEMETRY_DISABLED=1`
- `NEXT_PRIVATE_STANDALONE=1`
- `NODE_ENV=production`

The rest of the hermeticity scrub lives in each app's `next.config.ts` — `rules_nextjs` deliberately doesn't try to patch from the outside. Consumer-side checklist:

| Bring under control | How |
| --- | --- |
| Font CDN fetches | Vendor under `public/fonts/` or use `next/font/local`; `next/font/google` reaches `fonts.googleapis.com` at build time |
| Image optimizer pre-fetches | `images: { unoptimized: true }` or explicit `remotePatterns` |
| Build-time network from instrumentation | Audit `instrumentation*.ts` for module-init side effects |
| Next version | Pin via root `package.json` catalog |

Validate the scrub by building with `--network none` after the migration lands.

## Compatibility

- **Bazel**: 7.4+, bzlmod required.
- **Next.js**: 14+ tested. Earlier versions may work — `next build <app-dir>` and the env-var contract have been stable.
- **Workspace shape**: assumes `aspect_rules_js`-style npm linking (`:node_modules/next/dir`).

## Contributing

Reference docs (`docs/defs.md`) are stardoc-generated. After editing rule docstrings:

```sh
bazel run //docs:update
```

CI gates this via `bazel test //docs/...`.

## License

MIT.
