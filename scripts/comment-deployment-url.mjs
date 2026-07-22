const token = process.env.GITHUB_TOKEN ?? "";
const repository = process.env.GITHUB_REPOSITORY ?? "";
const prNumber = process.env.PR_NUMBER ?? "";
const deploymentUrl = process.env.DEPLOYMENT_URL ?? "";
const environment = process.env.ENVIRONMENT ?? "";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (!token || !repository || !prNumber || !deploymentUrl) {
  fail("GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, and DEPLOYMENT_URL are required");
}

const marker = "<!-- yearn-gha/vercel-deploy -->";
const body = `${marker}\nVercel ${environment} deployment: ${deploymentUrl}`;

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

let existing;
for (let page = 1; ; page++) {
  const comments = await api(
    `/repos/${repository}/issues/${prNumber}/comments?per_page=100&page=${page}`,
  );
  existing = comments.find((comment) => comment.body?.startsWith(marker));
  if (existing || comments.length < 100) break;
}
if (existing) {
  await api(`/repos/${repository}/issues/comments/${existing.id}`, {
    method: "PATCH",
    body: JSON.stringify({ body }),
  });
} else {
  await api(`/repos/${repository}/issues/${prNumber}/comments`, {
    method: "POST",
    body: JSON.stringify({ body }),
  });
}
