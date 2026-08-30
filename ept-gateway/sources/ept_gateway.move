/// Epoch EPT Gateway: pay the vesting deploy fee in $EPT instead of SUI, at a
/// discount, with the EPT burned by the contract itself.
///
/// Why a separate package instead of an upgrade to `vesting`:
/// the vesting package custodies user tokens, so we do not want to republish it
/// for a payment feature. This module sits next to it and calls the existing
/// public `create_vault` / `create_multi_vault`, which means:
///
/// - the resulting vaults are IDENTICAL to directly created ones: `creator` and
///   the emitted events use `ctx.sender()`, which is the user, not this module,
///   so indexers and the UI need no changes;
/// - this gateway never holds user tokens. The only asset it keeps is a small
///   SUI float used to pay the protocol fee on the user's behalf. That fee goes
///   to the vesting Treasury, which the protocol controls, so the float is
///   recycled and the arrangement costs only gas;
/// - the EPT the user pays is sent to @0x0 inside the same call. It is burned by
///   the contract, not by a promise to burn it later.
/// The self-transfer lint is silenced deliberately: change and withdrawals go
/// back to the transaction sender by design, which is what a payment gateway
/// should do.
#[allow(lint(self_transfer))]
module epoch_ept_gateway::ept_gateway {

    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;
    use vesting_service::vesting::{Self, Treasury};

    /// Coins sent here are unspendable: this is the burn.
    const DEAD_ADDRESS: address = @0x0;

    // =========================================================================
    // Errors
    // =========================================================================

    const ENotConfigured:   u64 = 0; // no payment coin configured yet
    const EWrongEptCoin:    u64 = 1; // coin type differs from the configured one
    const EInsufficientEpt: u64 = 2; // payment below the configured fee
    const EFloatTooLow:     u64 = 3; // the SUI float cannot cover the deploy fee
    const EZeroFee:         u64 = 4; // a zero EPT fee would make vaults free
    const ESuiFeeTooHigh:   u64 = 5; // the vesting deploy fee exceeds our cap
    const EPaused:          u64 = 6; // the gateway is paused

    // =========================================================================
    // Objects
    // =========================================================================

    /// Controls configuration and the SUI float. No power over any vault.
    public struct GatewayAdminCap has key, store { id: UID }

    /// Shared: anyone can pay through it, nobody can take anything out of it
    /// except the admin, and the only thing in it is the SUI float.
    public struct Gateway has key {
        id:        UID,
        sui_float: Balance<SUI>,
        /// Accepted payment coin, e.g. $EPT. None until configured.
        ept_type:  Option<TypeName>,
        /// Fee in raw units of that coin for one vault.
        ept_fee:   u64,
        /// Most SUI this gateway will ever pay for one vault. The vesting deploy
        /// fee lives in another contract and can be changed there; without this
        /// cap, raising it (or fat-fingering it) would drain the float on the
        /// next call. Above the cap we abort instead of paying.
        max_sui_fee: u64,
        /// Kill switch. If the EPT price moves far enough that the fixed fee
        /// stops making sense, stopping is cleaner than setting an absurd fee.
        paused: bool,
        /// Lifetime counters, for the public utility page.
        vaults_created: u64,
        ept_burned:     u64,
    }

    // =========================================================================
    // Events
    // =========================================================================

    public struct VaultPaidInEpt has copy, drop {
        payer:      address,
        ept_burned: u64,
        sui_fee:    u64,
        multi:      bool,
    }
    public struct ConfigUpdated has copy, drop {
        ept_type: TypeName,
        ept_fee:  u64,
    }
    public struct FloatFunded has copy, drop { funder: address, amount: u64, new_total: u64 }
    public struct FloatWithdrawn has copy, drop { amount: u64, new_total: u64 }
    public struct MaxSuiFeeUpdated has copy, drop { max_sui_fee: u64 }
    public struct PausedUpdated has copy, drop { paused: bool }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Gateway {
            id:        object::new(ctx),
            sui_float: balance::zero<SUI>(),
            ept_type:  option::none(),
            ept_fee:   0,
            // 20 SUI: twice the current deploy fee, so a normal fee change is
            // fine and a runaway one is not.
            max_sui_fee: 20_000_000_000,
            paused:      false,
            vaults_created: 0,
            ept_burned:     0,
        });
        transfer::public_transfer(GatewayAdminCap { id: object::new(ctx) }, ctx.sender());
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// Set (or change) the accepted coin and the fee charged in it.
    /// The fee is fixed rather than read from a pool: the EPT pool is thin
    /// enough that an oracle read could be pushed around for less than the fee
    /// itself. It is adjusted manually as the price moves.
    public fun set_ept_config<E>(
        _cap: &GatewayAdminCap,
        gw:   &mut Gateway,
        fee:  u64,
    ) {
        assert!(fee > 0, EZeroFee);
        let t = type_name::with_defining_ids<E>();
        gw.ept_type = option::some(t);
        gw.ept_fee  = fee;
        event::emit(ConfigUpdated { ept_type: t, ept_fee: fee });
    }

    /// Raise or lower the ceiling on the SUI we are willing to pay per vault.
    public fun set_max_sui_fee(_cap: &GatewayAdminCap, gw: &mut Gateway, max: u64) {
        gw.max_sui_fee = max;
        event::emit(MaxSuiFeeUpdated { max_sui_fee: max });
    }

    /// Stop or resume the gateway. Paying in SUI directly to the vesting
    /// contract is unaffected: this only turns off the EPT path.
    public fun set_paused(_cap: &GatewayAdminCap, gw: &mut Gateway, paused: bool) {
        gw.paused = paused;
        event::emit(PausedUpdated { paused });
    }

    /// Top up the SUI float. Permissionless on purpose: funding the gateway can
    /// only help users, and the SUI can only ever leave as a protocol fee or to
    /// the admin.
    public fun fund(gw: &mut Gateway, payment: Coin<SUI>, ctx: &TxContext) {
        let amount = payment.value();
        balance::join(&mut gw.sui_float, payment.into_balance());
        event::emit(FloatFunded { funder: ctx.sender(), amount, new_total: gw.sui_float.value() });
    }

    /// Recover float (the fees paid through this gateway land in the vesting
    /// Treasury, so this is how the loop is closed).
    public fun withdraw_sui(
        _cap:   &GatewayAdminCap,
        gw:     &mut Gateway,
        amount: u64,
        ctx:    &mut TxContext,
    ) {
        let c = coin::take(&mut gw.sui_float, amount, ctx);
        transfer::public_transfer(c, ctx.sender());
        event::emit(FloatWithdrawn { amount, new_total: gw.sui_float.value() });
    }

    // =========================================================================
    // Pay in EPT
    // =========================================================================

    /// Create a single-beneficiary vault paying the protocol fee in EPT.
    /// The EPT is burned here; the SUI fee comes from the float.
    public fun create_vault_with_ept<T, E>(
        gw:              &mut Gateway,
        treasury:        &mut Treasury,
        ept:             Coin<E>,
        tokens:          Coin<T>,
        beneficiary:     address,
        cliff_ts_ms:     u64,
        cliff_bps:       u64,
        linear_start_ms: u64,
        linear_end_ms:   u64,
        clock:           &Clock,
        ctx:             &mut TxContext,
    ) {
        let burned  = take_and_burn_ept<E>(gw, ept, ctx);
        let sui_fee = take_sui_fee(gw, treasury, ctx);
        let sui_amt = sui_fee.value();

        vesting::create_vault<T>(
            treasury, sui_fee, tokens, beneficiary,
            cliff_ts_ms, cliff_bps, linear_start_ms, linear_end_ms, clock, ctx,
        );

        gw.vaults_created = gw.vaults_created + 1;
        event::emit(VaultPaidInEpt {
            payer: ctx.sender(), ept_burned: burned, sui_fee: sui_amt, multi: false,
        });
    }

    /// Same, for a multi-beneficiary vault.
    public fun create_multi_vault_with_ept<T, E>(
        gw:              &mut Gateway,
        treasury:        &mut Treasury,
        ept:             Coin<E>,
        tokens:          Coin<T>,
        beneficiaries:   vector<address>,
        shares_bps:      vector<u64>,
        cliff_ts_ms:     u64,
        cliff_bps:       u64,
        linear_start_ms: u64,
        linear_end_ms:   u64,
        clock:           &Clock,
        ctx:             &mut TxContext,
    ) {
        let burned  = take_and_burn_ept<E>(gw, ept, ctx);
        let sui_fee = take_sui_fee(gw, treasury, ctx);
        let sui_amt = sui_fee.value();

        vesting::create_multi_vault<T>(
            treasury, sui_fee, tokens, beneficiaries, shares_bps,
            cliff_ts_ms, cliff_bps, linear_start_ms, linear_end_ms, clock, ctx,
        );

        gw.vaults_created = gw.vaults_created + 1;
        event::emit(VaultPaidInEpt {
            payer: ctx.sender(), ept_burned: burned, sui_fee: sui_amt, multi: true,
        });
    }

    // =========================================================================
    // Internals
    // =========================================================================

    /// Check the coin type, burn exactly the configured fee, hand the change
    /// back to the payer. Returns the amount burned.
    fun take_and_burn_ept<E>(gw: &mut Gateway, mut ept: Coin<E>, ctx: &mut TxContext): u64 {
        assert!(!gw.paused, EPaused);
        assert!(gw.ept_type.is_some(), ENotConfigured);
        assert!(*gw.ept_type.borrow() == type_name::with_defining_ids<E>(), EWrongEptCoin);
        assert!(ept.value() >= gw.ept_fee, EInsufficientEpt);

        let exact = ept.split(gw.ept_fee, ctx);
        transfer::public_transfer(exact, DEAD_ADDRESS);

        if (ept.value() > 0) {
            transfer::public_transfer(ept, ctx.sender());
        } else {
            ept.destroy_zero();
        };

        gw.ept_burned = gw.ept_burned + gw.ept_fee;
        gw.ept_fee
    }

    /// Take exactly the current deploy fee out of the float. Exactly, because
    /// `create_vault` refunds any excess to `ctx.sender()`, which is the user:
    /// sending more would be giving the float away.
    fun take_sui_fee(gw: &mut Gateway, treasury: &Treasury, ctx: &mut TxContext): Coin<SUI> {
        let needed = vesting::deploy_fee(treasury);
        assert!(needed <= gw.max_sui_fee, ESuiFeeTooHigh);
        assert!(gw.sui_float.value() >= needed, EFloatTooLow);
        coin::take(&mut gw.sui_float, needed, ctx)
    }

    // =========================================================================
    // Views
    // =========================================================================

    public fun ept_fee(gw: &Gateway): u64        { gw.ept_fee }
    public fun sui_float(gw: &Gateway): u64      { gw.sui_float.value() }
    public fun vaults_created(gw: &Gateway): u64 { gw.vaults_created }
    public fun ept_burned(gw: &Gateway): u64     { gw.ept_burned }
    public fun is_configured(gw: &Gateway): bool { gw.ept_type.is_some() }
    public fun max_sui_fee(gw: &Gateway): u64    { gw.max_sui_fee }
    public fun is_paused(gw: &Gateway): bool     { gw.paused }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
}
