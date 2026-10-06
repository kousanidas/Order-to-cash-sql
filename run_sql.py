"""
Small runner so the .sql files can be executed without the sqlite3 command line.

    python3 run_sql.py 04_analysis_queries.sql        # run every query, print results
    python3 run_sql.py 05_validation_checks.sql
    python3 run_sql.py 01_schema.sql --script         # DDL / inserts, no output
    python3 run_sql.py 05_validation_checks.sql --checks   # one line per check

macOS ships the sqlite3 command line, so `sqlite3 o2c.db < 04_...sql` works
there too. This exists because some machines do not have it, and because it
splits the file on the comment banners so each query's own header is printed
above its result.
"""

import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DB = f"{HERE}/o2c.db"


def split_statements(sql):
    """Split on semicolons at the end of a line, keeping the comment above."""
    out, buf = [], []
    for line in sql.splitlines():
        buf.append(line)
        if line.rstrip().endswith(";"):
            stmt = "\n".join(buf).strip()
            if any(l.strip() and not l.strip().startswith("--")
                   for l in stmt.splitlines()):
                out.append(stmt)
            buf = []
    if buf and "\n".join(buf).strip():
        out.append("\n".join(buf).strip())
    return out


def title_of(stmt):
    for line in stmt.splitlines():
        s = line.strip().lstrip("-").strip()
        if s and (s.startswith("Q") or s.startswith("V")) and "." in s[:4]:
            return s
    return None


def show(rows, cols, limit=40):
    if not rows:
        print("    (no rows)")
        return
    w = [max(len(str(c)), max(len(str(r[i])) for r in rows[:limit]))
         for i, c in enumerate(cols)]
    w = [min(x, 46) for x in w]
    print("    " + " | ".join(str(c)[:w[i]].ljust(w[i]) for i, c in enumerate(cols)))
    print("    " + "-+-".join("-" * x for x in w))
    for r in rows[:limit]:
        print("    " + " | ".join(
            ("" if v is None else str(v))[:w[i]].ljust(w[i]) for i, v in enumerate(r)))
    if len(rows) > limit:
        print(f"    ... {len(rows) - limit} more rows")


def run_checks(con, sql):
    """Print the validation suite as one line per check, plus a summary.

    The check files return (name, expected, actual, verdict) per statement. The
    wide default layout truncates the actual column, which is where the useful
    detail is, so this prints name / verdict / actual and adds the engine's own
    foreign-key check at the end.
    """
    res = []
    for stmt in split_statements(sql):
        body = "\n".join(l for l in stmt.splitlines()
                          if l.strip() and not l.strip().startswith("--"))
        if body.strip():
            res.append(con.execute(body).fetchone())
    print(f"{'check':42s} {'verdict':9s} actual")
    print("-" * 120)
    for r in res:
        print(f"{str(r[0])[:42]:42s} {str(r[3]):9s} {r[2]}")
    print("-" * 120)
    p = sum(1 for r in res if r[3] == "PASS")
    e = sum(1 for r in res if r[3] == "EXPECTED")
    f = len(res) - p - e
    print(f"{len(res)} checks | {p} PASS | {e} EXPECTED | {f} FAIL")
    fk = con.execute("PRAGMA foreign_key_check").fetchall()
    print(f"PRAGMA foreign_key_check: {len(fk)} violations")
    return f


def main():
    path = sys.argv[1]
    as_script = "--script" in sys.argv
    as_checks = "--checks" in sys.argv
    sql = open(path if os.path.isabs(path) else f"{HERE}/{path}").read()
    con = sqlite3.connect(DB)
    con.execute("PRAGMA foreign_keys = ON")
    if as_script:
        con.executescript(sql)
        con.commit()
        print(f"ran {os.path.basename(path)} as a script")
        return
    if as_checks:
        failed = run_checks(con, sql)
        con.close()
        sys.exit(1 if failed else 0)
    n_fail = 0
    for stmt in split_statements(sql):
        head = title_of(stmt)
        body = "\n".join(l for l in stmt.splitlines()
                         if l.strip() and not l.strip().startswith("--"))
        if not body.strip():
            continue
        if head:
            print(f"\n{'=' * 78}\n{head}\n{'=' * 78}")
        try:
            cur = con.execute(body)
            if cur.description:
                show(cur.fetchall(), [d[0] for d in cur.description])
            else:
                con.commit()
        except Exception as e:
            n_fail += 1
            print(f"    *** FAILED: {e}")
            print("    " + body.splitlines()[0][:100])
    con.close()
    if n_fail:
        print(f"\n{n_fail} statement(s) failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
