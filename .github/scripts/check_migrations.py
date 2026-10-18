"""Guard database migrations on pull requests: python .github/scripts/check_migrations.py <base-ref>

Production deploys apply new migrations to the live database while the previous release is still serving,
and a code rollback never undoes SQL. So every migration must be safe for BOTH the old and the new code:

* merged migration files are immutable (the runner checksums them and refuses to boot if one changes)
* numbers are unique and come after everything already on main
* no destructive or rewriting statements: dropping/renaming tables or columns, changing column types,
  adding NOT NULL to existing columns, adding a NOT NULL column without a DEFAULT, TRUNCATE, DELETE

Breaking changes are still possible, deliberately: split them into expand → migrate code → contract releases,
and mark the final contract migration with a line `-- agora: allow-breaking <why the old code no longer needs
it>`. See docs/deployment.md#changing-the-database-safely.
"""

import re
import subprocess
import sys
from pathlib import PurePosixPath

DIRECTORY = "backend/migrations"
NAME = re.compile(r"^(\d{4})_[a-z0-9_]+(\.timescale)?\.sql$")
MARKER = re.compile(r"--\s*agora:\s*allow-breaking\s+\S", re.I)
RULES = [
    (r"\bdrop\s+(table|schema|view|materialized\s+view|type|sequence)\b", "drops a table/view/type"),
    (r"\bdrop\s+column\b", "drops a column"),
    (r"\balter\s+table\s+[^;]*\bdrop\s+(?!constraint|default|not\s+null|policy|trigger)\w+", "drops a column"),
    (r"\brename\b", "renames a table or column (old code still uses the old name)"),
    (r"\balter\s+column\s+\w+\s+(set\s+data\s+)?type\b", "changes a column type"),
    (r"\bset\s+not\s+null\b", "adds NOT NULL to an existing column (old code may still insert NULLs)"),
    (r"\btruncate\b", "truncates a table"),
    (r"\bdelete\s+from\b", "deletes rows"),
]
ADD_NOT_NULL = re.compile(r"\badd\s+column\s+(if\s+not\s+exists\s+)?\w+\s+[^,;]*\bnot\s+null\b(?![^,;]*\bdefault\b)",
                          re.I | re.S)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout  # noqa: S603, S607


def strip_comments(sql: str) -> str:
    sql = re.sub(r"--[^\n]*", " ", sql)
    return re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    merge_base = git("merge-base", base, "HEAD").strip()
    errors: list[str] = []
    changes = [line.split("\t") for line in git("diff", "--name-status", "-M0", merge_base, "HEAD", "--",
                                                 DIRECTORY).splitlines() if line]
    on_main = {PurePosixPath(p).name for p in git("ls-tree", "--name-only", f"{base}:{DIRECTORY}").split()}
    main_numbers = {int(m.group(1)) for n in on_main if (m := NAME.match(n))}
    added: list[str] = []
    for status, *paths in changes:
        name = PurePosixPath(paths[-1]).name
        if status.startswith("A") and name not in on_main:
            added.append(paths[-1])
        else:
            errors.append(f"{name}: merged migrations are immutable ({status}); add a new migration instead")

    numbers: dict[int, list[str]] = {}
    for path in sorted(git("ls-tree", "--name-only", f"HEAD:{DIRECTORY}").split()):
        match = NAME.match(path)
        if not match:
            errors.append(f"{path}: name must look like NNNN_lower_snake.sql or NNNN_name.timescale.sql")
            continue
        numbers.setdefault(int(match.group(1)), []).append(path)
    for number, files in numbers.items():
        plain = [f for f in files if not f.endswith(".timescale.sql")]
        if len(plain) > 1 or len(files) - len(plain) > 1:
            errors.append(f"migration number {number:04d} is used twice: {files}")

    newest_on_main = max(main_numbers, default=0)
    for path in added:
        name = PurePosixPath(path).name
        match = NAME.match(name)
        if match and int(match.group(1)) <= newest_on_main and not (
                int(match.group(1)) in main_numbers and name.endswith(".timescale.sql")):
            errors.append(f"{name}: number must be above {newest_on_main:04d}, the newest on main "
                          "(another PR may have merged first: renumber yours)")
        sql = git("show", f"HEAD:{path}")
        if MARKER.search(sql):
            print(f"::warning file={path}::{name} is marked allow-breaking; make sure the previous release "
                  "no longer uses what it removes (expand/contract)")
            continue
        body = strip_comments(sql)
        for pattern, why in RULES:
            if re.search(pattern, body, re.I):
                errors.append(f"{name}: {why}. Make it additive, or split into expand/contract releases "
                              "and mark the contract step `-- agora: allow-breaking <reason>`")
        if ADD_NOT_NULL.search(body):
            errors.append(f"{name}: adds a NOT NULL column without a DEFAULT; existing rows and the running "
                          "release's inserts would fail. Add a DEFAULT or make it nullable first")

    errors = list(dict.fromkeys(errors))  # two rules can flag the same statement
    for error in errors:
        print(f"::error::{error}")
    print(f"checked {len(added)} new migration(s) against {base}: " + ("OK" if not errors else f"{len(errors)} problem(s)"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
