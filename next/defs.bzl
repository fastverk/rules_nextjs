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

    next_bin = ctx.attr.next_bin

    env = {
        "NEXT_TELEMETRY_DISABLED": "1",
        "NEXT_PRIVATE_STANDALONE": "1",
        "NODE_ENV": "production",
    }

    args = ctx.actions.args()
    args.add("build")
    args.add(ctx.attr.app_dir or ctx.label.package)

    ctx.actions.run(
        outputs = [out_dir],
        inputs = depset(direct = ctx.files.srcs + ctx.files.data),
        executable = next_bin.files_to_run.executable,
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
            doc = "`js_binary`-compatible target for the Next CLI " +
                  "(typically `:node_modules/next/dir`).",
        ),
    },
    doc = "Run `next build` hermetically and emit the `.next` tree as a Bazel-output directory.",
)
