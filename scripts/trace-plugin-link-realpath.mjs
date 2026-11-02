// Diagnostics helper: name the shipped call site that resolves a plugin link.
// Injected with NODE_OPTIONS=--import so it also applies to the snapshot child process.
import fs from "node:fs";
import fsp from "node:fs/promises";

const interested = (target) => String(target).endsWith("plugin-link");
const report = (kind, target) => {
  process.stderr.write(`[realpath-trace] ${kind} ${target}\n${new Error("trace").stack}\n`);
};

const promisesRealpath = fsp.realpath;
fsp.realpath = async function (target, ...rest) {
  if (interested(target)) {
    report("fs/promises.realpath", target);
  }
  return promisesRealpath.call(this, target, ...rest);
};
const fsPromisesRealpath = fs.promises.realpath;
fs.promises.realpath = async function (target, ...rest) {
  if (interested(target)) {
    report("fs.promises.realpath", target);
  }
  return fsPromisesRealpath.call(this, target, ...rest);
};
const syncRealpath = fs.realpathSync;
fs.realpathSync = function (target, ...rest) {
  if (interested(target)) {
    report("fs.realpathSync", target);
  }
  return syncRealpath.call(this, target, ...rest);
};
const nativeRealpath = fs.realpathSync.native;
fs.realpathSync.native = function (target, ...rest) {
  if (interested(target)) {
    report("fs.realpathSync.native", target);
  }
  return nativeRealpath.call(this, target, ...rest);
};
