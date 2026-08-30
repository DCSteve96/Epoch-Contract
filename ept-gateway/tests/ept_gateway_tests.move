#[test_only]
module epoch_ept_gateway::ept_gateway_tests {
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario as ts;
    use vesting_service::vesting::{Self, Treasury, VestingVault, MultiVestingVault};
    use epoch_ept_gateway::ept_gateway::{Self, Gateway, GatewayAdminCap};

    const ADMIN: address = @0xAD;
    const USER:  address = @0x5E4;

    /// Stand-in for $EPT (6 decimals) and for a random other coin.
    public struct EPT has drop {}
    public struct OTHER has drop {}
    /// Stand-in for the token being vested.
    public struct TOK has drop {}

    const EPT_FEE:    u64 = 40_000_000_000;   // 40,000 EPT at 6 decimals
    const DEPLOY_FEE: u64 = 10_000_000_000;   // 10 SUI, the vesting default

    /// Publish both packages, configure the gateway, fund the float.
    fun setup(sc: &mut ts::Scenario) {
        ts::next_tx(sc, ADMIN);
        {
            vesting::init_for_testing(ts::ctx(sc));
            ept_gateway::init_for_testing(ts::ctx(sc));
        };
        ts::next_tx(sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(sc);
            let mut gw = ts::take_shared<Gateway>(sc);
            ept_gateway::set_ept_config<EPT>(&cap, &mut gw, EPT_FEE);
            let float = coin::mint_for_testing<SUI>(DEPLOY_FEE * 3, ts::ctx(sc));
            ept_gateway::fund(&mut gw, float, ts::ctx(sc));
            ts::return_shared(gw);
            ts::return_to_sender(sc, cap);
        };
    }

    // A user pays in EPT: the EPT is burned, the SUI fee comes from the float,
    // and the vault belongs to the user exactly as if they had paid in SUI.
    #[test]
    fun pay_in_ept_creates_a_normal_vault() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));

            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );

            assert!(ept_gateway::ept_burned(&gw) == EPT_FEE, 0);
            assert!(ept_gateway::vaults_created(&gw) == 1, 1);
            assert!(ept_gateway::sui_float(&gw) == DEPLOY_FEE * 2, 2);
            ts::return_shared(tr);
            ts::return_shared(gw);
        };

        // The vault is a normal shared vault, created BY the user.
        ts::next_tx(&mut sc, USER);
        {
            let vault = ts::take_shared<VestingVault<TOK>>(&sc);
            assert!(vesting::creator(&vault) == USER, 3);
            assert!(vesting::beneficiary(&vault) == USER, 4);
            assert!(vesting::total_locked(&vault) == 1_000, 5);
            ts::return_shared(vault);
        };

        // The EPT really left: it now sits at the dead address.
        ts::next_tx(&mut sc, ADMIN);
        {
            let burned = ts::take_from_address<Coin<EPT>>(&sc, @0x0);
            assert!(coin::value(&burned) == EPT_FEE, 6);
            ts::return_to_address(@0x0, burned);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Overpaying gets the change back.
    #[test]
    fun change_is_returned() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE + 555, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        ts::next_tx(&mut sc, USER);
        {
            let change = ts::take_from_sender<Coin<EPT>>(&sc);
            assert!(coin::value(&change) == 555, 0);
            ts::return_to_sender(&sc, change);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Multi-beneficiary vaults work the same way.
    #[test]
    fun pay_in_ept_multi_vault() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_multi_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok,
                vector[@0xB1, @0xB2], vector[6_000, 4_000],
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        ts::next_tx(&mut sc, USER);
        {
            let vault = ts::take_shared<MultiVestingVault<TOK>>(&sc);
            assert!(vesting::multi_creator(&vault) == USER, 0);
            assert!(vesting::multi_beneficiary_count(&vault) == 2, 1);
            ts::return_shared(vault);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Paying with a coin that is not the configured one aborts (EWrongEptCoin = 1).
    #[test]
    #[expected_failure(abort_code = 1, location = epoch_ept_gateway::ept_gateway)]
    fun wrong_coin_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let other = coin::mint_for_testing<OTHER>(EPT_FEE, ts::ctx(&mut sc));
            let tok   = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, OTHER>(
                &mut gw, &mut tr, other, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Paying less than the fee aborts (EInsufficientEpt = 2).
    #[test]
    #[expected_failure(abort_code = 2, location = epoch_ept_gateway::ept_gateway)]
    fun underpay_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE - 1, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // An empty float aborts instead of silently failing (EFloatTooLow = 3).
    #[test]
    #[expected_failure(abort_code = 3, location = epoch_ept_gateway::ept_gateway)]
    fun empty_float_aborts() {
        let mut sc = ts::begin(ADMIN);
        ts::next_tx(&mut sc, ADMIN);
        {
            vesting::init_for_testing(ts::ctx(&mut sc));
            ept_gateway::init_for_testing(ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            ept_gateway::set_ept_config<EPT>(&cap, &mut gw, EPT_FEE);  // configured, not funded
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Before configuration nothing can be paid (ENotConfigured = 0).
    #[test]
    #[expected_failure(abort_code = 0, location = epoch_ept_gateway::ept_gateway)]
    fun unconfigured_aborts() {
        let mut sc = ts::begin(ADMIN);
        ts::next_tx(&mut sc, ADMIN);
        {
            vesting::init_for_testing(ts::ctx(&mut sc));
            ept_gateway::init_for_testing(ts::ctx(&mut sc));
        };
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A zero fee would make vaults free: rejected (EZeroFee = 4).
    #[test]
    #[expected_failure(abort_code = 4, location = epoch_ept_gateway::ept_gateway)]
    fun zero_fee_rejected() {
        let mut sc = ts::begin(ADMIN);
        ts::next_tx(&mut sc, ADMIN);
        {
            vesting::init_for_testing(ts::ctx(&mut sc));
            ept_gateway::init_for_testing(ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            ept_gateway::set_ept_config<EPT>(&cap, &mut gw, 0);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    // The SUI we advance really reaches the vesting Treasury: that is what makes
    // the float recyclable rather than a subsidy.
    #[test]
    fun the_sui_fee_reaches_the_treasury() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };

        // The vesting package has no balance view, so read it the way the
        // protocol actually does: withdraw and look at what comes out.
        ts::next_tx(&mut sc, ADMIN);
        {
            let vcap = ts::take_from_sender<vesting::AdminCap>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            vesting::withdraw_fees(&vcap, &mut tr, ts::ctx(&mut sc));
            ts::return_shared(tr);
            ts::return_to_sender(&sc, vcap);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let fees = ts::take_from_sender<Coin<SUI>>(&sc);
            assert!(coin::value(&fees) == DEPLOY_FEE, 0);
            ts::return_to_sender(&sc, fees);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // If the vesting deploy fee is raised above our cap, we abort instead of
    // draining the float (ESuiFeeTooHigh = 5).
    #[test]
    #[expected_failure(abort_code = 5, location = epoch_ept_gateway::ept_gateway)]
    fun deploy_fee_above_cap_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        // The vesting admin raises the fee to 100 SUI.
        ts::next_tx(&mut sc, ADMIN);
        {
            let vcap = ts::take_from_sender<vesting::AdminCap>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            vesting::update_deploy_fee(&vcap, &mut tr, 100_000_000_000);
            ts::return_shared(tr);
            ts::return_to_sender(&sc, vcap);
        };

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Pausing stops the EPT path (EPaused = 6).
    #[test]
    #[expected_failure(abort_code = 6, location = epoch_ept_gateway::ept_gateway)]
    fun paused_gateway_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            ept_gateway::set_paused(&cap, &mut gw, true);
            assert!(ept_gateway::is_paused(&gw), 0);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };

        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Unpausing puts it back in service.
    #[test]
    fun unpause_restores_service() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            ept_gateway::set_paused(&cap, &mut gw, true);
            ept_gateway::set_paused(&cap, &mut gw, false);
            ept_gateway::set_max_sui_fee(&cap, &mut gw, DEPLOY_FEE);
            assert!(ept_gateway::max_sui_fee(&gw) == DEPLOY_FEE, 0);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, USER);
        {
            let mut gw = ts::take_shared<Gateway>(&sc);
            let mut tr = ts::take_shared<Treasury>(&sc);
            let ept = coin::mint_for_testing<EPT>(EPT_FEE, ts::ctx(&mut sc));
            let tok = coin::mint_for_testing<TOK>(1_000, ts::ctx(&mut sc));
            ept_gateway::create_vault_with_ept<TOK, EPT>(
                &mut gw, &mut tr, ept, tok, USER,
                0, 0, 1_000, 10_000, &clk, ts::ctx(&mut sc),
            );
            assert!(ept_gateway::vaults_created(&gw) == 1, 1);
            ts::return_shared(tr);
            ts::return_shared(gw);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // The admin can pull the float back out (this is how the SUI fee, which
    // lands in the vesting Treasury, is recycled).
    #[test]
    fun admin_can_withdraw_float() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<GatewayAdminCap>(&sc);
            let mut gw = ts::take_shared<Gateway>(&sc);
            ept_gateway::withdraw_sui(&cap, &mut gw, DEPLOY_FEE, ts::ctx(&mut sc));
            assert!(ept_gateway::sui_float(&gw) == DEPLOY_FEE * 2, 0);
            ts::return_shared(gw);
            ts::return_to_sender(&sc, cap);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let c = ts::take_from_sender<Coin<SUI>>(&sc);
            assert!(coin::value(&c) == DEPLOY_FEE, 1);
            ts::return_to_sender(&sc, c);
        };
        ts::end(sc);
    }
}
