/// Vesting Service on SUI
///
/// A non-custodial, non-cancellable token vesting protocol. Supports:
///   - Pure Cliff:   all tokens unlock at a single timestamp
///   - Pure Linear:  tokens unlock continuously from start to end
///   - Hybrid:       X% unlocks at cliff, remaining unlocks linearly to end_ts
///
/// Design pattern:
///   cliff_bps controls the percentage (in basis points) released at the cliff.
///   The remaining (10000 - cliff_bps) is released linearly between linear_start_ms and linear_end_ms.
///
///   Pure cliff  → cliff_bps = 10000, linear_start_ms = linear_end_ms = cliff_ts_ms
///   Pure linear → cliff_bps = 0,     cliff_ts_ms = 0 (ignored)
///   Hybrid      → cliff_bps = N,     linear_start_ms = cliff_ts_ms, linear_end_ms = T
///
///   Once created, a vault is immutable and non-cancellable.
///   The creator has no special power over the vault after deployment.
///
module vesting_service::vesting {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;
    use sui::sui::SUI;
    use sui::vec_map::{Self, VecMap};

    // =========================================================================
    // Errors
    // =========================================================================

    const ENotBeneficiary: u64        = 0;
    const ENothingToClaim: u64        = 2;
    const EInvalidParams: u64         = 3;
    const EInsufficientFee: u64       = 4;
    const EInvalidTimestamps: u64     = 6;
    const EZeroAmount: u64            = 7;
    const EVestingAlreadyEnded: u64   = 8;
    const ETooManyBeneficiaries: u64  = 9;
    const ESharesMustSum10000: u64    = 10;
    const ENotMultiBeneficiary: u64   = 11;
    const EDuplicateBeneficiary: u64  = 12;
    const EEmptyBeneficiaries: u64    = 13;

    // =========================================================================
    // Constants
    // =========================================================================

    const BPS_BASE: u64 = 10_000;

    /// Default deploy fee: 10 SUI (in MIST, 1 SUI = 1_000_000_000 MIST)
    const DEFAULT_DEPLOY_FEE_MIST: u64 = 10_000_000_000;

    /// Maximum beneficiaries in a multi-vault
    const MAX_BENEFICIARIES: u64 = 20;

    // =========================================================================
    // Structs
    // =========================================================================

    /// One-time witness for module initialization
    public struct VESTING has drop {}

    /// Admin capability — held by the protocol deployer.
    /// Allows fee withdrawal and fee updates.
    ///
    /// NOTE: `store` is retained so that `transfer::public_transfer` and the
    /// test framework (`ts::take_from_sender`) work without modification.
    /// The downside is that AdminCap could theoretically be wrapped inside a
    /// custom object and become inaccessible. To mitigate this risk, the admin
    /// should ONLY transfer this cap via `transfer_admin` and never deposit it
    /// into third-party contracts.
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Shared treasury that collects deploy fees.
    public struct Treasury has key {
        id: UID,
        balance: Balance<SUI>,
        admin: address,
        deploy_fee: u64,
    }

    /// A shared vesting vault holding locked tokens for one beneficiary.
    /// Generic over token type T (works with any SUI coin).
    /// Immutable after creation — no cancel, no admin override.
    public struct VestingVault<phantom T> has key {
        id: UID,
        /// Who created and funded this vault
        creator: address,
        /// Who can claim vested tokens
        beneficiary: address,
        /// Remaining locked balance
        balance: Balance<T>,
        /// Total tokens originally locked
        total_locked: u64,
        /// How much has been claimed so far
        claimed: u64,
        /// Timestamp (ms) at which cliff unlocks — set to 0 if no cliff
        cliff_ts_ms: u64,
        /// Basis points (0–10000) unlocked at cliff
        cliff_bps: u64,
        /// Start of the linear vesting window
        linear_start_ms: u64,
        /// End of the linear vesting window
        linear_end_ms: u64,
        /// When this vault was created
        created_at_ms: u64,
    }

    /// A shared vesting vault for multiple beneficiaries.
    /// Each beneficiary gets a share (in basis points, summing to 10_000).
    /// The vesting schedule applies to the whole pool; each beneficiary's
    /// claimable amount is proportional to their share of the total.
    public struct MultiVestingVault<phantom T> has key {
        id: UID,
        /// Who created and funded this vault
        creator: address,
        /// Locked token balance
        balance: Balance<T>,
        /// Total tokens originally locked
        total_locked: u64,
        /// Per-beneficiary share in basis points (sum must equal 10_000)
        shares: VecMap<address, u64>,
        /// Per-beneficiary amount claimed so far
        claimed: VecMap<address, u64>,
        /// Timestamp (ms) at which cliff unlocks — set to 0 if no cliff
        cliff_ts_ms: u64,
        /// Basis points (0–10000) unlocked at cliff
        cliff_bps: u64,
        /// Start of the linear vesting window
        linear_start_ms: u64,
        /// End of the linear vesting window
        linear_end_ms: u64,
        /// When this vault was created
        created_at_ms: u64,
    }

    // =========================================================================
    // Events
    // =========================================================================

    public struct VaultCreated has copy, drop {
        vault_id: address,
        creator: address,
        beneficiary: address,
        total_locked: u64,
        cliff_ts_ms: u64,
        cliff_bps: u64,
        linear_start_ms: u64,
        linear_end_ms: u64,
    }

    public struct TokensClaimed has copy, drop {
        vault_id: address,
        beneficiary: address,
        amount: u64,
        total_claimed: u64,
    }

    public struct FeeUpdated has copy, drop {
        old_fee: u64,
        new_fee: u64,
    }

    /// Emitted once when a MultiVestingVault is created.
    public struct MultiVaultCreated has copy, drop {
        vault_id: address,
        creator: address,
        total_locked: u64,
        beneficiary_count: u64,
        cliff_ts_ms: u64,
        cliff_bps: u64,
        linear_start_ms: u64,
        linear_end_ms: u64,
    }

    /// Emitted once per beneficiary when a MultiVestingVault is created.
    /// This lets the frontend index vaults by beneficiary address efficiently.
    public struct MultiBeneficiaryAdded has copy, drop {
        vault_id: address,
        beneficiary: address,
        share_bps: u64,
        token_amount: u64,
    }

    /// Emitted each time a beneficiary claims from a MultiVestingVault.
    public struct MultiTokensClaimed has copy, drop {
        vault_id: address,
        beneficiary: address,
        amount: u64,
        total_claimed_by_beneficiary: u64,
    }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(_witness: VESTING, ctx: &mut TxContext) {
        let admin = ctx.sender();

        transfer::public_transfer(
            AdminCap { id: object::new(ctx) },
            admin,
        );

        transfer::share_object(Treasury {
            id: object::new(ctx),
            balance: balance::zero<SUI>(),
            admin,
            deploy_fee: DEFAULT_DEPLOY_FEE_MIST,
        });
    }

    // =========================================================================
    // Public entry functions
    // =========================================================================

    /// Create a new vesting vault.
    /// Once created, the vault is permanent — tokens vest according to the
    /// schedule and can only flow to the beneficiary. There is no cancel.
    public fun create_vault<T>(
        treasury: &mut Treasury,
        fee: Coin<SUI>,
        tokens: Coin<T>,
        beneficiary: address,
        cliff_ts_ms: u64,
        cliff_bps: u64,
        linear_start_ms: u64,
        linear_end_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // --- Validate fee ---
        let fee_value = fee.value();
        assert!(fee_value >= treasury.deploy_fee, EInsufficientFee);

        // --- Validate params ---
        assert!(cliff_bps <= BPS_BASE, EInvalidParams);
        assert!(linear_end_ms >= linear_start_ms, EInvalidTimestamps);
        let total = tokens.value();
        assert!(total > 0, EZeroAmount);
        // A cliff percentage requires a cliff timestamp — otherwise cliff_amount
        // is computed but the condition in compute_vested_total is never true,
        // permanently locking those tokens.
        if (cliff_bps > 0) {
            assert!(cliff_ts_ms > 0, EInvalidParams);
        };
        // Beneficiary must be a real address (not the zero address)
        assert!(beneficiary != @0x0, EInvalidParams);

        // If there is a cliff, linear window must start at or after the cliff
        if (cliff_ts_ms > 0 && cliff_bps < BPS_BASE) {
            assert!(linear_start_ms >= cliff_ts_ms, EInvalidTimestamps);
        };

        // The final vesting date must be in the future.
        let now_ms = clock.timestamp_ms();
        let end_ts = if (cliff_bps == BPS_BASE) { cliff_ts_ms } else { linear_end_ms };
        assert!(end_ts > now_ms, EVestingAlreadyEnded);

        // --- Collect exact fee, return change ---
        let mut fee_balance = fee.into_balance();
        let exact_fee = fee_balance.split(treasury.deploy_fee);
        balance::join(&mut treasury.balance, exact_fee);
        if (fee_balance.value() > 0) {
            transfer::public_transfer(coin::from_balance(fee_balance, ctx), ctx.sender());
        } else {
            fee_balance.destroy_zero();
        };

        // --- Build vault ---
        let vault_id_uid = object::new(ctx);
        let vault_id_addr = object::uid_to_address(&vault_id_uid);

        let vault = VestingVault<T> {
            id: vault_id_uid,
            creator: ctx.sender(),
            beneficiary,
            balance: tokens.into_balance(),
            total_locked: total,
            claimed: 0,
            cliff_ts_ms,
            cliff_bps,
            linear_start_ms,
            linear_end_ms,
            created_at_ms: now_ms,
        };

        event::emit(VaultCreated {
            vault_id: vault_id_addr,
            creator: ctx.sender(),
            beneficiary,
            total_locked: total,
            cliff_ts_ms,
            cliff_bps,
            linear_start_ms,
            linear_end_ms,
        });

        transfer::share_object(vault);
    }

    /// Create a new multi-beneficiary vesting vault.
    /// `beneficiaries` and `shares_bps` must have the same length,
    /// shares must sum to exactly 10_000, and there must be at most
    /// MAX_BENEFICIARIES (20) entries.
    public fun create_multi_vault<T>(
        treasury: &mut Treasury,
        fee: Coin<SUI>,
        tokens: Coin<T>,
        beneficiaries: vector<address>,
        shares_bps: vector<u64>,
        cliff_ts_ms: u64,
        cliff_bps: u64,
        linear_start_ms: u64,
        linear_end_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // --- Validate fee ---
        let fee_value = fee.value();
        assert!(fee_value >= treasury.deploy_fee, EInsufficientFee);

        // --- Validate beneficiaries ---
        let n = beneficiaries.length();
        assert!(n > 0, EEmptyBeneficiaries);
        assert!(n == shares_bps.length(), EInvalidParams);
        assert!((n as u64) <= MAX_BENEFICIARIES, ETooManyBeneficiaries);

        // Build VecMap and sum shares, checking for duplicates
        let mut shares: VecMap<address, u64> = vec_map::empty();
        let mut claimed: VecMap<address, u64> = vec_map::empty();
        let mut share_sum: u64 = 0;
        let mut i = 0;
        while (i < n) {
            let addr = *beneficiaries.borrow(i);
            let bps  = *shares_bps.borrow(i);
            // Each bps must be in [1, BPS_BASE] — prevents u64 overflow in share_sum
            // and ensures every beneficiary has a non-zero allocation
            assert!(bps > 0 && bps <= BPS_BASE, EInvalidParams);
            // Beneficiary must be a real address
            assert!(addr != @0x0, EInvalidParams);
            // VecMap::insert aborts if key already exists — serves as duplicate check
            assert!(!vec_map::contains(&shares, &addr), EDuplicateBeneficiary);
            vec_map::insert(&mut shares, addr, bps);
            vec_map::insert(&mut claimed, addr, 0);
            share_sum = share_sum + bps;
            i = i + 1;
        };
        assert!(share_sum == BPS_BASE, ESharesMustSum10000);

        // --- Validate schedule params ---
        assert!(cliff_bps <= BPS_BASE, EInvalidParams);
        assert!(linear_end_ms >= linear_start_ms, EInvalidTimestamps);
        let total = tokens.value();
        assert!(total > 0, EZeroAmount);
        // A cliff percentage requires a cliff timestamp
        if (cliff_bps > 0) {
            assert!(cliff_ts_ms > 0, EInvalidParams);
        };

        if (cliff_ts_ms > 0 && cliff_bps < BPS_BASE) {
            assert!(linear_start_ms >= cliff_ts_ms, EInvalidTimestamps);
        };

        let now_ms = clock.timestamp_ms();
        let end_ts = if (cliff_bps == BPS_BASE) { cliff_ts_ms } else { linear_end_ms };
        assert!(end_ts > now_ms, EVestingAlreadyEnded);

        // --- Collect exact fee, return change ---
        let mut fee_balance = fee.into_balance();
        let exact_fee = fee_balance.split(treasury.deploy_fee);
        balance::join(&mut treasury.balance, exact_fee);
        if (fee_balance.value() > 0) {
            transfer::public_transfer(coin::from_balance(fee_balance, ctx), ctx.sender());
        } else {
            fee_balance.destroy_zero();
        };

        // --- Build vault ---
        let vault_id_uid = object::new(ctx);
        let vault_id_addr = object::uid_to_address(&vault_id_uid);

        event::emit(MultiVaultCreated {
            vault_id: vault_id_addr,
            creator: ctx.sender(),
            total_locked: total,
            beneficiary_count: n as u64,
            cliff_ts_ms,
            cliff_bps,
            linear_start_ms,
            linear_end_ms,
        });

        // Emit per-beneficiary events for indexing
        let mut j = 0;
        while (j < n) {
            let addr = *beneficiaries.borrow(j);
            let bps  = *shares_bps.borrow(j);
            let token_amount = ((total as u128) * (bps as u128) / (BPS_BASE as u128)) as u64;
            event::emit(MultiBeneficiaryAdded {
                vault_id: vault_id_addr,
                beneficiary: addr,
                share_bps: bps,
                token_amount,
            });
            j = j + 1;
        };

        let vault = MultiVestingVault<T> {
            id: vault_id_uid,
            creator: ctx.sender(),
            balance: tokens.into_balance(),
            total_locked: total,
            shares,
            claimed,
            cliff_ts_ms,
            cliff_bps,
            linear_start_ms,
            linear_end_ms,
            created_at_ms: now_ms,
        };

        transfer::share_object(vault);
    }

    /// Claim all currently vested tokens (single-beneficiary vault).
    /// Only the beneficiary can call this.
    public fun claim<T>(
        vault: &mut VestingVault<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == vault.beneficiary, ENotBeneficiary);

        let now_ms = clock.timestamp_ms();
        let claimable = compute_claimable_internal(vault, now_ms);
        assert!(claimable > 0, ENothingToClaim);

        vault.claimed = vault.claimed + claimable;

        let vault_id = object::uid_to_address(&vault.id);
        event::emit(TokensClaimed {
            vault_id,
            beneficiary: ctx.sender(),
            amount: claimable,
            total_claimed: vault.claimed,
        });

        let payout = coin::from_balance(vault.balance.split(claimable), ctx);
        transfer::public_transfer(payout, ctx.sender());
    }

    /// Claim vested tokens from a multi-beneficiary vault.
    /// The caller must be one of the vault's beneficiaries.
    public fun claim_multi<T>(
        vault: &mut MultiVestingVault<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = ctx.sender();
        assert!(vec_map::contains(&vault.shares, &caller), ENotMultiBeneficiary);

        let now_ms = clock.timestamp_ms();

        // Compute total vested across the entire vault pool
        let total_vested = compute_vested_total(
            vault.total_locked,
            vault.cliff_ts_ms,
            vault.cliff_bps,
            vault.linear_start_ms,
            vault.linear_end_ms,
            now_ms,
        );

        // Caller's share and already-claimed amount
        let share_bps = *vec_map::get(&vault.shares, &caller);
        let already_claimed = *vec_map::get(&vault.claimed, &caller);

        // Caller's proportional vested amount
        let caller_vested = ((total_vested as u128) * (share_bps as u128) / (BPS_BASE as u128)) as u64;
        assert!(caller_vested > already_claimed, ENothingToClaim);

        let claimable = caller_vested - already_claimed;

        // Update claimed mapping
        let claimed_ref = vec_map::get_mut(&mut vault.claimed, &caller);
        *claimed_ref = already_claimed + claimable;

        let vault_id = object::uid_to_address(&vault.id);
        event::emit(MultiTokensClaimed {
            vault_id,
            beneficiary: caller,
            amount: claimable,
            total_claimed_by_beneficiary: already_claimed + claimable,
        });

        let payout = coin::from_balance(vault.balance.split(claimable), ctx);
        transfer::public_transfer(payout, caller);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// Withdraw all accumulated fees to the caller (AdminCap holder).
    public fun withdraw_fees(
        _cap: &AdminCap,
        treasury: &mut Treasury,
        ctx: &mut TxContext,
    ) {
        let amount = treasury.balance.value();
        if (amount > 0) {
            let payout = coin::from_balance(treasury.balance.split(amount), ctx);
            transfer::public_transfer(payout, ctx.sender());
        };
    }

    /// Update the deploy fee. Takes effect on the next vault creation.
    public fun update_deploy_fee(
        _cap: &AdminCap,
        treasury: &mut Treasury,
        new_fee: u64,
    ) {
        let old_fee = treasury.deploy_fee;
        treasury.deploy_fee = new_fee;
        event::emit(FeeUpdated { old_fee, new_fee });
    }

    /// Transfer admin rights to a new address.
    public fun transfer_admin(
        cap: AdminCap,
        treasury: &mut Treasury,
        new_admin: address,
    ) {
        treasury.admin = new_admin;
        transfer::public_transfer(cap, new_admin);
    }

    // =========================================================================
    // View / pure functions
    // =========================================================================

    /// Compute how many tokens are currently claimable (single vault).
    public fun claimable<T>(vault: &VestingVault<T>, clock: &Clock): u64 {
        compute_claimable_internal(vault, clock.timestamp_ms())
    }

    /// Compute how many tokens are currently claimable for a specific beneficiary
    /// in a multi-vault.
    public fun claimable_multi<T>(
        vault: &MultiVestingVault<T>,
        beneficiary: address,
        clock: &Clock,
    ): u64 {
        if (!vec_map::contains(&vault.shares, &beneficiary)) { return 0 };

        let now_ms = clock.timestamp_ms();
        let total_vested = compute_vested_total(
            vault.total_locked,
            vault.cliff_ts_ms,
            vault.cliff_bps,
            vault.linear_start_ms,
            vault.linear_end_ms,
            now_ms,
        );

        let share_bps = *vec_map::get(&vault.shares, &beneficiary);
        let already_claimed = *vec_map::get(&vault.claimed, &beneficiary);
        let caller_vested = ((total_vested as u128) * (share_bps as u128) / (BPS_BASE as u128)) as u64;

        if (caller_vested > already_claimed) { caller_vested - already_claimed } else { 0 }
    }

    public fun total_locked<T>(vault: &VestingVault<T>): u64    { vault.total_locked }
    public fun claimed<T>(vault: &VestingVault<T>): u64         { vault.claimed }
    public fun beneficiary<T>(vault: &VestingVault<T>): address { vault.beneficiary }
    public fun creator<T>(vault: &VestingVault<T>): address     { vault.creator }
    public fun deploy_fee(treasury: &Treasury): u64             { treasury.deploy_fee }

    public fun multi_total_locked<T>(vault: &MultiVestingVault<T>): u64 { vault.total_locked }
    public fun multi_creator<T>(vault: &MultiVestingVault<T>): address  { vault.creator }
    public fun multi_beneficiary_count<T>(vault: &MultiVestingVault<T>): u64 {
        vault.shares.length()
    }

    /// Remaining locked balance (not yet claimed, including not-yet-vested)
    public fun remaining_balance<T>(vault: &VestingVault<T>): u64 {
        vault.balance.value()
    }

    public fun multi_remaining_balance<T>(vault: &MultiVestingVault<T>): u64 {
        vault.balance.value()
    }

    // =========================================================================
    // Test helpers
    // =========================================================================

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(VESTING {}, ctx);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// Compute total vested tokens out of `total_locked` at time `now_ms`.
    /// Shared logic used by both single and multi vault claim paths.
    fun compute_vested_total(
        total_locked: u64,
        cliff_ts_ms: u64,
        cliff_bps: u64,
        linear_start_ms: u64,
        linear_end_ms: u64,
        now_ms: u64,
    ): u64 {
        let mut vested: u64 = 0;

        let cliff_amount = (
            (total_locked as u128) * (cliff_bps as u128) / (BPS_BASE as u128)
        ) as u64;

        if (cliff_amount > 0 && cliff_ts_ms > 0 && now_ms >= cliff_ts_ms) {
            vested = vested + cliff_amount;
        };

        let linear_amount = total_locked - cliff_amount;
        if (linear_amount > 0) {
            let start = linear_start_ms;
            let end   = linear_end_ms;

            if (start == end) {
                if (now_ms >= start) { vested = vested + linear_amount; }
            } else if (now_ms >= end) {
                vested = vested + linear_amount;
            } else if (now_ms > start) {
                let elapsed  = now_ms - start;
                let duration = end - start;
                let vested_linear = (
                    (linear_amount as u128) * (elapsed as u128) / (duration as u128)
                ) as u64;
                vested = vested + vested_linear;
            }
        };

        if (vested > total_locked) { total_locked } else { vested }
    }

    fun compute_claimable_internal<T>(vault: &VestingVault<T>, now_ms: u64): u64 {
        let vested = compute_vested_total(
            vault.total_locked,
            vault.cliff_ts_ms,
            vault.cliff_bps,
            vault.linear_start_ms,
            vault.linear_end_ms,
            now_ms,
        );
        if (vested > vault.claimed) { vested - vault.claimed } else { 0 }
    }
}
