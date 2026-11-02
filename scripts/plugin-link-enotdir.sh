#!/usr/bin/env bash
# Shipped `openclaw update` end-to-end proof for openclaw PR #191056.
#
#   cell=red   : candidate = the published package (both plugin-link guards stop at
#                ENOENT/ELOOP)  ->  the update must abort on the ENOTDIR link.
#   cell=green : candidate = the package built from the reviewed head (both guards
#                widened)       ->  the same store shape must update to completion.
#
# The driver is the same published command in both cells and the store is seeded by the
# same code, so the only variable is the candidate package. That is also where the
# shipped design runs this work from: the `candidate-state-snapshot` step starts its
# state inspection worker out of the candidate root, so the candidate's code reads the
# operator store.
set -uo pipefail

CELL="${1:?usage: plugin-link-enotdir.sh <red|green>}"
DRIVER_BIN="${DRIVER_BIN:?DRIVER_BIN must be the installed openclaw command}"
DRIVER_PKG="${DRIVER_PKG:?DRIVER_PKG must be the installed openclaw package root}"
PUBLISHED_DRIVER="${PUBLISHED_DRIVER:-2026.10.9}"
PUBLISHED_TARGET="${PUBLISHED_TARGET:-2026.10.10-beta.5}"
HEADFIX_TGZ="${HEADFIX_TGZ:?HEADFIX_TGZ must be the package built from the reviewed head}"
PORT_GATEWAY="${PORT_GATEWAY:-19031}"
STATE="$HOME/.openclaw"
PLUGIN_DIR="$STATE/extensions/proof-plugin"
export PLUGIN_DIR
SUM=/tmp/proof-summary.txt
: >"$SUM"

if [ "$CELL" = red ]; then
  TARGET="$PUBLISHED_TARGET"
else
  TARGET="$HEADFIX_TGZ"
fi

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUM"; }

guard_enotdir() {
  local fn=$1 pkg=$2
  local file body
  file=$(grep -rl "function $fn(" "$pkg/dist" 2>/dev/null | head -1)
  body=$(grep -A18 "function $fn(" "$file" 2>/dev/null | tr -s '\t ' ' ')
  echo "$body" | grep -c ENOTDIR
}

say "cell: one published driver, only the candidate differs"
note "cell=$CELL driver_bin=$DRIVER_BIN"
"$DRIVER_BIN" --version 2>&1 | grep -m1 "^OpenClaw" | tee -a "$SUM"
DRIVER_PACKAGE=$(grep -m1 version "$DRIVER_PKG/package.json" | sed -E 's/.*: *"([^"]+)".*/\1/')
for fn in ignoreUnresolvedPluginLink targetIdentity; do
  note "driver_guard_$fn accepts_ENOTDIR=$(guard_enotdir "$fn" "$DRIVER_PKG")"
done
# A driver tree that already carries the fix would mute the red cell, and a green run
# swaps this very tree in place: every cell must install its own published copy.
if [ "$DRIVER_PACKAGE" != "$PUBLISHED_DRIVER" ]; then
  note "VERDICT=FAIL cell=$CELL (driver tree is $DRIVER_PACKAGE, not published $PUBLISHED_DRIVER)"
  exit 1
fi
note "driver_matches_published_release=1 driver_package_version=$DRIVER_PACKAGE"
note "candidate=$TARGET"

say "seed: operator store with one plugin tree carrying the ENOTDIR link"
rm -rf "$STATE"
mkdir -p "$PLUGIN_DIR" "$STATE/workspace"
chmod 700 "$HOME" "$STATE"
cat >"$STATE/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "loopback", "port": $PORT_GATEWAY },
  "agents": { "defaults": { "workspace": "$STATE/workspace" }, "entries": { "main": {} } },
  "plugins": { "load": { "paths": ["$PLUGIN_DIR"] } },
  "logging": { "level": "info" }
}
JSON
cat >"$PLUGIN_DIR/package.json" <<'JSON'
{ "name": "proof-plugin", "version": "1.0.0", "main": "index.cjs", "openclaw": { "extensions": ["./index.cjs"] } }
JSON
echo 'module.exports = { id: "proof-plugin" };' >"$PLUGIN_DIR/index.cjs"
echo 'payload data' >"$PLUGIN_DIR/payload.txt"
echo "proof-marker-$CELL" >"$STATE/workspace/PROOF_MARKER.txt"
# The reported shape: a link whose target traverses a regular file.
printf 'not a directory' >"$PLUGIN_DIR/blocker"
ln -s blocker/nested "$PLUGIN_DIR/plugin-link"
node -e '
const fs = require("node:fs");
const link = process.env.PLUGIN_DIR + "/plugin-link";
console.log("link stored target =", fs.readlinkSync(link));
try {
  fs.realpathSync(link);
  console.log("realpath = UNEXPECTED SUCCESS");
} catch (error) {
  console.log("realpath errno =", error.code, "syscall =", error.syscall);
}
' 2>&1 | tee -a "$SUM"
note "config_sha_before=$(sha256sum "$STATE/openclaw.json" | cut -d' ' -f1)"

say "drive the shipped update entry: openclaw update --tag $TARGET --no-restart --yes"
START=$(date +%s)
RC=0
"$DRIVER_BIN" update --tag "$TARGET" --no-restart --yes --json --timeout 1500 \
  >/tmp/update.json 2>/tmp/update.err || RC=$?
note "update_exit=$RC elapsed_s=$(( $(date +%s) - START ))"

say "update result as reported by the shipped command"
node -e '
const fs = require("node:fs");
const raw = fs.readFileSync("/tmp/update.json", "utf8");
let doc;
try {
  doc = JSON.parse(raw.slice(raw.indexOf("{")));
} catch {
  console.log(raw.slice(0, 1500));
  process.exit(0);
}
const res = doc.result ?? doc;
const steps = res.steps ?? [];
const failed = steps.filter((s) => s.exitCode !== 0).length;
console.log("status=", res.status, "reason=", res.reason);
console.log("from=", res.before?.version, "to=", res.after?.version);
console.log(`run_status=${res.status} steps_total=${steps.length} steps_failed=${failed}`);
for (const step of steps) {
  console.log(
    "STEP",
    step.name,
    "exit=" + step.exitCode,
    String(step.stderrTail ?? "").slice(0, 260).replace(/\n/g, " | "),
  );
}
' 2>&1 | tee -a "$SUM"
RUN_STATUS=$(grep -oE "^run_status=[a-z]+" "$SUM" | tail -1 | cut -d= -f2)
STEPS_FAILED=$(grep -oE "steps_failed=[0-9]+" "$SUM" | tail -1 | cut -d= -f2)
RUN_STATUS=${RUN_STATUS:-unparsable}
STEPS_FAILED=${STEPS_FAILED:-unparsable}

say "completion and admission text written by the shipped updater"
# --json keeps the machine result on stdout; the human completion line, the admission
# summary and the phase timings land in the run report the update writes into the store.
REPORT=$(ls -t "$STATE"/update-reports/*.md 2>/dev/null | head -1)
note "report=${REPORT#$HOME/}"
grep -hE "OpenClaw updated to|Admission checks:|Phases:|Snapshot location:" "$REPORT" 2>/dev/null |
  head -6 | tee -a "$SUM"
node -e '
const fs = require("node:fs");
const raw = fs.readFileSync("/tmp/update.json", "utf8");
try {
  const doc = JSON.parse(raw.slice(raw.indexOf("{")));
  const res = doc.result ?? doc;
  const a = res.candidateAdmission ?? res.admission;
  console.log("candidate_admission=", a ? `${a.verdict} reasons=${JSON.stringify(a.reasons)}` : "absent");
} catch {
  console.log("candidate_admission= unparsable");
}
' 2>&1 | tee -a "$SUM"
grep -hoE "ENOTDIR[^\"]*" /tmp/update.json /tmp/update.err 2>/dev/null | sort -u | head -4 | tee -a "$SUM"

say "operator store after the update"
note "installed_after=$("$DRIVER_BIN" --version 2>&1 | grep -m1 "^OpenClaw")"
note "installed_package_version=$(grep -m1 version "$DRIVER_PKG/package.json" | sed -E 's/.*: *"([^"]+)".*/\1/')"
if [ "$CELL" = green ]; then
  # The swap leaves the reviewed candidate in this tree, so this is the shipped code
  # that will read every operator store from now on.
  for fn in ignoreUnresolvedPluginLink targetIdentity; do
    note "installed_guard_$fn accepts_ENOTDIR=$(guard_enotdir "$fn" "$DRIVER_PKG")"
  done
fi
note "link_still_on_disk=$(readlink "$PLUGIN_DIR/plugin-link" 2>/dev/null || echo MISSING)"
note "blocker_still_on_disk=$([ -f "$PLUGIN_DIR/blocker" ] && echo yes || echo no)"
note "payload_still_on_disk=$([ -f "$PLUGIN_DIR/payload.txt" ] && echo yes || echo no)"
note "plugin_entry_still_on_disk=$([ -f "$PLUGIN_DIR/index.cjs" ] && echo yes || echo no)"
note "proof_marker_after=$(cat "$STATE/workspace/PROOF_MARKER.txt" 2>/dev/null)"
note "config_port_after=$(grep -o '"port": *[0-9]*' "$STATE/openclaw.json" 2>/dev/null | tr -d ' ')"

say "verdict"
ENOTDIR_HITS=$( { cat /tmp/update.json /tmp/update.err; } 2>/dev/null | grep -c "ENOTDIR" || true)
REPORT_COMPLETED=$(grep -c "OpenClaw updated to" "$REPORT" 2>/dev/null || true)
REPORT_COMPLETED=${REPORT_COMPLETED:-0}
SNAPSHOT_EXIT=$(node -e '
const fs = require("node:fs");
try {
  const raw = fs.readFileSync("/tmp/update.json", "utf8");
  const res = JSON.parse(raw.slice(raw.indexOf("{")));
  const step = ((res.result ?? res).steps ?? []).find((s) => s.name === "candidate-state-snapshot");
  console.log(step ? String(step.exitCode) : "absent");
} catch {
  console.log("unparsable");
}
')
VERDICT=FAIL
if [ "$CELL" = red ]; then
  # The published candidate must abort on this link and name it.
  if [ "$RC" -ne 0 ] && [ "$ENOTDIR_HITS" -gt 0 ] && [ "$RUN_STATUS" != ok ] &&
    [ "$REPORT_COMPLETED" = 0 ]; then
    VERDICT=PASS
  fi
  note "red: exit=$RC enotdir=$ENOTDIR_HITS run_status=$RUN_STATUS report_completed=$REPORT_COMPLETED"
else
  # The reviewed candidate must carry the same store through every phase, data intact.
  if [ "$RC" -eq 0 ] && [ "$RUN_STATUS" = ok ] && [ "$STEPS_FAILED" = 0 ] &&
    [ "$ENOTDIR_HITS" = 0 ] && [ "$SNAPSHOT_EXIT" = 0 ] && [ "$REPORT_COMPLETED" = 1 ] &&
    [ -n "$(readlink "$PLUGIN_DIR/plugin-link" 2>/dev/null)" ]; then
    VERDICT=PASS
  fi
  note "green: exit=$RC enotdir=$ENOTDIR_HITS run_status=$RUN_STATUS steps_failed=$STEPS_FAILED snapshot_exit=$SNAPSHOT_EXIT report_completed=$REPORT_COMPLETED"
fi
note "VERDICT=$VERDICT cell=$CELL"
[ "$VERDICT" = PASS ] || exit 1
