"""One-shot smoke test for the running dashboard.

Confirms /, /perf and /health are alive and that key page elements render.
"""

import re
import sys

import httpx

BASE = "http://127.0.0.1:8765"


def check(path: str, expectations: list[tuple[str, str]]) -> bool:
    r = httpx.get(BASE + path)
    print(f"\n[{r.status_code}] GET {path}  ({len(r.text):,} bytes)")
    if r.status_code != 200:
        return False
    ok = True
    for label, pat in expectations:
        m = re.search(pat, r.text)
        if m:
            sample = m.group(0)[:80]
            print(f"  OK   {label}: {sample!r}")
        else:
            print(f"  MISS {label}: pattern {pat!r} not found")
            ok = False
    return ok


def main() -> int:
    all_ok = True
    all_ok &= check("/health", [("status field", r'"status":\s*"ok"')])
    all_ok &= check("/", [
        ("date picker",     r'<input type="date"'),
        ("dates list",      r'<option value="\d{4}-\d{2}-\d{2}">'),
        ("phase 1 header",  r'Phase 1 . Ingest'),
        ("phase 2 header",  r'Phase 2 . Process'),
        ("phase 3 header",  r'Phase 3 . Report'),
    ])
    all_ok &= check("/perf", [
        ("chart canvas",    r'<canvas id="bench"'),
        ("chart labels",    r'const labels\s*=\s*\['),
        ("optimized pill",  r'pill-opt'),
        ("not-optimized pill", r'pill-notopt'),
    ])
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
