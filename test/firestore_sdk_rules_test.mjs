import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const host = process.env.FIRESTORE_EMULATOR_HOST;
const local = { skip: !host && 'Requires a local Firestore emulator.', timeout: 20000 };
if (host) assert.match(host, /^(localhost|127\.0\.0\.1):\d+$/);
let env, sdk, assertSucceeds, assertFails;
before(async () => {
  if (!host) return;
  const require = createRequire(new URL('../tools/firebase-tests/package.json', import.meta.url));
  const testing = require('@firebase/rules-unit-testing');
  sdk = require('firebase/firestore');
  ({ assertSucceeds, assertFails } = testing);
  const [hostname, port] = host.split(':');
  env = await testing.initializeTestEnvironment({ projectId: 'demo-hakbanghero-duels', firestore: {
    host: hostname, port: Number(port), rules: readFileSync(process.env.RULES_FILE || new URL('../firestore.rules', import.meta.url), 'utf8'),
  } });
});
after(async () => env?.cleanup());
let serial = 0;
async function pair(status = 'validating', userFields = {}) {
  const id = `sdk-duel-${++serial}`, a = `sdk-a-${serial}`, b = `sdk-b-${serial}`;
  const start = sdk.Timestamp.fromMillis(Date.now() - 1200000);
  const cutoff = sdk.Timestamp.fromMillis(Date.now() - 10);
  const challenge = { protocol: 2, reward_protocol: 2, participants: [a, b], from: a, to: b,
    from_name: 'A', to_name: 'B', distance_km: 1, reward: 200, status,
    ready: { [a]: true, [b]: true }, progress: { [a]: 1, [b]: 0.8 }, seen: {}, finals: {},
    created_at: start, started_at: start, validating_at: cutoff, candidate: a, by_default: false };
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore(), batch = sdk.writeBatch(db);
    for (const uid of [a, b]) {
      batch.set(sdk.doc(db, `users/${uid}`), { coins: 1000, xp: 0, total_km: 0, total_sessions: 0,
        owned_heroes: [], owned_items: [], ...userFields });
      batch.set(sdk.doc(db, `player_activity/${uid}`), { kind: 'duel', challenge_id: id,
        session_id: uid, outcome_seen: '', updated_at: sdk.serverTimestamp() });
    }
    batch.set(sdk.doc(db, `challenges/${id}`), challenge);
    await batch.commit();
  });
  const db = uid => env.authenticatedContext(uid).firestore();
  return { id, a, b, db, challenge, cutoff, start };
}
async function seal(p, uid) {
  const db = p.db(uid);
  await assertSucceeds(sdk.updateDoc(sdk.doc(db, `challenges/${p.id}`), {
    [`finals.${uid}`]: { invalid: false, windows: [], jumps: [], first_at: p.start,
      observed_at: p.cutoff, fix_count: 100, for: p.cutoff },
  }));
}
function settlement(p, prize = 200, extra = {}) {
  const db = p.db(p.a), batch = sdk.writeBatch(db);
  const day = Math.floor((Date.now() + 28800000) / 86400000);
  batch.update(sdk.doc(db, `challenges/${p.id}`), { status: 'done', winner: p.a, prize,
    reward_receipt: p.id, finished_at: sdk.serverTimestamp(), validated_at: sdk.serverTimestamp() });
  batch.set(sdk.doc(db, `duel_reward_receipts/${p.id}`), { challenge_id: p.id,
    participants: [p.a, p.b], winner: p.a, prize, validated_at: sdk.serverTimestamp() });
  if (prize) batch.update(sdk.doc(db, `users/${p.a}`), { coins: 1000 + prize, coins_today: prize,
    coins_today_day: day, duel_prize_day: day, duel_prizes_today: 1, last_duel_id: p.id, ...extra });
  return batch.commit();
}

test('SDK participant reads and approved invalidation release both slots', local, async () => {
  const p = await pair('active'), db = p.db(p.b);
  const before = await assertSucceeds(sdk.getDoc(sdk.doc(db, `challenges/${p.id}`)));
  assert.equal(before.data().status, 'active');
  const batch = sdk.writeBatch(db);
  batch.update(sdk.doc(db, `challenges/${p.id}`), { status: 'invalid', invalidated_by: p.b,
    invalid_reason: 'unrealistic_movement', finished_at: sdk.serverTimestamp(), invalid_evidence: {
      invalid: true, observed_at: sdk.Timestamp.now(), jumps: [],
      windows: Array.from({ length: 3 }, () => ({ seconds: 10, fixes: 3, gap: 5, speed: 50 })),
    } });
  for (const uid of [p.a, p.b]) batch.update(sdk.doc(db, `player_activity/${uid}`), {
    kind: 'available', updated_at: sdk.serverTimestamp(),
  });
  await assertSucceeds(batch.commit());
  await assertFails(settlement(p));
});

test('SDK settlement requires two sealed reports and pays once with a receipt', local, async () => {
  const p = await pair();
  await assertFails(settlement(p));
  await seal(p, p.a); await seal(p, p.b);
  await assertFails(settlement(p, 200, { xp: 1000 }));
  await assertSucceeds(settlement(p));
  await assertFails(settlement(p));
  const db = p.db(p.a);
  assert.equal((await sdk.getDoc(sdk.doc(db, `users/${p.a}`))).data().coins, 1200);
  await assertFails(sdk.getDoc(sdk.doc(p.db('outsider'), `duel_reward_receipts/${p.id}`)));
});

test('SDK exhausted prize allowance permits completion without a payout', local, async () => {
  const day = Math.floor((Date.now() + 28800000) / 86400000);
  const p = await pair('validating', { duel_prize_day: day, duel_prizes_today: 3 });
  await seal(p, p.a); await seal(p, p.b);
  await assertFails(settlement(p));
  await assertSucceeds(settlement(p, 0));
});

test('SDK final reports reject missing coverage, third witnesses, forged authors and overwrites', local, async () => {
  const p = await pair(), db = p.db(p.a), ref = sdk.doc(db, `challenges/${p.id}`);
  const report = { invalid: false, windows: [], jumps: [], first_at: p.start,
    observed_at: p.cutoff, for: p.cutoff };
  await assertFails(sdk.updateDoc(ref, { [`finals.${p.a}`]: report }));
  await assertFails(sdk.updateDoc(ref, { [`finals.${p.a}`]: { ...report, fix_count: 100,
    windows: Array.from({ length: 3 }, () => ({ seconds: 10, fixes: 3, gap: 5, speed: 50 })) } }));
  await assertFails(sdk.updateDoc(ref, { [`finals.${p.b}`]: { ...report, fix_count: 100 } }));
  await seal(p, p.a);
  await assertFails(sdk.updateDoc(ref, { [`finals.${p.a}`]: { ...report, fix_count: 200 } }));
});

test('SDK consent is owner-only and requires exact versions and a server timestamp', local, async () => {
  const p = await pair(), db = p.db(p.a), ref = sdk.doc(db, `users/${p.a}/private/consent`);
  const consent = { terms_version: '1.0', privacy_version: '1.0', accepted_at: sdk.serverTimestamp() };
  await assertFails(sdk.setDoc(ref, { ...consent, privacy_version: 'unknown' }));
  await assertFails(sdk.setDoc(ref, { ...consent, accepted_at: p.start }));
  await assertFails(sdk.setDoc(ref, { ...consent, extra: 'unvalidated' }));
  await assertSucceeds(sdk.setDoc(ref, consent));
  await assertSucceeds(sdk.getDoc(ref));
  await assertFails(sdk.getDoc(sdk.doc(p.db(p.b), `users/${p.a}/private/consent`)));
});

test('SDK stale solo leases recover without taking a fresh activity session', local, async () => {
  const p = await pair();
  await env.withSecurityRulesDisabled(async context => {
    await sdk.setDoc(sdk.doc(context.firestore(), `player_activity/${p.a}`), {
      kind: 'solo', session_id: 'old', challenge_id: '', outcome_seen: '', updated_at: sdk.Timestamp.now(),
    });
  });
  const ref = sdk.doc(p.db(p.a), `player_activity/${p.a}`);
  const recovered = { kind: 'available', session_id: 'new', updated_at: sdk.serverTimestamp() };
  await assertFails(sdk.updateDoc(ref, recovered));
  await env.withSecurityRulesDisabled(async context => sdk.updateDoc(sdk.doc(context.firestore(), `player_activity/${p.a}`), {
    updated_at: sdk.Timestamp.fromMillis(Date.now() - 151000),
  }));
  await assertSucceeds(sdk.updateDoc(ref, recovered));
  await assertFails(sdk.updateDoc(sdk.doc(p.db(p.b), `player_activity/${p.a}`), { session_id: 'stolen', updated_at: sdk.serverTimestamp() }));
});

test('SDK completed run commits history, rewards and leaderboard fields together once', local, async () => {
  const p = await pair(), db = p.db(p.a), id = `sdk-run-${serial}`;
  const ended = sdk.Timestamp.fromMillis(Date.now() - 1000);
  const started = sdk.Timestamp.fromMillis(ended.toMillis() - 1200000);
  const day = Math.floor((Date.now() + 28800000) / 86400000);
  const save = (reward = 239) => {
    const batch = sdk.writeBatch(db);
    batch.set(sdk.doc(db, `users/${p.a}/activities/${id}`), { type: 'run', mode: 'endless', distanceKm: 2,
      durationSeconds: 1200, avgSpeedKmh: 6, maxSpeedKmh: 12, startTime: started, endTime: ended,
      xpEarned: 239, coinsEarned: 16, awardedXp: 239, awardedCoins: 16 });
    batch.update(sdk.doc(db, `users/${p.a}`), { total_km: 2, total_sessions: 1, xp: reward, coins: 1016,
      last_run_id: id, last_run_end: ended, coins_today: 16, coins_today_day: day,
      week_key: 'stabilization-week', week_km: 2, month_key: 'stabilization-month', month_km: 2 });
    return batch.commit();
  };
  await assertFails(save(999999));
  await assertSucceeds(save());
  await assertFails(save());
  const data = (await sdk.getDoc(sdk.doc(db, `users/${p.a}`))).data();
  assert.equal(data.xp, 239); assert.equal(data.coins, 1016); assert.equal(data.week_km, 2);
});

for (const questKm of [0, 3]) {
test(`SDK queued 2 km stage syncs rewards and distance from ${questKm} quest km exactly once`, local, async () => {
  const p = await pair('validating', { daily_progress_km: questKm });
  const db = p.db(p.a), id = `stage-${serial}`;
  const ended = sdk.Timestamp.fromMillis(Date.now() - 1000);
  const started = sdk.Timestamp.fromMillis(ended.toMillis() - 1200000);
  const day = Math.floor((Date.now() + 28800000) / 86400000);
  const coins = 170 + (questKm == 3 ? 750 : 0);
  const pending = sdk.doc(db, `users/${p.a}/pending_runs/${id}`);
  await assertSucceeds(sdk.setDoc(pending, { uid: p.a, id, modeId: 'stage_novice' }));
  const save = (distance = 2) => sdk.runTransaction(db, async txn => {
    const activity = sdk.doc(db, `users/${p.a}/activities/${id}`);
    const user = sdk.doc(db, `users/${p.a}`);
    if ((await txn.get(activity)).exists()) return;
    await txn.get(user);
    txn.set(activity, { type: 'run', mode: 'stage_novice', distanceKm: distance,
      durationSeconds: 1200, activeSeconds: 1200, startTime: started, endTime: ended,
      xpEarned: 299, coinsEarned: 20, awardedXp: 299, awardedCoins: coins,
      reward_mult: 1, stage_result: 'STAGE CLEARED!', routePoints: [] });
    txn.update(user, { total_km: sdk.increment(distance), total_sessions: sdk.increment(1),
      xp: sdk.increment(299), coins: sdk.increment(coins), last_run_id: id, last_run_end: ended,
      coins_today: coins, coins_today_day: day, 'badge_stats.longest_run_km': 2,
      daily_progress_date: '2026-11-15', daily_progress_km: questKm + 2,
      daily_quests_claimed: questKm == 3 ? { distance_warrior: true } : {},
      last_run_at: sdk.serverTimestamp(), week_key: 'stage-week', week_km: 2,
      month_key: 'stage-month', month_km: 2,
      stage_records: { stage_novice: { stars: 1, best_secs: 1200, clears: 1 } } });
  });
  // The optimized path must still refuse a stage clear without its distance.
  await assertFails(save(1.98));
  assert.equal((await sdk.getDoc(pending)).exists(), true);
  assert.equal((await sdk.getDoc(sdk.doc(db, `users/${p.a}`))).data().xp, 0);
  await assertSucceeds(save());
  await assertSucceeds(save());
  await assertSucceeds(sdk.deleteDoc(pending));
  const saved = (await sdk.getDoc(sdk.doc(db, `users/${p.a}`))).data();
  assert.equal(saved.daily_progress_km, questKm + 2);
  assert.equal(saved.daily_quests_claimed.distance_warrior === true, questKm === 3);
  assert.equal(saved.total_km, 2);
  assert.equal(saved.xp, 299);
  assert.equal(saved.week_km, 2);
  assert.equal(saved.month_km, 2);
  assert.equal(saved.coins, 1000 + coins);
});
}
