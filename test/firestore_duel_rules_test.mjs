// Run with Java 21 available:
// firebase emulators:exec --project demo-hakbanghero-duels --only "auth,firestore" "node --test test/firestore_duel_rules_test.mjs"
// Uses Node built-ins and emulator REST APIs; never connects to live Firebase.
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const project = 'demo-hakbanghero-duels';
const firestore = process.env.FIRESTORE_EMULATOR_HOST;
const auth = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const emulator = Boolean(firestore && auth);
after(async () => {
  if (!emulator) return;
  const r = await fetch(`http://${firestore}/emulator/v1/projects/${project}:ruleCoverage`);
  mkdirSync(new URL('../build/audit', import.meta.url), { recursive: true });
  writeFileSync(new URL('../build/audit/rules-coverage.json', import.meta.url), await r.text());
});
for (const host of [firestore, auth].filter(Boolean)) {
  assert.match(host, /^(127\.0\.0\.1|localhost):\d+$/, 'Only local emulators are permitted.');
}
const source = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const rules = source('firestore.rules');

test('generated duel constants agree with the approved policy and template', () => {
  const policy = source('lib/models/duel_policy.dart');
  let template = source('tools/firestore.rules.template');
  for (const [, name, value] of policy.matchAll(/static const (?:int|double) (\w+) = ([0-9.]+);/g)) {
    template = template.replaceAll(`__DUEL_${name}__`, value);
  }
  const marker = '    function otherOf(d)';
  assert.equal(template.slice(template.indexOf(marker)).replaceAll('\r\n', '\n'),
    rules.slice(rules.indexOf(marker)).replaceAll('\r\n', '\n'));
  assert.ok(!rules.includes('__DUEL_'));
});

test('duel reward prerequisites apply before existing tester alternatives', () => {
  assert.match(rules, /allow update: if isMe\(uid\) && duelUserGuard\(uid\)/);
  assert.match(rules, /duelRunOk\(uid, id, request.resource.data\)[\s\S]*?activityOk\(request.resource.data\) \|\| isTester\(\)/);
  assert.match(rules, /request.time >= get\(cooldownPath/);
});

const stamp = Symbol('server timestamp');
const fieldPath = path => path.split('.').map(p => /^[A-Za-z_][A-Za-z_0-9]*$/.test(p) ? p : '`' + p.replaceAll('`', '\\`') + '`').join('.');
function encode(value) {
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  if (value === null) return { nullValue: null };
  if (typeof value === 'string') return { stringValue: value };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encode) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)])) } };
}
function write(path, fields, merge = false) {
  const data = {};
  for (const [path, value] of Object.entries(fields)) {
    if (value === stamp) continue;
    const keys = path.split('.'); let target = data;
    for (const key of keys.slice(0, -1)) target = target[key] ??= {};
    target[keys.at(-1)] = value;
  }
  return {
    update: { name: `projects/${project}/databases/(default)/documents/${path}`, fields: encode(data).mapValue.fields },
    ...(merge ? { currentDocument: { exists: true }, updateMask: { fieldPaths: Object.keys(fields).filter((key) => fields[key] !== stamp).map(fieldPath) } } : {}),
    updateTransforms: Object.keys(fields).filter((key) => fields[key] === stamp)
      .map((path) => ({ fieldPath: fieldPath(path), setToServerValue: 'REQUEST_TIME' })),
  };
}
async function commit(token, writes) {
  const response = await fetch(`http://${firestore}/v1/projects/${project}/databases/(default)/documents:commit`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ writes }),
  });
  return { status: response.status, body: await response.text() };
}
const pass = (r) => assert.equal(r.status, 200, r.body);
const deny = (r) => assert.equal(r.status, 403, r.body);
async function account() {
  const r = await fetch(`http://${auth}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=local`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true }),
  });
  const d = await r.json(); assert.ok(d.idToken, JSON.stringify(d));
  return { id: d.localId, token: d.idToken };
}
let serial = 0;
async function pair() {
  const a = await account(), b = await account(), id = `duel-test-${++serial}`;
  const at = new Date(Date.now() - 100);
  const writes = [];
  for (const u of [a, b]) {
    writes.push(write(`users/${u.id}`, { coins: 1000, xp: 0, total_km: 0, total_sessions: 0, owned_heroes: [], owned_items: [] }));
    writes.push(write(`presence/${u.id}`, { presence: 'online', presence_at: at }));
    writes.push(write(`player_activity/${u.id}`, { kind: 'available', session_id: u.id, challenge_id: '', outcome_seen: '', updated_at: at }));
  }
  writes.push(write(`users/${a.id}/friends/${b.id}`, { name: 'B' }));
  writes.push(write(`users/${b.id}/friends/${a.id}`, { name: 'A' }));
  pass(await commit('owner', writes));
  const data = { protocol: 2, reward_protocol: 2, participants: [a.id, b.id], from: a.id, to: b.id, from_name: 'A', to_name: 'B',
    distance_km: 1, reward: 200, status: 'pending', ready: { [a.id]: false, [b.id]: false },
    progress: { [a.id]: 0, [b.id]: 0 }, seen: {}, finals: {}, created_at: at };
  const invite = (cid = id) => [write(`challenges/${cid}`, { ...data, created_at: stamp }),
    ...[a, b].map((u) => write(`player_activity/${u.id}`, { kind: 'duel', challenge_id: cid, updated_at: stamp }, true))];
  return { a, b, id, data, invite };
}
async function active(p, status = 'active') {
  const cutoff = new Date(Date.now() - 100);
  const d = { ...p.data, status, started_at: new Date(Date.now() - 1200000), candidate: p.a.id,
    validating_at: cutoff, by_default: false, progress: { [p.a.id]: 1, [p.b.id]: 0.8 } };
  pass(await commit('owner', [write(`challenges/${p.id}`, d), ...[p.a, p.b].map((u) =>
    write(`player_activity/${u.id}`, { kind: 'duel', challenge_id: p.id, updated_at: stamp }, true))]));
  const check = await fetch(`http://${firestore}/v1/projects/${project}/databases/(default)/documents/challenges/${p.id}`,
    { headers: { Authorization: `Bearer ${p.a.token}` } });
  assert.equal(check.status, 200, await check.clone().text());
  assert.equal((await check.json()).fields.status.stringValue, status);
  return d;
}
const local = { skip: emulator ? false : 'Blocked: local Auth/Firestore emulators require Java; not a backend verification result.' };

test('busy, offline, stale and unconfirmed presence cannot receive an invitation', local, async () => {
  for (const fields of [{ presence: 'offline' }, { presence_at: new Date(Date.now() - 151000) }, { presence_at: null }]) {
    const p = await pair(); pass(await commit('owner', [write(`presence/${p.b.id}`, fields, true)]));
    deny(await commit(p.a.token, p.invite()));
  }
  const p = await pair(); pass(await commit('owner', [write(`player_activity/${p.b.id}`, { kind: 'solo' }, true)]));
  deny(await commit(p.a.token, p.invite()));
});

test('invitation delivery and recipient-only acceptance resolve once', local, async () => {
  const p = await pair(); pass(await commit(p.a.token, p.invite()));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'lobby', accepted_at: stamp }, true)]));
  pass(await commit(p.b.token, [write(`challenges/${p.id}`, { delivered_at: stamp, delivery_session: p.b.id }, true)]));
  pass(await commit(p.b.token, [write(`challenges/${p.id}`, { status: 'lobby', accepted_at: stamp }, true)]));
  deny(await commit(p.b.token, [write(`challenges/${p.id}`, { status: 'lobby', accepted_at: stamp }, true)]));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'active', started_at: stamp }, true)]));
});

test('concurrent invitations reserve one shared slot only', local, async () => {
  const p = await pair();
  const results = await Promise.all([commit(p.a.token, p.invite()), commit(p.a.token, p.invite(`${p.id}-other`))]);
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 403]);
});

test('decline and directional cooldown commit together; sender cannot erase it', local, async () => {
  const p = await pair(); pass(await commit(p.a.token, p.invite()));
  const released = [p.a, p.b].map((u) => write(`player_activity/${u.id}`, { kind: 'available', updated_at: stamp }, true));
  deny(await commit(p.b.token, [write(`challenges/${p.id}`, { status: 'declined', finished_at: stamp }, true), ...released]));
  pass(await commit(p.b.token, [write(`challenges/${p.id}`, { status: 'declined', finished_at: stamp }, true), ...released,
    write(`duel_cooldowns/${p.a.id}/recipients/${p.b.id}`, { challenge_id: p.id, declined_at: stamp })]));
  deny(await commit(p.a.token, p.invite(`${p.id}-retry`)));
  deny(await commit(p.a.token, [{ delete: `projects/${project}/databases/(default)/documents/duel_cooldowns/${p.a.id}/recipients/${p.b.id}` }]));
  pass(await commit('owner', [write(`duel_cooldowns/${p.a.id}/recipients/${p.b.id}`, { declined_at: new Date(Date.now() - 3601000) }, true)]));
  pass(await commit(p.a.token, p.invite(`${p.id}-after-hour`)));
});

test('expired invitations cannot be delivered or accepted', local, async () => {
  const p = await pair(); pass(await commit(p.a.token, p.invite()));
  pass(await commit('owner', [write(`challenges/${p.id}`, { created_at: new Date(Date.now() - 61000) }, true)]));
  deny(await commit(p.b.token, [write(`challenges/${p.id}`, { delivered_at: stamp, delivery_session: p.b.id }, true)]));
});

test('ready gates, countdown timing and immutable identity are enforced', local, async () => {
  const p = await pair(); await active(p, 'lobby');
  pass(await commit('owner', [write(`challenges/${p.id}`, { accepted_at: new Date(), ready: { [p.a.id]: false, [p.b.id]: false } }, true)]));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'countdown', countdown_at: stamp }, true)]));
  for (const u of [p.a, p.b]) pass(await commit(u.token, [write(`challenges/${p.id}`, {
    [`ready.${u.id}`]: true, [`seen.${u.id}`]: stamp }, true)]));
  pass(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'countdown', countdown_at: stamp }, true)]));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'active', started_at: stamp }, true)]));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { from: p.b.id }, true)]));
});

test('invalid movement dismisses both players and prevents all duel-linked rewards', local, async () => {
  const p = await pair(); await active(p);
  const evidence = { invalid: true, observed_at: new Date(Date.now() - 10), jumps: [],
    windows: Array.from({ length: 3 }, () => ({ speed: 50, seconds: 10, fixes: 3, gap: 5 })) };
  const release = [p.a, p.b].map((u) => write(`player_activity/${u.id}`, { kind: 'available', updated_at: stamp }, true));
  pass(await commit(p.b.token, [write(`challenges/${p.id}`, { status: 'invalid', invalidated_by: p.b.id,
    invalid_reason: 'unrealistic_movement', invalid_evidence: evidence, finished_at: stamp }, true), ...release]));
  deny(await commit(p.a.token, [write(`challenges/${p.id}`, { status: 'done', winner: p.a.id, prize: 200,
    finished_at: stamp, validated_at: stamp }, true)]));
  deny(await commit(p.a.token, [write(`users/${p.a.id}/activities/duel_${p.id}`, {
    mode: 'duel', duel_id: p.id, distanceKm: 1, durationSeconds: 1200, xpEarned: 100, coinsEarned: 10,
    startTime: new Date(Date.now() - 1200000), endTime: new Date(),
  })]));
});

test('settlement needs both sealed final reports and credits the capped prize once', local, async () => {
  const p = await pair(); const d = await active(p, 'validating');
  const day = Math.floor((Date.now() + 28800000) / 86400000);
  const settle = () => commit(p.a.token, [write(`challenges/${p.id}`, { status: 'done', winner: p.a.id,
    prize: 200, reward_receipt: p.id, finished_at: stamp, validated_at: stamp }, true),
    write(`duel_reward_receipts/${p.id}`, { challenge_id: p.id, participants: p.data.participants, winner: p.a.id, prize: 200, validated_at: stamp }), write(`users/${p.a.id}`, {
    coins: 1200, coins_today: 200, coins_today_day: day, duel_prize_day: day, duel_prizes_today: 1, last_duel_id: p.id,
  }, true)]);
  deny(await settle());
  for (const u of [p.a, p.b]) pass(await commit(u.token, [write(`challenges/${p.id}`, {
    [`finals.${u.id}`]: { invalid: false, windows: [], jumps: [], for: d.validating_at, fix_count: 100, first_at: d.started_at, observed_at: d.validating_at },
  }, true)]));
  pass(await settle());
  deny(await settle());
});

test('invalidation racing with an incomplete settlement cannot leave a credited prize', local, async () => {
  const p = await pair(); await active(p, 'validating');
  const evidence = { invalid: true, observed_at: new Date(Date.now() - 500), jumps: [],
    windows: Array.from({ length: 3 }, () => ({ speed: 50, seconds: 10, fixes: 3, gap: 5 })) };
  const invalidate = () => commit(p.b.token, [write(`challenges/${p.id}`, { status: 'invalid', invalidated_by: p.b.id,
    invalid_reason: 'unrealistic_movement', invalid_evidence: evidence, finished_at: stamp }, true),
    ...[p.a, p.b].map((u) => write(`player_activity/${u.id}`, { kind: 'available', updated_at: stamp }, true))]);
  const results = await Promise.all([
    commit(p.a.token, [write(`challenges/${p.id}`, { status: 'done', winner: p.a.id, prize: 200,
      finished_at: stamp, validated_at: stamp }, true)]),
    invalidate(),
  ]);
  assert.equal(results[0].status, 403, results[0].body);
  // Concurrent REST commits can abort on the emulator's transaction lock.
  // Retry only that transient conflict; permission failures must still fail.
  pass(results[1].status === 409 ? await invalidate() : results[1]);
});
