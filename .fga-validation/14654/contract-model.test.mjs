import assert from 'node:assert/strict';
import test from 'node:test';

function replayCleanerClick({editable, hasDropdown, initiallyOpen = false}) {
  let value = '09.09.2025';
  let open = initiallyOpen;
  const events = [];

  // Candidate TuiTextfieldComponent.onCleanerClick
  value = null;
  events.push('clear');

  if (hasDropdown && editable) {
    open = true;
    events.push('explicit-open');
  }

  // Existing TuiDropdownOpen host click runs after the cleaner button handler.
  if (!editable) {
    open = !open;
    events.push('host-toggle');
  }

  return {value, open, events};
}

test('editable date input opens after cleaner click', () => {
  assert.deepEqual(replayCleanerClick({editable: true, hasDropdown: true}), {
    value: null,
    open: true,
    events: ['clear', 'explicit-open'],
  });
});

test('readonly Select keeps its existing single host toggle', () => {
  assert.deepEqual(replayCleanerClick({editable: false, hasDropdown: true}), {
    value: null,
    open: true,
    events: ['clear', 'host-toggle'],
  });
});

test('plain editable textfield does not enter an open state', () => {
  assert.deepEqual(replayCleanerClick({editable: true, hasDropdown: false}), {
    value: null,
    open: false,
    events: ['clear'],
  });
});

test('date dropdown stays open if cleaner is clicked while already open', () => {
  assert.equal(
    replayCleanerClick({editable: true, hasDropdown: true, initiallyOpen: true}).open,
    true,
  );
});
