# Epoch Farm: internal security review

Scope: `sources/farm.move`, `tests/farm_tests.move`, `Move.toml`, plus the design in
`SPEC.md`. Three review rounds, all on 17 Sep 2026: the first on the design before any
code existed, the second on the code as written, the third adversarial, reading the same
code looking for ways to make it misbehave rather than ways to make it work.

**Status: not published, not compiled.** The sandbox where this module was written has no
`sui` binary, so `sui move build` and `sui move test` have not been run yet. Everything
below is review, not compilation. Two findings (A-15, A-16) and two rules (C-3, C-4) live
in the off chain worker, which does not exist yet.

**What this is not.** This is our own review, not an external audit. It is published for
the same reason the other modules in this repository are: so that anyone can check what we
claim against what the code does.

---

## The one sentence that decides everything

The contract never takes custody of a liquidity position. Positions stay in their owners'
wallets on Cetus. The contract holds only EPT that we put in, and pays whoever presents a
valid Merkle proof. So in the worst case the only money at risk is ours, and nobody can
ever be locked out of their own liquidity by a bug of ours. The price we pay for that is
that rewards are computed off chain by a worker, and that the published root is a claim
you have to trust or verify yourself from the data we publish.

---

# Round 1: the design (17 Sep 2026)

Written before the code, as for `epoch-lp-lock` and `epoch-templates`. Anything marked
**open** was not allowed into the Move until it had an answer.

## A-1 Custody: closed by construction

There is no function that can hold, lock or move anyone else's liquidity, and no path in
which a bug of ours costs a user their LP. This is why this architecture was preferred
over the Cetus one, which takes the position into custody.

Only the EPT we fund is at risk. Almost every item below is about limiting damage to that
pot, not to other people's assets.

## A-2 A wrong root pays the wrong person, and there is no way back

This is the main risk of the whole design. Without custody we cannot claw anything back:
what leaves has left.

**Closed by four things together, none of which is sufficient alone:**

1. **cumulative roots**: an inflated root is corrected by the next one, as long as nobody
   has claimed yet (SPEC 3.1);
2. **twenty four hours** between accrual and claimability, so there is time to notice;
3. **a per call cap** (`max_per_claim`, A-4);
4. **the worker refuses to publish** a root where any address jumps more than a threshold
   over the previous one, or where the total grows more than the pot grew. The diff
   between the two roots is printed and read before signing, the same way the template
   burn dry run is read before pressing the button.

## A-3 A root could promise more than the pot holds (bank run)

If `declared_total` exceeds the pot, whoever arrives first gets paid and the rest hit an
empty balance. The damage is double: you do not pay everyone, and you look insolvent.

**Closed in `set_root`**, which aborts unless
`declared_total - paid_total <= balance(reward)`. The invariant is written above the
function and pinned by a test: **a root can never promise more than the pot holds at that
moment.**

## A-4 The emergency cap must not lock out people who are owed

A per call cap is the switch that limits the damage of a wrong root. But if `claim`
aborted when the amount due exceeded the cap, someone who has been away for two months
would be stuck until we raised the cap by hand, and the cap would become a way of not
paying.

**Closed like this**: `claim` pays `min(due, max_per_claim)` and updates `claimed`
accordingly, so a large credit is collected in two calls. Nobody is locked out, and the
switch still limits how fast the pot can drain.

## A-5 Hit and run liquidity

Add liquidity, get photographed, remove it, come back to collect.

**Closed with two pieces**: the score is **weight times time** (one hour out of twenty
four is worth one twenty fourth), and the end of day consolidation **checks presence** on
the address (SPEC 5.4), not on the position id, so rebalancing is not punished.

A property worth writing down: **snapshot times are not observable**. The reads are done
by a worker over GraphQL and leave no trace on chain, so there is no way to know when we
are looking. Anyone trying to inflate only around snapshots has to guess, and on average
gets what they would have got by staying put.

## A-6 Manipulating the price to inflate your own weight

Cetus computes weight at the **current price**. On a pool with 25,000 dollars of TVL,
moving the price inside your own transaction costs a few hundred dollars, so copying that
part would be an invitation.

**Closed**: weight is measured at the **window reference price**, fixed until the window
moves (SPEC 5.2). There is nothing to gain from moving spot.

**Side effect we declare rather than hide**: we choose the window, so we also choose the
reference price, and moving the window changes everyone's weight. That is why a window
move is announced first and takes effect the following day.

## A-7 Sybil: pointless, and that is a property of the design

Splitting a position across ten wallets changes nothing, because the reward is
**proportional to the score** and the score is linear in capital. Ten tenths make one.

This is exactly why there is **no leaderboard**: a top ten would pay people for splitting
and for already being large. If someone later proposes "let us reward the top ten", this
line is the answer.

The only effect of splitting is falling under the minimum threshold and accruing zero,
which hurts whoever tries.

## A-8 Rewards in EPT: the circular problem. **Accepted, knowingly**

Whoever receives EPT and sells it sells it **into the pool we are trying to grow**: price
down, and the EPT side of subsequent fees is worth less. This is why farms paid in their
own token burn out.

Decision taken on 17 Sep 2026: **we pay in EPT anyway**, because the stated goal is to
grow the pool and the token, and paying in SUI gives nobody a reason to touch EPT. The
planned corrective is a multiplier for people who lock their LP with us, which is **not in
v1** and will arrive without a contract upgrade, because the score is computed by the
worker.

To be said publicly, not hidden: rewards are our EPT entering circulation, with the same
market effect as any other distribution.

## A-9 Precision and rounding

With today's numbers (roughly 125 dollars a week spread over tens of trillions of
liquidity units) the reward per unit of weight per second is a tiny number: in naive
integer math it is **zero**, and the farm would work perfectly while paying nobody
anything.

**Closed**: the worker computes in full precision integers (separate numerators and
denominators, no floating point anywhere in the path that decides money) and **always
rounds down**, in favour of the pot. That way the sum of the leaves cannot exceed the
day's budget, which is the invariant A-3 rests on.

## A-10 Merkle tree: domain separation

If leaves and nodes are hashed the same way, an internal node can be passed off as a leaf
and a proof forged.

**Closed**: `leaf = blake2b256(0x00 || farm_id || address || cumulative)` and
`node = blake2b256(0x01 || min(a,b) || max(a,b))`. The tag byte separates the two worlds,
sorting the pair makes the proof side independent, and `farm_id` inside the leaf prevents
reusing a root built for a different Farm object (the testnet one, for instance).

## A-11 The cumulative amount cannot go down

If a new root declares less for an address than that address has already claimed, the
subtraction would underflow.

**Closed**: `claim` aborts with `ENothingToClaim` when `cumulative <= claimed[sender]`,
and the worker never emits a cumulative lower than the previous one. A miscalculation in
that direction takes money from nobody, it just stops.

## A-12 Upgrades: `migrate` exists from day one

Lesson from `epoch-templates`, where its absence would have frozen `swap_and_burn` forever
at the first upgrade that raised the version, while the ungated functions kept working.
The mirror risk here would be: `claim` frozen and the pot unreachable.

**Closed in the code**: version gating on every function that touches the pot, and
`migrate` present from the start. **Not yet pinned by a test**: the upgrade path has no
test of its own, so it is on the list below rather than claimed as covered.

## A-13 Pausing is a power, so it is declared

`claims_paused` exists to stop withdrawals if we spot a bad root. It is also the only way
we have of not paying, so it is treated as such: it emits an event, it comes with a
reason, and it **does not stop accrual** (which is off chain), so nobody loses what they
earned. The page says it exists.

## A-14 If the worker dies

We stop publishing roots: people keep accruing and nobody gets paid.

**Mitigated**: snapshots live in Supabase, so a restart does not lose history and the next
root catches everything up (it is cumulative). And since no withdrawal function exists,
the pot stays claimable forever even if the project stops.

## A-15 If we read positions wrong, we pay people wrong. **Open**

Computing weights requires enumerating every position in the pool. If the read misses a
slice of them, those people are not paid and never find out.

To be closed before the worker code, with a **reconciliation at every snapshot**: the sum
of the liquidity we read, inside the range, must match the pool's active liquidity within
a small tolerance. If it does not, **the snapshot is discarded and no root is published**.
House rule applies: a plausible fallback is worse than an error that surfaces, because the
plausible fallback becomes a decision.

## A-16 The forgotten window. **Open**

If the price leaves the window and nobody notices, everyone accrues zero without knowing
why, and the first person to notice writes it on X rather than to us.

To be built with the worker: a daily check like the EPT fee drift one
(`epoch-ept-fee-drift`), warning when the price approaches the edge of the window, plus a
page that says so plainly before anyone deposits.

## A-17 Dust

Leaves worth a few cents inflate the tree and cost us gas on every root. Closed with a
minimum capital threshold below which nothing accrues, stated on the page.

---

# Round 2: the code (17 Sep 2026)

Rereading `sources/farm.move` as written. The `B-` items are the ones born here, the
things the design did not show.

## B-1 The pot could be sealed shut forever. **Found and fixed**

`burn_leftover` counted the six months from `root_at_ms`, and `root_at_ms` stays zero
until the first root is published. So the most ordinary sequence in the world, **funding
the pot and then not starting the program**, left rewards locked in there with no function
to get them out: `fund` is permissionless, withdrawal does not exist by choice (A-1), and
the burn would never unlock. No attacker required, just a change of mind.

Fixed with `last_activity_ms`, updated by both `fund` and `set_root`: the six months run
from the last sign of life, whatever it was. Intended side effect: anyone can keep the
farm alive by putting something into it. Two new tests, one that burns although no root
ever existed and one that checks that funding pushes the clock forward.

## B-2 `declared_total` is a declaration, the pot is the real ceiling

The contract cannot sum the leaves, so it cannot know whether a root declares less than
its leaves actually promise. If the worker gets that number wrong, `set_root` still
passes.

This is not a hole, because the damage is bounded by two things that are in the code:
`claim` never pays more than the pot holds (an amount above the pot is clamped) and
`max_per_claim` limits the rate. But it needs saying out loud: **the number that protects
is the pot, not the declaration**. The declaration serves the A-3 invariant and helps us
catch our own mistakes, it does not stop an attack.

## B-3 A downward correction does not recover money already paid out

If an inflated root paid Alice 100 and the next one puts her at 90, Alice owes nobody
anything: her `claimed` stays at 100, her future calls abort with `ENothingToClaim`, and
the extra 10 is a loss to the pot.

This is a direct consequence of having no custody (A-1) and it is already in the spec, but
it is repeated here because it is the reason the twenty four hour delay and the pause
exist: **the only moment a mistake can be corrected is before anyone has collected.**

## B-4 The proof comes from outside, so it is measured before it is used

`lte` walks the bytes of the first hash and reads the second at the same offset: a shorter
proof element would have killed the transaction with an index error, which tells nobody
anything. `verify` now checks that every element is 32 bytes and, if not, answers
`EBadProof`, which is both handled and true. Dedicated test.

## B-5 `create` can be called more than once

The `AdminCap` can create several Farm objects. Not a risk (each has its own pot and its
own roots, and leaves carry the farm id, see A-10), but a possible confusion: two live
farms and people looking at the wrong one. Operational rule, not code: **one farm per
network**, id recorded in CLAUDE.md like every other shared object.

## Still open, and it has to be closed outside the Move

A-15 (read reconciliation) and A-16 (forgotten window) are worker work, and the worker
does not exist yet. The contract cannot notice either: it pays what the root says.

---

# Round 3: adversarial reread (17 Sep 2026)

Same code, read looking for **how to make it misbehave**. Two real findings, two rules to
carry into the worker.

## C-1 A cap of zero is a pause that is not called a pause. **Fixed**

`max_per_claim = 0` (at `create`, or via a mistaken `set_max_per_claim`) makes every
`claim` compute `amount = 0` and abort with `ENothingToClaim`. Result: withdrawals are
frozen for everyone, `claims_paused` reads `false`, no event is emitted, and someone
watching the chain has no way to understand why. One finger on a keyboard and the farm
looks broken.

Fixed with `assert!(max_per_claim > 0, EZeroAmount)` in both places. To stop withdrawals
there is `set_paused`, which emits an event and is a visible thing. Dedicated test.

## C-2 `burn_leftover` could burn rewards people had not collected yet. **Fixed**

The most serious of the three rounds, and it comes from **two sentences of the spec that
looked compatible**: "what you accrued stays claimable forever" and "after six months of
silence anyone can burn the leftover". In the first version the function took **the whole
pot**, so:

1. someone who had been away seven months found their credit erased **by a stranger**,
   without us deciding it and without being able to prevent it (the function is
   permissionless, and it is right that it should be);
2. the farm was left **insolvent against its own root**: the leaves kept promising, and
   every `claim` fell through the pot clamp down to `ENothingToClaim`.

It now burns only `pot - (declared_total - paid_total)`, the part no root has ever
promised. What was promised stays there until its owner takes it. Two tests: one checks
that the burn leaves exactly what is owed and that the rightful claimant collects **after**
the burn, the other that when the whole pot is promised the call stops instead of emptying
the treasury.

A note on method, because it is the second time this has happened on this project: **the
contradiction was not in the code, it was between two sentences written in two different
places in the document.** The code merely sided with one of them.

## C-3 For the worker: the tree is built by promotion, not by duplicating the last leaf

When a level has an odd number of leaves, the convenient choice is to duplicate the last
one (`H(X, X)`). With sorted pairs that is also the classic route to forged proofs. The
rule for the worker: **the odd node is promoted to the next level as is**, without a twin.
To be pinned by a worker side test, because Move cannot see it.

## C-4 For the worker: the sum of the leaves must match `declared_total`

The contract cannot sum the leaves, so `set_root` accepts any `declared_total` that
satisfies the A-3 invariant. If the worker declares a number different from the true sum,
the damage is bounded (the pot is still the ceiling, see B-2) but the public accounting
becomes a lie. Check to add in the worker, before signing: sum of leaves equals
`declared_total`, and the difference from the previous root equals the day's rewards.

---

## Things we did not fix, and say instead

- **`declared_total` remains our declaration.** Nobody can verify it on chain without
  redoing the computation from the snapshots. That is the same trust that sits at the
  centre of the whole design (A-1), and it is paid for by publishing the data, not with an
  `assert`.
- **Scoring is off chain.** The contract verifies a proof, it does not verify that the
  proof describes reality.
- **No clawback.** A reward paid to the wrong address is gone. See A-2 and B-3.
- **"Sent to 0x0" makes tokens unrecoverable, it does not reduce supply.** Anywhere we
  mention burning, that is what it means.
- **The admin cannot withdraw from the pot.** Ending the program means not publishing
  roots any more; the remainder stays claimable forever, and after 180 days of silence the
  unpromised part can be burned by anyone. Same shape as the burn treasury in
  `epoch-templates`.

## Error codes

```
0 EWrongVersion    1 EPaused        2 ENothingToClaim   3 EBadProof      4 EPotTooSmall
5 ETooEarlyToBurn  6 ENotUpgrade    7 EBadRoot          8 EZeroAmount
```

## Before publishing

1. `sui move build` and `sui move test` on a machine with the `sui` binary (18 tests).
2. A test for the `migrate` path (A-12), which today is code without a test.
3. Close A-15 and A-16 and implement C-3 and C-4 in the worker, with tests.
4. One farm per network, id recorded alongside the other shared objects.
5. Keep the `UpgradeCap` alive during the break in period, as was done for
   `epoch-lp-lock`, and say so publicly while it is.

The fourth review round belongs to the worker, which is where the numbers live.
