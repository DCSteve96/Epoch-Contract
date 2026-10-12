#[test_only]
module epoch_names_gateway::names_gateway_tests {
    use std::string;
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario as ts;
    use vesting_service::vesting::{Self, Treasury as VestingTreasury, VestingVault};
    use walrus_names::walrus_names::{Self, Registry, WalNamesTreasury, NameCap, AdminCap};
    use epoch_names_gateway::names_gateway::{Self, Gateway, GatewayAdminCap, KeeperCap};

    const ADMIN:  address = @0xAD;
    const USER:   address = @0x5E4;
    const KEEPER: address = @0xBEEF;

    /// Stand-in for a partner token (SuiCat, 6 decimals) and for a random coin.
    public struct CAT has drop {}
    public struct OTHER has drop {}

    const CAT_FEE:  u64 = 375_000_000;   // 375 CAT at 6 decimals for a 5+ char name
    const CAT_MIN:  u64 = 100_000_000;
    const CAT_MAX:  u64 = 2_000_000_000;
    const STEP_BPS: u64 = 2_000;          // 20% per keeper update
    const SUI_FEE:  u64 = 500_000_000;    // 0.5 SUI, the registry default
    const VAULT_FEE: u64 = 10_000_000_000; // 10 SUI, the vesting default
    const YEAR_MS:  u64 = 365 * 24 * 60 * 60 * 1000;
    const EPOCH:    address = @0xE70C;

    /// Publish the packages, accept CAT, fund the float with 3 names' worth.
    fun setup(sc: &mut ts::Scenario) {
        let clk = clock::create_for_testing(ts::ctx(sc));
        setup_with(sc, &clk);
        clock::destroy_for_testing(clk);
    }
    fun setup_with(sc: &mut ts::Scenario, clk: &clock::Clock) {
        ts::next_tx(sc, ADMIN);
        {
            walrus_names::init_for_testing(ts::ctx(sc));
            vesting::init_for_testing(ts::ctx(sc));
            names_gateway::init_for_testing(ts::ctx(sc));
        };
        ts::next_tx(sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(sc);
            let mut gw = ts::take_shared<Gateway>(sc);
            names_gateway::add_token<CAT>(&cap, &mut gw, CAT_FEE, CAT_MIN, CAT_MAX, STEP_BPS, clk);
            let float = coin::mint_for_testing<SUI>(SUI_FEE * 3, ts::ctx(sc));
            names_gateway::fund(&mut gw, float, ts::ctx(sc));
            ts::return_shared(gw);
            ts::return_to_sender(sc, cap);
        };
    }

    fun pay(sc: &mut ts::Scenario, name: vector<u8>, amount: u64) {
        let mut gw = ts::take_shared<Gateway>(sc);
        let mut reg = ts::take_shared<Registry>(sc);
        let mut tr  = ts::take_shared<WalNamesTreasury>(sc);
        let cat = coin::mint_for_testing<CAT>(amount, ts::ctx(sc));
        names_gateway::register_with_token<CAT>(
            &mut gw, &mut reg, &mut tr, string::utf8(name), string::utf8(b"blob"), cat, ts::ctx(sc),
        );
        ts::return_shared(tr);
        ts::return_shared(reg);
        ts::return_shared(gw);
    }

    // A user pays in CAT: the name is theirs, exactly as if paid in SUI; the
    // CAT is kept; the registry got its SUI from the float; change came back.
    #[test]
    fun pay_in_token_registers_a_normal_name() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);

        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE + 7);

        ts::next_tx(&mut sc, USER);
        {
            let cap = ts::take_from_sender<NameCap>(&sc);
            ts::return_to_sender(&sc, cap);
            let change = ts::take_from_sender<Coin<CAT>>(&sc);
            assert!(change.value() == 7, 0);
            ts::return_to_sender(&sc, change);

            let gw  = ts::take_shared<Gateway>(&sc);
            let reg = ts::take_shared<Registry>(&sc);
            let tr  = ts::take_shared<WalNamesTreasury>(&sc);
            assert!(walrus_names::owner_of(&reg, string::utf8(b"stefano")) == USER, 1);
            assert!(names_gateway::token_collected<CAT>(&gw) == CAT_FEE, 2);
            assert!(names_gateway::token_names_sold<CAT>(&gw) == 1, 3);
            assert!(names_gateway::names_sold(&gw) == 1, 4);
            assert!(names_gateway::sui_float(&gw) == SUI_FEE * 2, 5);
            assert!(walrus_names::treasury_balance(&tr) == SUI_FEE, 6);
            ts::return_shared(tr);
            ts::return_shared(reg);
            ts::return_shared(gw);
        };
        ts::end(sc);
    }

    // Short names use the registry multipliers on both sides.
    #[test]
    fun short_names_scale_both_fees() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            // 3 chars = x25 = 12.5 SUI: top the float up.
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::fund(&mut gw, coin::mint_for_testing<SUI>(SUI_FEE * 25, ts::ctx(&mut sc)), ts::ctx(&mut sc));
            assert!(names_gateway::quote<CAT>(&gw, 3) == CAT_FEE * 25, 0);
            assert!(names_gateway::quote<CAT>(&gw, 4) == CAT_FEE * 5, 1);
            assert!(names_gateway::quote<CAT>(&gw, 9) == CAT_FEE, 2);
            ts::return_shared(gw);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"abc", CAT_FEE * 25);
        ts::next_tx(&mut sc, USER);
        {
            let gw = ts::take_shared<Gateway>(&sc);
            assert!(names_gateway::token_collected<CAT>(&gw) == CAT_FEE * 25, 3);
            assert!(names_gateway::sui_float(&gw) == SUI_FEE * 3, 4);
            ts::return_shared(gw);
        };
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EInsufficientToken)]
    fun underpaying_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE - 1);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::ETokenNotAccepted)]
    fun unknown_coin_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tr  = ts::take_shared<WalNamesTreasury>(&sc);
            let other = coin::mint_for_testing<OTHER>(CAT_FEE, ts::ctx(&mut sc));
            names_gateway::register_with_token<OTHER>(
                &mut gw, &mut reg, &mut tr, string::utf8(b"stefano"), string::utf8(b"blob"), other, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(reg);
            ts::return_shared(gw);
        };
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::ETokenDisabled)]
    fun disabled_coin_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::set_token_enabled<CAT>(&cap, &mut gw, false);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EPaused)]
    fun paused_gateway_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::set_paused(&cap, &mut gw, true);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::end(sc);
    }

    // A whitelisted wallet would make `register` refund the float to the user.
    #[test, expected_failure(abort_code = names_gateway::EWhitelistedUseFree)]
    fun whitelisted_wallet_is_refused() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tr = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::whitelist_add(&cap, &mut tr, USER);
            ts::return_shared(tr);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EFloatTooLow)]
    fun empty_float_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::withdraw_sui(&cap, &mut gw, SUI_FEE * 3, ts::ctx(&mut sc));
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::end(sc);
    }

    // If the registry fee is raised past our cap, we stop paying instead of
    // draining the float.
    #[test, expected_failure(abort_code = names_gateway::ESuiFeeTooHigh)]
    fun registry_fee_above_cap_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::set_max_sui_fee(&cap, &mut gw, SUI_FEE - 1);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::end(sc);
    }

    // Setup plus a keeper key in KEEPER's wallet, with a clock at HOUR_MS*7
    // so the first keeper move is past the interval from add_token (t=0).
    const HOUR_MS: u64 = 60 * 60 * 1000;
    fun setup_keeper(sc: &mut ts::Scenario): clock::Clock {
        let mut clk = clock::create_for_testing(ts::ctx(sc));
        setup_with(sc, &clk);
        ts::next_tx(sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(sc);
            let mut gw = ts::take_shared<Gateway>(sc);
            names_gateway::mint_keeper(&cap, &mut gw, KEEPER, ts::ctx(sc));
            ts::return_shared(gw);
            ts::return_to_sender(sc, cap);
        };
        clock::set_for_testing(&mut clk, 7 * HOUR_MS);
        clk
    }
    fun keeper_move(sc: &ts::Scenario, clk: &clock::Clock, fee: u64) {
        let k = ts::take_from_sender<KeeperCap>(sc);
        let mut gw = ts::take_shared<Gateway>(sc);
        names_gateway::keeper_set_fee<CAT>(&k, &mut gw, fee, clk);
        ts::return_shared(gw);
        ts::return_to_sender(sc, k);
    }

    // The keeper follows the price inside the corridor, one bounded step at a
    // time, and the fee timestamp comes from the clock.
    #[test]
    fun keeper_moves_fee_within_bounds() {
        let mut sc = ts::begin(ADMIN);
        let clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 12 / 10);   // +20% exactly: allowed
        ts::next_tx(&mut sc, KEEPER);
        {
            let gw = ts::take_shared<Gateway>(&sc);
            assert!(names_gateway::token_fee_base<CAT>(&gw) == CAT_FEE * 12 / 10, 0);
            assert!(names_gateway::token_fee_updated_ms<CAT>(&gw) == 7 * HOUR_MS, 1);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EStepTooLarge)]
    fun keeper_step_too_large_aborts() {
        let mut sc = ts::begin(ADMIN);
        let clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 13 / 10);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EOutOfBounds)]
    fun keeper_outside_corridor_aborts() {
        let mut sc = ts::begin(ADMIN);
        let clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            // Narrow the corridor so a legal-size step falls outside it.
            names_gateway::set_token_bounds<CAT>(&cap, &mut gw, CAT_FEE, CAT_FEE + 1, STEP_BPS);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 11 / 10);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Steps cannot be compounded: a second move inside the interval aborts,
    // whether in the same transaction or the next one.
    #[test, expected_failure(abort_code = names_gateway::EKeeperTooSoon)]
    fun keeper_cannot_compound_steps() {
        let mut sc = ts::begin(ADMIN);
        let clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 9 / 10);
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 9 / 10 * 9 / 10);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // After the interval the keeper may move again.
    #[test]
    fun keeper_moves_again_after_interval() {
        let mut sc = ts::begin(ADMIN);
        let mut clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 9 / 10);
        clock::set_for_testing(&mut clk, 7 * HOUR_MS + names_gateway::min_keeper_interval_ms());
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 9 / 10 * 9 / 10);
        ts::next_tx(&mut sc, KEEPER);
        {
            let gw = ts::take_shared<Gateway>(&sc);
            assert!(names_gateway::token_fee_base<CAT>(&gw) == CAT_FEE * 9 / 10 * 9 / 10, 0);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A revoked key still exists in the bot's wallet and does nothing.
    #[test, expected_failure(abort_code = names_gateway::EKeeperNotAuthorized)]
    fun revoked_keeper_aborts() {
        let mut sc = ts::begin(ADMIN);
        let clk = setup_keeper(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let keeper_id = ts::most_recent_id_for_address<KeeperCap>(KEEPER).destroy_some();
            names_gateway::revoke_keeper(&cap, &mut gw, keeper_id);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, KEEPER);
        keeper_move(&sc, &clk, CAT_FEE * 9 / 10);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // The only way out: a real Epoch vault, 100% at the cliff, a year away,
    // owned by the beneficiary. The config can be removed once it is empty.
    #[test]
    fun lock_creates_a_vault_then_remove() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut vt = ts::take_shared<VestingTreasury>(&sc);
            let fee = coin::mint_for_testing<SUI>(VAULT_FEE, ts::ctx(&mut sc));
            names_gateway::lock_collected<CAT>(&cap, &mut gw, &mut vt, fee, EPOCH, YEAR_MS, &clk, ts::ctx(&mut sc));
            assert!(names_gateway::token_collected<CAT>(&gw) == 0, 0);
            assert!(names_gateway::token_total_collected<CAT>(&gw) == CAT_FEE, 1);
            names_gateway::remove_token<CAT>(&cap, &mut gw);
            assert!(!names_gateway::has_token<CAT>(&gw), 2);
            assert!(names_gateway::tokens(&gw).length() == 0, 3);
            ts::return_shared(vt);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let v = ts::take_shared<VestingVault<CAT>>(&sc);
            assert!(vesting::total_locked(&v) == CAT_FEE, 4);
            assert!(vesting::beneficiary(&v) == EPOCH, 5);
            assert!(vesting::creator(&v) == ADMIN, 6);
            // Nothing claimable before the year is over, everything after.
            assert!(vesting::claimable(&v, &clk) == 0, 7);
            clock::set_for_testing(&mut clk, 1_000 + YEAR_MS - 1);
            assert!(vesting::claimable(&v, &clk) == 0, 8);
            clock::set_for_testing(&mut clk, 1_000 + YEAR_MS);
            assert!(vesting::claimable(&v, &clk) == CAT_FEE, 9);
            ts::return_shared(v);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::ELockTooShort)]
    fun lock_shorter_than_a_year_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut vt = ts::take_shared<VestingTreasury>(&sc);
            let fee = coin::mint_for_testing<SUI>(VAULT_FEE, ts::ctx(&mut sc));
            names_gateway::lock_collected<CAT>(&cap, &mut gw, &mut vt, fee, EPOCH, YEAR_MS - 1, &clk, ts::ctx(&mut sc));
            ts::return_shared(vt);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::ENothingToLock)]
    fun lock_with_nothing_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut vt = ts::take_shared<VestingTreasury>(&sc);
            let fee = coin::mint_for_testing<SUI>(VAULT_FEE, ts::ctx(&mut sc));
            names_gateway::lock_collected<CAT>(&cap, &mut gw, &mut vt, fee, EPOCH, YEAR_MS, &clk, ts::ctx(&mut sc));
            ts::return_shared(vt);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EBalanceNotEmpty)]
    fun remove_with_balance_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, USER);
        pay(&mut sc, b"stefano", CAT_FEE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            names_gateway::remove_token<CAT>(&cap, &mut gw);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::EFeeTooHigh)]
    fun absurd_fee_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let clk = clock::create_for_testing(ts::ctx(&mut sc));
            names_gateway::set_token_fee<CAT>(&cap, &mut gw, 18_000_000_000_000_000_000 / 25 + 1, &clk);
            clock::destroy_for_testing(clk);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = names_gateway::ETokenAlreadyAdded)]
    fun add_twice_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let clk = clock::create_for_testing(ts::ctx(&mut sc));
            names_gateway::add_token<CAT>(&cap, &mut gw, CAT_FEE, CAT_MIN, CAT_MAX, STEP_BPS, &clk);
            clock::destroy_for_testing(clk);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    // Admin fee changes widen the corridor rather than failing against it.
    #[test]
    fun admin_fee_change_widens_bounds() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            let clk = clock::create_for_testing(ts::ctx(&mut sc));
            names_gateway::set_token_fee<CAT>(&cap, &mut gw, CAT_MAX * 2, &clk);
            clock::destroy_for_testing(clk);
            let (lo, hi, step) = names_gateway::token_bounds<CAT>(&gw);
            assert!(lo == CAT_MIN && hi == CAT_MAX * 2 && step == STEP_BPS, 0);
            assert!(names_gateway::token_fee_base<CAT>(&gw) == CAT_MAX * 2, 1);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }
}
