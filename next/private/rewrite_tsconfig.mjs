#!/usr/bin/env node
// Internal helper for rules_nextjs's `next_build` action.
//
// Reads `srcTsconfig` (a source-tree tsconfig.json reached via a
// sandbox input-symlink), resolves any relative `extends` paths
// against the source tsconfig's directory, and writes the result to
// `dstTsconfig` as a deref'd writable copy. The bin-side dst sits
// in a different parent directory than the source, so relative
// extends would otherwise dangle after the deref.
//
// Falls back to a plain copy when the file isn't parseable as JSON
// (e.g. JSON5 with constructs `tsc` accepts but `JSON.parse` doesn't).
// Next.js's TS bootstrap can still mutate the copy in place after
// that — the rewrite is best-effort plumbing, not validation.
//
// Usage: node rewrite_tsconfig.mjs <srcTsconfig> <dstTsconfig>

import fs from 'node:fs';
import path from 'node:path';

const [, , src, dst] = process.argv;
if (!src || !dst) {
  console.error('usage: rewrite_tsconfig.mjs <srcTsconfig> <dstTsconfig>');
  process.exit(1);
}

const srcDir = path.dirname(src);
const raw = fs.readFileSync(src, 'utf8');

// Strip line + block comments so JSON.parse accepts JSON-with-comments.
const stripped = raw
  .replace(/\/\/.*$/gm, '')
  .replace(/\/\*[\s\S]*?\*\//g, '')
  // Strip trailing commas before `}` or `]`.
  .replace(/,(\s*[}\]])/g, '$1');

let cfg;
try {
  cfg = JSON.parse(stripped);
} catch (err) {
  fs.copyFileSync(src, dst);
  process.exit(0);
}

function rewriteExtendsValue(value) {
  if (typeof value !== 'string') return value;
  // Don't touch absolute paths or bare-package specifiers (`@foo/bar`,
  // `foo/baz`) — only relative paths starting with `./` or `../`.
  if (path.isAbsolute(value)) return value;
  if (!value.startsWith('./') && !value.startsWith('../')) return value;
  return path.resolve(srcDir, value);
}

if (typeof cfg.extends === 'string') {
  cfg.extends = rewriteExtendsValue(cfg.extends);
} else if (Array.isArray(cfg.extends)) {
  cfg.extends = cfg.extends.map(rewriteExtendsValue);
}

// Override `compilerOptions.paths` and `compilerOptions.baseUrl` to
// empty values. Next.js + webpack pick up tsconfig `paths` via
// `tsconfig-paths-webpack-plugin` and resolve workspace imports
// (`@savvi-studio/foo`) to *source* `.ts`/`.tsx` files. Those sources
// use `.js` extensions in their imports referring to compiled
// siblings that don't exist next to the source (the Bazel build
// emits them into `bazel-out/.../bin` instead). Empty paths so
// resolution falls back to the node_modules layer that
// aspect_rules_js materializes — that layer points to the compiled
// outputs and Just Works.
//
// TypeScript's tsconfig inheritance *replaces* `paths` rather than
// merging, so setting `paths: {}` here also overrides any inherited
// paths from `extends` (and there typically are some in monorepo
// base configs). The original tsconfig is untouched in the source
// tree — this only affects the bin-side writable copy used by the
// Bazel action.
cfg.compilerOptions = cfg.compilerOptions ?? {};
cfg.compilerOptions.paths = {};
cfg.compilerOptions.baseUrl = '.';

fs.writeFileSync(dst, JSON.stringify(cfg, null, 2));
