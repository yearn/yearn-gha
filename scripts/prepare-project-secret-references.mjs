import { appendFileSync } from "node:fs";

const opEnv = process.env.OP_ENV ?? "";
const vault = process.env.VAULT ?? "";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

appendFileSync(
  process.env.GITHUB_OUTPUT,
  `vercel-project-id=op://${vault}/VERCEL_PROJECT_ID/VERCEL_PROJECT_ID\n`,
);

const envLines = [];
for (const rawLine of opEnv.split("\n")) {
  const line = rawLine.replaceAll("\r", "");
  if (!line.trim() || line.trimStart().startsWith("#")) continue;
  const separatorIndex = line.indexOf("=");
  if (separatorIndex === -1) {
    fail(`Invalid secrets entry (expected KEY=item/field or op://...): ${line}`);
  }
  const key = line.slice(0, separatorIndex).replace(/\s/g, "");
  const reference = line.slice(separatorIndex + 1);
  if (!key || !reference) {
    fail(`Invalid secrets entry (expected KEY=item/field or op://...): ${line}`);
  }
  envLines.push(
    reference.startsWith("op://") ? `${key}=${reference}` : `${key}=op://${vault}/${reference}`,
  );
}
appendFileSync(process.env.GITHUB_ENV, envLines.map((entry) => `${entry}\n`).join(""));
