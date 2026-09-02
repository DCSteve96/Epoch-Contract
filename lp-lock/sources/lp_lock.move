/// Epoch LP Lock: time-lock a Cetus CLMM position WITHOUT giving up its income.
///
/// Why this exists, next to `epoch_object_lock`:
///
/// `object_lock` takes any `key + store` object and hands it back at the unlock
/// date. That is the right shape for an NFT or a cap, but it is the wrong shape
/// for a liquidity position, for two reasons.
///
/// 1. Income. While a position sits inside a generic lock, nobody can call
///    `collect_fee` on it, so locking liquidity means giving up its fee income
///    until unlock. That is the real reason teams do not lock: Cetus' own
///    `lp_burn` lets a burned position keep earning, a plain time-lock does not.
///    Here the beneficiary keeps the income and gives up only the capital.
///
/// 2. Empty locks. A generic lock cannot know whether the object it holds is
///    worth anything, and it should not pretend to. A module that claims to
///    lock liquidity can and must: `lock` aborts on a position with zero
///    liquidity, and records the tick range and the token amounts at lock time
///    so a reader can tell a real two-sided position from a decorative one.
///
/// Trust model, unchanged from the rest of Epoch: no admin, no fees, no
/// protocol-owned capability. The unlock date can only be pushed further away,
/// only by the beneficiary, and nothing can pull it closer.
///
/// The single security property everything else rests on: this module NEVER
/// hands a `&mut Position` to the outside. Cetus' `remove_liquidity` requires
/// one, so as long as that reference stays inside these functions, there is no
/// call path, in any PTB, that drains a locked position before its date.
module epoch_lp_lock::lp_lock {

    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use sui::balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;

    use integer_mate::i32::I32;

    use cetusclmm::clmm_math;
    use cetusclmm::config::GlobalConfig;
    use cetusclmm::pool::{Self, Pool};
    use cetusclmm::position::{Self, Position};
    use cetusclmm::rewarder::RewarderGlobalVault;

    // =========================================================================
    // Errors
    // =========================================================================

    const EStillLocked:      u64 = 0; // capital cannot move before the date
    const ENotBeneficiary:   u64 = 1;
    const EUnlockInPast:     u64 = 2;
    const EAlreadyClaimed:   u64 = 3;
    const ENotExtension:     u64 = 4; // an unlock date may only move forward
    const EZeroBeneficiary:  u64 = 5; // @0x0 could never sign a claim
    const EEmptyPosition:    u64 = 6; // locking nothing proves nothing
    const EWrongPool:        u64 = 7; // the pool must be the position's own
    const EInsufficientCoin: u64 = 8; // not enough to pay for the added liquidity
    const ESlippage:         u64 = 9; // the top-up would cost more than allowed

    // =========================================================================
    // Structs
    // =========================================================================

    /// A time-locked liquidity position.
    ///
    /// Shared, so anyone can verify it. Generic in `P` for one reason only: it
    /// lets the unit tests exercise the guards with a dummy object, since the
    /// Cetus interface package cannot mint a real `Position` outside a live
    /// network. Every public constructor below fixes `P = Position`.
    public struct LpLock<P: key + store> has key {
        id:                UID,
        position:          Option<P>,
        /// Fixed at lock time. Every Cetus call must present this pool.
        pool_id:           ID,
        unlock_ms:         u64,
        locked_at_ms:      u64,
        beneficiary:       address,
        creator:           address,
        /// Snapshot from the pool's own `PositionInfo`. Liquidity can only grow
        /// while locked, so this is a floor, not a claim about the present.
        liquidity_at_lock: u128,
        /// The range and the market at lock time. Without these, "liquidity
        /// locked" is a number with no meaning: a position parked entirely
        /// outside the market can hold a large liquidity value and provide no
        /// depth at all. Recorded so a reader can tell the difference.
        tick_lower:        I32,
        tick_upper:        I32,
        tick_at_lock:      I32,
        amount_a_at_lock:  u64,
        amount_b_at_lock:  u64,
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// Carries the pair types and the range on purpose: an indexer should not
    /// have to fetch the pool to learn what was locked, and anyone reading raw
    /// events without our frontend should see something meaningful. Event shape
    /// freezes at publication, so everything worth having is here from the start.
    public struct LpLocked has copy, drop {
        lock_id:      ID,
        position_id:  ID,
        pool_id:      ID,
        coin_type_a:  TypeName,
        coin_type_b:  TypeName,
        liquidity:    u128,
        tick_lower:   I32,
        tick_upper:   I32,
        tick_at_lock: I32,
        amount_a:     u64,
        amount_b:     u64,
        unlock_ms:    u64,
        creator:      address,
        beneficiary:  address,
    }
    public struct LpClaimed has copy, drop {
        lock_id:     ID,
        position_id: ID,
        beneficiary: address,
    }
    public struct LpExtended has copy, drop {
        lock_id:       ID,
        old_unlock_ms: u64,
        new_unlock_ms: u64,
    }
    public struct LpDestroyed has copy, drop {
        lock_id:     ID,
        beneficiary: address,
    }
    public struct FeesCollected has copy, drop {
        lock_id:     ID,
        pool_id:     ID,
        coin_type_a: TypeName,
        coin_type_b: TypeName,
        amount_a:    u64,
        amount_b:    u64,
        beneficiary: address,
    }
    /// The reward type is the whole point of the event: a pool can run several
    /// rewarders, and without it an indexer cannot tell which token was paid.
    public struct RewardsCollected has copy, drop {
        lock_id:     ID,
        pool_id:     ID,
        reward_type: TypeName,
        amount:      u64,
        beneficiary: address,
    }
    public struct LiquidityAdded has copy, drop {
        lock_id:       ID,
        pool_id:       ID,
        delta:         u128,
        new_liquidity: u128,
        amount_a:      u64,
        amount_b:      u64,
        payer:         address,
    }

    // =========================================================================
    // Lock / claim / extend
    // =========================================================================

    /// Lock `position` until `unlock_ms` for `beneficiary`.
    ///
    /// `pool` is required for three reasons: the pool identity is recorded from
    /// the chain rather than from the caller, the authoritative liquidity lives
    /// in the pool and not in the position NFT, and the token amounts are what
    /// make the record readable.
    ///
    /// It stays `&mut` even though every read here now takes `&`: changing a
    /// public signature would make the package upgrade incompatible, and locks
    /// already created must keep resolving. Not worth breaking them to drop a
    /// `mut`.
    public fun lock<A, B>(
        position:    Position,
        pool:        &mut Pool<A, B>,
        unlock_ms:   u64,
        beneficiary: address,
        clock:       &Clock,
        ctx:         &mut TxContext,
    ) {
        assert!(unlock_ms > clock.timestamp_ms(), EUnlockInPast);
        assert!(beneficiary != @0x0, EZeroBeneficiary);

        let pool_id     = object::id(pool);
        let position_id = object::id(&position);
        assert!(position::pool_id(&position) == pool_id, EWrongPool);

        // Cetus documents the fields on the position NFT as display-only: the
        // numbers that take part in the calculations live in `PositionInfo`,
        // inside the pool. Read the authoritative source, since the whole
        // product is the claim that this number is true.
        let (liquidity, tick_lower, tick_upper) = {
            let info = pool::borrow_position_info(pool, position_id);
            let (lo, hi) = position::info_tick_range(info);
            (position::info_liquidity(info), lo, hi)
        };
        assert!(liquidity > 0, EEmptyPosition);

        let tick_at_lock = pool::current_tick_index(pool);

        // Gli importi si calcolano con la matematica pura di Cetus invece che
        // con `pool::get_position_amounts`. Quest'ultima, sulla v14 di mainnet,
        // aborta con codice 32 anche su una position sana, mentre su testnet
        // passava: è una funzione che tocca lo stato della pool e il suo
        // comportamento cambia fra versioni. `get_amount_by_liquidity` prende
        // solo numeri che abbiamo già letto, quindi non ha stato da cui abortire
        // e dà lo stesso risultato, perché è quello che Cetus usa internamente.
        let (amount_a, amount_b) = clmm_math::get_amount_by_liquidity(
            tick_lower, tick_upper, tick_at_lock,
            pool::current_sqrt_price(pool), liquidity, false,
        );

        let lock = LpLock<Position> {
            id:                object::new(ctx),
            position:          option::some(position),
            pool_id,
            unlock_ms,
            locked_at_ms:      clock.timestamp_ms(),
            beneficiary,
            creator:           ctx.sender(),
            liquidity_at_lock: liquidity,
            tick_lower,
            tick_upper,
            tick_at_lock,
            amount_a_at_lock:  amount_a,
            amount_b_at_lock:  amount_b,
        };
        event::emit(LpLocked {
            lock_id: object::id(&lock), position_id, pool_id,
            coin_type_a: type_name::with_defining_ids<A>(),
            coin_type_b: type_name::with_defining_ids<B>(),
            liquidity, tick_lower, tick_upper, tick_at_lock,
            amount_a, amount_b,
            unlock_ms, creator: ctx.sender(), beneficiary,
        });
        transfer::share_object(lock);
    }

    /// Convenience: lock for yourself.
    public fun lock_self<A, B>(
        position: Position, pool: &mut Pool<A, B>, unlock_ms: u64,
        clock: &Clock, ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        lock(position, pool, unlock_ms, sender, clock, ctx)
    }

    /// After the unlock date, the beneficiary takes the position back.
    public fun claim<P: key + store>(
        lock:  &mut LpLock<P>,
        clock: &Clock,
        ctx:   &mut TxContext,
    ) {
        assert!(clock.timestamp_ms() >= lock.unlock_ms, EStillLocked);
        assert!(ctx.sender() == lock.beneficiary,       ENotBeneficiary);
        assert!(option::is_some(&lock.position),        EAlreadyClaimed);
        let lock_id  = object::id(lock);
        let position = option::extract(&mut lock.position);
        event::emit(LpClaimed {
            lock_id, position_id: object::id(&position), beneficiary: lock.beneficiary,
        });
        transfer::public_transfer(position, lock.beneficiary);
    }

    /// Push the unlock date further away. Never closer, and only the
    /// beneficiary may do it: they are the only party giving something up.
    public fun extend<P: key + store>(
        lock:          &mut LpLock<P>,
        new_unlock_ms: u64,
        ctx:           &mut TxContext,
    ) {
        assert!(ctx.sender() == lock.beneficiary,   ENotBeneficiary);
        assert!(option::is_some(&lock.position),    EAlreadyClaimed);
        assert!(new_unlock_ms > lock.unlock_ms,     ENotExtension);
        event::emit(LpExtended {
            lock_id: object::id(lock),
            old_unlock_ms: lock.unlock_ms,
            new_unlock_ms,
        });
        lock.unlock_ms = new_unlock_ms;
    }

    /// Delete a lock whose position has already been returned, recovering the
    /// storage deposit. Beneficiary only: nobody should be able to erase the
    /// public record of someone else's lock. Keeping the record is also a valid
    /// choice, so this is opt-in and never automatic.
    public fun destroy_claimed<P: key + store>(
        lock: LpLock<P>,
        ctx:  &mut TxContext,
    ) {
        assert!(ctx.sender() == lock.beneficiary, ENotBeneficiary);
        // Refuse to delete a lock that still holds the capital. Checked before
        // taking the struct apart, so the failure mode reads as a refusal
        // rather than as an abort in the middle of a destructuring.
        assert!(option::is_none(&lock.position), EStillLocked);
        event::emit(LpDestroyed {
            lock_id: object::id(&lock), beneficiary: lock.beneficiary,
        });
        let LpLock {
            id, position, pool_id: _, unlock_ms: _, locked_at_ms: _,
            beneficiary: _, creator: _, liquidity_at_lock: _,
            tick_lower: _, tick_upper: _, tick_at_lock: _,
            amount_a_at_lock: _, amount_b_at_lock: _,
        } = lock;
        option::destroy_none(position);
        object::delete(id);
    }

    // =========================================================================
    // Income: allowed for the whole duration of the lock
    // =========================================================================

    /// Collect the position's trading fees and send them to the beneficiary.
    ///
    /// Takes `&LpLock`, not `&mut`: Cetus' `collect_fee` only needs `&Position`,
    /// so this path cannot touch the capital even by mistake.
    ///
    /// Permissionless on purpose. The proceeds go to `lock.beneficiary` and
    /// nowhere else, whoever pays the gas, so gating it on the beneficiary would
    /// only add a liveness dependency: a beneficiary that cannot sign right now
    /// would have no way to have its own fees swept.
    public fun collect_fee<A, B>(
        lock:   &LpLock<Position>,
        config: &GlobalConfig,
        pool:   &mut Pool<A, B>,
        ctx:    &mut TxContext,
    ) {
        assert!(option::is_some(&lock.position),  EAlreadyClaimed);
        assert!(object::id(pool) == lock.pool_id, EWrongPool);

        let position = option::borrow(&lock.position);
        let (bal_a, bal_b) = pool::collect_fee(config, pool, position, true);
        let amount_a = balance::value(&bal_a);
        let amount_b = balance::value(&bal_b);

        event::emit(FeesCollected {
            lock_id: object::id(lock), pool_id: lock.pool_id,
            coin_type_a: type_name::with_defining_ids<A>(),
            coin_type_b: type_name::with_defining_ids<B>(),
            amount_a, amount_b, beneficiary: lock.beneficiary,
        });
        pay(coin::from_balance(bal_a, ctx), lock.beneficiary);
        pay(coin::from_balance(bal_b, ctx), lock.beneficiary);
    }

    /// Collect one incentive reward stream and send it to the beneficiary.
    /// Permissionless for the same reason as `collect_fee`.
    public fun collect_reward<A, B, R>(
        lock:   &LpLock<Position>,
        config: &GlobalConfig,
        pool:   &mut Pool<A, B>,
        vault:  &mut RewarderGlobalVault,
        clock:  &Clock,
        ctx:    &mut TxContext,
    ) {
        assert!(option::is_some(&lock.position),  EAlreadyClaimed);
        assert!(object::id(pool) == lock.pool_id, EWrongPool);

        let position = option::borrow(&lock.position);
        let bal = pool::collect_reward<A, B, R>(config, pool, position, vault, true, clock);
        let amount = balance::value(&bal);

        event::emit(RewardsCollected {
            lock_id: object::id(lock), pool_id: lock.pool_id,
            reward_type: type_name::with_defining_ids<R>(),
            amount, beneficiary: lock.beneficiary,
        });
        pay(coin::from_balance(bal, ctx), lock.beneficiary);
    }

    /// Add liquidity to a locked position. Open to anyone on purpose: topping up
    /// a lock can only strengthen it, and it lets a third party reinforce a
    /// commitment without being able to touch it.
    ///
    /// `max_a` and `max_b` are not optional politeness. Cetus prices the top-up
    /// at the pool's price at execution time, so without an upper bound the call
    /// spends whatever the coins hold: a price move between quoting and landing,
    /// deliberate or not, would consume the whole balance. Everywhere else that
    /// mistake is undone with `remove_liquidity` in the next block; here there
    /// is no removal path until the unlock date, so the overpayment is locked in
    /// and then belongs to the beneficiary. Bound it.
    ///
    /// Leftovers go back to the payer, not to the beneficiary: whoever pays owns
    /// what they did not spend.
    public fun add_liquidity<A, B>(
        lock:            &mut LpLock<Position>,
        config:          &GlobalConfig,
        pool:            &mut Pool<A, B>,
        mut coin_a:      Coin<A>,
        mut coin_b:      Coin<B>,
        delta_liquidity: u128,
        max_a:           u64,
        max_b:           u64,
        clock:           &Clock,
        ctx:             &mut TxContext,
    ) {
        assert!(option::is_some(&lock.position),  EAlreadyClaimed);
        assert!(object::id(pool) == lock.pool_id, EWrongPool);

        let lock_id = object::id(lock);
        let payer   = ctx.sender();

        let position = option::borrow_mut(&mut lock.position);
        let receipt = pool::add_liquidity(config, pool, position, delta_liquidity, clock);
        let (need_a, need_b) = pool::add_liquidity_pay_amount(&receipt);
        assert!(need_a <= max_a && need_b <= max_b,  ESlippage);
        assert!(coin::value(&coin_a) >= need_a,      EInsufficientCoin);
        assert!(coin::value(&coin_b) >= need_b,      EInsufficientCoin);

        let bal_a = coin::into_balance(coin::split(&mut coin_a, need_a, ctx));
        let bal_b = coin::into_balance(coin::split(&mut coin_b, need_b, ctx));
        pool::repay_add_liquidity(config, pool, bal_a, bal_b, receipt);

        let new_liquidity = position::info_liquidity(
            pool::borrow_position_info(pool, object::id(option::borrow(&lock.position))),
        );
        event::emit(LiquidityAdded {
            lock_id, pool_id: lock.pool_id, delta: delta_liquidity, new_liquidity,
            amount_a: need_a, amount_b: need_b, payer,
        });
        pay(coin_a, payer);
        pay(coin_b, payer);
    }

    /// Send a coin, or destroy it when there is nothing to send: shipping empty
    /// coin objects around is just litter on the beneficiary's wallet.
    fun pay<T>(c: Coin<T>, to: address) {
        if (coin::value(&c) == 0) { coin::destroy_zero(c) }
        else { transfer::public_transfer(c, to) }
    }

    // =========================================================================
    // Views
    // =========================================================================

    public fun unlock_ms<P: key + store>(lock: &LpLock<P>): u64 { lock.unlock_ms }
    public fun locked_at_ms<P: key + store>(lock: &LpLock<P>): u64 { lock.locked_at_ms }
    public fun beneficiary<P: key + store>(lock: &LpLock<P>): address { lock.beneficiary }
    public fun creator<P: key + store>(lock: &LpLock<P>): address { lock.creator }
    public fun pool_id<P: key + store>(lock: &LpLock<P>): ID { lock.pool_id }
    public fun liquidity_at_lock<P: key + store>(lock: &LpLock<P>): u128 { lock.liquidity_at_lock }
    public fun tick_range<P: key + store>(lock: &LpLock<P>): (I32, I32) { (lock.tick_lower, lock.tick_upper) }
    public fun tick_at_lock<P: key + store>(lock: &LpLock<P>): I32 { lock.tick_at_lock }
    public fun amounts_at_lock<P: key + store>(lock: &LpLock<P>): (u64, u64) {
        (lock.amount_a_at_lock, lock.amount_b_at_lock)
    }
    public fun is_claimed<P: key + store>(lock: &LpLock<P>): bool { option::is_none(&lock.position) }

    /// Live liquidity, read from the pool rather than from the position NFT.
    public fun liquidity<A, B>(lock: &LpLock<Position>, pool: &Pool<A, B>): u128 {
        assert!(object::id(pool) == lock.pool_id, EWrongPool);
        if (option::is_none(&lock.position)) { 0 }
        else {
            position::info_liquidity(
                pool::borrow_position_info(pool, object::id(option::borrow(&lock.position))),
            )
        }
    }

    // =========================================================================
    // Test-only
    // =========================================================================

    /// Builds a lock around any object, so the guards can be tested without a
    /// live Cetus pool. Runs the SAME assertions as `lock` on the values it is
    /// given, including the empty-position check: a test constructor that skips
    /// the guards it is supposed to protect is worse than no test at all.
    /// Not compiled into the published bytecode.
    #[test_only]
    public fun lock_for_testing<P: key + store>(
        item:        P,
        pool_id:     ID,
        liquidity:   u128,
        unlock_ms:   u64,
        beneficiary: address,
        clock:       &Clock,
        ctx:         &mut TxContext,
    ) {
        use integer_mate::i32;
        assert!(unlock_ms > clock.timestamp_ms(), EUnlockInPast);
        assert!(beneficiary != @0x0, EZeroBeneficiary);
        assert!(liquidity > 0, EEmptyPosition);
        let lock = LpLock<P> {
            id:                object::new(ctx),
            position:          option::some(item),
            pool_id,
            unlock_ms,
            locked_at_ms:      clock.timestamp_ms(),
            beneficiary,
            creator:           ctx.sender(),
            liquidity_at_lock: liquidity,
            tick_lower:        i32::from_u32(0),
            tick_upper:        i32::from_u32(0),
            tick_at_lock:      i32::from_u32(0),
            amount_a_at_lock:  0,
            amount_b_at_lock:  0,
        };
        transfer::share_object(lock);
    }
}
