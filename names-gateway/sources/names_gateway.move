/// Epoch Names Gateway: register a `.epoch` name paying in a partner token
/// instead of SUI, with the token kept by the protocol instead of sold.
///
/// Why a separate package instead of a sixth upgrade of `walrus_names`:
/// that package is the registry of every name, audited and live. Accepting a
/// new coin is a payment feature, and the EPT path inside it already showed
/// the cost of putting payment logic in the registry: one coin, one fixed fee,
/// and three manual recalibrations when the price drifted. This module sits
/// next to the registry and calls its public `register`, which means:
///
/// - the name that comes out is IDENTICAL to one paid in SUI: `register` uses
///   `ctx.sender()`, which is the user, so the NameCap, the Registry record,
///   the cap link and the `NameRegistered` event are the usual ones and no
///   indexer or page needs to know a partner token was involved;
/// - any number of coins can be accepted, each with its own fee, switch and
///   balance, added and removed from the admin panel without a republish;
/// - the registry's SUI fee is still paid, in full, from a SUI float this
///   gateway keeps. That fee lands in the names Treasury, which the protocol
///   controls, so the float is recycled and the arrangement costs only gas;
/// - the partner tokens collected can leave this object in exactly one way:
///   `lock_collected`, which puts them in an Epoch vesting vault that unlocks
///   no sooner than a year later. There is no withdraw. The public promise,
///   that what is earned in a partner token is locked and not sold, is kept
///   by this code, not by whoever holds the admin key.
///
/// Fees are fixed numbers of the token, not pool reads. A pool read can be
/// pushed around inside one transaction for less than a name costs; a fixed
/// number cannot, it just drifts. The drift is handled by a `KeeperCap`: a key
/// a bot can hold that may only move a fee within bounds the admin set (a
/// floor, a ceiling, a maximum step per update, a minimum time between
/// updates), so following the price is automatic. A stolen keeper key is
/// worth one bounded step every `MIN_KEEPER_INTERVAL_MS` until the admin
/// revokes it, and never more than the corridor.
///
/// The self-transfer lint is silenced deliberately: change and withdrawals go
/// back to the transaction sender by design, which is what a payment gateway
/// should do.
#[allow(lint(self_transfer))]
module epoch_names_gateway::names_gateway {

    use std::string::{Self, String};
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::dynamic_field as df;
    use sui::event;
    use sui::sui::SUI;
    use sui::vec_set::{Self, VecSet};
    use vesting_service::vesting::{Self, Treasury as VestingTreasury};
    use walrus_names::walrus_names::{Self, Registry, WalNamesTreasury};

    // =========================================================================
    // Errors
    // =========================================================================

    const ETokenNotAccepted:   u64 = 0; // no config for this coin type
    const ETokenDisabled:      u64 = 1; // config exists but the switch is off
    const EInsufficientToken:  u64 = 2; // payment below the fee for this length
    const EFloatTooLow:        u64 = 3; // the SUI float cannot cover the registry fee
    const EZeroFee:            u64 = 4; // a zero fee would make names free
    const ESuiFeeTooHigh:      u64 = 5; // the registry fee exceeds our cap
    const EPaused:             u64 = 6; // the gateway is paused
    const ETokenAlreadyAdded:  u64 = 7; // add_token twice for the same coin
    const EBadBounds:          u64 = 8; // min > fee, fee > max, or step > 50%
    const EOutOfBounds:        u64 = 9; // keeper update outside the admin bounds
    const EStepTooLarge:       u64 = 10; // keeper update moves the fee too far at once
    const EBalanceNotEmpty:    u64 = 11; // remove_token with tokens still inside
    const EWhitelistedUseFree: u64 = 12; // a whitelisted wallet has a free name: use it
    const ENothingToLock:      u64 = 13; // lock_collected with an empty balance
    const ELockTooShort:       u64 = 14; // a vault shorter than the minimum lock
    const EFeeTooHigh:         u64 = 15; // fee_base so large that x25 would overflow
    const EKeeperNotAuthorized: u64 = 16; // a revoked (or foreign) keeper cap
    const EKeeperTooSoon:      u64 = 17; // keeper update before the minimum interval

    /// A keeper may never move a fee by more than half in one update.
    const MAX_STEP_BPS: u64 = 5_000;
    /// Collected tokens leave only into a vault at least this long: 365 days.
    const MIN_LOCK_MS: u64 = 365 * 24 * 60 * 60 * 1000;
    /// Ceiling on any fee base, so `fee_base * 25` (3-char names) cannot overflow.
    const MAX_FEE_BASE: u64 = 700_000_000_000_000_000;
    /// A keeper may move a fee at most once every 6 hours: steps cannot be
    /// compounded inside one transaction (or one day) to walk the fee to the
    /// edge of the corridor.
    const MIN_KEEPER_INTERVAL_MS: u64 = 6 * 60 * 60 * 1000;

    // =========================================================================
    // Objects
    // =========================================================================

    /// Controls configuration, the SUI float and the collected tokens.
    /// No power over any name.
    public struct GatewayAdminCap has key, store { id: UID }

    /// May only move a token's fee within the bounds the admin set, and only if
    /// its id is still in `Gateway.keepers`: the admin revokes a key without
    /// having to get the object back. Meant for a bot that follows the pool
    /// price; harmless beyond that.
    public struct KeeperCap has key, store { id: UID }

    /// Shared: anyone can pay through it; only the admin can take anything out.
    public struct Gateway has key {
        id:          UID,
        sui_float:   Balance<SUI>,
        /// Most SUI this gateway will ever pay for one name. The registry fee
        /// lives in another contract and can be raised there; above the cap we
        /// abort instead of draining the float.
        max_sui_fee: u64,
        /// Kill switch for every token at once. Paying in SUI or EPT directly
        /// to the registry is unaffected.
        paused:      bool,
        /// Lifetime counter across all tokens, for the public page.
        names_sold:  u64,
        /// The accepted coin types, so a page can list them without guessing.
        /// Each one has a `TokenConfig<T>` attached as a dynamic field.
        tokens:      vector<TypeName>,
        /// Ids of the keeper caps that are still allowed to act.
        keepers:     VecSet<ID>,
    }

    /// Dynamic-field key: one config per coin type.
    public struct TokenKey has copy, drop, store { t: TypeName }

    /// Everything about one accepted coin. Lives in a dynamic field of the
    /// Gateway so coins can be added after publish.
    public struct TokenConfig<phantom T> has store {
        /// Raw units of T for a name of 5+ characters. Shorter names use the
        /// registry's own multipliers (x5 for 4 chars, x25 for 3) so the
        /// discount is the same at every length.
        fee_base:        u64,
        /// Bounds for the keeper, not for the admin.
        min_fee_base:    u64,
        max_fee_base:    u64,
        /// Largest relative move a keeper may make in one update, in bps.
        max_step_bps:    u64,
        enabled:         bool,
        collected:       Balance<T>,
        names_sold:      u64,
        total_collected: u64,
        /// Clock time of the last fee change: for the keeper interval, and so
        /// a page can show how stale the price is.
        fee_updated_ms:  u64,
    }

    // =========================================================================
    // Events
    // =========================================================================

    public struct NamePaidInToken has copy, drop {
        payer:     address,
        name:      String,
        coin_type: TypeName,
        amount:    u64,
        sui_fee:   u64,
    }
    public struct TokenAdded     has copy, drop { coin_type: TypeName, fee_base: u64 }
    public struct TokenRemoved   has copy, drop { coin_type: TypeName }
    public struct TokenFeeUpdated has copy, drop { coin_type: TypeName, old_fee_base: u64, new_fee_base: u64, by_keeper: bool }
    public struct TokenBoundsUpdated has copy, drop { coin_type: TypeName, min_fee_base: u64, max_fee_base: u64, max_step_bps: u64 }
    public struct TokenEnabledUpdated has copy, drop { coin_type: TypeName, enabled: bool }
    public struct TokenLocked    has copy, drop { coin_type: TypeName, amount: u64, beneficiary: address, unlock_ms: u64 }
    public struct FloatFunded    has copy, drop { funder: address, amount: u64, new_total: u64 }
    public struct FloatWithdrawn has copy, drop { amount: u64, new_total: u64 }
    public struct MaxSuiFeeUpdated has copy, drop { max_sui_fee: u64 }
    public struct PausedUpdated  has copy, drop { paused: bool }
    public struct KeeperMinted   has copy, drop { keeper: ID, to: address }
    public struct KeeperRevoked  has copy, drop { keeper: ID }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Gateway {
            id:          object::new(ctx),
            sui_float:   balance::zero<SUI>(),
            // 15 SUI: a 3-char name costs 12.5 SUI at the current base, so a
            // normal fee change is fine and a runaway one is not.
            max_sui_fee: 15_000_000_000,
            paused:      false,
            names_sold:  0,
            tokens:      vector[],
            keepers:     vec_set::empty(),
        });
        transfer::public_transfer(GatewayAdminCap { id: object::new(ctx) }, ctx.sender());
    }

    // =========================================================================
    // Admin: tokens
    // =========================================================================

    /// Accept a new coin. `fee_base` is for a 5+ char name, in raw units.
    /// The bounds apply to keeper updates only.
    public fun add_token<T>(
        _cap:         &GatewayAdminCap,
        gw:           &mut Gateway,
        fee_base:     u64,
        min_fee_base: u64,
        max_fee_base: u64,
        max_step_bps: u64,
        clock:        &Clock,
    ) {
        let t = type_name::with_defining_ids<T>();
        assert!(!df::exists(&gw.id, TokenKey { t }), ETokenAlreadyAdded);
        assert_fee(fee_base);
        assert_bounds(fee_base, min_fee_base, max_fee_base, max_step_bps);
        df::add(&mut gw.id, TokenKey { t }, TokenConfig<T> {
            fee_base, min_fee_base, max_fee_base, max_step_bps,
            enabled:         true,
            collected:       balance::zero<T>(),
            names_sold:      0,
            total_collected: 0,
            fee_updated_ms:  clock.timestamp_ms(),
        });
        gw.tokens.push_back(t);
        event::emit(TokenAdded { coin_type: t, fee_base });
    }

    /// Admin: set the fee directly. Not bound by the keeper limits, but the
    /// bounds are widened if needed so the keeper can keep working from here.
    public fun set_token_fee<T>(_cap: &GatewayAdminCap, gw: &mut Gateway, fee_base: u64, clock: &Clock) {
        assert_fee(fee_base);
        let t = type_name::with_defining_ids<T>();
        let cfg = config_mut<T>(gw, t);
        let old = cfg.fee_base;
        cfg.fee_base = fee_base;
        if (fee_base < cfg.min_fee_base) { cfg.min_fee_base = fee_base };
        if (fee_base > cfg.max_fee_base) { cfg.max_fee_base = fee_base };
        cfg.fee_updated_ms = clock.timestamp_ms();
        event::emit(TokenFeeUpdated { coin_type: t, old_fee_base: old, new_fee_base: fee_base, by_keeper: false });
    }

    /// Admin: the corridor a keeper may move the fee in.
    public fun set_token_bounds<T>(
        _cap:         &GatewayAdminCap,
        gw:           &mut Gateway,
        min_fee_base: u64,
        max_fee_base: u64,
        max_step_bps: u64,
    ) {
        let t = type_name::with_defining_ids<T>();
        let cfg = config_mut<T>(gw, t);
        assert_bounds(cfg.fee_base, min_fee_base, max_fee_base, max_step_bps);
        cfg.min_fee_base = min_fee_base;
        cfg.max_fee_base = max_fee_base;
        cfg.max_step_bps = max_step_bps;
        event::emit(TokenBoundsUpdated { coin_type: t, min_fee_base, max_fee_base, max_step_bps });
    }

    /// Admin: switch one coin off (or on) without losing its config or balance.
    public fun set_token_enabled<T>(_cap: &GatewayAdminCap, gw: &mut Gateway, enabled: bool) {
        let t = type_name::with_defining_ids<T>();
        config_mut<T>(gw, t).enabled = enabled;
        event::emit(TokenEnabledUpdated { coin_type: t, enabled });
    }

    /// Admin: drop a coin entirely. Its balance must have been locked first:
    /// a config holding tokens cannot be deleted by mistake.
    public fun remove_token<T>(_cap: &GatewayAdminCap, gw: &mut Gateway) {
        let t = type_name::with_defining_ids<T>();
        assert!(df::exists(&gw.id, TokenKey { t }), ETokenNotAccepted);
        let TokenConfig<T> { fee_base: _, min_fee_base: _, max_fee_base: _, max_step_bps: _, enabled: _, collected, names_sold: _, total_collected: _, fee_updated_ms: _ } =
            df::remove(&mut gw.id, TokenKey { t });
        assert!(collected.value() == 0, EBalanceNotEmpty);
        collected.destroy_zero();
        let (found, i) = gw.tokens.index_of(&t);
        if (found) { gw.tokens.remove(i); };
        event::emit(TokenRemoved { coin_type: t });
    }

    /// Admin: move everything collected in `T` into an Epoch vesting vault
    /// that unlocks in full after `lock_ms`, which cannot be less than a year.
    /// This is the only way tokens leave the gateway. The vault is a normal
    /// one (creator = the admin, shared, immutable), so it shows up in the
    /// Epoch UI and its id is what gets announced. `vault_fee` is the vesting
    /// deploy fee in SUI, paid by the admin; the vesting contract refunds any
    /// excess to the sender.
    public fun lock_collected<T>(
        _cap:        &GatewayAdminCap,
        gw:          &mut Gateway,
        vesting:     &mut VestingTreasury,
        vault_fee:   Coin<SUI>,
        beneficiary: address,
        lock_ms:     u64,
        clock:       &Clock,
        ctx:         &mut TxContext,
    ) {
        assert!(lock_ms >= MIN_LOCK_MS, ELockTooShort);
        let t = type_name::with_defining_ids<T>();
        let cfg = config_mut<T>(gw, t);
        let amount = cfg.collected.value();
        assert!(amount > 0, ENothingToLock);
        let tokens = coin::take(&mut cfg.collected, amount, ctx);
        let unlock_ms = clock.timestamp_ms() + lock_ms;
        // 100% at the cliff; the linear window is irrelevant and set to the
        // same instant, which the vesting contract accepts (end >= start).
        vesting::create_vault<T>(
            vesting, vault_fee, tokens, beneficiary,
            unlock_ms, 10_000, unlock_ms, unlock_ms, clock, ctx,
        );
        event::emit(TokenLocked { coin_type: t, amount, beneficiary, unlock_ms });
    }

    // =========================================================================
    // Keeper
    // =========================================================================

    /// Admin: hand a keeper key to a bot wallet. Any number can exist; each
    /// is registered in the gateway so it can be revoked later.
    public fun mint_keeper(_cap: &GatewayAdminCap, gw: &mut Gateway, to: address, ctx: &mut TxContext) {
        let cap = KeeperCap { id: object::new(ctx) };
        let id = object::id(&cap);
        gw.keepers.insert(id);
        transfer::public_transfer(cap, to);
        event::emit(KeeperMinted { keeper: id, to });
    }

    /// Admin: a revoked keeper cap still exists but does nothing.
    public fun revoke_keeper(_cap: &GatewayAdminCap, gw: &mut Gateway, keeper: ID) {
        if (gw.keepers.contains(&keeper)) { gw.keepers.remove(&keeper); };
        event::emit(KeeperRevoked { keeper });
    }

    /// Keeper: move the fee to follow the price, inside the admin corridor, by
    /// at most `max_step_bps` of the current value, and not more often than
    /// once every `MIN_KEEPER_INTERVAL_MS` per token (the admin's own fee
    /// changes count as an update too).
    public fun keeper_set_fee<T>(keeper: &KeeperCap, gw: &mut Gateway, fee_base: u64, clock: &Clock) {
        assert!(gw.keepers.contains(&object::id(keeper)), EKeeperNotAuthorized);
        assert_fee(fee_base);
        let now = clock.timestamp_ms();
        let t = type_name::with_defining_ids<T>();
        let cfg = config_mut<T>(gw, t);
        assert!(now >= cfg.fee_updated_ms + MIN_KEEPER_INTERVAL_MS, EKeeperTooSoon);
        assert!(fee_base >= cfg.min_fee_base && fee_base <= cfg.max_fee_base, EOutOfBounds);
        let old = cfg.fee_base;
        let diff = if (fee_base > old) { fee_base - old } else { old - fee_base };
        let max_diff = ((old as u128) * (cfg.max_step_bps as u128) / 10_000u128) as u64;
        assert!(diff <= max_diff, EStepTooLarge);
        cfg.fee_base = fee_base;
        cfg.fee_updated_ms = now;
        event::emit(TokenFeeUpdated { coin_type: t, old_fee_base: old, new_fee_base: fee_base, by_keeper: true });
    }

    // =========================================================================
    // Admin: float and switches
    // =========================================================================

    public fun set_max_sui_fee(_cap: &GatewayAdminCap, gw: &mut Gateway, max: u64) {
        gw.max_sui_fee = max;
        event::emit(MaxSuiFeeUpdated { max_sui_fee: max });
    }

    public fun set_paused(_cap: &GatewayAdminCap, gw: &mut Gateway, paused: bool) {
        gw.paused = paused;
        event::emit(PausedUpdated { paused });
    }

    /// Top up the SUI float. Permissionless on purpose: funding the gateway can
    /// only help users, and the SUI can only ever leave as a registry fee or
    /// to the admin.
    public fun fund(gw: &mut Gateway, payment: Coin<SUI>, ctx: &TxContext) {
        let amount = payment.value();
        balance::join(&mut gw.sui_float, payment.into_balance());
        event::emit(FloatFunded { funder: ctx.sender(), amount, new_total: gw.sui_float.value() });
    }

    /// Recover float (the fees paid through this gateway land in the names
    /// Treasury, so this is how the loop is closed).
    public fun withdraw_sui(_cap: &GatewayAdminCap, gw: &mut Gateway, amount: u64, ctx: &mut TxContext) {
        let c = coin::take(&mut gw.sui_float, amount, ctx);
        transfer::public_transfer(c, ctx.sender());
        event::emit(FloatWithdrawn { amount, new_total: gw.sui_float.value() });
    }

    // =========================================================================
    // Pay in a partner token
    // =========================================================================

    /// Register `name` for the sender, paying in `T`. The token stays here;
    /// the registry's SUI fee comes from the float. Change goes back to the
    /// sender. Everything `register` checks (length, charset, availability,
    /// version) is still checked by `register`.
    ///
    /// A whitelisted wallet is refused: `register` would waive the SUI fee and
    /// refund the float's coin to the user. Such a wallet has a free name
    /// waiting; it should use that.
    public fun register_with_token<T>(
        gw:       &mut Gateway,
        registry: &mut Registry,
        treasury: &mut WalNamesTreasury,
        name:     String,
        blob_id:  String,
        mut payment: Coin<T>,
        ctx:      &mut TxContext,
    ) {
        assert!(!gw.paused, EPaused);
        let sender = ctx.sender();
        assert!(!walrus_names::is_whitelisted(treasury, sender), EWhitelistedUseFree);

        let t   = type_name::with_defining_ids<T>();
        let len = string::as_bytes(&name).length();

        // The registry fee, exactly: `register` refunds any excess to the
        // sender, and the sender is the user, so paying more would give the
        // float away.
        let sui_fee = walrus_names::registration_fee(walrus_names::fee_base(treasury), len);
        assert!(sui_fee <= gw.max_sui_fee, ESuiFeeTooHigh);
        assert!(gw.sui_float.value() >= sui_fee, EFloatTooLow);
        let sui_coin = coin::take(&mut gw.sui_float, sui_fee, ctx);

        // The token fee, same multipliers as the registry.
        let cfg = config_mut<T>(gw, t);
        assert!(cfg.enabled, ETokenDisabled);
        let fee = walrus_names::registration_fee(cfg.fee_base, len);
        assert!(payment.value() >= fee, EInsufficientToken);
        let exact = payment.split(fee, ctx);
        balance::join(&mut cfg.collected, exact.into_balance());
        cfg.names_sold      = cfg.names_sold + 1;
        cfg.total_collected = cfg.total_collected + fee;
        if (payment.value() > 0) {
            transfer::public_transfer(payment, sender);
        } else {
            payment.destroy_zero();
        };

        walrus_names::register(registry, treasury, name, blob_id, sui_coin, ctx);

        gw.names_sold = gw.names_sold + 1;
        event::emit(NamePaidInToken { payer: sender, name, coin_type: t, amount: fee, sui_fee });
    }

    // =========================================================================
    // Views
    // =========================================================================

    public fun has_token<T>(gw: &Gateway): bool {
        df::exists(&gw.id, TokenKey { t: type_name::with_defining_ids<T>() })
    }
    public fun token_fee_base<T>(gw: &Gateway): u64        { config<T>(gw).fee_base }
    public fun token_enabled<T>(gw: &Gateway): bool        { config<T>(gw).enabled }
    public fun token_collected<T>(gw: &Gateway): u64       { config<T>(gw).collected.value() }
    public fun token_total_collected<T>(gw: &Gateway): u64 { config<T>(gw).total_collected }
    public fun token_names_sold<T>(gw: &Gateway): u64      { config<T>(gw).names_sold }
    public fun token_bounds<T>(gw: &Gateway): (u64, u64, u64) {
        let c = config<T>(gw);
        (c.min_fee_base, c.max_fee_base, c.max_step_bps)
    }
    /// Fee in `T` for a name of `len` characters.
    public fun quote<T>(gw: &Gateway, len: u64): u64 {
        walrus_names::registration_fee(config<T>(gw).fee_base, len)
    }
    public fun tokens(gw: &Gateway): &vector<TypeName> { &gw.tokens }
    public fun sui_float(gw: &Gateway): u64   { gw.sui_float.value() }
    public fun names_sold(gw: &Gateway): u64  { gw.names_sold }
    public fun min_lock_ms(): u64             { MIN_LOCK_MS }
    public fun min_keeper_interval_ms(): u64  { MIN_KEEPER_INTERVAL_MS }
    public fun is_keeper(gw: &Gateway, keeper: &KeeperCap): bool { gw.keepers.contains(&object::id(keeper)) }
    public fun token_fee_updated_ms<T>(gw: &Gateway): u64 { config<T>(gw).fee_updated_ms }
    public fun max_sui_fee(gw: &Gateway): u64 { gw.max_sui_fee }
    public fun is_paused(gw: &Gateway): bool  { gw.paused }

    // =========================================================================
    // Internals
    // =========================================================================

    fun assert_fee(fee_base: u64) {
        assert!(fee_base > 0, EZeroFee);
        assert!(fee_base <= MAX_FEE_BASE, EFeeTooHigh);
    }

    fun assert_bounds(fee_base: u64, min: u64, max: u64, step_bps: u64) {
        assert!(min <= fee_base && fee_base <= max, EBadBounds);
        assert!(step_bps <= MAX_STEP_BPS, EBadBounds);
    }

    fun config<T>(gw: &Gateway): &TokenConfig<T> {
        let key = TokenKey { t: type_name::with_defining_ids<T>() };
        assert!(df::exists(&gw.id, key), ETokenNotAccepted);
        df::borrow(&gw.id, key)
    }

    fun config_mut<T>(gw: &mut Gateway, t: TypeName): &mut TokenConfig<T> {
        let key = TokenKey { t };
        assert!(df::exists(&gw.id, key), ETokenNotAccepted);
        df::borrow_mut(&mut gw.id, key)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
}
