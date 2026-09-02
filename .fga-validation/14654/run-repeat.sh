#!/usr/bin/env bash
set -Eeuo pipefail

REPEAT_INDEX="${1:?repeat index required}"
ROOT="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE required}"
RUNNER_DIR="$ROOT/runner"
TAIGA_DIR="$ROOT/taiga-ui"
PACKET_DIR="$RUNNER_DIR/.fga-validation/14654"
OUT="$ROOT/repeat-receipt"
UPSTREAM_SHA="4d72ec26c4d353af3de01a9e17a35c87a91744a6"
PATCH_PATH="$PACKET_DIR/taiga-ui-14654.patch"
PATCH_DIGEST_PATH="$PACKET_DIR/taiga-ui-14654.patch.sha256"
CONTRACT_MODEL="$PACKET_DIR/contract-model.test.mjs"
SUMMARY_SCRIPT="$PACKET_DIR/summarize-playwright.mjs"
PORT="3333"
DEMO_DIR="dist/demo/browser"
PHASE="INITIALIZING"
DECISION="NOT_EVALUATED"
BASELINE_EXIT="-1"
CANDIDATE_EXIT="-1"
SERVER_PID=""

mkdir -p "$OUT"

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

emit_receipt() {
  local script_exit="$?"
  stop_server
  export REPEAT_INDEX UPSTREAM_SHA PHASE DECISION BASELINE_EXIT CANDIDATE_EXIT SCRIPT_EXIT="$script_exit" OUT ROOT
  node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = process.env.ROOT;
const out = process.env.OUT;
const readJson = (name) => {
  const file = path.join(root, name);
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
};
const sha = (name) => {
  const file = path.join(root, name);
  return fs.existsSync(file)
    ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
    : '';
};
const before = readJson('baseline-summary.json');
const after = readJson('candidate-summary.json');
const receipt = {
  schema: 'fga-taiga-ui-14654-repeat-replay-v1',
  repeatIndex: Number(process.env.REPEAT_INDEX),
  workflowRunId: process.env.GITHUB_RUN_ID || '',
  workflowRunAttempt: Number(process.env.GITHUB_RUN_ATTEMPT || 0),
  validationCommit: process.env.GITHUB_SHA || '',
  upstreamSha: process.env.UPSTREAM_SHA,
  patchSha256: process.env.PATCH_SHA256 || '',
  terminalPhase: process.env.PHASE,
  scriptExitCode: Number(process.env.SCRIPT_EXIT),
  environment: {
    runner: process.env.RUNNER_OS || '',
    image: process.env.ImageOS || '',
    node: process.version,
    npm: process.env.NPM_VERSION || '',
    playwright: process.env.PLAYWRIGHT_VERSION || '',
    chromium: 'playwright-managed',
    workers: 1,
    retries: 0,
  },
  before: {
    exitCode: Number(process.env.BASELINE_EXIT),
    summary: before,
    reportSha256: sha('baseline-report.json'),
  },
  after: {
    exitCode: Number(process.env.CANDIDATE_EXIT),
    summary: after,
    reportSha256: sha('candidate-report.json'),
  },
  decision: process.env.DECISION,
  status: 'INFERRED',
  scoreable: false,
  requiresHumanConfirm: true,
  finalVerifierEligible: false,
  canClaimVerifiedFixed: false,
  canClaimVerifiedOutcome: false,
  canClaimVerifiedValue: false,
  claimBoundary: 'Public repeat replay only. Sandbox admission, independent contract, blind annotation, maintainer acceptance, release, deployment, outcome and VERIFIED_FIXED remain unestablished.',
};
fs.writeFileSync(path.join(out, 'receipt.json'), `${JSON.stringify(receipt, null, 2)}\n`);
NODE

  for file in \
    identity.txt \
    baseline-summary.json baseline-report.json baseline-playwright.log baseline-server.log \
    candidate-summary.json candidate-report.json candidate-playwright.log candidate-server.log; do
    [[ -f "$ROOT/$file" ]] && cp "$ROOT/$file" "$OUT/$file"
  done
  (cd "$OUT" && sha256sum * > MANIFEST.sha256)
  return "$script_exit"
}
trap emit_receipt EXIT
trap 'PHASE="ERROR:${PHASE}"' ERR

PHASE="VERIFY_IDENTITIES"
actual_upstream="$(git -C "$TAIGA_DIR" rev-parse HEAD)"
actual_patch="$(sha256sum "$PATCH_PATH" | awk '{print $1}')"
expected_patch="$(tr -d '[:space:]' < "$PATCH_DIGEST_PATH")"
[[ "$actual_upstream" == "$UPSTREAM_SHA" ]]
[[ "$actual_patch" == "$expected_patch" ]]
git -C "$TAIGA_DIR" apply --check --verbose "$PATCH_PATH"
node "$CONTRACT_MODEL"
export PATCH_SHA256="$actual_patch"
export NPM_VERSION="$(npm --version)"
{
  echo "repeat=$REPEAT_INDEX"
  echo "workflow_run=${GITHUB_RUN_ID:-}"
  echo "workflow_attempt=${GITHUB_RUN_ATTEMPT:-}"
  echo "validation_commit=${GITHUB_SHA:-}"
  echo "upstream=$actual_upstream"
  echo "patch_sha256=$actual_patch"
  echo "node=$(node --version)"
  echo "npm=$NPM_VERSION"
} | tee "$ROOT/identity.txt"

PHASE="INSTALL"
cd "$TAIGA_DIR"
npm ci
npx playwright install --with-deps chromium
export PLAYWRIGHT_VERSION="$(npx playwright --version)"

PHASE="BASELINE_PREPARE"
git reset --hard "$UPSTREAM_SHA"
git clean -fd
git apply "$PATCH_PATH"
git checkout "$UPSTREAM_SHA" -- \
  projects/core/components/textfield/textfield.component.ts \
  projects/core/components/textfield/textfield.template.html
npx nx type-check demo-playwright
npx nx build demo
[[ -f "$DEMO_DIR/index.html" ]]

PHASE="BASELINE_SERVE"
npx --yes --package=local-web-server@5.4.0 ws \
  --port "$PORT" --directory "$DEMO_DIR" --spa index.html \
  > "$ROOT/baseline-server.log" 2>&1 &
SERVER_PID=$!
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:${PORT}/" >/dev/null; then
    break
  fi
  if [[ "$attempt" == "60" ]]; then
    cat "$ROOT/baseline-server.log"
    exit 1
  fi
  sleep 1
done

PHASE="BASELINE_REPLAY"
set +e
PLAYWRIGHT_JSON_OUTPUT_NAME="$ROOT/baseline-report.json" \
  npx playwright test \
    --config projects/demo-playwright/playwright.config.ts \
    --project chromium --workers 1 --retries 0 --reporter json \
    projects/demo-playwright/tests/core/input/textfield-cleaner.pw.spec.ts \
    > "$ROOT/baseline-playwright.log" 2>&1
BASELINE_EXIT="$?"
set -e
[[ "$BASELINE_EXIT" != "0" ]]
node "$SUMMARY_SCRIPT" before "$ROOT/baseline-report.json" "$ROOT/baseline-summary.json"
stop_server

PHASE="CANDIDATE_PREPARE"
git reset --hard "$UPSTREAM_SHA"
git clean -fd
git apply "$PATCH_PATH"
npx prettier --check \
  projects/core/components/textfield/textfield.component.ts \
  projects/core/components/textfield/textfield.template.html \
  projects/demo-playwright/tests/core/input/textfield-cleaner.pw.spec.ts
npx eslint \
  projects/core/components/textfield/textfield.component.ts \
  projects/demo-playwright/tests/core/input/textfield-cleaner.pw.spec.ts
npx nx type-check demo-playwright
npx nx build core
npx nx build demo
[[ -f "$DEMO_DIR/index.html" ]]

PHASE="CANDIDATE_SERVE"
npx --yes --package=local-web-server@5.4.0 ws \
  --port "$PORT" --directory "$DEMO_DIR" --spa index.html \
  > "$ROOT/candidate-server.log" 2>&1 &
SERVER_PID=$!
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:${PORT}/" >/dev/null; then
    break
  fi
  if [[ "$attempt" == "60" ]]; then
    cat "$ROOT/candidate-server.log"
    exit 1
  fi
  sleep 1
done

PHASE="CANDIDATE_REPLAY"
set +e
PLAYWRIGHT_JSON_OUTPUT_NAME="$ROOT/candidate-report.json" \
  npx playwright test \
    --config projects/demo-playwright/playwright.config.ts \
    --project chromium --workers 1 --retries 0 --reporter json \
    projects/demo-playwright/tests/core/input/textfield-cleaner.pw.spec.ts \
    > "$ROOT/candidate-playwright.log" 2>&1
CANDIDATE_EXIT="$?"
set -e
[[ "$CANDIDATE_EXIT" == "0" ]]
node "$SUMMARY_SCRIPT" after "$ROOT/candidate-report.json" "$ROOT/candidate-summary.json"
stop_server

PHASE="COMPLETE"
DECISION="CANDIDATE_SAME_CONDITION_REPEAT_PASS"
