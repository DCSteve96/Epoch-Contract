#[test_only]
module epoch_drops::drops_tests;

use epoch_drops::drops::{Self, Drop, Treasury, AdminCap};
use std::string;
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

public struct TOKEN has drop {}

const ADMIN:   address = @0xA0;
const CREATOR: address = @0xC0;
const ALICE:   address = @0xA1;
const BOB:     address = @0xB2;
const CAROL:   address = @0xC3;
const EVE:     address = @0xE5;

const SALT: address = @0x2222222222222222222222222222222222222222222222222222222222222222;
const FEE: u64 = 10_000_000_000;
const DAY_MS: u64 = 86_400_000;
const T0: u64 = 1_000 * DAY_MS;

fun setup(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    drops::init_for_testing(sc.ctx());
    sc
}

fun clk(at_ms: u64, sc: &mut ts::Scenario): clock::Clock {
    let mut c = clock::create_for_testing(sc.ctx());
    c.set_for_testing(at_ms);
    c
}

/// Albero delle tre foglie del test dei vettori: A 1000, B 2000, C 3000.
/// Restituisce (root, node_ab, leaf_a, leaf_b, leaf_c).
fun tree(): (vector<u8>, vector<u8>, vector<u8>, vector<u8>, vector<u8>) {
    let la = drops::leaf_hash(SALT, ALICE, 1_000);
    let lb = drops::leaf_hash(SALT, BOB, 2_000);
    let lc = drops::leaf_hash(SALT, CAROL, 3_000);
    let ab = drops::node_hash_for_testing(&la, &lb);
    let root = drops::node_hash_for_testing(&ab, &lc);
    (root, ab, la, lb, lc)
}

/// Drop standard: 25% al cliff (T0 + 10 giorni), lineare dal cliff a T0 + 110 giorni.
fun create_drop(sc: &mut ts::Scenario, deposit: u64, declared: u64, root: vector<u8>, fee_amount: u64) {
    create_drop_with_deadline(sc, deposit, declared, root, fee_amount, 0)
}

fun create_drop_with_deadline(sc: &mut ts::Scenario, deposit: u64, declared: u64, root: vector<u8>, fee_amount: u64, deadline: u64) {
    sc.next_tx(CREATOR);
    {
        let mut tr = sc.take_shared<Treasury>();
        let fee = coin::mint_for_testing<SUI>(fee_amount, sc.ctx());
        let tokens = coin::mint_for_testing<TOKEN>(deposit, sc.ctx());
        let c = clk(T0, sc);
        drops::create<TOKEN>(
            &mut tr, fee, tokens,
            string::utf8(b"Community drop"), SALT, root, string::utf8(b"BLOBID"),
            declared, 3,
            T0 + 10 * DAY_MS, 2_500, T0 + 10 * DAY_MS, T0 + 110 * DAY_MS, deadline,
            &c, sc.ctx(),
        );
        c.destroy_for_testing();
        ts::return_shared(tr);
    };
}

fun claim_as(sc: &mut ts::Scenario, who: address, allocation: u64, proof: vector<vector<u8>>, at_ms: u64): u64 {
    sc.next_tx(who);
    let mut d = sc.take_shared<Drop<TOKEN>>();
    let c = clk(at_ms, sc);
    let coin = drops::claim(&mut d, allocation, proof, &c, sc.ctx());
    let v = coin.value();
    transfer::public_transfer(coin, who);
    c.destroy_for_testing();
    ts::return_shared(d);
    v
}

// ── Vettori: gli stessi che calcola dropsMerkle.ts ──────────────────────

#[test]
fun same_hashes_as_the_frontend() {
    let (root, ab, la, lb, lc) = tree();
    assert!(la == x"05f5b3690fe2c91cd622ee7906c832316cf87eb7ccf97199ed6e537cb0c88f88", 0);
    assert!(lb == x"ff8804316cc0b70aa7a0cebf178585f95c85bcc6bcfbbed09172d58c0e430dd1", 1);
    assert!(lc == x"7b265d2e7070852b9e8c21dbce8a77f63cc20a4544aa954999d060bb67422672", 2);
    assert!(ab == x"dd4a8514ffb00e2c0523b543ee4e2043df1be461c4d7f6f4378d381f2b4c87b6", 3);
    assert!(root == x"f5011ea3d8faf5e98e8c3545ba258517eb29dff3dada5260c18e424dda4c77c2", 4);
    // Le prove che il frontend consegna.
    assert!(drops::verify(&root, &vector[lb, lc], SALT, ALICE, 1_000), 5);
    assert!(drops::verify(&root, &vector[ab], SALT, CAROL, 3_000), 6);
    // Il dispari duplicato darebbe un'altra radice.
    let twin = drops::node_hash_for_testing(&lc, &lc);
    assert!(drops::node_hash_for_testing(&ab, &twin) != root, 7);
    // Importo sbagliato, salt sbagliato, indirizzo sbagliato: tutti rifiutati.
    assert!(!drops::verify(&root, &vector[lb, lc], SALT, ALICE, 1_001), 8);
    assert!(!drops::verify(&root, &vector[lb, lc], @0x33, ALICE, 1_000), 9);
    assert!(!drops::verify(&root, &vector[lb, lc], SALT, EVE, 1_000), 10);
    // Un elemento della prova lungo 31 byte non deve far morire `lte`.
    assert!(!drops::verify(&root, &vector[x"00"], SALT, ALICE, 1_000), 11);
}

#[test]
fun same_vesting_math_as_the_vaults() {
    // 1000, 25% al cliff (100), lineare 100..300, a 200: 250 + 750/2 = 625
    assert!(drops::vested_for_testing(1_000, 100, 2_500, 100, 300, 200) == 625, 0);
    assert!(drops::vested_for_testing(1_000, 100, 2_500, 100, 300, 99) == 0, 1);
    assert!(drops::vested_for_testing(1_000, 100, 2_500, 100, 300, 100) == 250, 2);
    assert!(drops::vested_for_testing(1_000, 100, 2_500, 100, 300, 300) == 1_000, 3);
    // Tutto al cliff.
    assert!(drops::vested_for_testing(1_000, 100, 10_000, 100, 100, 99) == 0, 4);
    assert!(drops::vested_for_testing(1_000, 100, 10_000, 100, 100, 100) == 1_000, 5);
}

// ── Creazione ───────────────────────────────────────────────────────────

#[test]
fun create_takes_exact_fee_and_returns_change() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE + 5);
    sc.next_tx(CREATOR);
    {
        // Il resto (5 MIST) è tornato al creatore.
        let change = sc.take_from_sender<coin::Coin<SUI>>();
        assert!(change.value() == 5, 0);
        sc.return_to_sender(change);
        let d = sc.take_shared<Drop<TOKEN>>();
        assert!(drops::pot(&d) == 6_000, 1);
        assert!(drops::declared_total(&d) == 6_000, 2);
        assert!(drops::creator(&d) == CREATOR, 3);
        ts::return_shared(d);
    };
    sc.next_tx(ADMIN);
    {
        let cap = sc.take_from_sender<AdminCap>();
        let mut tr = sc.take_shared<Treasury>();
        let fees = drops::withdraw_fees(&cap, &mut tr, sc.ctx());
        assert!(fees.value() == FEE, 4);
        transfer::public_transfer(fees, ADMIN);
        sc.return_to_sender(cap);
        ts::return_shared(tr);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::EInsufficientFee)]
fun create_rejects_low_fee() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE - 1);
    sc.end();
}

#[test, expected_failure(abort_code = drops::EUnderfunded)]
fun create_rejects_deposit_below_declared() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 5_999, 6_000, root, FEE);
    sc.end();
}

#[test, expected_failure(abort_code = drops::EBadRoot)]
fun create_rejects_short_root() {
    let mut sc = setup();
    create_drop(&mut sc, 6_000, 6_000, x"00", FEE);
    sc.end();
}

#[test, expected_failure(abort_code = drops::EAlreadyEnded)]
fun create_rejects_schedule_in_the_past() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    sc.next_tx(CREATOR);
    {
        let mut tr = sc.take_shared<Treasury>();
        let fee = coin::mint_for_testing<SUI>(FEE, sc.ctx());
        let tokens = coin::mint_for_testing<TOKEN>(6_000, sc.ctx());
        let c = clk(T0, &mut sc);
        drops::create<TOKEN>(
            &mut tr, fee, tokens, string::utf8(b"x"), SALT, root, string::utf8(b"b"),
            6_000, 3, 0, 0, T0 - 2, T0 - 1, 0, &c, sc.ctx(),
        );
        c.destroy_for_testing();
        ts::return_shared(tr);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::EInvalidParams)]
fun create_rejects_cliff_bps_without_cliff_date() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    sc.next_tx(CREATOR);
    {
        let mut tr = sc.take_shared<Treasury>();
        let fee = coin::mint_for_testing<SUI>(FEE, sc.ctx());
        let tokens = coin::mint_for_testing<TOKEN>(6_000, sc.ctx());
        let c = clk(T0, &mut sc);
        drops::create<TOKEN>(
            &mut tr, fee, tokens, string::utf8(b"x"), SALT, root, string::utf8(b"b"),
            6_000, 3, 0, 2_500, T0 + DAY_MS, T0 + 2 * DAY_MS, 0, &c, sc.ctx(),
        );
        c.destroy_for_testing();
        ts::return_shared(tr);
    };
    sc.end();
}

// ── Ritiro ──────────────────────────────────────────────────────────────

#[test]
fun claim_follows_the_schedule_and_never_pays_twice() {
    let mut sc = setup();
    let (root, ab, _, lb, lc) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);

    // Al cliff: Alice prende il 25% di 1000.
    let v = claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 10 * DAY_MS);
    assert!(v == 250, 0);
    // A metà finestra lineare (60 giorni dopo il cliff, su 100): 250 + 750/2 = 625, meno 250.
    let v = claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 60 * DAY_MS);
    assert!(v == 375, 1);
    // Alla fine: il resto.
    let v = claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 200 * DAY_MS);
    assert!(v == 375, 2);
    // Carol prende tutto in una volta, anni dopo.
    let v = claim_as(&mut sc, CAROL, 3_000, vector[ab], T0 + 1_000 * DAY_MS);
    assert!(v == 3_000, 3);

    sc.next_tx(ADMIN);
    {
        let d = sc.take_shared<Drop<TOKEN>>();
        assert!(drops::paid_total(&d) == 4_000, 4);
        assert!(drops::claimed_of(&d, ALICE) == 1_000, 5);
        assert!(drops::claimed_of(&d, BOB) == 0, 6);
        assert!(drops::pot(&d) == 2_000, 7);
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENothingToClaim)]
fun claim_twice_at_the_same_time_pays_once() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 10 * DAY_MS);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 10 * DAY_MS);
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENothingToClaim)]
fun claim_before_cliff_gives_nothing() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 9 * DAY_MS);
    sc.end();
}

#[test, expected_failure(abort_code = drops::EBadProof)]
fun claim_with_someone_elses_proof_fails() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    // Eve presenta la prova di Alice.
    claim_as(&mut sc, EVE, 1_000, vector[lb, lc], T0 + 10 * DAY_MS);
    sc.end();
}

#[test, expected_failure(abort_code = drops::EBadProof)]
fun claim_with_inflated_allocation_fails() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    claim_as(&mut sc, ALICE, 5_000, vector[lb, lc], T0 + 10 * DAY_MS);
    sc.end();
}

// ── Surplus ─────────────────────────────────────────────────────────────

#[test]
fun surplus_is_only_what_exceeds_the_promise() {
    let mut sc = setup();
    let (root, ab, _, lb, lc) = tree();
    // Deposita 6500 contro 6000 dichiarati.
    create_drop(&mut sc, 6_500, 6_000, root, FEE);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 10 * DAY_MS); // 250 pagati

    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        // pot 6250, outstanding 5750: surplus 500, cioè esattamente il margine.
        assert!(c.value() == 500, 0);
        transfer::public_transfer(c, CREATOR);
        assert!(drops::pot(&d) == 5_750, 1);
        ts::return_shared(d);
    };
    // Bob e Carol trovano ancora tutto il loro.
    let v = claim_as(&mut sc, CAROL, 3_000, vector[ab], T0 + 500 * DAY_MS);
    assert!(v == 3_000, 2);
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENoSurplus)]
fun surplus_cannot_touch_the_promise() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        transfer::public_transfer(c, CREATOR);
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENotCreator)]
fun surplus_is_the_creators_only() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 7_000, 6_000, root, FEE);
    sc.next_tx(EVE);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        transfer::public_transfer(c, EVE);
        ts::return_shared(d);
    };
    sc.end();
}

// ── Tesoreria ───────────────────────────────────────────────────────────

#[test]
fun fee_can_be_updated_by_admin() {
    let mut sc = setup();
    sc.next_tx(ADMIN);
    {
        let cap = sc.take_from_sender<AdminCap>();
        let mut tr = sc.take_shared<Treasury>();
        drops::update_fee(&cap, &mut tr, 1);
        assert!(drops::fee(&tr) == 1, 0);
        sc.return_to_sender(cap);
        ts::return_shared(tr);
    };
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, 1);
    sc.end();
}

// ── Scadenza e ricarica ─────────────────────────────────────────────────

#[test]
fun deadline_lets_the_creator_reclaim_only_after_it() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    let deadline = T0 + 400 * DAY_MS;
    create_drop_with_deadline(&mut sc, 6_000, 6_000, root, FEE, deadline);
    // Alice ritira tutto il suo prima della scadenza.
    let v = claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 200 * DAY_MS);
    assert!(v == 1_000, 0);
    // Il giorno della scadenza il creatore riprende il residuo (5000).
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = clk(deadline, &mut sc);
        let coin = drops::reclaim_expired(&mut d, &c, sc.ctx());
        assert!(coin.value() == 5_000, 1);
        transfer::public_transfer(coin, CREATOR);
        assert!(drops::pot(&d) == 0, 2);
        c.destroy_for_testing();
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::EExpired)]
fun claim_after_deadline_fails() {
    let mut sc = setup();
    let (root, _, _, lb, lc) = tree();
    let deadline = T0 + 400 * DAY_MS;
    create_drop_with_deadline(&mut sc, 6_000, 6_000, root, FEE, deadline);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], deadline);
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENotExpired)]
fun reclaim_before_deadline_fails() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop_with_deadline(&mut sc, 6_000, 6_000, root, FEE, T0 + 400 * DAY_MS);
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = clk(T0 + 399 * DAY_MS, &mut sc);
        let coin = drops::reclaim_expired(&mut d, &c, sc.ctx());
        transfer::public_transfer(coin, CREATOR);
        c.destroy_for_testing();
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENotExpired)]
fun reclaim_without_deadline_never_exists() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_000, 6_000, root, FEE);
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = clk(T0 + 10_000 * DAY_MS, &mut sc);
        let coin = drops::reclaim_expired(&mut d, &c, sc.ctx());
        transfer::public_transfer(coin, CREATOR);
        c.destroy_for_testing();
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::EInvalidTimestamps)]
fun deadline_before_the_end_of_the_schedule_is_rejected() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    // Lo schedule finisce a T0 + 110 giorni: una scadenza uguale non basta,
    // l'ultima quota matura esattamente in quel millisecondo.
    create_drop_with_deadline(&mut sc, 6_000, 6_000, root, FEE, T0 + 110 * DAY_MS);
    sc.end();
}

#[test]
fun top_up_rescues_an_underdeclared_drop_without_raising_the_surplus() {
    let mut sc = setup();
    let (root, ab, _, lb, lc) = tree();
    // Lista da 6000, dichiarati e depositati 4000: nato sottofinanziato.
    create_drop(&mut sc, 4_000, 4_000, root, FEE);
    // Carol (3000) e Alice (1000) prendono tutto: pot a zero.
    claim_as(&mut sc, CAROL, 3_000, vector[ab], T0 + 500 * DAY_MS);
    claim_as(&mut sc, ALICE, 1_000, vector[lb, lc], T0 + 500 * DAY_MS);
    // Bob troverebbe il vuoto. Qualcuno ricarica 2000.
    sc.next_tx(EVE);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        drops::top_up(&mut d, coin::mint_for_testing<TOKEN>(2_000, sc.ctx()), sc.ctx());
        assert!(drops::pot(&d) == 2_000, 0);
        ts::return_shared(d);
    };
    let la = drops::leaf_hash(SALT, ALICE, 1_000);
    let v = claim_as(&mut sc, BOB, 2_000, vector[la, lc], T0 + 500 * DAY_MS);
    assert!(v == 2_000, 1);
    // E il creatore non può chiamare surplus quello che è entrato col top up.
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        drops::top_up(&mut d, coin::mint_for_testing<TOKEN>(100, sc.ctx()), sc.ctx());
        ts::return_shared(d);
    };
    sc.next_tx(CREATOR);
    {
        let d = sc.take_shared<Drop<TOKEN>>();
        // deposited 4000 - declared 4000 = 0 di margine: ENoSurplus, anche con 100 nel pot.
        assert!(drops::deposited(&d) == 4_000, 2);
        assert!(drops::pot(&d) == 100, 3);
        ts::return_shared(d);
    };
    sc.end();
}

#[test]
fun surplus_is_measured_on_deposits_not_on_claims() {
    let mut sc = setup();
    let (root, ab, _, _, _) = tree();
    // Lista da 6000 ma dichiarati 3000, depositati 3500: margine 500.
    create_drop(&mut sc, 3_500, 3_000, root, FEE);
    // Carol prende 3000: paid supera... no, paid == declared. Ora surplus = 500.
    claim_as(&mut sc, CAROL, 3_000, vector[ab], T0 + 500 * DAY_MS);
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        assert!(c.value() == 500, 0);
        transfer::public_transfer(c, CREATOR);
        ts::return_shared(d);
    };
    // Un secondo giro non dà niente: il margine è stato preso una volta.
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        drops::top_up(&mut d, coin::mint_for_testing<TOKEN>(1_000, sc.ctx()), sc.ctx());
        ts::return_shared(d);
    };
    sc.end();
}

#[test, expected_failure(abort_code = drops::ENoSurplus)]
fun surplus_cannot_be_taken_twice() {
    let mut sc = setup();
    let (root, _, _, _, _) = tree();
    create_drop(&mut sc, 6_500, 6_000, root, FEE);
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        transfer::public_transfer(c, CREATOR);
        ts::return_shared(d);
    };
    sc.next_tx(CREATOR);
    {
        let mut d = sc.take_shared<Drop<TOKEN>>();
        drops::top_up(&mut d, coin::mint_for_testing<TOKEN>(1_000, sc.ctx()), sc.ctx());
        let c = drops::withdraw_surplus(&mut d, sc.ctx());
        transfer::public_transfer(c, CREATOR);
        ts::return_shared(d);
    };
    sc.end();
}
