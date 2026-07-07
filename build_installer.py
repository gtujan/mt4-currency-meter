#!/usr/bin/env python3
"""Generate a self-contained install.sh that recreates the Currency Meter
project (all text source files embedded as heredocs) and sets up the venv."""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "install.sh")
MARK = "___CM_EOF___"

FILES = [
    "bridge/server.py", "bridge/meter.py", "bridge/symbols.py",
    "bridge/mock_feed.py", "bridge/test_meter.py", "bridge/requirements.txt",
    "bridge/sample_quotes.json", "web/index.html",
    "mt4/CurrencyMeterFeed.mq4", "mt4/WebRequestTest.mq4",
    "meterctl.sh", "README.md", "INSTALL.md",
    "com.currencymeter.bridge.plist",
]

HEADER = r'''#!/usr/bin/env bash
#
# Currency Strength Meter — self-contained installer.
#
# One-liner:
#   curl -fsSL <URL>/install.sh | bash
# or download then run:
#   bash install.sh
#
# Installs into $CM_DIR (default: $HOME/currency_meter). Override with:
#   CM_DIR=/path/to/dir  curl -fsSL <URL>/install.sh | bash
#
# All source files are embedded below — no git clone, no extra downloads.
# The bridge/web app runs on any OS with Python 3.8+. MT4-specific setup
# (macOS/Wine, port 80, launchd) is documented in the installed INSTALL.md.

set -euo pipefail

CM_DIR="${CM_DIR:-$HOME/currency_meter}"

c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
say() { printf '%s %s\n' "$(c 36 '==>')" "$1"; }
ok()  { printf '%s %s\n' "$(c 32 '✓')" "$1"; }
die() { printf '%s %s\n' "$(c 31 '✗')" "$1" >&2; exit 1; }

say "$(c 1 'Currency Strength Meter installer')"

# ---- prerequisites ----
command -v python3 >/dev/null 2>&1 || die "python3 not found — install Python 3.8+ and re-run."
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
python3 -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,8) else 1)' \
  || die "Python $PYV is too old; need 3.8+."
python3 -m venv --help >/dev/null 2>&1 \
  || die "python3 'venv' module missing. On Debian/Ubuntu: sudo apt-get install python3-venv"
ok "python3 $PYV"

# ---- target directory ----
if [ -e "$CM_DIR" ] && [ -n "$(ls -A "$CM_DIR" 2>/dev/null)" ]; then
  say "$(c 33 "note:") $CM_DIR exists and is not empty — files will be overwritten."
fi
mkdir -p "$CM_DIR"
say "Installing into $(c 1 "$CM_DIR")"

# ---- project files (embedded) ----
'''

FOOTER = r'''
chmod +x "$CM_DIR/meterctl.sh"
ok "wrote project files"

# ---- python environment ----
say "Creating virtualenv and installing dependencies…"
python3 -m venv "$CM_DIR/.venv"
"$CM_DIR/.venv/bin/python" -m pip install --quiet --upgrade pip
"$CM_DIR/.venv/bin/pip" install --quiet -r "$CM_DIR/bridge/requirements.txt"
ok "dependencies installed (aiohttp)"

# ---- self-check ----
( cd "$CM_DIR/bridge" && "$CM_DIR/.venv/bin/python" test_meter.py >/dev/null 2>&1 ) \
  && ok "algorithm self-test passed" || say "$(c 33 'note:') self-test skipped/failed (non-fatal)"

printf '\n'
ok "$(c 1 'Installed.')"
cat <<DONE

Next steps:

  1. Try the demo (no MT4 needed):
       cd "$CM_DIR"
       source .venv/bin/activate
       python bridge/server.py &
       python bridge/mock_feed.py
     then open  http://127.0.0.1:8010

  2. Manage the server:
       cd "$CM_DIR"
       ./meterctl.sh start | stop | restart | status | logs

  3. Connect real MT4 and (on macOS) run at boot:
       see  "$CM_DIR/INSTALL.md"   (full MT4 + Wine + port-80 + launchd guide)

DONE
'''


def emit_file(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        content = f.read()
    if MARK in content:
        raise SystemExit(f"marker collision in {rel}")
    d = os.path.dirname(rel)
    block = ""
    if d:
        block += f'mkdir -p "$CM_DIR/{d}"\n'
    block += f"cat > \"$CM_DIR/{rel}\" <<'{MARK}'\n"
    block += content
    if not content.endswith("\n"):
        block += "\n"
    block += f"{MARK}\n"
    return block


parts = [HEADER]
for rel in FILES:
    parts.append(emit_file(rel))
parts.append(FOOTER)

with open(OUT, "w", encoding="utf-8") as f:
    f.write("".join(parts))
os.chmod(OUT, 0o755)
print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes), {len(FILES)} files embedded")
