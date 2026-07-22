import { spawnSync } from "node:child_process";

const opEnv = process.env.OP_ENV ?? "";
const environment = process.env.ENVIRONMENT ?? "";
const vercelToken = process.env.VERCEL_TOKEN ?? "";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

const vercelCredentialKeys = new Set(["VERCEL_PROJECT_ID", "VERCEL_TOKEN", "VERCEL_ORG_ID"]);

const listResult = spawnSync("vercel", ["env", "ls", environment, `--token=${vercelToken}`], {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "inherit"],
});
if (listResult.status !== 0) {
  fail(`Failed to list Vercel env vars for ${environment}`);
}
const existingKeys = listResult.stdout
  .split("\n")
  .map((line) => line.trim().split(/\s+/)[0])
  .filter((key) => key && key !== "name" && !key.startsWith(">"));

for (const key of existingKeys) {
  const result = spawnSync(
    "vercel",
    ["env", "rm", key, environment, "--yes", `--token=${vercelToken}`],
    { stdio: ["ignore", "inherit", "inherit"] },
  );
  if (result.status !== 0) {
    fail(`Failed to remove ${key} from Vercel`);
  }
}

for (const rawLine of opEnv.split("\n")) {
  const line = rawLine.replaceAll("\r", "");
  if (!line.trim() || line.trimStart().startsWith("#")) continue;
  const key = line.split("=")[0].replace(/\s/g, "");
  if (vercelCredentialKeys.has(key)) continue;
  const value = process.env[key];
  if (value === undefined) {
    fail(`Secret ${key} was not loaded into the environment`);
  }
  const result = spawnSync(
    "vercel",
    ["env", "add", key, environment, "--sensitive", "--force", `--token=${vercelToken}`],
    { input: value, stdio: ["pipe", "inherit", "inherit"] },
  );
  if (result.status !== 0) {
    fail(`Failed to push ${key} to Vercel`);
  }
}
