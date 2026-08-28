/// Epoch Object Lock: time-lock ANY `key + store` object (LP position NFTs,
/// NameCaps, game items, anything) until an unlock date.
///
/// Built for LP vesting: Cetus CLMM positions and launchpad LP NFTs are objects,
/// not coins, so the (immutable) Epoch vesting vaults cannot hold them. This
/// package fills that gap with the same trust model:
///
/// - NO admin, NO fees, NO upgrade-based backdoors: once locked, nobody
///   (not the creator, not Epoch) can shorten or cancel the lock.
/// - Cliff-only unlock: objects are indivisible, so the lock releases the whole
///   object at `unlock_ms`. For linear vesting of fungible tokens use the Epoch
///   vesting vaults instead.
/// - Locks are SHARED objects: anyone can look one up on-chain and verify the
///   item, the unlock date and the beneficiary. Proof-of-lock by construction.
/// - The unlock can only ever be EXTENDED (never shortened), and only by the
///   beneficiary.
#[allow(lint(self_transfer, public_entry))]
module epoch_object_lock::object_lock {

    use std::option::{Self, Option};
    use sui::clock::Clock;
    use sui::event;

    // =========================================================================
    // Errors
    // =========================================================================

    const EStillLocked:     u64 = 0;
    const ENotBeneficiary:  u64 = 1;
    const EUnlockInPast:    u64 = 2;
    const EAlreadyClaimed:  u64 = 3;
    const ENotExtension:    u64 = 4; // new unlock must be strictly later

    // =========================================================================
    // Structs
    // =========================================================================

    /// A time-lock holding one object of type `T` until `unlock_ms`.
    /// Shared: publicly inspectable. `item` becomes None after claim.
    public struct ObjectLock<T: key + store> has key {
        id:          UID,
        item:        Option<T>,
        unlock_ms:   u64,
        beneficiary: address,
        creator:     address,
        locked_at_ms: u64,
    }

    // =========================================================================
    // Events
    // =========================================================================

    public struct ObjectLocked has copy, drop {
        lock_id:     ID,
        item_id:     ID,
        unlock_ms:   u64,
        creator:     address,
        beneficiary: address,
    }
    public struct ObjectClaimed has copy, drop {
        lock_id:     ID,
        item_id:     ID,
        beneficiary: address,
    }
    public struct LockExtended has copy, drop {
        lock_id:       ID,
        old_unlock_ms: u64,
        new_unlock_ms: u64,
    }

    // =========================================================================
    // Entry points
    // =========================================================================

    /// Lock `item` until `unlock_ms` (epoch milliseconds) for `beneficiary`.
    /// The lock is shared and immutable: no cancel, no early release.
    public fun lock<T: key + store>(
        item:        T,
        unlock_ms:   u64,
        beneficiary: address,
        clock:       &Clock,
        ctx:         &mut TxContext,
    ) {
        assert!(unlock_ms > clock.timestamp_ms(), EUnlockInPast);
        let item_id = object::id(&item);
        let lock = ObjectLock<T> {
            id:           object::new(ctx),
            item:         option::some(item),
            unlock_ms,
            beneficiary,
            creator:      ctx.sender(),
            locked_at_ms: clock.timestamp_ms(),
        };
        event::emit(ObjectLocked {
            lock_id: object::id(&lock), item_id, unlock_ms,
            creator: ctx.sender(), beneficiary,
        });
        transfer::share_object(lock);
    }

    /// Convenience: lock for yourself.
    public fun lock_self<T: key + store>(
        item: T, unlock_ms: u64, clock: &Clock, ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        lock(item, unlock_ms, sender, clock, ctx)
    }

    /// After `unlock_ms`, the beneficiary claims the object.
    public fun claim<T: key + store>(
        lock:  &mut ObjectLock<T>,
        clock: &Clock,
        ctx:   &mut TxContext,
    ) {
        assert!(clock.timestamp_ms() >= lock.unlock_ms, EStillLocked);
        assert!(ctx.sender() == lock.beneficiary,       ENotBeneficiary);
        assert!(option::is_some(&lock.item),            EAlreadyClaimed);
        let item = option::extract(&mut lock.item);
        event::emit(ObjectClaimed {
            lock_id: object::id(lock), item_id: object::id(&item),
            beneficiary: lock.beneficiary,
        });
        transfer::public_transfer(item, lock.beneficiary);
    }

    /// Extend the lock (never shorten). Only the beneficiary can extend:
    /// they are the only party giving something up.
    public fun extend<T: key + store>(
        lock:          &mut ObjectLock<T>,
        new_unlock_ms: u64,
        ctx:           &mut TxContext,
    ) {
        assert!(ctx.sender() == lock.beneficiary,  ENotBeneficiary);
        assert!(option::is_some(&lock.item),       EAlreadyClaimed);
        assert!(new_unlock_ms > lock.unlock_ms,    ENotExtension);
        event::emit(LockExtended {
            lock_id: object::id(lock),
            old_unlock_ms: lock.unlock_ms,
            new_unlock_ms,
        });
        lock.unlock_ms = new_unlock_ms;
    }

    // =========================================================================
    // Views
    // =========================================================================

    public fun unlock_ms<T: key + store>(lock: &ObjectLock<T>): u64 { lock.unlock_ms }
    public fun beneficiary<T: key + store>(lock: &ObjectLock<T>): address { lock.beneficiary }
    public fun creator<T: key + store>(lock: &ObjectLock<T>): address { lock.creator }
    public fun locked_at_ms<T: key + store>(lock: &ObjectLock<T>): u64 { lock.locked_at_ms }
    public fun is_claimed<T: key + store>(lock: &ObjectLock<T>): bool { option::is_none(&lock.item) }
}
