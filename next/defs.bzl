"""User-facing rules for rules_nextjs.

Exports `next_build`, which runs `next build` as a Bazel action with
the workspace's deps as inputs and `.next/` as the declared output.
Forces hermeticity-relevant Next.js env vars
(`NEXT_TELEMETRY_DISABLED=1`, `NEXT_PRIVATE_STANDALONE=1`,
`NODE_ENV=production`) so the build itself doesn't drift.

Targets returning `NextBuildInfo` expose the `.next` tree
programmatically so future rules (deploy targets, doc-site
extractors, `oci_image` wrappers) can consume builds without
re-running `next build`.

## Two-action design

`next_build` expands into two actions:

  1. **Stage** (`copy_to_directory_bin_action` from aspect_bazel_lib):
     materializes `srcs` + `data` into a TreeArtifact of *real files*
     (not symlinks).
  2. **NextBuild** (run_shell): copies the staged tree into a
     writable working dir, links node_modules in from
     aspect_rules_js's content store, rewrites the app's tsconfig
     (absolute extends + cleared paths), wraps next.config to inject
     `webpack.resolve.extensionAlias`, then runs `next build`.

The stage action exists because Bazel's sandbox materializes inputs
as symlink chains back to the workspace source. Webpack with its
default `resolve.symlinks: true` realpaths each src and walks parent
dirs for `node_modules` from the *realpath'd* (workspace) location,
finding the user's pnpm-managed source tree and pulling source `.ts`
packages whose compiled `.js` siblings only exist in bazel-out.
Staging as real files keeps webpack's realpath inside the sandbox so
transitive resolution walks aspect_rules_js's content-store layout
(which has compiled `.js`).

## Bundler: webpack (not Turbopack)

Next 16 defaults to Turbopack, but Turbopack rejects symlinks whose
canonical targets fall outside its configured project root with
`Invalid symlink` / `Symlink ... points out of the filesystem root`.
That's the exact topology aspect_rules_js produces (every npm package
under `<app>/node_modules/<pkg>` is a symlink to a sibling
content-addressed store at `bazel-out/.../bin/node_modules/.aspect_rules_js/`)
and that Bazel's per-action sandbox produces (output files symlink
back to a master output base outside the sandbox root).

We pass `--webpack` to force the webpack pipeline. Webpack tolerates
arbitrary symlink topologies — it just follows them transparently via
`open(2)`. The trade-off is a slower build vs. Turbopack, but the
build actually succeeds.

A patched Turbopack that tolerates out-of-root symlinks is in
development at fastverk/next.js (branch `fastverk/symlink-outside-root`).
Once that lands upstream, this rule can drop `--webpack`.
"""

load(
    "@aspect_bazel_lib//lib:copy_to_directory.bzl",
    "copy_to_directory_bin_action",
)

NextBuildInfo = provider(
    doc = "A `next build` output tree.",
    fields = {
        "tree": "Directory: the .next output (standalone + static).",
    },
)

_COPY_TO_DIRECTORY_TOOLCHAIN = "@aspect_bazel_lib//lib:copy_to_directory_toolchain_type"

def _next_build_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out")
    staged_dir = ctx.actions.declare_directory(ctx.label.name + ".staged")

    app_dir = ctx.attr.app_dir or ctx.label.package
    app_dir_arg = app_dir if app_dir else "."

    # Stage app srcs + data as a real-file directory. See module
    # docstring for the rationale. `hardlink = "off"` forces a real
    # copy (default "auto" hardlinks when possible); we need real
    # files so the downstream NextBuild action can rewrite tsconfig
    # in place without `chmod` chasing shared inodes.
    copy_to_directory_bin_action(
        ctx,
        name = ctx.label.name + "_stage",
        dst = staged_dir,
        copy_to_directory_bin = ctx.toolchains[_COPY_TO_DIRECTORY_TOOLCHAIN].copy_to_directory_info.bin,
        files = ctx.files.srcs + ctx.files.data,
        root_paths = [app_dir] if app_dir else ["."],
        hardlink = "off",
    )

    env = {
        "NEXT_TELEMETRY_DISABLED": "1",
        "NEXT_PRIVATE_STANDALONE": "1",
        "NODE_ENV": "production",
        # next.config.mjs may want this to resolve Bazel-managed paths
        # (e.g. for outputFileTracingRoot) — surface it explicitly.
        "BAZEL_BINDIR": ctx.bin_dir.path,
    }

    args = ctx.actions.args()
    args.add(ctx.executable.next_bin.path)
    args.add(app_dir_arg)
    args.add(out_dir.path)
    args.add(staged_dir.path)
    args.add(ctx.file._rewrite_tsconfig.path)
    args.add(ctx.file._write_next_config_wrapper.path)

    deps_inputs = depset(transitive = [
        d[DefaultInfo].default_runfiles.files
        for d in ctx.attr.deps
    ])

    ctx.actions.run_shell(
        outputs = [out_dir],
        inputs = depset(
            # `srcs` (as Bazel-staged symlinks) are still listed here so
            # the action can readlink the original tsconfig / next.config
            # locations for the rewrite helpers — the staged TreeArtifact
            # has deref'd copies but loses each file's original-location
            # context (needed for resolving tsconfig `extends` relative
            # paths).
            direct = ctx.files.srcs + ctx.files.data + [
                staged_dir,
                ctx.file._rewrite_tsconfig,
                ctx.file._write_next_config_wrapper,
            ],
            transitive = [deps_inputs],
        ),
        tools = [ctx.attr.next_bin[DefaultInfo].files_to_run],
        command = """
set -euo pipefail
NEXT_BIN="$(pwd)/$1"
APP_DIR="$2"
OUT_DIR="$(pwd)/$3"
STAGED_DIR="$(pwd)/$4"
REWRITE_TSCONFIG="$(pwd)/$5"
WRITE_NEXT_CONFIG_WRAPPER="$(pwd)/$6"
EXEC_ROOT="$(pwd)"
export BAZEL_BINDIR="${EXEC_ROOT}/${BAZEL_BINDIR}"

# `APP_RUN_DIR` is the writable working tree. The staged TreeArtifact
# from the upstream copy_to_directory action already holds deref'd
# copies of `srcs` + `data` (with `app_dir` prefix stripped); copy
# them in (real-file-to-real-file, no symlink resolution) so we can
# add `node_modules`, rewritten tsconfig, and the wrapped next.config
# alongside them.
APP_RUN_DIR="$(pwd)/_next_build_app"
mkdir -p "$APP_RUN_DIR"
# Copy the staged tree in. The TreeArtifact's directories ship as
# read-only — `find … chmod u+wx` lets us add new entries (node_modules
# link, next.config wrapper) under the staged subdirs. Individual file
# rewrites below `rm` + recreate, which works regardless of file mode.
cp -R "$STAGED_DIR"/. "$APP_RUN_DIR/"
find "$APP_RUN_DIR" -type d -exec chmod u+wx {} +

if [ "$APP_DIR" = "." ]; then
    SRC_APP_DIR="."
    NODE_MODULES_SRC="${BAZEL_BINDIR}/node_modules"
else
    SRC_APP_DIR="$APP_DIR"
    NODE_MODULES_SRC="${BAZEL_BINDIR}/${APP_DIR}/node_modules"
fi
ln -sfn "$NODE_MODULES_SRC" "$APP_RUN_DIR/node_modules"

# Capture tsconfig's *original symlink target* (before staging
# dereferenced it). rewrite_tsconfig.mjs needs the original location
# so relative `extends` paths (e.g. `"extends": "../configs/tsconfig.next"`)
# anchor to the workspace tree where the sibling configs actually live.
TSCONFIG_SRC=""
TSCONFIG_NAME=""
for candidate in tsconfig.json jsconfig.json; do
    [ -L "${SRC_APP_DIR}/${candidate}" ] || continue
    target="$(readlink "${SRC_APP_DIR}/${candidate}")"
    case "$target" in
        /*) TSCONFIG_SRC="$target" ;;
        *) TSCONFIG_SRC="$(cd "${SRC_APP_DIR}" && cd "$(dirname "$target")" && pwd)/$(basename "$target")" ;;
    esac
    TSCONFIG_NAME="$candidate"
    break
done

# Don't invoke the js_binary launcher directly — its own exec-cfg
# runfiles ship react-dom alongside next, so Next.js's build worker
# would load the binary's react-dom while compiled pages load the
# *target-config* react. Two React module copies → "Cannot read
# properties of null (reading 'useContext')". Run the next.js entry
# script directly via the hermetic Node runtime — module resolution
# then walks one node_modules layout for every import.
NEXT_RUNFILES="${NEXT_BIN}.runfiles"
NODE_BIN=""
for candidate in \\
    "${NEXT_RUNFILES}"/rules_nodejs*/bin/nodejs/bin/node \\
    "${NEXT_RUNFILES}"/_main/external/rules_nodejs*/bin/nodejs/bin/node; do
    [ -x "$candidate" ] && NODE_BIN="$candidate" && break
done
if [ -z "$NODE_BIN" ]; then
    echo "next_build: could not locate hermetic node binary under ${NEXT_RUNFILES}" >&2
    exit 1
fi

# Next.js's TypeScript bootstrap mutates `tsconfig.json` in place
# (adds `.next/dev/types/**/*.ts` to `include`, may rewrite
# `compilerOptions.jsx`). Overwrite the staged copy with a rewritten
# version sourced from the *original* tsconfig path so `extends` can
# resolve. Also clears `paths`/`baseUrl` so
# `tsconfig-paths-webpack-plugin` can't bypass the npm-link layer.
# See private/rewrite_tsconfig.mjs.
if [ -n "$TSCONFIG_SRC" ]; then
    rm -f "${APP_RUN_DIR}/${TSCONFIG_NAME}"
    "$NODE_BIN" "$REWRITE_TSCONFIG" "$TSCONFIG_SRC" "${APP_RUN_DIR}/${TSCONFIG_NAME}"
fi

# Inject a webpack `resolve.extensionAlias` so `.js` imports inside the
# compiled npm_packages fall through to `.jsx`/`.ts`/`.tsx`. The
# workspace's shared tsconfig sets `"jsx": "preserve"` so ts_project
# emits `.jsx` (not `.js`) for `.tsx` sources, but the surrounding
# compiled `.ts` modules still import siblings with `.js` (tsc doesn't
# rewrite specifiers). Wrap the user's next.config to register the
# alias without disturbing other settings. See private/write_next_config_wrapper.mjs.
for candidate in next.config.mjs next.config.js next.config.ts; do
    [ -f "${APP_RUN_DIR}/${candidate}" ] || continue
    mv "${APP_RUN_DIR}/${candidate}" "${APP_RUN_DIR}/_user.${candidate}"
    "$NODE_BIN" "$WRITE_NEXT_CONFIG_WRAPPER" \\
        "${APP_RUN_DIR}/_user.${candidate}" "${APP_RUN_DIR}/${candidate}"
    break
done

# `--webpack` forces the webpack pipeline. See the module docstring
# for why Turbopack doesn't work with aspect_rules_js's npm-link
# topology today.
"$NODE_BIN" "${APP_RUN_DIR}/node_modules/next/dist/bin/next" build --webpack "$APP_RUN_DIR"

# Next writes to `<app_dir>/.next/`; promote to declared output.
# `-L` dereferences symlinks so Bazel's output-tree validator doesn't
# flag the `standalone/node_modules` link as dangling (Next.js stages
# a relative-symlinked node_modules into its standalone output, and
# the target lies outside the declared output tree).
cp -RL "${APP_RUN_DIR}/.next/." "$OUT_DIR/"
""",
        arguments = [args],
        env = env,
        mnemonic = "NextBuild",
        progress_message = "next build %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([out_dir])),
        NextBuildInfo(tree = out_dir),
    ]

next_build = rule(
    implementation = _next_build_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Application source files + public/ assets + `next.config.mjs` + `instrumentation.*`.",
        ),
        "deps": attr.label_list(
            doc = "`ts_project` / npm link targets the app imports. " +
                  "Brought into runfiles for the build action.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional inputs that should land in the working tree " +
                  "before `next build` runs (e.g. migrations.zip -> public/).",
        ),
        "app_dir": attr.string(
            doc = "Package-relative app root. Defaults to the package " +
                  "containing the rule.",
        ),
        "next_bin": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
            doc = "`js_binary`-compatible target for the Next CLI. " +
                  "Generate one via `bin.next_binary(name = \"next_cli\")` " +
                  "loaded from `@npm//<app-pkg>:next/package_json.bzl` " +
                  "(aspect_rules_js auto-emits a binary generator for any " +
                  "npm package with a `bin` field), then pass `:next_cli`.",
        ),
        "_rewrite_tsconfig": attr.label(
            default = "//next/private:rewrite_tsconfig.mjs",
            allow_single_file = True,
            doc = "Helper script that re-anchors `extends` paths to " +
                  "absolute and clears `paths`/`baseUrl`. " +
                  "See private/rewrite_tsconfig.mjs.",
        ),
        "_write_next_config_wrapper": attr.label(
            default = "//next/private:write_next_config_wrapper.mjs",
            allow_single_file = True,
            doc = "Helper script that writes a `next.config.mjs` " +
                  "wrapper injecting `webpack.resolve.extensionAlias`. " +
                  "See private/write_next_config_wrapper.mjs.",
        ),
    },
    toolchains = [_COPY_TO_DIRECTORY_TOOLCHAIN],
    doc = "Run `next build` hermetically and emit the `.next` tree as a Bazel-output directory.",
)

def _next_dev_impl(ctx):
    app_dir = ctx.attr.app_dir or ctx.label.package
    app_dir_arg = app_dir if app_dir else "."

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = launcher,
        is_executable = True,
        content = """#!/usr/bin/env bash
# `bazel run`-launched Next.js dev server.
#
# Unlike `next_build`, dev mode runs *in the workspace tree* (via
# `BUILD_WORKSPACE_DIRECTORY`, the env var bazel run sets to the
# user's working directory) rather than a sandbox. Next.js dev needs:
#   * Real, writable source files (so its TypeScript bootstrap can
#     mutate tsconfig.json and the user's edits trigger fast refresh).
#   * fs.watch on the source tree — sandbox copies wouldn't see edits.
#   * The pnpm-managed node_modules already laid out by `pnpm install`
#     (dev mode bundles workspace packages from source `.tsx`, not
#     from aspect_rules_js's compiled `.jsx` content store).
#
# So this binary just locates the hermetic Node from `next_bin`'s
# runfiles and execs `node <app>/node_modules/next/dist/bin/next dev`
# from the workspace's app dir. The Bazel layer's value-add is the
# pinned Node version + a single `bazel run` entry point alongside
# the rest of the build graph.
set -euo pipefail

if [ -z "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]; then
    echo "next_dev: must be invoked via 'bazel run' (BUILD_WORKSPACE_DIRECTORY unset)" >&2
    exit 1
fi

APP_DIR="{app_dir}"
cd "${{BUILD_WORKSPACE_DIRECTORY}}/${{APP_DIR}}"

# Reuse the hermetic Node `next_bin` brought in via its js_binary
# runfiles so dev mode runs against the same Node version `next_build`
# does. `next_bin`'s deps are merged into our runfiles tree at the
# top level (sibling of `_main`), so we walk RUNFILES_DIR directly
# rather than chasing a nested `.runfiles`.
RUNFILES="${{RUNFILES_DIR:-$0.runfiles}}"
NODE_BIN=""
for candidate in "$RUNFILES"/rules_nodejs+*/bin/nodejs/bin/node; do
    [ -x "$candidate" ] && NODE_BIN="$candidate" && break
done
if [ -z "$NODE_BIN" ]; then
    echo "next_dev: could not locate hermetic node binary; falling back to PATH" >&2
    NODE_BIN="$(command -v node)"
fi

# Workspace's next CLI (pnpm-installed). NOT the bazel-out one — dev
# mode resolves the rest of node_modules relative to the next binary's
# location, so we want the workspace layout.
exec "$NODE_BIN" "node_modules/next/dist/bin/next" dev "$@"
""".format(app_dir = app_dir_arg),
    )

    runfiles = ctx.runfiles(files = [launcher]).merge(
        ctx.attr.next_bin[DefaultInfo].default_runfiles,
    )

    return [
        DefaultInfo(
            executable = launcher,
            runfiles = runfiles,
        ),
    ]

next_dev = rule(
    implementation = _next_dev_impl,
    attrs = {
        "app_dir": attr.string(
            doc = "Package-relative app root. Defaults to the package " +
                  "containing the rule.",
        ),
        "next_bin": attr.label(
            executable = True,
            cfg = "target",
            mandatory = True,
            doc = "`js_binary` target for the Next CLI — used only to " +
                  "borrow its runfiles' hermetic Node toolchain. The " +
                  "Next CLI itself is loaded from the workspace's " +
                  "pnpm-managed `node_modules/next` so dev-mode module " +
                  "resolution matches `pnpm dev`.",
        ),
    },
    executable = True,
    doc = "`bazel run`-launched Next.js dev server. Runs `next dev` " +
          "in the workspace tree against pnpm-managed node_modules.",
)
