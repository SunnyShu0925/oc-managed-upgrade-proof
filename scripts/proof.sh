#!/usr/bin/env bash
# Published-driver (npm 2026.10.8) to reviewed-candidate managed upgrade proof.
# Everything runs on a GitHub-hosted Ubuntu VM with a real systemd user manager.
set -uo pipefail

STABLE="${STABLE_VERSION:-2026.10.8}"
CANDIDATE="${CANDIDATE_VERSION:-2026.10.9}"
PORT=18799
TOKEN="$(openssl rand -hex 16)"
SUMMARY=/tmp/proof-summary.txt
: >"$SUMMARY"

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUMMARY"; }

say "environment"
{
  uname -a
  systemctl --version | head -1
  echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
  systemctl --user is-system-running || true
  git -C "$PWD" rev-parse HEAD
  git -C "$PWD" log -1 --format='%H %s'
} 2>&1 | tee -a "$SUMMARY"

say "install published stable driver $STABLE"
npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -5
PUBLISHED_BIN="$HOME/.npm-global/bin/openclaw"
"$PUBLISHED_BIN" --version | tee -a "$SUMMARY"

say "pack reviewed candidate $CANDIDATE from this head"
mkdir -p "$RUNNER_TEMP/pkg"
MANIFEST="$RUNNER_TEMP/pkg/candidate-manifest.json"
CANDIDATE_VERSION="$CANDIDATE" MANIFEST="$MANIFEST" node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync("package.json", "utf8"));
manifest.version = process.env.CANDIDATE_VERSION;
fs.writeFileSync(process.env.MANIFEST, JSON.stringify(manifest, null, 2));
fs.writeFileSync("package.json", JSON.stringify(manifest, null, 2) + "\n");
'
npm pack --pack-destination "$RUNNER_TEMP/pkg" 2>&1 | tail -3
TARBALL="$(ls "$RUNNER_TEMP/pkg"/openclaw-*.tgz | head -1)"
git checkout -- package.json
note "candidate tarball: $TARBALL ($(stat -c%s "$TARBALL") bytes)"
tar -xzOf "$TARBALL" package/dist/update-managed-service-handoff-current-*.mjs \
  | grep -o 'scheduleAbsoluteDeadline(performance.now() + timeoutMs[^;]*' | head -1 | tee -a "$SUMMARY"

say "start loopback registry for the candidate"
PROOF_REGISTRY_PORT=48761 \
PROOF_TARBALL="$TARBALL" \
PROOF_CANDIDATE_VERSION="$CANDIDATE" \
PROOF_BASE_VERSION="$STABLE" \
PROOF_CANDIDATE_MANIFEST="$MANIFEST" \
PROOF_REGISTRY_LOG=/tmp/registry.log \
  node "$GITHUB_WORKSPACE/scripts/registry-proxy.mjs" >/tmp/registry.out 2>&1 &
for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://127.0.0.1:48761/openclaw && break
  sleep 1
done
curl -s http://127.0.0.1:48761/openclaw | CANDIDATE_VERSION="$CANDIDATE" node -e '
let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
  const doc = JSON.parse(raw);
  const entry = doc.versions[process.env.CANDIDATE_VERSION];
  console.log(`registry latest=${doc["dist-tags"].latest} tarball=${entry?.dist?.tarball}`);
});
' | tee -a "$SUMMARY"

say "seed operator state (config, workspace marker, cron job)"
mkdir -p "$HOME/.openclaw/workspace"
cat >"$HOME/.openclaw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "loopback", "port": $PORT, "auth": { "mode": "token", "token": "$TOKEN" } },
  "agents": { "defaults": { "workspace": "$HOME/.openclaw/workspace" }, "entries": { "main": {} } },
  "logging": { "level": "info" }
}
JSON
chmod 600 "$HOME/.openclaw/openclaw.json"
echo "proof-data-marker-2026-10-28" >"$HOME/.openclaw/workspace/PROOF_MARKER.txt"

say "install and start the managed gateway service"
"$PUBLISHED_BIN" gateway install --port "$PORT" --token "$TOKEN" --json 2>&1 | tail -6
for _ in $(seq 1 60); do
  "$PUBLISHED_BIN" gateway status --json >/tmp/gateway-status.json 2>/dev/null || true
  node -e '
const s = require("/tmp/gateway-status.json");
process.exit(s?.service?.runtime?.status === "running" ? 0 : 1);
' 2>/dev/null && break
  sleep 2
done
node -e '
const s = require("/tmp/gateway-status.json");
console.log(`service status=${s?.service?.runtime?.status} managerUid=${s?.service?.runtime?.systemd?.managerUid} unit=${s?.service?.runtime?.systemd?.unit}`);
' | tee -a "$SUMMARY"

say "seed a cron job through the shipped CLI"
"$PUBLISHED_BIN" cron add --every 1d --agent main --message "proof turn" \
  --display-name proof-job --json 2>&1 | tail -4
"$PUBLISHED_BIN" cron list --json >/tmp/cron-before.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-before.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
console.log(`cron before: ${list.length} job(s) ${list.map((job) => job.name ?? job.id).join(",")}`);
' | tee -a "$SUMMARY"
sha256sum "$HOME/.openclaw/openclaw.json" "$HOME/.openclaw/workspace/PROOF_MARKER.txt" | tee -a "$SUMMARY"

say "run the published-driver -> candidate managed upgrade"
UPDATE_RC=0
npm_config_registry=http://127.0.0.1:48761/ \
OPENCLAW_UPDATE_PACKAGE_SPEC=openclaw \
  "$PUBLISHED_BIN" update --yes --json --timeout 1200 >/tmp/update.json 2>/tmp/update.err || UPDATE_RC=$?
note "update exit=$UPDATE_RC"
tail -30 /tmp/update.err
node -e '
const raw = require("node:fs").readFileSync("/tmp/update.json", "utf8");
const body = JSON.parse(raw);
const steps = (body.run?.steps ?? body.steps ?? []).map((step) => `${step.step ?? step.name}:${step.status}`);
console.log(`update status=${body.status ?? body.run?.status} reason=${body.reason ?? body.run?.reason ?? ""}`);
console.log(`update phase=${body.run?.phase} steps=${steps.join(" -> ")}`);
console.log(`target=${body.tag ?? ""} from=${body.currentVersion ?? ""} to=${body.targetVersion ?? ""}`);
' | tee -a "$SUMMARY"

say "verify the candidate is installed and operator data survived"
INSTALLED="$("$PUBLISHED_BIN" --version 2>&1)"
echo "openclaw --version: $INSTALLED"
note "post-update version: $INSTALLED"
"$PUBLISHED_BIN" cron list --json >/tmp/cron-after.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-after.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
const hit = list.find((job) => (job.name ?? job.displayName ?? job.id ?? "").includes("proof-job"));
console.log(`cron after: ${list.length} job(s) proof-job=${hit ? "present" : "MISSING"}`);
process.exit(hit ? 0 : 1);
' | tee -a "$SUMMARY"
CRON_RC=${PIPESTATUS[0]}
node -e '
const config = require(process.env.HOME + "/.openclaw/openclaw.json");
console.log(`config gateway.port=${config.gateway?.port} workspace=${config.agents?.defaults?.workspace}`);
process.exit(config.gateway?.port === 18799 ? 0 : 1);
' | tee -a "$SUMMARY"
CONFIG_RC=${PIPESTATUS[0]}
echo "workspace marker: $(cat "$HOME/.openclaw/workspace/PROOF_MARKER.txt")" | tee -a "$SUMMARY"
"$PUBLISHED_BIN" gateway status --json >/tmp/gateway-status-after.json 2>/dev/null || true
node -e '
const s = require("/tmp/gateway-status-after.json");
console.log(`service after=${s?.service?.runtime?.status} version=${s?.service?.runtime?.version ?? "n/a"} pid=${s?.service?.runtime?.pid ?? "n/a"}`);
' | tee -a "$SUMMARY"

say "verdict"
VERDICT="FAIL"
case "$INSTALLED" in
  *"$CANDIDATE"*) VERSION_OK=yes ;;
  *) VERSION_OK=no ;;
esac
[ "$UPDATE_RC" -eq 0 ] && [ "$VERSION_OK" = yes ] && [ "$CRON_RC" -eq 0 ] && [ "$CONFIG_RC" -eq 0 ] && VERDICT="PASS"
note "VERDICT=$VERDICT updateExit=$UPDATE_RC installedCandidate=$VERSION_OK cronIntact=$([ "$CRON_RC" -eq 0 ] && echo yes || echo no) configIntact=$([ "$CONFIG_RC" -eq 0 ] && echo yes || echo no)"

if [ "$VERDICT" != "PASS" ]; then
  exit 1
fi
