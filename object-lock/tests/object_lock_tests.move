#[test_only]
module epoch_object_lock::object_lock_tests {
    use sui::clock;
    use sui::test_scenario as ts;
    use epoch_object_lock::object_lock::{Self, ObjectLock};

    const ALICE: address = @0xA11CE;
    const BOB:   address = @0xB0B;

    /// Dummy lockable object (stands in for an LP position NFT).
    public struct DummyNft has key, store { id: UID }

    fun mint_nft(sc: &mut ts::Scenario): DummyNft {
        DummyNft { id: object::new(ts::ctx(sc)) }
    }

    // Lock then claim after the unlock time: item comes back to the beneficiary.
    #[test]
    fun lock_and_claim_after_unlock() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };

        // time passes beyond unlock
        clock::set_for_testing(&mut clk, 6_000);

        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            assert!(!object_lock::is_claimed(&lock), 0);
            object_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            assert!(object_lock::is_claimed(&lock), 1);
            ts::return_shared(lock);
        };
        // BOB now owns the NFT
        ts::next_tx(&mut sc, BOB);
        {
            let nft = ts::take_from_sender<DummyNft>(&sc);
            ts::return_to_sender(&sc, nft);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Claiming before the unlock time aborts (EStillLocked = 0).
    #[test]
    #[expected_failure(abort_code = 0, location = epoch_object_lock::object_lock)]
    fun claim_before_unlock_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            object_lock::claim(&mut lock, &clk, ts::ctx(&mut sc)); // still locked
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Only the beneficiary can claim (ENotBeneficiary = 1).
    #[test]
    #[expected_failure(abort_code = 1, location = epoch_object_lock::object_lock)]
    fun claim_by_non_beneficiary_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, ALICE); // ALICE (creator) tries to claim BOB's lock
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            object_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Unlock date in the past aborts (EUnlockInPast = 2).
    #[test]
    #[expected_failure(abort_code = 2, location = epoch_object_lock::object_lock)]
    fun lock_with_past_unlock_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 10_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc)); // past
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Extend works (beneficiary, strictly later); shortening aborts.
    #[test]
    fun extend_by_beneficiary_ok() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            object_lock::extend(&mut lock, 9_000, ts::ctx(&mut sc));
            assert!(object_lock::unlock_ms(&lock) == 9_000, 0);
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = epoch_object_lock::object_lock)]
    fun shorten_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            object_lock::extend(&mut lock, 3_000, ts::ctx(&mut sc)); // shorten → abort
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Double-claim aborts (EAlreadyClaimed = 3).
    #[test]
    #[expected_failure(abort_code = 3, location = epoch_object_lock::object_lock)]
    fun double_claim_aborts() {
        let mut sc = ts::begin(ALICE);
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, ALICE);
        {
            let nft = mint_nft(&mut sc);
            object_lock::lock(nft, 5_000, BOB, &clk, ts::ctx(&mut sc));
        };
        clock::set_for_testing(&mut clk, 6_000);
        ts::next_tx(&mut sc, BOB);
        {
            let mut lock = ts::take_shared<ObjectLock<DummyNft>>(&sc);
            object_lock::claim(&mut lock, &clk, ts::ctx(&mut sc));
            object_lock::claim(&mut lock, &clk, ts::ctx(&mut sc)); // again → abort
            ts::return_shared(lock);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
