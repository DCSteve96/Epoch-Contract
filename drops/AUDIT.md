# Epoch Drops: internal audit notes

Package `epoch_drops`, module `drops`. One shared `Drop<T>` per campaign: a balance,
a Merkle root over `(address, allocation)`, the same schedule as Epoch vaults, and a
per-address claimed table. Nobody, creator or admin, can change the list, the
schedule or the beneficiaries after creation. Tests: 25, all green (`sui move test`).

## What the contract enforces

- Creation takes the exact fee (change returned), refuses a root that is not 32 bytes,
  a deposit below `declared_total`, a schedule that already ended, a cliff percentage
  without a cliff date, and a claim deadline that is not strictly after the end of the
  schedule.
- `claim` verifies the proof against `(salt, sender, allocation)`, computes the vested
  amount with the vault formula, pays the difference against what the sender already
  took, never more than the pot, and records the cumulative. Calling twice at the same
  time aborts instead of paying twice. After `claim_deadline_ms` (if set) claims abort.
- `withdraw_surplus` (creator only) is measured on deposits, not on claims:
  `deposited - declared_total - surplus_taken`. Even if the list promises more than
  declared, the creator cannot take a token a claimant is contesting.
- `top_up` is permissionless and never raises the withdrawable surplus.
- `reclaim_expired` (creator only) exists only when a deadline was set and only after it.
- The admin cap touches the fee treasury and nothing else.

## Findings and decisions

**F-1 (design, documented).** The contract cannot verify that the sum of the leaves
equals `declared_total`; it sees only the root. An under-declared drop leaves the last
claimants with an empty pot. Mitigations: the frontend computes the sum and passes it;
the claim page rebuilds the tree from the public leaves blob, checks the root and shows
"underfunded" when `sum(leaves) > declared_total`; `top_up` lets anyone fix it. The
surplus rule (F-3) makes sure the creator cannot profit from under-declaring.

**F-2 (fixed before publish).** A deadline equal to the schedule end made the last vested
share unclaimable: the share vests at `now >= end` and the claim required `now < deadline`.
Now the deadline must be strictly after the end.

**F-3 (fixed before publish).** First draft computed surplus as
`pot - (declared - paid)`. With an under-declared list `paid` can exceed `declared`, the
outstanding would read zero and the creator could withdraw the whole pot while claimants
were still owed tokens. Surplus is now tracked against deposits (`deposited`,
`surplus_taken`) and `top_up` does not touch `deposited`.

**F-4 (accepted).** A wrong root (typo, wrong salt) locks the deposit forever unless a
deadline was set. Same class as a vault with a wrong beneficiary. The creation page shows
the rebuilt root from the uploaded list and refuses to proceed if the leaves blob upload
did not return the expected content; a deadline is suggested as the recovery path.

**F-5 (accepted).** `recipients` is declared by the creator and informative only. The UI
labels it as such and shows the count from the blob.

**F-6 (accepted).** Leaf domain is a creator-chosen `salt`, not the object id (unknown
before the creating transaction). Reusing a salt and root on a second drop only makes the
creator pay the same list twice; it cannot be used to claim from someone else's drop
because the sender is inside the leaf.

**F-7 (accepted).** Proof elements are length-checked before comparison, as in the farm,
so a short element yields `EBadProof` instead of an out-of-bounds abort.

**F-8 (note).** The vesting math is copied from `vesting::compute_vested_total` and pinned
by `same_vesting_math_as_the_vaults`. The tree hashes are pinned by
`same_hashes_as_the_frontend` with vectors produced by `dropsMerkle.ts`.

**F-9 (accepted, second pass).** The contract does not forbid the same address twice in
the tree. Two leaves for one address with different allocations do not add up: `claimed`
is keyed by address, so that wallet can take at most the larger allocation, and the
difference stays locked as a false surplus. The tree builder in the frontend rejects a
repeated address before anything is uploaded, and the claim page refuses a list with
duplicates (it cannot rebuild the tree), so this only bites lists built outside our UI.
Rule for anyone building a list by hand: one line per address.

**F-10 (fixed, second pass, frontend).** `MAX_TITLE_BYTES` is measured in bytes on chain
while the input limited characters: a 64-character title with accents or emoji exceeds
64 bytes and would abort with `ETitleTooLong` after the list was already uploaded. The
form now measures the UTF-8 length and blocks the step.

**F-11 (note, second pass).** `Drop` has no `version` field on purpose: nobody, not even
the admin, has a function on a Drop, so there is nothing to gate. An upgrade can add
functions but cannot change the struct; if a future function must be reachable only from
a new version, it will need its own guard.

## Honest limits, to repeat in public

- Claimability "forever" holds only for drops created without a deadline. With a
  deadline, unclaimed tokens go back to the creator after it, and that date is on chain
  from day one.
- The leaves blob lives on Walrus and is paid by the protocol for a fixed period. If it
  expires, proofs can still be rebuilt from any copy of the list (the root on chain is
  the truth); the creator should keep the CSV.
