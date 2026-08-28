# Epoch Object Lock: internal security review

Scope: `sources/object_lock.move` (155 lines), `tests/object_lock_tests.move`, `Move.toml`.
Deployed mainnet package: `0xe0f23402fae139961a3d5ffa99d054a7821b82295eb5988957053f0c9a4dd14d`.
Reviewer: internal (pre-bounty). Date: 2026-08-29.

## Summary

The core logic is small and correct. No path was found where a third party, the
creator, or the protocol can take the locked object, shorten the lock, or drain a
locked LP position. All state-changing functions are gated by
`sender == beneficiary`, the item is stored by value in an `Option<T>` inside a
shared object with `key` only (no `store`, so the lock itself cannot be wrapped or
transferred), and there is no borrow/mutable-access function, which is what
prevents a "locked" Cetus position from having its liquidity withdrawn while
locked.

The material issues are one operational item (the UpgradeCap is still live, so the
"no backdoor" claim is not yet true on-chain) and two correctness/UX gaps that are
cheap to fix while the package is still upgradeable.

| # | Severity | Issue | Status |
|---|---|---|---|
| 1 | High (operational) | `UpgradeCap` not burned: package is still upgradeable | open |
| 2 | Medium | No `beneficiary != @0x0` check: permanent, silent loss | fixed, live in v2 |
| 3 | Medium (product) | Proof-of-lock is only as good as type verification in UI/indexer | fixed in the UI |
| 4 | Low | Claimed locks are never destroyed: storage rebate lost forever |
| 5 | Low | `ObjectLocked` event carries no type info: indexer needs an extra RPC |
| 6 | Low | `extend` has no clock and no upper bound |
| 7 | Info | Fees/rewards accrued by a locked LP position are inaccessible until unlock |
| 8 | Info | Test-coverage gaps on the `extend` guard paths and `lock_self` |

---

## 1. High (operational): UpgradeCap still live

`UpgradeCap 0x1e5b4a698184666f3ac8a081768de0cb6f5a06b6773246bcfd4d783ab1bfb768`
is still owned by the deployer. Until it is burned, the marketing claim "zero
admin, no upgrade-based backdoors" is not enforceable on-chain: a future upgrade
could add a function that borrows the item out of an existing lock. Note this is
true even for locks created today, because `ObjectLock` objects are typed by the
package's origin ID and would remain callable by the upgraded package.

**Action:** after the UI lock test, run
`sui client call --package 0x2 --module package --function make_immutable --args <UPGRADE_CAP>`
and put the tx hash in the docs. Do the fixes below first, in the same window.

## 2. Medium: no zero-address (or self-sanity) check on `beneficiary`

```move
public fun lock<T>(item: T, unlock_ms: u64, beneficiary: address, ...)
```
`beneficiary` is never validated. `lock(item, t, @0x0, ...)` produces a lock that
nobody can ever claim: `claim` requires `sender == @0x0`, which is unreachable.
The object is destroyed in practice, with no warning and no recovery. The Epoch
vesting contract already guards this case (Finding #8 of its own review), so this
is an inconsistency as well as a hazard: a typo or a truncated address pasted into
the UI permanently burns an LP position.

**Fix (applied in source):** `assert!(beneficiary != @0x0, EZeroBeneficiary);` with
`EZeroBeneficiary = 5`, covered by `lock_with_zero_beneficiary_aborts`. Live on mainnet in
package v2 `0x0267556b54173e71b4eefce7c2466770fa52842d0b4242dae49f023022636e89`
(upgrade tx `8FbSqus34zSKLPxMuq5BrJGi8ZKK2Up9sSxtn5M88WSJ`) and verified on-chain by
dry run: `beneficiary = @0x0` aborts with code 5, the same call with a real address
succeeds. The frontend now also rejects the zero address and
any address that is not a full 32-byte value, so truncated pastes are caught before
signing.

Note this does not remove the ability to burn intentionally: a caller who wants a
permanent burn can still set a far-future `unlock_ms`, which is a legitimate and
explicit use.

## 3. Medium (product, not contract): what a "verified lock" actually proves

`ObjectLock<T>` is generic over any `key + store` type. The contract guarantees
that *some* object of type `T` is locked; it says nothing about that object's
value. A malicious project can:

- lock a worthless NFT of a lookalike type and screenshot the shared lock, or
- lock a real Cetus `Position` that holds close to zero liquidity.

The on-chain data is honest either way; the misleading part happens in the reading.
Since Epoch publishes a public lock registry, the registry is the place that has to
be strict:

- display the **full type string** (`0x1eabed72...::position::Position`), not a
  friendly label, and mark unknown types plainly as unrecognized;
- for known LP types, fetch and display the actual position value (pool, tick
  range, liquidity) and not just "LP locked";
- never render project-supplied text next to a lock without making clear it is
  unverified.

**Fix (applied in the UI):** `/lock` now reads every locked item on-chain and shows
the full type string plus a `KNOWN TYPE` / `UNRECOGNISED TYPE` badge; for Cetus
positions it reads liquidity, tick range and the pool's current sqrt price and
displays the token amounts actually held (`utils/clmm.ts`), flagging empty
positions in red. The same read-out is shown in the create form before signing, and
the registry carries an explicit notice that a lock proves time-locking, not value.

## 4. Low: claimed locks are never destroyed

After `claim`, the `ObjectLock` remains shared forever with `item: None`. Sui
supports deleting shared objects, so the storage deposit could be returned.

**Fix (optional):**
```move
public fun destroy_claimed<T: key + store>(lock: ObjectLock<T>, ctx: &mut TxContext) {
    assert!(ctx.sender() == lock.beneficiary, ENotBeneficiary);
    let ObjectLock { id, item, unlock_ms: _, beneficiary: _, creator: _, locked_at_ms: _ } = lock;
    assert!(option::is_none(&item), EStillLocked);
    option::destroy_none(item);
    object::delete(id);
}
```
Keep it beneficiary-only so nobody can wipe the public record of someone else's
lock, and consider leaving the record in place deliberately (proof-of-lock history
has value); this is a trade-off, not a defect.

## 5. Low: `ObjectLocked` event has no type information

The indexer currently recovers the item type with a follow-up `getObject` and a
regex on `<...>`. Emitting `type_name::with_defining_ids<T>()` in the event makes
indexing single-pass and makes the type visible to anyone reading raw events,
which supports finding 3.

## 6. Low: `extend` accepts any future value and ignores the clock

`extend` only requires `new_unlock_ms > lock.unlock_ms`. The beneficiary can set
`u64::MAX` and lock the item forever, and can extend a lock whose unlock time has
already passed. Both are self-harm only (the beneficiary is the sole party giving
something up), so this is acceptable by design. Worth a confirmation dialog in the
UI showing the resulting date, and worth rejecting absurd dates client-side.

## 7. Info: an LP position keeps earning while locked, and the fees are locked too

There is deliberately no function that hands out `&mut T`. That is the property
that stops "locked" liquidity from being withdrawn through Cetus'
`remove_liquidity`, which takes `&mut Position`. The side effect is that swap fees
and rewards accrued by the position cannot be collected until the lock expires;
they are not lost, they are claimed with the position. **Do not add a
fee-collection helper that borrows the position mutably**: any such function
reintroduces the withdraw path and voids the whole guarantee. If fee collection
during the lock is ever required, it must be a Cetus-specific function that takes
only the fee coins and can be proven not to touch liquidity, and it should be
reviewed as its own change.

## 8. Info: test coverage gaps

Current suite (7 tests) covers claim after unlock, claim before unlock, claim by
non-beneficiary, past unlock date, extend, shorten, double claim. Missing:

- `extend` by a non-beneficiary (the `ENotBeneficiary` branch in `extend`)
- `extend` after claim (the `EAlreadyClaimed` branch in `extend`)
- `lock_self` happy path (beneficiary == creator)
- zero-address beneficiary, once finding 2 is fixed
- two locks of different `T` coexisting, to pin the generic instantiation

## Verified as safe

- Only the beneficiary can claim or extend; the creator has no privilege after
  `lock` beyond being recorded in the struct.
- The unlock timestamp can never decrease: the only writer is `extend`, guarded by
  a strict `>`.
- Double claim is impossible: `option::extract` plus the `is_some` assertion.
- The lock cannot be shortened or cancelled by an upgrade of a *different* package,
  and cannot be wrapped or traded (`ObjectLock` has `key` only).
- No arithmetic: no overflow or rounding surface.
- No admin, no fee, no treasury, so no privileged withdrawal path exists.
- `share_object` happens in the same transaction as creation, so there is no window
  where the lock is owned and drainable.

## Recommended order of operations

1. Patch findings 2 and 5 (and optionally 4), add the missing tests, run `sui move test`.
2. Upgrade the mainnet package with the patch.
3. Re-run the on-chain lock/claim test against the new package.
4. `make_immutable` on the UpgradeCap and publish the tx hash.
5. Point the frontend and indexer at the new package id, and keep the old package
   in the indexer's historical array so existing locks stay visible.
