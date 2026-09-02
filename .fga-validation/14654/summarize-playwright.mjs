import fs from 'node:fs';
import path from 'node:path';

const ALL_TESTS = Object.freeze([
  'ComboBox',
  'Select',
  'InputCard',
  'InputChip',
  'InputColor',
  'InputDate',
  'InputDateRange',
  'InputMonth',
  'InputNumber',
  'InputYear',
  'InputPhoneInternational',
  'InputTime',
  'InputPhone',
  'Textarea',
  'Input',
]);

const DROPDOWN_TARGETS = new Set([
  'ComboBox',
  'Select',
  'InputDate',
  'InputDateRange',
  'InputMonth',
]);

const [mode, reportPath, outputPath] = process.argv.slice(2);

if (!['before', 'after'].includes(mode) || !reportPath || !outputPath) {
  throw new Error(
    'Usage: node summarize-playwright.mjs <before|after> <report.json> <summary.json>',
  );
}

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const outcomes = collectOutcomes(report.suites || []);
const missing = ALL_TESTS.filter((name) => !outcomes.has(name));

if (missing.length > 0) {
  throw new Error(`Harness did not execute the complete bounded test file: ${missing.join(', ')}`);
}

const unexpected = [...outcomes.keys()].filter((name) => !ALL_TESTS.includes(name));
if (unexpected.length > 0) {
  throw new Error(`Unexpected tests entered the bounded denominator: ${unexpected.join(', ')}`);
}

const controls = ALL_TESTS.filter((name) => !DROPDOWN_TARGETS.has(name));
const failedControls = controls.filter((name) => outcomes.get(name).status !== 'passed');

if (failedControls.length > 0) {
  throw new Error(
    `Harness or unrelated behavior failure: non-target controls did not pass: ${failedControls.join(', ')}`,
  );
}

const targetRows = [...DROPDOWN_TARGETS].map((name) => outcomes.get(name));

if (mode === 'before') {
  const failedTargets = targetRows.filter((row) => row.status === 'failed');
  const invalidTargetStatuses = targetRows.filter(
    (row) => !['passed', 'failed'].includes(row.status),
  );

  if (invalidTargetStatuses.length > 0) {
    throw new Error(
      `BEFORE target execution was incomplete: ${invalidTargetStatuses
        .map((row) => `${row.name}:${row.status}`)
        .join(', ')}`,
    );
  }
  if (failedTargets.length === 0) {
    throw new Error('BEFORE produced no dropdown-reopen failure under the candidate assertions.');
  }

  const wrongFailureSurface = failedTargets.filter(
    (row) => !/tui-dropdown|toBeVisible/i.test(row.errorText),
  );
  if (wrongFailureSurface.length > 0) {
    throw new Error(
      `BEFORE failed outside the added dropdown visibility assertion: ${wrongFailureSurface
        .map((row) => row.name)
        .join(', ')}`,
    );
  }
}

if (mode === 'after') {
  const failed = ALL_TESTS.filter((name) => outcomes.get(name).status !== 'passed');
  if (failed.length > 0) {
    throw new Error(`AFTER did not pass the bounded test file: ${failed.join(', ')}`);
  }
}

const summary = {
  schema: 'fga-taiga-ui-14654-playwright-summary-v1',
  mode: mode.toUpperCase(),
  denominator: ALL_TESTS.length,
  dropdownTargets: [...DROPDOWN_TARGETS],
  controls,
  targetFailures: targetRows
    .filter((row) => row.status === 'failed')
    .map((row) => row.name),
  targetPasses: targetRows
    .filter((row) => row.status === 'passed')
    .map((row) => row.name),
  controlStatus: 'PASS',
  outcomes: Object.fromEntries(
    ALL_TESTS.map((name) => {
      const row = outcomes.get(name);
      return [
        name,
        {
          status: row.status,
          errorText: row.errorText.slice(0, 500),
        },
      ];
    }),
  ),
  status: 'INFERRED',
  requiresHumanConfirm: true,
  finalVerifierEligible: false,
  canClaimVerifiedFixed: false,
};

fs.mkdirSync(path.dirname(outputPath), {recursive: true});
fs.writeFileSync(outputPath, `${JSON.stringify(summary, null, 2)}\n`);

function collectOutcomes(suites, parents = [], result = new Map()) {
  for (const suite of suites) {
    const suitePath = [...parents, suite.title].filter(Boolean);

    for (const spec of suite.specs || []) {
      if (result.has(spec.title)) {
        throw new Error(`Duplicate test title in bounded report: ${spec.title}`);
      }

      const testResults = (spec.tests || []).flatMap((testCase) => testCase.results || []);
      const latest = testResults.at(-1);
      const errorText = [
        latest?.error?.message,
        ...(latest?.errors || []).map((error) => error?.message),
      ]
        .filter(Boolean)
        .join('\n');

      result.set(spec.title, {
        name: spec.title,
        title: [...suitePath, spec.title].join(' > '),
        status: latest?.status || 'missing',
        errorText,
      });
    }

    collectOutcomes(suite.suites || [], suitePath, result);
  }

  return result;
}
