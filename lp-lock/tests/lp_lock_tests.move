/// What these tests can and cannot cover.
///
/// The Cetus dependency is an INTERFACE package: every function body is
/// `abort 0`, and there is no way to mint a `Pool` or a `Position` outside a
/// live network. So the fee, reward and add-liquidity paths cannot run here.
/// That gap is NOT covered anywhere yet: the testnet script that has to cover it
/// is not written. It is listed as an open finding in AUDIT.md rather than
/// hidden behind a green run here.
///
/// What runs here is everything that does not need Cetus: the lifecycle and
/// every guard around the capital, exercised through the generic `LpLock<P>`
/// with a dummy object standing in for a position. `lock_for_testing` runs the
/// same assertions as `lock` on the values it is handed, so deleting a guard in
/// the production path breaks these tests instead of passing silently.
#[test_only]
module epoch_lp_lock::lp_lock_tests {
    use sui::clock;
    use sui::test_scenario as ts;
    use epoch_lp_lock::lp_lock::{Self, LpLock};

    const ALICE: address = @0xA11CE;
    const BOB:   address = @0xB0B;
    const CAROL: address = @0xCA401;

    /// Stands in for a Cetus position.
    public struct DummyPos has key, store { id: UID }

    fun mint(sc: &mut ts::Scenario): DummyPos {
        DummyPos { id: object::new(ts::ctx(sc)) }
    }
    /// Any id works as the pool id in these tests: the pool identity is only
    /// compared, never dereferenced, on the paths under test.
    fun some_id(sc: &mut ts::Scenario): ID {
        let uid = object::new(ts::ctx(sc));
        let id = object::uid_to_inner(&uid);
        object::delete(uid);
        id
    }

    // 1. Happy path: locked, then returned to the beneficiary after the date.
    #[test]
    fun lock_and_claim_after_unlock() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };

        clock::set_for_testing(&mut clk, 6_000);

        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            assert!(!lp_lock::is_claimed(&lock), 0);
            assert!(lp_lock::beneficiary(&lock) == BOB, 1);
            assert!(lp_lock::creator(&lock) == ALICE, 2);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            assert!(lp_lock::is_claimed(&lock), 3);
            ts::return_shared(lock);
        };
        ts::next_tx(&mut sc, BOB);
        {
            let pos = ts::take_from_sender<DummyPos>(&sc);
            ts::return_to_sender(&sc, pos);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 2. The capital cannot move before the date. EStillLocked = 0.
    #[test]
    #[expected_failure(abort_code = 0, location = epoch_lp_lock::lp_lock)]
    fun claim_before_unlock_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 3. Only the beneficiary claims, even after the date. ENotBeneficiary = 1.
    #[test]
    #[expected_failure(abort_code = 1, location = epoch_lp_lock::lp_lock)]
    fun claim_by_stranger_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 9_000);
        ts::next_tx(&mut sc, CAROL);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 4. Claiming twice aborts. EAlreadyClaimed = 3.
    #[test]
    #[expected_failure(abort_code = 3, location = epoch_lp_lock::lp_lock)]
    fun double_claim_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 5. The date moves forward and the lock keeps the new one.
    #[test]
    fun extend_moves_the_date_forward() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::extend(&mut lock, 50_000, ts::ctx(&mut sc));
            assert!(lp_lock::unlock_ms(&lock) == 50_000, 0);
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 6. The date can never move closer. ENotExtension = 4.
    #[test]
    #[expected_failure(abort_code = 4, location = epoch_lp_lock::lp_lock)]
    fun extend_backwards_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::extend(&mut lock, 4_000, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 7. Not even the creator can extend: only the party giving something up.
    //    ENotBeneficiary = 1.
    #[test]
    #[expected_failure(abort_code = 1, location = epoch_lp_lock::lp_lock)]
    fun creator_cannot_extend() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::extend(&mut lock, 50_000, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 8. A lock that unlocks in the past is not a lock. EUnlockInPast = 2.
    #[test]
    #[expected_failure(abort_code = 2, location = epoch_lp_lock::lp_lock)]
    fun unlock_in_the_past_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 10_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 9. A @0x0 beneficiary could never sign a claim: the position would be
    //    gone forever. EZeroBeneficiary = 5.
    #[test]
    #[expected_failure(abort_code = 5, location = epoch_lp_lock::lp_lock)]
    fun zero_beneficiary_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, @0x0, &clk, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 10. Extending a claimed lock aborts. EAlreadyClaimed = 3.
    #[test]
    #[expected_failure(abort_code = 3, location = epoch_lp_lock::lp_lock)]
    fun extend_after_claim_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            lp_lock::extend(&mut lock, 99_000, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 11. A claimed lock can be deleted by the beneficiary, recovering storage.
    #[test]
    fun destroy_after_claim() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            lp_lock::destroy_claimed(lock, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 12. Deleting a lock that still holds the position aborts. EStillLocked = 0.
    #[test]
    #[expected_failure(abort_code = 0, location = epoch_lp_lock::lp_lock)]
    fun destroy_while_holding_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::destroy_claimed(lock, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 13. A stranger cannot delete someone else's record. ENotBeneficiary = 1.
    #[test]
    #[expected_failure(abort_code = 1, location = epoch_lp_lock::lp_lock)]
    fun stranger_cannot_destroy() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        ts::next_tx(&mut sc, CAROL);
        {
            let lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            lp_lock::destroy_claimed(lock, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 14. Locking a position with no liquidity is refused. EEmptyPosition = 6.
    //     This is the guard the whole module exists for: an empty lock looks
    //     exactly like a full one in a screenshot.
    #[test]
    #[expected_failure(abort_code = 6, location = epoch_lp_lock::lp_lock)]
    fun empty_position_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 0, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 15. The snapshot is the value it was given, not a hardcoded placeholder.
    #[test]
    fun liquidity_snapshot_is_recorded() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            let pid = some_id(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 42_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            assert!(lp_lock::liquidity_at_lock(&lock) == 42_000_000, 0);
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // 16. The recorded pool id survives untouched: every Cetus call compares
    //     against it, so it must be readable and stable.
    #[test]
    fun pool_id_is_recorded() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        let pid = some_id(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let pos = mint(&mut sc);
            lp_lock::lock_for_testing(pos, pid, 1_000_000, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let lock = ts::take_shared<LpLock<DummyPos>>(&sc);
            assert!(lp_lock::pool_id(&lock) == pid, 0);
            assert!(lp_lock::locked_at_ms(&lock) == 1_000, 1);
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
