const token = process.env.GITHUB_TOKEN ?? "";
const repository = process.env.GITHUB_REPOSITORY ?? "";
const ref = process.env.REF ?? "";
const deploymentUrl = process.env.DEPLOYMENT_URL ?? "";
const environment = process.env.ENVIRONMENT ?? "";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (!token || !repository || !ref || !deploymentUrl || !environment) {
  fail("GITHUB_TOKEN, GITHUB_REPOSITORY, REF, DEPLOYMENT_URL, and ENVIRONMENT are required");
}

async function api(path, init = {}) {
  const response = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!response.ok) {
    fail(`GitHub API ${init.method ?? "GET"} ${path} failed with ${response.status}`);
  }
  return response.json();
}

const deployment = await api(`/repos/${repository}/deployments`, {
  method: "POST",
  body: JSON.stringify({
    ref,
    environment,
    auto_merge: false,
    required_contexts: [],
    transient_environment: environment !== "production",
    production_environment: environment === "production",
  }),
});

if (!deployment.id) {
  fail("GitHub did not create a deployment record");
}

await api(`/repos/${repository}/deployments/${deployment.id}/statuses`, {
  method: "POST",
  body: JSON.stringify({
    state: "success",
    environment_url: deploymentUrl,
  }),
});
