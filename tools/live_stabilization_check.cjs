// Explicitly authorized live checks. Creates only new, named test accounts;
// authenticates every feature write as its participant; cleans only those IDs.
// Credentials are held in memory and never written to the fixture manifest.
const fs = require('node:fs');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const path = require('node:path');
const project = 'hakbanghero';
assert.equal(JSON.parse(fs.readFileSync('.firebaserc')).projects.default, project);
const source = fs.readFileSync('lib/firebase_options.dart', 'utf8');
const web = source.slice(source.indexOf('static const FirebaseOptions web'));
const key = web.match(/apiKey:\s*'([^']+)'/)[1];
const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents`;
const run = Date.now().toString(36) + crypto.randomBytes(3).toString('hex');
const legacy = process.argv.includes('--legacy');
const accounts = [], docs = new Set(), created = new Set();
const manifest = 'build/audit/live-fixtures.json';
const server = Symbol('timestamp');
fs.mkdirSync('build/audit', { recursive: true });
function retain() {
  fs.writeFileSync(manifest, JSON.stringify({ project, run, users: accounts.map(a => a.id), documents: [...created], attemptedDocuments: [...docs] }, null, 2));
}
function track(p) { docs.add(p); retain(); return p; }
function encode(v) {
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (v === null) return { nullValue: null };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encode) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, encode(x)])) } };
}
function fieldPath(p) { return p.split('.').map(k => /^[A-Za-z_][A-Za-z_0-9]*$/.test(k) ? k : '`' + k + '`').join('.'); }
function write(p, fields, update = false) {
  track(p);
  const data = {};
  for (const [k, v] of Object.entries(fields)) {
    if (v === server) continue;
    const keys = k.split('.'); let node = data;
    for (const key of keys.slice(0, -1)) node = node[key] ??= {};
    node[keys.at(-1)] = v;
  }
  return { update: { name: `${base.slice('https://firestore.googleapis.com/v1/'.length)}/${p}`, fields: encode(data).mapValue.fields },
    currentDocument: { exists: update },
    ...(update ? { updateMask: { fieldPaths: Object.keys(fields).filter(k => fields[k] !== server).map(fieldPath) } } : {}),
    updateTransforms: Object.keys(fields).filter(k => fields[k] === server).map(k => ({ fieldPath: fieldPath(k), setToServerValue: 'REQUEST_TIME' })) };
}
async function request(url, token, body, method = 'POST') {
  const r = await fetch(url, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(25000) });
  const text = await r.text();
  return { status: r.status, body: text ? JSON.parse(text) : {} };
}
async function commit(a, writes, expected = 200) {
  const r = await request(`${base}:commit`, a.token, { writes });
  assert.equal(r.status, expected, JSON.stringify(r.body.error));
  if (r.status === 200) {
    for (const w of writes) {
      if (w.currentDocument?.exists === false) created.add(w.update.name.split('/documents/')[1]);
    }
    retain();
  }
  return r.body;
}
async function get(a, p) {
  const r = await request(`${base}/${p}`, a.token, null, 'GET');
  assert.equal(r.status, 200, JSON.stringify(r.body.error));
  return r.body.fields;
}
async function account(suffix) {
  const r = await request(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${key}`, null, {
    email: `stabilization.${run}.${suffix}@hakbanghero-test.invalid`, password: crypto.randomBytes(24).toString('base64url'), returnSecureToken: true,
  });
  assert.equal(r.status, 200, JSON.stringify(r.body.error));
  const a = { id: r.body.localId, token: r.body.idToken, session: `stabilization_${run}_${suffix}` };
  accounts.push(a); retain();
  const name = `STAB_${run.slice(-7)}_${suffix}`;
  await commit(a, [write(`users/${a.id}`, { username: name, username_key: name.toLowerCase(), tester: true,
    gender: 'male', level: 1, xp: 0, coins: 100, total_km: 0, total_steps: 0, total_sessions: 0,
    character_created: false, legal_consent_required: true, owned_items: [], owned_heroes: [], created_at: server }),
    write(`usernames/${name.toLowerCase()}`, { uid: a.id, name }),
    write(`users/${a.id}/private/body`, { email: `stabilization.${run}.${suffix}@hakbanghero-test.invalid` }),
    write(`users/${a.id}/private/consent`, { terms_version: '1.0', privacy_version: '1.0', accepted_at: server })]);
  return a;
}
async function available(a) {
  await commit(a, [write(`presence/${a.id}`, { presence: 'online', presence_at: server }, docs.has(`presence/${a.id}`)),
    write(`player_activity/${a.id}`, { kind: 'available', session_id: a.session, challenge_id: '', outcome_seen: '', updated_at: server })]);
}
let serial = 0;
function invitation(from, to) {
  const id = `stabilization_${run}_${++serial}`;
  return { id, from, to, writes: [write(`challenges/${id}`, { protocol: 2, ...(!legacy ? { reward_protocol: 2 } : {}),
    participants: [from.id, to.id], from: from.id, to: to.id, from_name: 'Stabilization A', to_name: 'Stabilization B',
    distance_km: 1, reward: 200, status: 'pending', ready: { [from.id]: false, [to.id]: false },
    progress: { [from.id]: 0, [to.id]: 0 }, seen: {}, finals: {}, created_at: server }),
    ...[from, to].map(a => write(`player_activity/${a.id}`, { kind: 'duel', challenge_id: id, updated_at: server }, true))] };
}
async function deliver(invite) {
  await commit(invite.from, invite.writes);
  await get(invite.to, `challenges/${invite.id}`);
  await commit(invite.to, [write(`challenges/${invite.id}`, { delivered_at: server, delivery_session: invite.to.session }, true)]);
}
async function cleanup() {
  const auth = require(path.join(process.env.APPDATA, 'npm/node_modules/firebase-tools/lib/auth.js'));
  const a = auth.getGlobalDefaultAccount();
  const token = await auth.getAccessToken(a.tokens.refresh_token, ['https://www.googleapis.com/auth/cloud-platform', 'https://www.googleapis.com/auth/firebase']);
  // This exact manifest contains only IDs registered by the current process.
  if (created.size) {
    const r = await request(`${base}:commit`, token.access_token, { writes: [...created].map(p => ({ delete: `${base.slice('https://firestore.googleapis.com/v1/'.length)}/${p}` })) });
    assert.equal(r.status, 200, 'Test-document cleanup failed; consult live-fixtures.json.');
  }
  for (const a of accounts) {
    const r = await request(`https://identitytoolkit.googleapis.com/v1/projects/${project}/accounts:delete`, token.access_token, { localId: a.id });
    assert.equal(r.status, 200, 'Test-account cleanup failed; consult live-fixtures.json.');
  }
  fs.writeFileSync(manifest, JSON.stringify({ project, run, cleaned: true, userCount: accounts.length, documentCount: created.size }, null, 2));
  console.log(`Cleaned ${accounts.length} dedicated test accounts and ${created.size} confirmed-created test documents.`);
}
(async () => {
  try {
    const a = await account('A'), b = await account('B');
    const rid = `${a.id}_${b.id}`;
    await commit(a, [write(`friend_requests/${rid}`, { from: a.id, to: b.id, from_name: 'Stabilization A', status: 'pending', created_at: server })]);
    await commit(b, [write(`users/${a.id}/friends/${b.id}`, { name: 'Stabilization B', since: server }),
      write(`users/${b.id}/friends/${a.id}`, { name: 'Stabilization A', since: server }), write(`friend_requests/${rid}`, { status: 'accepted' }, true)]);
    await available(a); await available(b);
    const first = invitation(a, b); await deliver(first);
    await commit(b, [write(`challenges/${first.id}`, { status: 'declined', finished_at: server }, true),
      write(`duel_cooldowns/${a.id}/recipients/${b.id}`, { challenge_id: first.id, declined_at: server }),
      ...[a, b].map(u => write(`player_activity/${u.id}`, { kind: 'available', updated_at: server }, true))]);
    await commit(a, invitation(a, b).writes, 403);
    console.log('PASS: authenticated profile creation, friendship, invitation reception, decline and cooldown.');
    if (legacy) return;
    const reverse = invitation(b, a); await deliver(reverse);
    await commit(a, [write(`challenges/${reverse.id}`, { status: 'lobby', accepted_at: server }, true)]);
    for (const u of [a, b]) await commit(u, [write(`challenges/${reverse.id}`, { [`ready.${u.id}`]: true, [`seen.${u.id}`]: server }, true)]);
    await commit(b, [write(`challenges/${reverse.id}`, { status: 'countdown', countdown_at: server }, true)]);
    await new Promise(resolve => setTimeout(resolve, 5200));
    await commit(b, [write(`challenges/${reverse.id}`, { status: 'active', started_at: server }, true)]);
    const started = new Date((await get(a, `challenges/${reverse.id}`)).started_at.timestampValue);
    await new Promise(resolve => setTimeout(resolve, 10500));
    for (const u of [a, b]) await commit(u, [write(`challenges/${reverse.id}`, { [`progress.${u.id}`]: 0.2, [`seen.${u.id}`]: server }, true),
      write(`player_activity/${u.id}`, { updated_at: server }, true)]);
    await commit(a, [write(`challenges/${reverse.id}`, { status: 'validating', candidate: b.id, by_default: true, forfeit_by: a.id, validating_at: server }, true)]);
    const cutoff = new Date((await get(a, `challenges/${reverse.id}`)).validating_at.timestampValue);
    for (const u of [a, b]) await commit(u, [write(`challenges/${reverse.id}`, { [`finals.${u.id}`]: {
      invalid: false, windows: [], jumps: [], first_at: started, observed_at: cutoff, fix_count: 12, for: cutoff,
    } }, true)]);
    const day = Math.floor((Date.now() + 28800000) / 86400000);
    const settlement = [write(`challenges/${reverse.id}`, { status: 'done', winner: b.id, prize: 40, reward_receipt: reverse.id, validated_at: server, finished_at: server }, true),
      write(`duel_reward_receipts/${reverse.id}`, { challenge_id: reverse.id, participants: [b.id, a.id], winner: b.id, prize: 40, validated_at: server }),
      write(`users/${b.id}`, { coins: 140, coins_today: 40, coins_today_day: day, duel_prize_day: day, duel_prizes_today: 1, last_duel_id: reverse.id }, true)];
    await commit(b, settlement);
    await commit(b, settlement, 403);
    assert.equal(Number((await get(b, `users/${b.id}`)).coins.integerValue), 140);
    await get(a, `duel_reward_receipts/${reverse.id}`);
    console.log('PASS: reverse-direction invitation, accept, ready, countdown, active, forfeit, sealed synthetic reports and exactly-once bounded payout.');
  } finally { await cleanup(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
