// tests/fixtures/ci-failure-alert-harness.js — AXI-2282 (FR8/AC5).
// Executes the REAL `script:` body of .github/workflows/ci-failure-alert.yml
// (extracted by tests/ci-failure-alert-workflow.bats) the way
// actions/github-script does — as an async function of (github, context) —
// against an in-memory issue tracker. No network: `github` is a mock and
// SLACK_WEBHOOK_URL is unset, so the Slack half takes its no-op branch.
//
// Usage: node ci-failure-alert-harness.js <script-file> <scenario.json>
// scenario = { run: {name, conclusion, head_sha, html_url}, issues: [{number, title}] }
// Prints the recorded issue API calls as JSON on stdout.
'use strict';
const fs = require('fs');

const [scriptPath, scenarioPath] = process.argv.slice(2);
const script = fs.readFileSync(scriptPath, 'utf8');
const scenario = JSON.parse(fs.readFileSync(scenarioPath, 'utf8'));
const calls = [];
const record = (op) => async (args) => {
  const { owner, repo, ...rest } = args;
  calls.push({ op, ...rest });
  if (op === 'listForRepo') return { data: scenario.issues };
  return { data: {} };
};
const github = {
  rest: {
    issues: {
      getLabel: record('getLabel'),
      createLabel: record('createLabel'),
      listForRepo: record('listForRepo'),
      create: record('create'),
      createComment: record('createComment'),
      update: record('update'),
    },
  },
};
const context = { repo: { owner: 'o', repo: 'axiome-infra' }, payload: { workflow_run: scenario.run } };

delete process.env.SLACK_WEBHOOK_URL;
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const silenced = console.log;
console.log = () => {};
new AsyncFunction('github', 'context', script)(github, context)
  .then(() => {
    console.log = silenced;
    process.stdout.write(JSON.stringify(calls.filter((c) => !['getLabel', 'listForRepo'].includes(c.op))));
  })
  .catch((err) => {
    console.log = silenced;
    process.stderr.write(String(err && err.stack));
    process.exit(1);
  });
