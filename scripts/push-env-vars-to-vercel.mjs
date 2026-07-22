const opEnv = process.env.OP_ENV ?? "";
const environment = process.env.ENVIRONMENT ?? "";
const vercelToken = process.env.VERCEL_TOKEN ?? "";
const orgId = process.env.VERCEL_ORG_ID ?? "";
const projectId = process.env.VERCEL_PROJECT_ID ?? "";
const secrets = JSON.parse(process.env.SECRETS_JSON ?? "{}");

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

const vercelCredentialKeys = new Set(["VERCEL_PROJECT_ID", "VERCEL_TOKEN", "VERCEL_ORG_ID"]);

async function api(path, { method = "GET", body, query = {} } = {}) {
  const url = new URL(`https://api.vercel.com${path}`);
  if (orgId.startsWith("team_")) url.searchParams.set("teamId", orgId);
  for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
  const response = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${vercelToken}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    fail(`Vercel API ${method} ${path} failed with ${response.status}`);
  }
  return response.json();
}

const { envs } = await api(`/v10/projects/${projectId}/env`);
const inTarget = (envs ?? []).filter((env) => env.target?.includes(environment));

// A var that also targets another environment or a specific git branch was
// configured outside this workflow; deleting it would destroy that config,
// so refuse and make the operator migrate it deliberately.
const unsafe = inTarget.filter((env) => env.target.length > 1 || env.gitBranch);
if (unsafe.length > 0) {
  fail(
    `Refusing to sync ${environment}: ${unsafe.map((env) => env.key).join(", ")} ` +
      "also targets another environment or a specific git branch; migrate it manually first",
  );
}

for (const env of inTarget) {
  await api(`/v9/projects/${projectId}/env/${env.id}`, { method: "DELETE" });
  console.log(`Removed ${env.key} from ${environment}`);
}

for (const rawLine of opEnv.split("\n")) {
  const line = rawLine.replaceAll("\r", "");
  if (!line.trim() || line.trimStart().startsWith("#")) continue;
  const key = line.split("=")[0].replace(/\s/g, "");
  if (vercelCredentialKeys.has(key)) continue;
  const value = secrets[key];
  if (value === undefined) {
    fail(`Secret ${key} was not loaded from 1Password`);
  }
  await api(`/v10/projects/${projectId}/env`, {
    method: "POST",
    query: { upsert: "true" },
    body: { key, value, type: "sensitive", target: [environment] },
  });
  console.log(`Added ${key} to ${environment} as sensitive`);
}
