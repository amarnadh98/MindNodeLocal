# FSRS-6 reference vectors

`fsrs6-vectors.json` holds deterministic review histories produced by the **real
reference implementation**, not by hand or from memory. The Swift port in
`Sources/MapStudy` must match it (SPEC §10, §14 "FSRS reference vectors"):

- stability/difficulty/retrievability to ≥ 1e-4 relative tolerance,
- due dates, scheduled days, reps, lapses, learning steps and states exactly.

## Provenance

- **Tool:** [`ts-fsrs`](https://github.com/open-spaced-repetition/ts-fsrs), the
  TypeScript FSRS reference implementation named in SPEC §10.
- **Exact version:** `ts-fsrs@6.0.0` (installed with `npm i ts-fsrs@6.0.0`).
- **API used:** the legacy `FSRS` class (`new FSRS({}).next(card, now, rating)`),
  which is the default configuration — `BasicScheduler`, `enable_short_term:
  true`, learning steps `["1m","10m"]`, relearning steps `["10m"]`, desired
  retention 0.9, maximum interval 36500, **fuzz off**, and the default FSRS-6
  weights `w[0…20]` (w[20] = 0.1542 is the trained decay).

## Scenarios

Twelve deterministic histories with fixed UTC timestamps: all four grades out of
`new`; graduation; a full lapse/relearning cycle (twice); same-day reviews of
review-state cards (short-term stability, including a same-day lapse); a
review card 30 days overdue answered with each grade; a long on-time chain with
one late review; and a retrievability probe set. The probe set pins the
retrievability convention (whole 24-hour periods since the last review) while
the card fields pin the scheduler convention (UTC calendar days since the last
review) — the reference itself uses both, and so does the port.

## Regenerating

Run this script in a scratch directory outside the repo (`npm i ts-fsrs@6.0.0`,
then `node gen-vectors.mjs > fsrs6-vectors.json`) and replace the fixture. The
committed fixture was generated on 2026-11-19.

```javascript
// gen-vectors.mjs
import * as m from 'ts-fsrs';

const T0 = Date.UTC(2026, 0, 5, 9, 0, 0); // 2026-01-05T09:00:00Z
const MIN = 60 * 1000;
const DAY = 24 * 60 * MIN;
const f = new m.FSRS({}); // defaults: fuzz off, short term on, DR 0.9

const gradeName = { 1: 'again', 2: 'hard', 3: 'good', 4: 'easy' };
const stateName = ['new', 'learning', 'review', 'relearning'];

const iso = (ms) => new Date(ms).toISOString();
// The elapsed-days formula used by the reference scheduler's init()
// (UTC calendar-day difference, dateDiffInDays in src/legacy/help.ts).
function dateDiffInDays(last, cur) {
  const utc1 = Date.UTC(last.getUTCFullYear(), last.getUTCMonth(), last.getUTCDate());
  const utc2 = Date.UTC(cur.getUTCFullYear(), cur.getUTCMonth(), cur.getUTCDate());
  return Math.floor((utc2 - utc1) / 86400000);
}

function run(name, steps, probes) {
  let card = m.createEmptyCard(new Date(T0));
  const out = { name, steps: [] };
  for (const [grade, offsetMs] of steps) {
    const now = new Date(T0 + offsetMs);
    const before = {
      state: stateName[card.state],
      retrievability: f.retrievability(card, now),
      elapsedDays:
        card.state !== 0 && card.last_review ? dateDiffInDays(card.last_review, now) : 0,
    };
    const result = f.next(card, now, grade);
    card = result.card;
    out.steps.push({
      grade: gradeName[grade],
      ts: iso(now.getTime()),
      stateBefore: before.state,
      retrievabilityBefore: before.retrievability,
      elapsedDaysBefore: before.elapsedDays,
      card: {
        due: card.due.toISOString(),
        stability: card.stability,
        difficulty: card.difficulty,
        scheduledDays: card.scheduled_days,
        reps: card.reps,
        lapses: card.lapses,
        learningSteps: card.learning_steps,
        state: stateName[card.state],
        lastReview: card.last_review ? card.last_review.toISOString() : null,
      },
    });
  }
  if (probes) {
    out.retrievabilityProbes = probes.map((offsetMs) => {
      const now = new Date(T0 + offsetMs);
      return { ts: iso(now.getTime()), value: f.retrievability(card, now) };
    });
  }
  return out;
}

const scenarios = [
  // Learning steps: every grade out of New.
  run('new-again', [[1, 0], [1, MIN], [3, 2 * MIN], [3, 12 * MIN]]),
  run('new-hard', [[2, 0], [2, 330 * 1000], [3, 660 * 1000], [3, 1260 * 1000]]),
  run('new-good-graduates', [[3, 0], [3, 10 * MIN], [3, 10 * MIN], [3, 10 * MIN], [3, 10 * MIN]]),
  run('new-easy', [[4, 0], [3, 8 * DAY], [3, 8 * DAY], [4, 8 * DAY]]),
  // Lapse cycle: graduate, lapse, relearn, graduate again, lapse again.
  run('lapse-cycle', [
    [3, 0],
    [3, 10 * MIN], // graduate -> review
    [1, 2 * DAY], // lapse -> relearning (10m)
    [1, 2 * DAY + 10 * MIN], // again in relearning
    [3, 2 * DAY + 20 * MIN], // graduate relearning
    [1, 4 * DAY], // lapse again
    [2, 4 * DAY + 10 * MIN], // hard in relearning (15m)
    [3, 4 * DAY + 25 * MIN], // graduate
    [3, 6 * DAY],
  ]),
  // Same-day reviews of a Review-state card: short-term stability path (t = 0).
  run('same-day-review', [
    [4, 0], // easy: straight to review (due +8d)
    [3, 3600 * 1000], // same-day good (short term)
    [2, 7200 * 1000], // same-day hard
    [4, 3 * 3600 * 1000], // same-day easy
    [1, 4 * 3600 * 1000], // same-day again -> lapse to relearning
    [3, 4 * 3600 * 1000 + 10 * MIN], // graduate relearning
  ]),
  // Overdue review card, each grade (30 days late, elapsed 34 from +4d due).
  run('overdue-again', [[3, 0], [3, 10 * MIN], [1, 32 * DAY], [3, 32 * DAY + 10 * MIN]]),
  run('overdue-hard', [[3, 0], [3, 10 * MIN], [2, 32 * DAY]]),
  run('overdue-good', [[3, 0], [3, 10 * MIN], [3, 32 * DAY]]),
  run('overdue-easy', [[3, 0], [3, 10 * MIN], [4, 32 * DAY]]),
  // Long chain of on-time goods, then a late good, then on-time again.
  run('long-chain', [
    [3, 0],
    [3, 10 * MIN],
    [3, 10 * MIN + 2 * DAY],
    [3, 10 * MIN + 2 * DAY + 5 * DAY],
    [3, 10 * MIN + 2 * DAY + 5 * DAY + 11 * DAY],
    [3, 10 * MIN + 2 * DAY + 5 * DAY + 11 * DAY + 20 * DAY + 3 * DAY], // 3 days late
    [2, 10 * MIN + 2 * DAY + 5 * DAY + 11 * DAY + 23 * DAY + 39 * DAY],
  ]),
  // Retrievability probe set: a graduated card measured at several elapsed times.
  run(
    'retrievability-probe',
    [[3, 0], [3, 10 * MIN], [3, 10 * MIN + 2 * DAY]],
    [10 * MIN + 2 * DAY, 10 * MIN + 2 * DAY + 0.5 * DAY, 10 * MIN + 3 * DAY,
      10 * MIN + 5 * DAY, 10 * MIN + 30 * DAY, 10 * MIN + 365 * DAY]
  ),
];

const output = {
  generator: {
    tool: 'ts-fsrs',
    version: '6.0.0',
    api: 'legacy FSRS class (BasicScheduler, enable_short_term true)',
    fuzz: false,
    desiredRetention: 0.9,
    maximumInterval: 36500,
    learningSteps: ['1m', '10m'],
    relearningSteps: ['10m'],
    weights: Array.from(m.default_w),
    generatedAt: '2026-11-19',
  },
  scenarios,
};

console.log(JSON.stringify(output, null, 2));
```
