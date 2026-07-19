# pqcheck

Offline syntax checker for the `.pq` readers in this repo, built on Microsoft's
official open-source M parser,
[`@microsoft/powerquery-parser`](https://github.com/microsoft/powerquery-parser).

There is no M runtime outside a real Power Query host, so a typo in a reader is
normally invisible until someone pastes it into Power BI. This closes that gap
for the syntax half: every malformed `let`/`in`, comma, bracket, or string
literal is caught locally, with a line and column.

It checks syntax only. It will not catch a misspelled standard-library function
(`Number.BitwiseXOr`), a wrong offset, or a dead binding that lazy evaluation
never reaches. Those need fixtures and a real host; see each reader's `test/`
folder.

## Usage

```sh
cd tools/pqcheck
npm install          # once
npm run check        # checks every .pq/.m file in the repo
```

or against specific files or folders:

```sh
node check.js ../../sqlite3/Sqlite3.Database.pq
node check.js ../../access
```

Output is one `OK`/`FAIL` line per file, a summary line, and for failures the
parser message plus the offending token's location. Exit code 0 when everything
parses, 1 on any failure, 2 when nothing was found to check, so it is CI-ready.

