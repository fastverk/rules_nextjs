<!-- Generated with Stardoc: http://skydoc.bazel.build -->

User-facing rules for rules_nextjs.

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

<a id="next_build"></a>

## next_build

<pre>
load("@rules_nextjs//next:defs.bzl", "next_build")

next_build(<a href="#next_build-name">name</a>, <a href="#next_build-deps">deps</a>, <a href="#next_build-srcs">srcs</a>, <a href="#next_build-data">data</a>, <a href="#next_build-app_dir">app_dir</a>, <a href="#next_build-next_bin">next_bin</a>)
</pre>

Run `next build` hermetically and emit the `.next` tree as a Bazel-output directory.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="next_build-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="next_build-deps"></a>deps |  `ts_project` / npm link targets the app imports. Brought into runfiles for the build action.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="next_build-srcs"></a>srcs |  Application source files + public/ assets + `next.config.ts` + `instrumentation.*`.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="next_build-data"></a>data |  Additional inputs that should land in the working tree before `next build` runs (e.g. migrations.zip -> public/).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="next_build-app_dir"></a>app_dir |  Package-relative app root. Defaults to the package containing the rule.   | String | optional |  `""`  |
| <a id="next_build-next_bin"></a>next_bin |  `js_binary`-compatible target for the Next CLI (typically `:node_modules/next/dir`).   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="NextBuildInfo"></a>

## NextBuildInfo

<pre>
load("@rules_nextjs//next:defs.bzl", "NextBuildInfo")

NextBuildInfo(<a href="#NextBuildInfo-tree">tree</a>)
</pre>

A `next build` output tree.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="NextBuildInfo-tree"></a>tree |  Directory: the .next output (standalone + static).    |


