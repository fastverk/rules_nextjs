"""User-facing rules for rules_nextjs.

Currently exports `next_build`, which runs `next build` as a Bazel
action with the workspace's deps as inputs and `.next/` as the
declared output. Forces hermeticity-relevant Next.js env vars
(`NEXT_TELEMETRY_DISABLED=1`, `NEXT_PRIVATE_STANDALONE=1`,
`NODE_ENV=production`) so the build itself doesn't drift.

The font/image-optimizer/instrumentation hermeticity scrub lives in
each consuming app's `next.config.ts` — the rule doesn't try to
patch it from the outside. See README.md for the consumer-side
checklist.

Targets returning `NextBuildInfo` expose the `.next` tree
programmatically so future rules (deploy targets, doc-site
extractors, `oci_image` wrappers) can consume builds without
re-running `next build`.
"""

NextBuildInfo = provider(
    doc = "A `next build` output tree.",
    fields = {
        "tree": "Directory: the .next output (standalone + static).",
    },
)

def _next_build_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out")

    env = {
        "NEXT_TELEMETRY_DISABLED": "1",
        "NEXT_PRIVATE_STANDALONE": "1",
        "NODE_ENV": "production",
        # aspect_rules_js js_binary actions abort at startup unless
        # BAZEL_BINDIR is set. `js_run_binary` would set this via the
        # `$(BINDIR)` make-var, but we invoke `next_bin` as a tool of
        # a custom rule's ctx.actions.run, not via js_run_binary, so we
        # pin it to "." (action working dir is the execroot, which is
        # the project root the bin should chdir to anyway).
        "BAZEL_BINDIR": ".",
    }

    args = ctx.actions.args()
    args.add("build")
    args.add(ctx.attr.app_dir or ctx.label.package)

    # `deps` carries the workspace ts_project libs + npm link targets
    # the next build action needs to resolve. Their runfiles must land
    # in the action's input set so node's module resolution finds them
    # under the runfiles tree.
    deps_inputs = depset(transitive = [
        d[DefaultInfo].default_runfiles.files
        for d in ctx.attr.deps
    ])

    ctx.actions.run(
        outputs = [out_dir],
        inputs = depset(
            direct = ctx.files.srcs + ctx.files.data,
            transitive = [deps_inputs],
        ),
        # Passing the FilesToRunProvider (not just `.executable`) auto-
        # includes next_bin's runfiles in the action sandbox — required
        # for `next` to load its own dependencies (webpack, swc, …).
        executable = ctx.attr.next_bin[DefaultInfo].files_to_run,
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
            doc = "Application source files + public/ assets + `next.config.ts` + `instrumentation.*`.",
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
    },
    doc = "Run `next build` hermetically and emit the `.next` tree as a Bazel-output directory.",
)
