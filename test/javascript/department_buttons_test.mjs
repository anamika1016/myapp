import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const view = readFileSync(new URL('../../app/views/departments/index.html.erb', import.meta.url), 'utf8');
const userDetailsView = readFileSync(new URL('../../app/views/user_details/new.html.erb', import.meta.url), 'utf8');
const submittedAchievementsView = readFileSync(
  new URL('../../app/views/user_details/submitted_achievements.html.erb', import.meta.url),
  'utf8'
);
const binding = view.slice(view.indexOf('  bindEvents() {'), view.indexOf('  removeEventListeners() {'));

test('existing-data Delete uses a Turbo DELETE request and confirmation', () => {
  assert.match(userDetailsView, /turbo_method:\s*:delete/);
  assert.match(userDetailsView, /turbo_confirm:\s*"Are you sure you want to delete this record\?"/);
  assert.doesNotMatch(userDetailsView, /button_to "Delete"/);
});

test('submitted achievements includes a confirmed month-specific delete button', () => {
  assert.match(submittedAchievementsView, /button_to ""/);
  assert.match(submittedAchievementsView, /delete_month_data_user_detail_path/);
  assert.match(submittedAchievementsView, /month: month/);
  assert.match(submittedAchievementsView, /Other months will remain unchanged/);
  assert.match(submittedAchievementsView, /Final confirmation/);
  assert.match(submittedAchievementsView, /h-1\.5 w-1\.5 rounded-full border-0 bg-gray-400 p-0/);
  assert.doesNotMatch(submittedAchievementsView, /border-red-300/);
});

test('Edit and delete buttons respond to clicks on their SVG icons', () => {
  const document = new EventTarget();
  document.getElementById = () => null;
  const calls = [];
  const pageListeners = new AbortController();
  const context = vm.createContext({ document, pageListeners, calls, console: { log() {}, error() {} } });
  vm.runInContext(`class Manager {
    ${binding}
    removeEventListeners() {}
    editDepartment(id) { calls.push(['edit', id]); }
    deleteDepartment(id) { calls.push(['delete', id]); }
    deleteUserActivities(department, employee) { calls.push(['deleteUser', department, employee]); }
  }
  new Manager().bindEvents();`, context);

  for (const selector of ['.edit-btn', '.delete-user-btn', '.delete-dept-btn']) {
    const button = { dataset: { employeeId: 'PAPL126', departmentId: '42' } };
    const event = new Event('click', { cancelable: true });
    Object.defineProperty(event, 'target', { value: { closest: (match) => match === selector ? button : null } });
    document.dispatchEvent(event);
    assert.equal(event.defaultPrevented, true);
  }
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['edit', 'PAPL126'], ['deleteUser', '42', 'PAPL126'], ['delete', '42']]);
  pageListeners.abort();
  document.dispatchEvent(new Event('click'));
  assert.equal(calls.length, 3);
});

test('Turbo visits recreate the manager and remove previous document listeners', () => {
  const script = view.match(/<script>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=([\s\S]*?)%>/g, '[]').replace(/<%[\s\S]*?%>/g, '');
  // Exercise the real lifecycle with a minimal manager to isolate navigation.
  const start = script.indexOf('class DepartmentManager {');
  const end = script.indexOf('} // End of DepartmentManager class', start) + '} // End of DepartmentManager class'.length;
  const lifecycle = script.slice(0, start) + `class DepartmentManager {
    constructor() { window.created = (window.created || 0) + 1; }
    destroy() { window.departmentManagerInstance = null; }
  }` + script.slice(end);
  const document = new EventTarget();
  document.readyState = 'complete';
  document.getElementById = () => null;
  const window = {};
  const context = vm.createContext({ document, window, AbortController, console: { log() {}, error() {} } });
  vm.runInContext(lifecycle, context);
  document.dispatchEvent(new Event('turbo:load'));
  assert.equal(window.created, 1);
  const firstListeners = window.departmentPageListeners;
  document.dispatchEvent(new Event('turbo:before-cache'));
  assert.equal(firstListeners.signal.aborted, true);
  vm.runInContext(lifecycle, context);
  document.dispatchEvent(new Event('turbo:load'));
  assert.equal(window.created, 2);
});
