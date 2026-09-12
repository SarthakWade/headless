import { createHash } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const RELEASE_ORIGIN = "https://github.com";
const RELEASE_REPOSITORY = "LockInTime/headless";
const MANIFEST_LIMIT = 256 * 1024;
const ASSET_LIMIT = 512 * 1024 * 1024;
const PROCESS_STDOUT_LIMIT = 1024 * 1024;
const PROCESS_STDERR_LIMIT = 64 * 1024;
const PROCESS_TIMEOUT_MS = 120_000;
const LOCK_WAIT_MS = 30_000;
const LOCK_STALE_MS = 20 * 60_000;
const REDIRECT_LIMIT = 5;
const MANIFEST_TIMEOUT_MS = 30_000;
const ASSET_TIMEOUT_MS = 120_000;
const ALLOWED_DOWNLOAD_HOSTS = new Set([
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
]);
const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

export class InstallError extends Error {
  constructor(message, exitCode = 69, options) {
    super(message, options);
    this.name = "InstallError";
    this.exitCode = exitCode;
  }
}

export class InstallCancelledError extends InstallError {
  constructor(signal) {
    super("Headless installation was cancelled", 75, {
      ...(signal?.reason instanceof Error ? { cause: signal.reason } : {}),
    });
    this.name = "InstallCancelledError";
  }
}

function throwIfCancelled(signal) {
  if (signal?.aborted) throw new InstallCancelledError(signal);
}

function sleep(milliseconds, signal) {
  throwIfCancelled(signal);
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      if (error) rejectPromise(error);
      else resolvePromise();
    };
    const onAbort = () => {
      finish(new InstallCancelledError(signal));
    };
    const timer = setTimeout(() => finish(), milliseconds);
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();
  });
}

function packageRoot() {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

export async function packageVersion() {
  const document = JSON.parse(await readFile(join(packageRoot(), "package.json"), "utf8"));
  if (typeof document.version !== "string" || !SEMVER.test(document.version)) {
    throw new InstallError("the npm package has an invalid product version", 70);
  }
  return document.version;
}

export function platformRelease(version, platform = process.platform, architecture = process.arch) {
  if (!SEMVER.test(version)) throw new InstallError(`invalid product version: ${version}`, 64);
  if (platform === "linux" && architecture === "x64") {
    return {
      asset: `headless-${version}-linux-amd64.tar.gz`,
      kind: "tar.gz",
      executable: "headless",
      hostExecutable: "headless-host",
      mcpExecutable: "headless-mcp",
      brokerExecutable: "headless-credential-broker",
      key: "linux-amd64",
    };
  }
  if (platform === "linux" && architecture === "arm64") {
    return {
      asset: `headless-${version}-linux-arm64.tar.gz`,
      kind: "tar.gz",
      executable: "headless",
      hostExecutable: "headless-host",
      mcpExecutable: "headless-mcp",
      brokerExecutable: "headless-credential-broker",
      key: "linux-arm64",
    };
  }
  if (platform === "darwin" && (architecture === "arm64" || architecture === "x64")) {
    const prefix = "Headless.app/Contents/Resources/bin";
    return {
      asset: `Headless-${version}-macos.zip`,
      kind: "zip",
      executable: `${prefix}/headless`,
      hostExecutable: "Headless.app/Contents/MacOS/Headless",
      mcpExecutable: `${prefix}/headless-mcp`,
      brokerExecutable: `${prefix}/headless-credential-broker`,
      key: `macos-${architecture}`,
    };
  }
  throw new InstallError(
    `Headless does not publish an npm binary for ${platform}/${architecture}. `
      + "Use the GHCR image on Windows, or install a supported macOS/Linux package.",
    69,
  );
}

export function defaultCacheRoot(platform = process.platform, environment = process.env) {
  if (environment.HEADLESS_NPM_CACHE) {
    if (!isAbsolute(environment.HEADLESS_NPM_CACHE)) {
      throw new InstallError("HEADLESS_NPM_CACHE must be an absolute path", 64);
    }
    return resolve(environment.HEADLESS_NPM_CACHE);
  }
  if (platform === "darwin") return join(homedir(), "Library", "Caches", "headless-npm");
  const base = environment.XDG_CACHE_HOME && isAbsolute(environment.XDG_CACHE_HOME)
    ? environment.XDG_CACHE_HOME
    : join(homedir(), ".cache");
  return join(base, "headless-npm");
}

function validateDownloadURL(url, allowedHosts, allowHTTP, allowCustomPort) {
  if (!(url instanceof URL)) throw new InstallError("invalid release URL", 70);
  if (url.username || url.password || (url.port && !allowCustomPort)) {
    throw new InstallError("release URL must not contain credentials or a custom port", 70);
  }
  if (url.protocol !== "https:" && !(allowHTTP && url.protocol === "http:")) {
    throw new InstallError("release downloads require HTTPS", 70);
  }
  if (!allowedHosts.has(url.hostname)) {
    throw new InstallError(`release download redirected to an untrusted host: ${url.hostname}`, 70);
  }
}

async function trustedFetch(url, options) {
  const { allowedHosts, allowHTTP, allowCustomPort, fetchImpl, signal, timeoutMilliseconds } = options;
  let current = new URL(url);
  for (let redirects = 0; redirects <= REDIRECT_LIMIT; redirects += 1) {
    throwIfCancelled(signal);
    validateDownloadURL(current, allowedHosts, allowHTTP, allowCustomPort);
    const timeoutSignal = AbortSignal.timeout(timeoutMilliseconds);
    const requestSignal = signal === undefined
      ? timeoutSignal
      : AbortSignal.any([signal, timeoutSignal]);
    let response;
    try {
      response = await fetchImpl(current, { redirect: "manual", signal: requestSignal });
    } catch (cause) {
      if (signal?.aborted) throw new InstallCancelledError(signal);
      if (timeoutSignal.aborted) {
        throw new InstallError("release download timed out", 69, { cause });
      }
      throw new InstallError("release download failed", 69, { cause });
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        await response.body?.cancel();
        throw new InstallError("release download returned a redirect without a location");
      }
      await response.body?.cancel();
      current = new URL(location, current);
      continue;
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new InstallError(`release download failed with HTTP ${response.status}: ${current}`);
    }
    return response;
  }
  throw new InstallError("release download exceeded the redirect limit");
}

async function boundedText(response, maximumBytes, signal) {
  throwIfCancelled(signal);
  if (response.body === null) throw new InstallError("release manifest response has no body");
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximumBytes) {
    await response.body.cancel();
    throw new InstallError("release manifest is too large");
  }
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of response.body) {
      throwIfCancelled(signal);
      size += chunk.byteLength;
      if (size > maximumBytes) throw new InstallError("release manifest is too large");
      chunks.push(chunk);
    }
  } catch (cause) {
    if (signal?.aborted) throw new InstallCancelledError(signal);
    throw cause;
  }
  throwIfCancelled(signal);
  return Buffer.concat(chunks, size).toString("utf8");
}

export function checksumFromManifest(manifest, asset) {
  const matches = [];
  for (const line of manifest.split("\n")) {
    const match = /^([0-9a-f]{64})  ([^\r\n]+)$/.exec(line);
    if (match && match[2] === asset) matches.push(match[1]);
  }
  if (matches.length !== 1) {
    throw new InstallError(`release manifest must contain exactly one checksum for ${asset}`, 65);
  }
  return matches[0];
}

async function downloadAsset(response, destination, expectedChecksum, signal) {
  throwIfCancelled(signal);
  if (response.body === null) throw new InstallError("release asset response has no body", 65);
  const contentLength = response.headers.get("content-length");
  const declared = contentLength === null ? undefined : Number(contentLength);
  if (declared !== undefined
    && (!Number.isSafeInteger(declared) || declared <= 0 || declared > ASSET_LIMIT)) {
    await response.body.cancel();
    throw new InstallError("release asset has an unsafe size", 65);
  }
  const handle = await open(destination, "wx", 0o600);
  const hash = createHash("sha256");
  let size = 0;
  try {
    for await (const chunk of response.body) {
      throwIfCancelled(signal);
      size += chunk.byteLength;
      if (size > ASSET_LIMIT) throw new InstallError("release asset is too large", 65);
      hash.update(chunk);
      let offset = 0;
      while (offset < chunk.byteLength) {
        throwIfCancelled(signal);
        const { bytesWritten } = await handle.write(
          chunk,
          offset,
          chunk.byteLength - offset,
        );
        if (bytesWritten <= 0) throw new InstallError("release asset write made no progress", 74);
        offset += bytesWritten;
      }
    }
  } catch (cause) {
    if (signal?.aborted) throw new InstallCancelledError(signal);
    throw cause;
  } finally {
    await handle.close();
  }
  throwIfCancelled(signal);
  if (size === 0) throw new InstallError("release asset is empty", 65);
  const actual = hash.digest("hex");
  if (actual !== expectedChecksum) throw new InstallError("release asset checksum mismatch", 65);
}

export function run(command, argumentsList, options = {}) {
  throwIfCancelled(options.signal);
  const timeoutMilliseconds = options.timeoutMilliseconds ?? PROCESS_TIMEOUT_MS;
  if (!Number.isSafeInteger(timeoutMilliseconds)
    || timeoutMilliseconds < 1 || timeoutMilliseconds > PROCESS_TIMEOUT_MS) {
    throw new InstallError(
      `subprocess timeout must be an integer between 1 and ${PROCESS_TIMEOUT_MS}`,
      64,
    );
  }
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, argumentsList, { stdio: options.stdio ?? "pipe" });
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let cancelled = false;
    let outputError;
    let killTimer;
    let timeoutTimer;
    const cleanup = () => {
      options.signal?.removeEventListener("abort", onAbort);
      if (killTimer) clearTimeout(killTimer);
      if (timeoutTimer) clearTimeout(timeoutTimer);
    };
    const terminate = () => {
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 1_000);
      killTimer.unref();
    };
    const onAbort = () => {
      if (cancelled) return;
      cancelled = true;
      terminate();
    };
    const stopForOutput = (stream, maximumBytes) => {
      if (outputError !== undefined) return;
      outputError = new InstallError(
        `${basename(command)} ${stream} exceeded ${maximumBytes} bytes`,
        65,
      );
      terminate();
    };
    options.signal?.addEventListener("abort", onAbort, { once: true });
    if (options.signal?.aborted) onAbort();
    timeoutTimer = setTimeout(() => {
      if (cancelled || outputError !== undefined) return;
      outputError = new InstallError(
        `${basename(command)} timed out after ${timeoutMilliseconds} ms`,
        75,
      );
      terminate();
    }, timeoutMilliseconds);
    timeoutTimer.unref();
    child.stdout?.on("data", (chunk) => {
      stdoutBytes += chunk.byteLength;
      if (stdoutBytes > PROCESS_STDOUT_LIMIT) {
        stopForOutput("stdout", PROCESS_STDOUT_LIMIT);
      } else {
        stdout += chunk;
      }
    });
    child.stderr?.on("data", (chunk) => {
      stderrBytes += chunk.byteLength;
      if (stderrBytes > PROCESS_STDERR_LIMIT) {
        stopForOutput("stderr", PROCESS_STDERR_LIMIT);
      } else {
        stderr += chunk;
      }
    });
    child.on("error", (cause) => {
      cleanup();
      if (cancelled) rejectPromise(new InstallCancelledError(options.signal));
      else rejectPromise(cause);
    });
    child.on("close", (code, signal) => {
      cleanup();
      if (cancelled) rejectPromise(new InstallCancelledError(options.signal));
      else if (outputError) rejectPromise(outputError);
      else if (code === 0) resolvePromise({ stdout, stderr });
      else rejectPromise(new InstallError(
        `${basename(command)} failed${signal ? ` with ${signal}` : ` with status ${code}`}: ${stderr.trim()}`,
        65,
      ));
    });
  });
}

export function validateArchiveEntries(text, kind) {
  const entries = text.split("\n").filter(Boolean);
  if (entries.length === 0 || entries.length > 1_000) {
    throw new InstallError("release archive has an unsafe entry count", 65);
  }
  const seen = new Set();
  for (const entry of entries) {
    const canonical = entry.endsWith("/") ? entry.slice(0, -1) : entry;
    const components = canonical.split("/");
    if (!canonical || entry.includes("\0") || entry.includes("\\") || entry.startsWith("/")
      || /^[A-Za-z]:/.test(entry)
      || components.some((component) => !component || component === "." || component === "..")) {
      throw new InstallError(`release archive contains an unsafe path: ${entry}`, 65);
    }
    if (seen.has(canonical)) throw new InstallError(`release archive contains a duplicate path: ${entry}`, 65);
    seen.add(canonical);
  }
  if (kind === "tar.gz") {
    for (const required of [
      "headless",
      "headless-host",
      "headless-mcp",
      "headless-credential-broker",
      "Headless_HeadlessProtocol.resources/AgentRuntime.js",
    ]) {
      if (!seen.has(required)) throw new InstallError(`release archive is missing ${required}`, 65);
    }
  } else if (kind === "zip") {
    for (const required of [
      "Headless.app/Contents/MacOS/Headless",
      "Headless.app/Contents/Resources/bin/headless",
      "Headless.app/Contents/Resources/bin/headless-mcp",
      "Headless.app/Contents/Resources/bin/headless-credential-broker",
    ]) {
      if (!seen.has(required)) throw new InstallError(`release archive is missing ${required}`, 65);
    }
    if (!entries.every((entry) => entry === "Headless.app" || entry.startsWith("Headless.app/"))) {
      throw new InstallError("release archive contains files outside Headless.app", 65);
    }
  }
  return entries;
}

async function rejectLinks(root, signal) {
  const pending = [root];
  while (pending.length > 0) {
    throwIfCancelled(signal);
    const directory = pending.pop();
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      const metadata = await lstat(path);
      if (metadata.isSymbolicLink()) throw new InstallError(`release archive contains a symbolic link: ${entry.name}`, 65);
      if (metadata.isDirectory()) pending.push(path);
      else if (!metadata.isFile()) throw new InstallError(`release archive contains a non-regular file: ${entry.name}`, 65);
    }
  }
}

async function extractArchive(archive, staging, release, signal) {
  if (release.kind === "tar.gz") {
    const listing = await run("/usr/bin/tar", ["-tzf", archive], { signal });
    validateArchiveEntries(listing.stdout, release.kind);
    await run("/usr/bin/tar", ["-xzf", archive, "-C", staging, "--no-same-owner", "--no-same-permissions"], { signal });
  } else {
    const listing = await run("/usr/bin/unzip", ["-Z1", archive], { signal });
    validateArchiveEntries(listing.stdout, release.kind);
    await run("/usr/bin/unzip", ["-q", archive, "-d", staging], { signal });
  }
  await rejectLinks(staging, signal);
}

async function isUsableInstall(directory, release, version, signal) {
  try {
    throwIfCancelled(signal);
    for (const relative of [
      release.executable, release.hostExecutable, release.mcpExecutable, release.brokerExecutable,
    ]) {
      const metadata = await lstat(join(directory, relative));
      if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    }
    const result = await run(join(directory, release.executable), ["--version"], { signal });
    return result.stdout.trim() === `headless ${version}`;
  } catch (error) {
    if (error instanceof InstallCancelledError) throw error;
    return false;
  }
}

async function acquireLock(lockPath, signal) {
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    throwIfCancelled(signal);
    try {
      await mkdir(lockPath, { mode: 0o700 });
      return;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      try {
        const metadata = await stat(lockPath);
        if (Date.now() - metadata.mtimeMs > LOCK_STALE_MS) {
          await rm(lockPath, { recursive: true });
          continue;
        }
      } catch (statError) {
        if (statError.code !== "ENOENT") throw statError;
      }
      await sleep(100, signal);
    }
  }
  throw new InstallError("timed out waiting for another Headless npm installation", 75);
}

export async function ensureInstalled(options = {}) {
  const signal = options.signal;
  throwIfCancelled(signal);
  const version = options.version ?? await packageVersion();
  const platform = options.platform ?? process.platform;
  const architecture = options.architecture ?? process.arch;
  const release = platformRelease(version, platform, architecture);
  const cacheRoot = resolve(options.cacheRoot ?? defaultCacheRoot(platform));
  const installParent = join(cacheRoot, `v${version}`);
  const installDirectory = join(installParent, release.key);
  const lockPath = `${installDirectory}.lock`;
  await mkdir(installParent, { recursive: true, mode: 0o700 });
  await chmod(cacheRoot, 0o700).catch(() => {});
  await chmod(installParent, 0o700);

  if (await isUsableInstall(installDirectory, release, version, signal)) {
    return { directory: installDirectory, release };
  }

  await acquireLock(lockPath, signal);
  try {
    throwIfCancelled(signal);
    if (await isUsableInstall(installDirectory, release, version, signal)) {
      return { directory: installDirectory, release };
    }
    await rm(installDirectory, { recursive: true, force: true });
    const temporary = await mkdtemp(join(lockPath, "install-"));
    const archive = join(temporary, release.asset);
    const staging = join(temporary, "payload");
    await mkdir(staging, { mode: 0o700 });

    const defaultBase = `${RELEASE_ORIGIN}/${RELEASE_REPOSITORY}/releases/download/v${version}`;
    const baseURL = options.releaseBaseURL ?? defaultBase;
    const allowHTTP = options.allowHTTP === true;
    const allowedHosts = options.allowedHosts ?? ALLOWED_DOWNLOAD_HOSTS;
    const fetchImpl = options.fetchImpl ?? globalThis.fetch;
    const fetchOptions = {
      allowedHosts,
      allowHTTP,
      allowCustomPort: options.allowCustomPort === true,
      fetchImpl,
      signal,
    };
    const manifestResponse = await trustedFetch(`${baseURL}/SHA256SUMS`, {
      ...fetchOptions, timeoutMilliseconds: MANIFEST_TIMEOUT_MS,
    });
    const manifest = await boundedText(manifestResponse, MANIFEST_LIMIT, signal);
    const checksum = checksumFromManifest(manifest, release.asset);
    const assetResponse = await trustedFetch(`${baseURL}/${release.asset}`, {
      ...fetchOptions, timeoutMilliseconds: ASSET_TIMEOUT_MS,
    });
    await downloadAsset(assetResponse, archive, checksum, signal);
    await extractArchive(archive, staging, release, signal);
    throwIfCancelled(signal);
    await chmod(join(staging, release.executable), 0o755);
    await chmod(join(staging, release.hostExecutable), 0o755);
    await chmod(join(staging, release.mcpExecutable), 0o755);
    await chmod(join(staging, release.brokerExecutable), 0o755);
    if (!(await isUsableInstall(staging, release, version, signal))) {
      throw new InstallError("downloaded Headless package failed its version check", 65);
    }
    throwIfCancelled(signal);
    await rename(staging, installDirectory);
    return { directory: installDirectory, release };
  } finally {
    await rm(lockPath, { recursive: true, force: true });
  }
}
