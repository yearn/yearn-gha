const environment = process.env.ENVIRONMENT ?? "";
const vault = process.env.VAULT ?? "";

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (environment !== "preview" && environment !== "production") {
  fail("environment must be preview or production");
}

if (!vault) {
  fail("vault must name a project-specific vault");
}

if (!vault.startsWith("webops-prod-") || vault === "webops-prod-shared") {
  fail("vault must name a project vault in the form webops-prod-<project>");
}
