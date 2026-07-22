import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function findVcConfigs(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) findVcConfigs(path, out);
    else if (entry.name === ".vc-config.json") out.push(path);
  }
  return out;
}

// `vercel deploy --prebuilt` reads every filePathMap value (repo-relative
// paths, typically traced node_modules files) from the deploying machine's
// disk, so they must travel in the artifact alongside .vercel/output.
const refs = new Set();
for (const configPath of findVcConfigs(".vercel/output")) {
  const config = JSON.parse(readFileSync(configPath, "utf8"));
  for (const value of Object.values(config.filePathMap ?? {})) {
    if (value.startsWith(".vercel/") || value.split("/").pop().startsWith(".env")) continue;
    refs.add(value);
  }
}

const files = [".vercel/output", ".vercel/project.json", ...refs];
writeFileSync("vercel-prebuilt-files.txt", `${files.join("\n")}\n`);
const result = spawnSync("tar", ["-czhf", "vercel-prebuilt.tgz", "-T", "vercel-prebuilt-files.txt"], {
  stdio: "inherit",
});
if (result.error) fail(result.error.message);
process.exit(result.status ?? 1);
