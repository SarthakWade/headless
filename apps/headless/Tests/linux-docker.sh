#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || { echo "Linux E2E tests require Docker" >&2; exit 69; }
docker build --target test -f Dockerfile.linux -t headless-p1-test .
EVIDENCE_ROOT="${HEADLESS_EVIDENCE_ROOT:-$PWD/build/qa-evidence}"
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_DIR="$(mktemp -d "$EVIDENCE_ROOT/linux.XXXXXX")"
chmod 0777 "$EVIDENCE_DIR"
# The container writes evidence as its own non-root user, which lands on the
# host as an id this user cannot read. Which id to hand it back to depends on
# how the daemon maps them: rootful Docker maps uid to uid, so the invoking
# user's id is correct, while rootless maps container root to the invoking user
# and every other container id to an unreadable subuid.
if docker info --format '{{join .SecurityOptions ","}}' 2>/dev/null | grep -q rootless; then
  EVIDENCE_OWNER="0:0"
else
  EVIDENCE_OWNER="$(id -u):$(id -g)"
fi
restore_evidence_owner() {
  docker run --rm --user root -v "$EVIDENCE_DIR:/evidence" \
    headless-p1-test chown -R "$EVIDENCE_OWNER" /evidence >/dev/null 2>&1 || true
  chmod 0700 "$EVIDENCE_DIR" >/dev/null 2>&1 || true
}
file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}
trap restore_evidence_owner EXIT INT TERM
# SYS_ADMIN is limited to this disposable test container so Chromium can use
# its nested namespace sandbox. The shipped host still runs as non-root and
# never enables --no-sandbox.
docker run --rm --name headless-p1-e2e --shm-size=1g --cap-add=SYS_ADMIN \
  -e HEADLESS_EVIDENCE_DIR=/evidence -v "$EVIDENCE_DIR:/evidence" \
  headless-p1-test /opt/headless/linux-e2e.sh
docker run --rm --name headless-python-sdk-integration --shm-size=1g --cap-add=SYS_ADMIN \
  -e PYTHONPATH=/opt/python-sdk/src \
  -e HEADLESS_TEST_CLI=/usr/local/bin/headless \
  -e HEADLESS_TEST_HOST=/usr/local/bin/headless-host \
  -v "$PWD/../../packages/headless-python:/opt/python-sdk:ro" \
  headless-p1-test python3 /opt/python-sdk/tests/swift_integration.py
restore_evidence_owner
trap - EXIT INT TERM
(
  cd "$EVIDENCE_DIR"
  sha256sum -c SHA256SUMS
)
test -s "$EVIDENCE_DIR/viewport.png"
test -s "$EVIDENCE_DIR/full-page.png"
test -s "$EVIDENCE_DIR/dashboard-flow.mp4"
test "$(file_mode "$EVIDENCE_DIR/viewport.png")" = "600"
test "$(file_mode "$EVIDENCE_DIR/dashboard-flow.mp4")" = "600"
echo "Linux QA evidence: $EVIDENCE_DIR"
