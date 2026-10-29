// Preloaded into every Node process the managed-service update path runs
// (`Environment=NODE_OPTIONS=--require=...`), so it also reaches the sealed
// handoff helper and the update child that the installed driver spawns.
//
// It applies one wall-clock correction at the boundary this PR changes:
//   pre-fix helper  -> deadline = Date.now() + timeout, then `deadline - Date.now()`
//                      once per command: the step resizes every command budget.
//   post-fix helper -> `monotonicDeadlineFromWallClock` converts the epoch once
//                      onto performance.now(); the step cannot resize anything
//                      after that conversion.
// `Date.now()` moves by offsetMs; `performance.now()` never moves.
//
// The step is armed from the deadline seed/translation call itself (call-stack
// match) for fixed revisions, and from helper/child startup for pre-fix
// revisions where the deadline is re-read from the wall clock every time.
"use strict";
const fs = require("node:fs");

const ARG0 = process.argv[1] || "";
const ROLE = /handoff\.cjs$/i.test(ARG0)
  ? "helper"
  : /index\.js$/i.test(ARG0)
    ? process.argv[2] === "gateway"
      ? "gateway"
      : "cli"
    : "other";
const LOG = process.env.PROOF_CLOCK_LOG || "/tmp/clock-step.log";
const OFFSET_MS = Number(process.env.PROOF_CLOCK_OFFSET_MS || "0");
const REV = (process.env.PROOF_CLOCK_REV || "head").toLowerCase();
const ARM_DELAY_MS = Number(process.env.PROOF_ARM_DELAY_MS || "300");
// When the step lands: at process start, when the helper spawns the update
// child (activation begins), or when the helper dispatches the service stop.
const ARM_ON = (process.env.PROOF_CLOCK_ARM_ON || "startup").toLowerCase();
const realNow = Date.now;

let armed = false;
let armedSite = "";

function log(line) {
  try {
    fs.appendFileSync(
      LOG,
      `${new Date(realNow()).toISOString()} pid=${process.pid} role=${ROLE} ${line}\n`,
    );
  } catch {}
}

function arm(site) {
  if (armed) return;
  armed = true;
  armedSite = site;
  log(`armed site=${site} offsetMs=${OFFSET_MS} revision=${REV}`);
}

// Only the processes that receive the already-seeded handoff deadline may step.
// The Gateway seeds it, so stepping the Gateway would move the seed with it.
if (ROLE === "helper" || ROLE === "cli") {
  log(
    `loaded script=${ARG0} argv=${process.argv.slice(2, 5).join(" ")} offsetMs=${OFFSET_MS} revision=${REV} wallNow=${realNow()} monoNow=${performance.now().toFixed(1)}`,
  );

  if (ARM_ON === "startup" && REV !== "head") {
    // Pre-fix revisions keep the raw wall-clock epoch and re-read it per command,
    // so the step only has to land before the first activation command.
    setTimeout(() => arm("startup"), ARM_DELAY_MS).unref?.();
  }

  const SEED_SITE = /monotonicDeadlineFromWallClock|armActivationDeadline|activateTransferredGateway/;
  Date.now = function steppableDateNow() {
    if (!armed && REV === "head") {
      const stack = new Error().stack || "";
      if (SEED_SITE.test(stack)) {
        // This call translates the cross-process epoch, so it must observe the
        // true clock; the step applies from the next read on.
        arm("deadline-translation");
        return realNow();
      }
    }
    return armed ? realNow() + OFFSET_MS : realNow();
  };

  // Record the subprocess budget the changed code hands to Node's monotonic
  // timeout without mutating it. This is the observable the two revisions differ on.
  const { ChildProcess } = require("node:child_process");
  for (const name of ["spawn", "spawnSync"]) {
    const original = ChildProcess.prototype[name];
    if (typeof original !== "function") continue;
    ChildProcess.prototype[name] = function patched(options) {
      try {
        const file = options?.file;
        const args = Array.isArray(options?.args) ? options.args : [];
        const nodeBinary = /(^|[\\/])node$/.test(String(file ?? ""));
        const spawnsUpdateChild =
          ROLE === "helper" &&
          nodeBinary &&
          args.some((arg) => /dist[\\/]index\.js$/.test(String(arg))) &&
          args.includes("update");
        const stopsService = ROLE === "helper" && file === "systemctl" && args.includes("stop");
        if (!armed && ARM_ON === "owned-command" && spawnsUpdateChild) arm("owned-command");
        if (!armed && ARM_ON === "service-stop" && stopsService) arm("service-stop");
        const interesting =
          file === "systemctl" ||
          file === "systemd-run" ||
          file === "launchctl" ||
          file === "schtasks" ||
          /handoff\.cjs$/.test(String(args[0] ?? "")) ||
          nodeBinary;
        if (interesting) {
          const shown = args.map((arg) => String(arg).slice(0, 120)).join(" ");
          log(
            `dispatch file=${file} args=${shown} timeoutMs=${options?.timeout}` +
              ` armed=${armed} site=${armedSite || "none"} monoNow=${performance.now().toFixed(1)} wallNow=${realNow()}`,
          );
        }
      } catch {}
      return original.call(this, options);
    };
  }
}
