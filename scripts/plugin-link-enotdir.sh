#!/usr/bin/env bash
# Shipped `openclaw update` end-to-end proof for openclaw PR #191056.
#
#   arm=prefix : driver = published openclaw (both plugin-link guards still stop at
#                ENOENT/ELOOP)  ->  the update must abort on the ENOTDIR link.
#   arm=head   : driver = the package built from the reviewed head (both guards
#                widened)       ->  the same store shape must update to completion.
#
# Only the driver code differs: both arms target the same published version and seed
# the store with the same script, so the link is never removed or pre-resolved.
set -uo pipefail

ARM="${1:?usage: plugin-link-enotdir.sh <prefix|head>}"
DRIVER_BIN="${DRIVER_BIN:?DRIVER_BIN must be the installed openclaw command}"
DRIVER_PKG="${DRIVER_PKG:?DRIVER_PKG must be the installed openclaw package root}"
PUBLISHED_DRIVER="${PUBLISHED_DRIVER:-2026.10.9}"
TARGET_VERSION="${TARGET_VERSION:-2026.10.10-beta.5}"
PORT_GATEWAY="${PORT_GATEWAY:-19031}"
STATE="$HOME/.openclaw"
PLUGIN_DIR="$STATE/extensions/proof-plugin"
export PLUGIN_DIR
SUM=/tmp/proof-summary.txt
: >"$SUM"

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUM"; }

say "driver: installed command identity"
note "driver_bin=$DRIVER_BIN"
"$DRIVER_BIN" --version 2>&1 | tail -1 | tee -a "$SUM"
note "published_driver=$PUBLISHED_DRIVER target_version=$TARGET_VERSION"

say "driver: the two plugin-link guards as actually installed"
for fn in ignoreUnresolvedPluginLink targetIdentity; do
  file=$(grep -rl "function $fn(" "$DRIVER_PKG/dist" 2>/dev/null | head -1)
  if [ -z "$file" ]; then
    note "guard_$fn=NOT_FOUND in installed dist"
    continue
  fi
  body=$(grep -A14 "function $fn(" "$file" | tr -s '\t ' ' ')
  note "guard_$fn file=$(basename "$file")"
  echo "$body" | tee -a "$SUM"
  note "guard_$fn accepts_ENOTDIR=$(echo "$body" | grep -c ENOTDIR)"
done

say "seed: operator store with one plugin tree carrying the ENOTDIR link"
mkdir -p "$PLUGIN_DIR" "$STATE/workspace"
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
echo "proof-marker-$ARM" >"$STATE/workspace/PROOF_MARKER.txt"
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
' | tee -a "$SUM"
find "$STATE" -maxdepth 3 | sed "s#$HOME#~#" | sort | tee -a "$SUM"
note "config_sha_before=$(sha256sum "$STATE/openclaw.json" | cut -d' ' -f1)"

cat >/tmp/dump-plugin-index.cjs <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const dbPath = path.join(process.env.HOME, ".openclaw", "state", "openclaw.sqlite");
if (!fs.existsSync(dbPath)) {
  console.log("no state database at", dbPath);
  process.exit(0);
}
const db = new DatabaseSync(dbPath, { readOnly: true });
const tables = db
  .prepare("select name from sqlite_master where type = 'table'")
  .all()
  .map((row) => row.name);
console.log("tables=", tables.join(","));
if (tables.includes("config_machine_state")) {
  for (const row of db
    .prepare("select state_key, substr(value_json, 1, 1200) as v from config_machine_state")
    .all()) {
    console.log("machine_state key=", row.state_key);
    console.log(row.v);
  }
}
db.close();
NODE

say "operator store the update reads: config and plugin index"
cat "$STATE/openclaw.json" | tee -a "$SUM"
node /tmp/dump-plugin-index.cjs 2>&1 | tee -a "$SUM" | head -40

say "drive the shipped update entry: openclaw update --tag $TARGET_VERSION --no-restart --yes"
if [ "${TRACE_REALPATH:-}" = "1" ]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  export NODE_OPTIONS="--import $here/trace-plugin-link-realpath.mjs ${NODE_OPTIONS:-}"
  note "node_options=$NODE_OPTIONS"
fi
START=$(date +%s)
RC=0
"$DRIVER_BIN" update --tag "$TARGET_VERSION" --no-restart --yes --json --timeout 1500 \
  >/tmp/update.json 2>/tmp/update.err || RC=$?
note "update_exit=$RC elapsed_s=$(( $(date +%s) - START ))"
say "failure diagnostics written by the shipped update"
for f in "$STATE"/logs/support/openclaw-update-failure-*.json; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  node -e '
const fs = require("node:fs");
const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const walk = (value, key) => {
  if (typeof value === "string" && /at .*\.mjs|stack|realpath|ENOTDIR/i.test(key + " " + value)) {
    console.log(key + " => " + value.slice(0, 1200));
  }
  if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) walk(v, k);
  }
};
walk(body, "root");
  ' "$f" 2>&1 | head -40
done
echo "--- update stderr (guard-relevant lines) ---"
grep -nE "ENOTDIR|ELOOP|ENOENT|plugin-link|Failed:|Phase:" /tmp/update.err | head -20
echo "--- update stdout summary ---"
node -e '
const fs = require("node:fs");
const raw = fs.readFileSync("/tmp/update.json", "utf8");
let body;
try { body = JSON.parse(raw); } catch { console.log(raw.slice(0, 800)); process.exit(0); }
const run = body.run ?? body;
console.log("status=", run.status ?? body.status, "reason=", run.reason ?? body.reason ?? "");
console.log("from=", run.currentVersion ?? body.currentVersion, "to=", run.targetVersion ?? body.targetVersion);
console.log("phases=", (run.phases ?? run.steps ?? []).map?.((s) => `${s.name ?? s.phase}:${s.status ?? s.exitCode}`).join(" -> "));
' 2>&1 | head -12
echo "--- full human-readable tail ---"
{ cat /tmp/update.err; tail -40 /tmp/update.json; } | grep -vE '^\s*$' | tail -25 | tee -a "$SUM"

say "operator store after the run: plugin index the inventory read"
node /tmp/dump-plugin-index.cjs 2>&1 | tee -a "$SUM" | head -60

say "shipped realpath call sites on the proof link"
grep -A12 "realpath-trace" /tmp/update.err | head -80

say "verdict"
ENOTDIR_HITS=$( { cat /tmp/update.err /tmp/update.json; } 2>/dev/null | grep -c "ENOTDIR" || true)
COMPLETED=$( { cat /tmp/update.err /tmp/update.json; } 2>/dev/null | grep -c "updated to" || true)
INSTALLED_VERSION=$("$DRIVER_BIN" --version 2>&1 | tail -1)
note "enotdir_reported=$ENOTDIR_HITS update_reported_completion=$COMPLETED installed_after=$INSTALLED_VERSION"
note "proof_marker_after=$(cat "$STATE/workspace/PROOF_MARKER.txt" 2>/dev/null)"
note "config_port_after=$("$DRIVER_BIN" config get gateway.port --json 2>/dev/null | tr -d '\n')"
note "link_still_on_disk=$(readlink "$PLUGIN_DIR/plugin-link" 2>/dev/null || echo MISSING)"
note "blocker_still_on_disk=$([ -f "$PLUGIN_DIR/blocker" ] && echo yes || echo no)"
note "config_sha_after=$(sha256sum "$STATE/openclaw.json" 2>/dev/null | cut -d' ' -f1)"

VERDICT=FAIL
if [ "$ARM" = prefix ]; then
  # The shipped, unmodified CLI must fail on this link, and the failure must name it.
  [ "$RC" -ne 0 ] && [ "$ENOTDIR_HITS" -gt 0 ] && [ "$COMPLETED" -eq 0 ] && VERDICT=PASS
  note "expected=prefail observed_exit=$RC enotdir=$ENOTDIR_HITS"
else
  # The reviewed driver must carry the same store through every phase with data intact.
  [ "$RC" -eq 0 ] && [ "$COMPLETED" -gt 0 ] && [ "$ENOTDIR_HITS" -eq 0 ] &&
    [ -n "$(readlink "$PLUGIN_DIR/plugin-link" 2>/dev/null)" ] && VERDICT=PASS
  note "expected=complete observed_exit=$RC completed=$COMPLETED"
fi
note "VERDICT=$VERDICT arm=$ARM"
[ "$VERDICT" = PASS ] || exit 1
