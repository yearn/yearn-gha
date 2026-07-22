import { spawnSync } from "node:child_process";

const opEnv = process.env.OP_ENV ?? "";
const environment = process.env.ENVIRONMENT ?? "";

// The op:// references written to GITHUB_ENV for the 1Password step persist
// in the job env; delete those keys so the build can only see the real
// values `vercel pull` wrote to .vercel/.env.<target>.local.
const env = { ...process.env };
for (const rawLine of opEnv.split("\n")) {
  const line = rawLine.replaceAll("\r", "");
  if (!line.trim() || line.trimStart().startsWith("#")) continue;
  const key = line.split("=")[0].replace(/\s/g, "");
  if (key) delete env[key];
}

const args = ["build"];
if (environment === "production") args.push("--prod");
const result = spawnSync("vercel", args, { stdio: "inherit", env });
process.exit(result.status ?? 1);
