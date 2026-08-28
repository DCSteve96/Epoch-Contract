#[test_only]
module vesting_service::vesting_tests {

    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use vesting_service::vesting::{Self, VestingVault, MultiVestingVault, Treasury};

    // =========================================================================
    // Indirizzi di test
    // =========================================================================

    const ADMIN:        address = @0xAD;
    const CREATOR:      address = @0xC0;
    const BENEFICIARY:  address = @0xBE;
    const BENEFICIARY2: address = @0xBE2;
    const BENEFICIARY3: address = @0xBE3;
    const STRANGER:     address = @0x57;

    // 0.1 SUI (deve corrispondere alla fee impostata in init_for_testing)
    const FEE:    u64 = 100_000_000;
    // 1 SUI da bloccare nel vault
    const AMOUNT: u64 = 1_000_000_000;

    // =========================================================================
    // Helper: inizializza il contratto e imposta fee a 0.1 SUI
    // =========================================================================

    fun setup(scenario: &mut sui::test_scenario::Scenario) {
        ts::next_tx(scenario, ADMIN);
        vesting::init_for_testing(ts::ctx(scenario));

        ts::next_tx(scenario, ADMIN);
        {
            let admin_cap = ts::take_from_sender<vesting::AdminCap>(scenario);
            let mut treasury = ts::take_shared<Treasury>(scenario);
            vesting::update_deploy_fee(&admin_cap, &mut treasury, FEE);
            ts::return_to_sender(scenario, admin_cap);
            ts::return_shared(treasury);
        };
    }

    fun make_clock(ts_ms: u64, scenario: &mut sui::test_scenario::Scenario): clock::Clock {
        let mut clk = clock::create_for_testing(ts::ctx(scenario));
        clock::set_for_testing(&mut clk, ts_ms);
        clk
    }

    fun create_test_vault(
        scenario:        &mut sui::test_scenario::Scenario,
        creator:         address,
        beneficiary:     address,
        cliff_ts_ms:     u64,
        cliff_bps:       u64,
        linear_start_ms: u64,
        linear_end_ms:   u64,
        clock_ts_ms:     u64,
    ) {
        ts::next_tx(scenario, creator);
        {
            let mut treasury = ts::take_shared<Treasury>(scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(scenario));
            let clk    = make_clock(clock_ts_ms, scenario);

            vesting::create_vault<SUI>(
                &mut treasury,
                fee,
                tokens,
                beneficiary,
                cliff_ts_ms,
                cliff_bps,
                linear_start_ms,
                linear_end_ms,
                &clk,
                ts::ctx(scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };
    }

    // =========================================================================
    // 1. Pure cliff — claim totale dopo il cliff
    // =========================================================================

    #[test]
    fun test_pure_cliff_full_claim() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        // Vault: 100% al cliff (t=1000ms)
        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 1000, 10000, 1000, 1000, 0);

        // Prima del cliff: niente da claimare
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk   = make_clock(500, &mut scenario);
            assert!(vesting::claimable(&vault, &clk) == 0, 0);
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        // Dopo il cliff: tutto claimabile
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(2000, &mut scenario);

            assert!(vesting::claimable(&vault, &clk) == AMOUNT, 1);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            assert!(vesting::claimed(&vault) == AMOUNT, 2);
            assert!(vesting::remaining_balance(&vault) == 0, 3);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 2. Double claim — la seconda deve fallire con ENothingToClaim
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::ENothingToClaim)]
    fun test_double_claim_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 1000, 10000, 1000, 1000, 0);

        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(2000, &mut scenario);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(3000, &mut scenario);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario)); // abort
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 3. Linear vesting — claim a metà durata
    // =========================================================================

    #[test]
    fun test_linear_claim_at_midpoint() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 0, 0, 0, 10000, 0);

        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(5000, &mut scenario);

            let expected = AMOUNT / 2;
            assert!(vesting::claimable(&vault, &clk) == expected, 0);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            assert!(vesting::claimed(&vault) == expected, 1);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(10000, &mut scenario);

            assert!(vesting::claimable(&vault, &clk) == AMOUNT / 2, 2);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            assert!(vesting::claimed(&vault) == AMOUNT, 3);
            assert!(vesting::remaining_balance(&vault) == 0, 4);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 4. Linear vesting — claim unico dopo la fine
    // =========================================================================

    #[test]
    fun test_linear_full_claim_after_end() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 0, 0, 0, 10000, 0);

        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(99999, &mut scenario);

            assert!(vesting::claimable(&vault, &clk) == AMOUNT, 0);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            assert!(vesting::claimed(&vault) == AMOUNT, 1);
            assert!(vesting::remaining_balance(&vault) == 0, 2);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 5. Hybrid vesting — 20% al cliff + 80% lineare
    // =========================================================================

    #[test]
    fun test_hybrid_cliff_plus_linear() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        // 20% al cliff (t=1000), poi 80% lineare fino a t=5000
        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 1000, 2000, 1000, 5000, 0);

        // Al cliff (t=1000): 20%
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(1000, &mut scenario);

            let cliff_amount = AMOUNT * 2000 / 10000; // 200_000_000
            assert!(vesting::claimable(&vault, &clk) == cliff_amount, 0);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        // A metà del lineare (t=3000): ulteriore 40%
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(3000, &mut scenario);

            let expected = AMOUNT * 4000 / 10000; // 400_000_000
            assert!(vesting::claimable(&vault, &clk) == expected, 1);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        // Dopo la fine (t=6000): restante 40%
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(6000, &mut scenario);

            let expected = AMOUNT * 4000 / 10000; // 400_000_000
            assert!(vesting::claimable(&vault, &clk) == expected, 2);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            assert!(vesting::claimed(&vault) == AMOUNT, 3);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 6. Fee insufficiente — deve abortire
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::EInsufficientFee)]
    fun test_insufficient_fee_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE - 1, ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT,  ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            vesting::create_vault<SUI>(
                &mut treasury, fee, tokens, BENEFICIARY,
                0, 0, 0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 7. Indirizzo sbagliato tenta il claim — deve abortire
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::ENotBeneficiary)]
    fun test_wrong_beneficiary_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 1000, 10000, 1000, 1000, 0);

        ts::next_tx(&mut scenario, STRANGER);
        {
            let mut vault = ts::take_shared<VestingVault<SUI>>(&scenario);
            let clk       = make_clock(2000, &mut scenario);
            vesting::claim<SUI>(&mut vault, &clk, ts::ctx(&mut scenario)); // abort
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 8. cliff_bps > 0 con cliff_ts_ms = 0 — deve abortire (Finding #2)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::EInvalidParams)]
    fun test_cliff_bps_without_cliff_ts_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            // cliff_bps=5000 ma cliff_ts_ms=0: deve abortire con EInvalidParams
            vesting::create_vault<SUI>(
                &mut treasury, fee, tokens, BENEFICIARY,
                0,     // cliff_ts_ms = 0
                5000,  // cliff_bps = 50%
                0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 9. Beneficiario zero-address — deve abortire (Finding #8)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::EInvalidParams)]
    fun test_zero_address_beneficiary_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            vesting::create_vault<SUI>(
                &mut treasury, fee, tokens,
                @0x0,  // zero address — deve abortire
                0, 0, 0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 10. Multi-vault — claim proporzionale per due beneficiari
    // =========================================================================

    #[test]
    fun test_multi_vault_proportional_claim() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        // Crea multi-vault: 60% a B1, 40% a B2, linear 0→10000ms
        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            vesting::create_multi_vault<SUI>(
                &mut treasury,
                fee,
                tokens,
                vector[BENEFICIARY, BENEFICIARY2],
                vector[6000, 4000],  // 60% / 40%
                0, 0, 0, 10000,
                &clk,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        // A metà (t=5000): B1 clama 30% (50% di 60%), B2 clama 20% (50% di 40%)
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk       = make_clock(5000, &mut scenario);

            let expected_b1 = AMOUNT * 6000 / 10000 / 2; // 300_000_000
            assert!(vesting::claimable_multi(&vault, BENEFICIARY, &clk) == expected_b1, 0);
            vesting::claim_multi<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, BENEFICIARY2);
        {
            let mut vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk       = make_clock(5000, &mut scenario);

            let expected_b2 = AMOUNT * 4000 / 10000 / 2; // 200_000_000
            assert!(vesting::claimable_multi(&vault, BENEFICIARY2, &clk) == expected_b2, 1);
            vesting::claim_multi<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        // Dopo la fine (t=10000): entrambi claimano il restante
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let mut vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk       = make_clock(10000, &mut scenario);
            vesting::claim_multi<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, BENEFICIARY2);
        {
            let mut vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk       = make_clock(10000, &mut scenario);
            vesting::claim_multi<SUI>(&mut vault, &clk, ts::ctx(&mut scenario));

            // Vault deve essere vuoto (o con dust trascurabile di rounding)
            assert!(vesting::multi_remaining_balance(&vault) == 0, 2);

            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 11. Multi-vault — non-beneficiario non può claimare
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::ENotMultiBeneficiary)]
    fun test_multi_vault_stranger_cannot_claim() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            vesting::create_multi_vault<SUI>(
                &mut treasury, fee, tokens,
                vector[BENEFICIARY, BENEFICIARY2],
                vector[5000, 5000],
                0, 0, 0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::next_tx(&mut scenario, STRANGER);
        {
            let mut vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk       = make_clock(10000, &mut scenario);
            vesting::claim_multi<SUI>(&mut vault, &clk, ts::ctx(&mut scenario)); // abort
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 12. Multi-vault — shares che non sommano 10000 devono abortire
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::ESharesMustSum10000)]
    fun test_multi_vault_bad_shares_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            // 60% + 30% = 90%, non 100% — deve abortire
            vesting::create_multi_vault<SUI>(
                &mut treasury, fee, tokens,
                vector[BENEFICIARY, BENEFICIARY2],
                vector[6000, 3000],
                0, 0, 0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 13. Multi-vault — bps=0 per un beneficiario deve abortire (Finding #6)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = vesting_service::vesting::EInvalidParams)]
    fun test_multi_vault_zero_bps_aborts() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            // bps=0 per B2 — deve abortire con EInvalidParams
            vesting::create_multi_vault<SUI>(
                &mut treasury, fee, tokens,
                vector[BENEFICIARY, BENEFICIARY2],
                vector[10000, 0],
                0, 0, 0, 10000, &clk, ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 14. Admin — aggiornamento fee e withdraw
    // =========================================================================

    #[test]
    fun test_admin_fee_update_and_withdraw() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        // Crea un vault per generare fee nel treasury
        create_test_vault(&mut scenario, CREATOR, BENEFICIARY, 0, 0, 0, 10000, 0);

        // Fee deve essere 0.1 SUI nel treasury
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            assert!(vesting::deploy_fee(&treasury) == FEE, 0);
            ts::return_shared(treasury);
        };

        // Admin preleva le fee
        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap    = ts::take_from_sender<vesting::AdminCap>(&scenario);
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            vesting::withdraw_fees(&admin_cap, &mut treasury, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, admin_cap);
            ts::return_shared(treasury);
        };

        // Admin riceve la coin con il valore della fee
        ts::next_tx(&mut scenario, ADMIN);
        {
            let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
            assert!(coin::value(&payout) == FEE, 1);
            ts::return_to_sender(&scenario, payout);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 15. Multi-vault — cliff + linear con 3 beneficiari
    // =========================================================================

    #[test]
    fun test_multi_vault_cliff_linear_three_beneficiaries() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        // 3 beneficiari: 50% / 30% / 20%, 25% al cliff (t=1000), poi lineare → t=5000
        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let fee    = coin::mint_for_testing<SUI>(FEE,    ts::ctx(&mut scenario));
            let tokens = coin::mint_for_testing<SUI>(AMOUNT, ts::ctx(&mut scenario));
            let clk    = make_clock(0, &mut scenario);

            vesting::create_multi_vault<SUI>(
                &mut treasury,
                fee,
                tokens,
                vector[BENEFICIARY, BENEFICIARY2, BENEFICIARY3],
                vector[5000, 3000, 2000],
                1000, 2500, 1000, 5000,  // 25% al cliff t=1000, linear start=1000 end=5000
                &clk,
                ts::ctx(&mut scenario),
            );

            clock::destroy_for_testing(clk);
            ts::return_shared(treasury);
        };

        // Al cliff (t=1000): ogni beneficiario può claimare il 25% della sua quota
        ts::next_tx(&mut scenario, BENEFICIARY);
        {
            let vault = ts::take_shared<MultiVestingVault<SUI>>(&scenario);
            let clk   = make_clock(1000, &mut scenario);
            // B1 vested = 25% di 1 SUI = 250M; B1 share=50% → 125M
            let b1_cliff = AMOUNT * 2500 / 10000 * 5000 / 10000; // 125_000_000
            assert!(vesting::claimable_multi(&vault, BENEFICIARY, &clk) == b1_cliff, 0);
            clock::destroy_for_testing(clk);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }
}
