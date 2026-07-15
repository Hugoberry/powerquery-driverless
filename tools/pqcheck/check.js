#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
//
// Syntax-checks Power Query M files with Microsoft's official parser
// (@microsoft/powerquery-parser). Syntax only: it will not catch misspelled
// standard-library functions or semantic mistakes, but it catches every
// malformed let/in, comma, and bracket before a file ever reaches a real host.
//
//   node check.js                 check every .pq/.m file in the repo
//   node check.js file.pq dir/    check specific files or directories
//
// Exit code: 0 all files parse, 1 at least one failure, 2 nothing to check.

const fs = require("fs");
const path = require("path");
const PQP = require("@microsoft/powerquery-parser");

const SKIP_DIRS = new Set(["node_modules", ".git", "context"]);

function collect(target, out) {
  const st = fs.statSync(target);
  if (st.isDirectory()) {
    if (SKIP_DIRS.has(path.basename(target))) return;
    for (const entry of fs.readdirSync(target).sort()) {
      collect(path.join(target, entry), out);
    }
  } else if (/\.(pq|m)$/i.test(target)) {
    out.push(target);
  }
}

function location(error) {
  // Best-effort extraction of the offending token from lex/parse errors.
  const inner = error && error.innerError;
  if (!inner) return null;
  const token =
    inner.token ??
    (inner.state
      ? inner.state.lexerSnapshot.tokens[inner.state.tokenIndex]
      : undefined);
  if (!token) return null;
  const pos = token.positionStart;
  return `line ${pos.lineNumber + 1}, col ${pos.lineCodeUnit + 1}, near '${token.data}'`;
}

async function main() {
  const args = process.argv.slice(2);
  const roots = args.length ? args : [path.join(__dirname, "..", "..")];
  const files = [];
  for (const root of roots) collect(root, files);
  if (files.length === 0) {
    console.error("pqcheck: no .pq or .m files found");
    process.exit(2);
  }

  let failed = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const result = await PQP.TaskUtils.tryLexParse(PQP.DefaultSettings, text);
    if (PQP.TaskUtils.isParseStageOk(result)) {
      console.log(`OK   ${file}`);
      continue;
    }
    failed += 1;
    console.log(`FAIL ${file}`);
    if (result.error) {
      console.log(`     ${result.error.message}`);
      const loc = location(result.error);
      if (loc) console.log(`     at ${loc}`);
    }
  }

  console.log(`pqcheck: ${files.length - failed}/${files.length} OK`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error("pqcheck:", e);
  process.exit(2);
});
