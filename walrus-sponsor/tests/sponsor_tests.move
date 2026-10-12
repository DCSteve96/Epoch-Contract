#[test_only, allow(implicit_const_copy)]
module epoch_walrus_sponsor::sponsor_tests;

use epoch_walrus_sponsor::sponsor::{Self, Treasury, AdminCap};
use sui::coin;
use sui::ed25519;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const USER: address = @0xCAFE;
const PUBKEY: vector<u8> = x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
const BLOB_ID: u256 = 73770302483225222888095022013499065808665894649364078610166851921135550754414;
const NOW: u64 = 1_790_000_000_000;
const EP: u32 = 35;       // epoca Walrus del voucher
const END: u32 = 87;      // EP + 52
const WAL: u64 = 1_000_000_000;
// Prezzi reali del 30 set 2026 (epoca 40): 0,225 WAL fino a ~0,1 MiB, 0,383 a 10 MiB.
const BASE: u64 = 250_000_000;    // 0,25 WAL
const PER_MIB: u64 = 20_000_000;  // 0,02 WAL per MiB

fun new_treasury(sc: &mut Scenario, max: u64, day: u64, balance: u64) {
    let cap = sponsor::create(PUBKEY, max, day, BASE, PER_MIB, 52, sc.ctx());
    transfer::public_transfer(cap, ADMIN);
    sc.next_tx(ADMIN);
    let mut t = sc.take_shared<Treasury>();
    sponsor::deposit(&mut t, sponsor::mint_wal_for_testing(balance, sc.ctx()));
    ts::return_shared(t);
    sc.next_tx(USER);
}

fun setup(balance: u64): Scenario {
    let mut sc = ts::begin(ADMIN);
    new_treasury(&mut sc, 500_000_000, 500 * WAL, balance);
    sc
}

/// Un prestito normale da 0,23 WAL, chiuso con un Blob nuovo.
fun lend_and_settle(t: &mut Treasury, nonce: u64, blob: address, sc: &mut Scenario) {
    let (c, loan) = sponsor::borrow_for_testing(t, BLOB_ID, 2457, EP, 230_000_000, nonce, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(t, loan, object::id_from_address(blob), BLOB_ID, 2457, false, false, EP, END, c, sc.ctx());
}

/// Il vettore viene da epoch-walrus/src/sponsorVoucher.ts (seed 32 x 0x07):
/// stessi input, stessi byte, e la firma TypeScript verifica in Move.
#[test]
fun voucher_matches_typescript() {
    let msg = sponsor::voucher_message(
        object::id_from_address(@0xAB), @0xCAFE, BLOB_ID, 2457, EP, 230_000_000, 42, 1_790_000_000_000,
    );
    let expected = x"65706f63682d77616c7275732d73706f6e736f722f766f75636865722f763200000000000000000000000000000000000000000000000000000000000000ab000000000000000000000000000000000000000000000000000000000000cafe6e6e3e8716ff53918cda0f92309b173c24ed62633ea957853f4ca816f58218a39909000000000000230000008085b50d000000002a00000000000000006c50c4a0010000";
    assert!(msg == expected, 0);
    let sig = x"4fc475ac607e1edacb0513eb9267f055c162a0609566a7d66dcff98e3b837495b08fb839ddfad2280742b02f20bf1166cfc8d4efc9bc8519edcb1607ddde0c00";
    assert!(ed25519::ed25519_verify(&sig, &PUBKEY, &msg), 1);
    // Un solo campo diverso e la firma non vale più: importo, utente, epoca.
    let other = sponsor::voucher_message(object::id_from_address(@0xAB), @0xCAFE, BLOB_ID, 2457, EP, 230_000_001, 42, 1_790_000_000_000);
    assert!(!ed25519::ed25519_verify(&sig, &PUBKEY, &other), 2);
    let other_user = sponsor::voucher_message(object::id_from_address(@0xAB), @0xBEEF, BLOB_ID, 2457, EP, 230_000_000, 42, 1_790_000_000_000);
    assert!(!ed25519::ed25519_verify(&sig, &PUBKEY, &other_user), 3);
    let other_epoch = sponsor::voucher_message(object::id_from_address(@0xAB), @0xCAFE, BLOB_ID, 2457, EP - 1, 230_000_000, 42, 1_790_000_000_000);
    assert!(!ed25519::ed25519_verify(&sig, &PUBKEY, &other_epoch), 4);
}

#[test]
fun happy_path_lend_and_settle() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (mut c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    assert!(c.value() == 230_000_000, 0);
    // Il PTB spende 225 milioni su Walrus (simulato bruciandoli), ne restano 5.
    coin::burn_for_testing(c.split(225_278_928, sc.ctx()));
    let blob_obj = object::id_from_address(@0xB10B);
    sponsor::settle_for_testing(&mut t, loan, blob_obj, BLOB_ID, 2457, false, false, EP, END, c, sc.ctx());
    assert!(sponsor::balance_of(&t) == 10 * WAL - 225_278_928, 1);
    assert!(sponsor::nonce_used(&t, 1) && sponsor::blob_used(&t, blob_obj), 2);
    let (lent, returned, loans) = sponsor::totals(&t);
    assert!(lent == 230_000_000 && returned == 4_721_072 && loans == 1, 3);
    ts::return_shared(t);
    sc.end();
}

#[test]
fun epoch_change_between_voucher_and_execution_is_fine() {
    // Voucher firmato all'epoca 35, blob registrato alla 36 per 52 epoche.
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, false, EP + 1, END + 1, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

// === Gli attacchi dell'audit del 30 set 2026: ora falliscono ===

/// Audit #3/#4: prestito preso, Blob VECCHIO dello stesso contenuto esteso di
/// poche epoche (costa poco), resto zero, WAL in tasca. Ora: EOldBlob.
#[test, expected_failure(abort_code = sponsor::EOldBlob)]
fun attack_old_blob_extended_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (loot, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    transfer::public_transfer(loot, USER);
    // Registrato all'epoca 10, esteso fino alla 100, mai certificato.
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, false, 10, 100, coin::zero(sc.ctx()), sc.ctx());
    ts::return_shared(t);
    sc.end();
}

/// Audit #4: un Blob già certificato (di un altro o proprio) non chiude prestiti.
#[test, expected_failure(abort_code = sponsor::ECertified)]
fun attack_certified_blob_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (loot, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    transfer::public_transfer(loot, USER);
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, true, EP, END, coin::zero(sc.ctx()), sc.ctx());
    ts::return_shared(t);
    sc.end();
}

/// Audit #2, chiave rubata: importo massimo per un blob minuscolo. Ora il
/// tetto di prezzo per dimensione lo ferma in `borrow`.
#[test, expected_failure(abort_code = sponsor::EAbovePrice)]
fun attack_leaked_key_overpriced_voucher_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 1, EP, 500_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 1, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

/// Audit #2, chiave rubata: blob da 1 epoca. Ora la durata la impone il
/// contratto (52 epoche dalla registrazione), non il voucher.
#[test, expected_failure(abort_code = sponsor::ETooShort)]
fun attack_leaked_key_one_epoch_blob_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 1, EP, 250_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 1, false, false, EP, EP + 1, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test]
fun price_ceiling_follows_size() {
    let sc = setup(10 * WAL);
    let t = sc.take_shared<Treasury>();
    assert!(sponsor::price_ceiling(&t, 1) == BASE + PER_MIB, 0);
    assert!(sponsor::price_ceiling(&t, 1_048_576) == BASE + PER_MIB, 1);
    assert!(sponsor::price_ceiling(&t, 1_048_577) == BASE + 2 * PER_MIB, 2);
    // 10 MiB: 0,45 WAL, sopra il prezzo reale di 0,383.
    assert!(sponsor::price_ceiling(&t, 10 * 1_048_576) == 450_000_000, 3);
    ts::return_shared(t);
    sc.end();
}

#[test]
fun a_loan_exactly_at_the_ceiling_passes() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, BASE + PER_MIB, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

// === Controlli di base ===

#[test, expected_failure(abort_code = sponsor::ENonceUsed)]
fun nonce_is_single_use() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    lend_and_settle(&mut t, 1, @0xB2, &mut sc);
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EBlobAlreadyUsed)]
fun a_blob_closes_one_loan_only() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB10B, &mut sc);
    lend_and_settle(&mut t, 2, @0xB10B, &mut sc);
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EDeletable)]
fun deletable_blob_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, true, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EWrongBlobId)]
fun other_blob_id_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID + 1, 2457, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EWrongSize)]
fun other_size_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2456, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::ETooShort)]
fun one_epoch_less_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW + 60_000, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, false, EP, END - 1, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EExpired)]
fun expired_voucher_is_refused() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 1, NOW - 1, NOW, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB1), BLOB_ID, 2457, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EAboveLoanCap)]
fun loan_cap_holds() {
    let mut sc = ts::begin(ADMIN);
    new_treasury(&mut sc, 200_000_000, 500 * WAL, 10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EAboveDayCap)]
fun day_cap_holds_until_the_window_rolls() {
    let mut sc = ts::begin(ADMIN);
    new_treasury(&mut sc, 500_000_000, 400_000_000, 10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    lend_and_settle(&mut t, 2, @0xB2, &mut sc); // 0,46 > 0,40
    ts::return_shared(t);
    sc.end();
}

#[test]
fun day_window_rolls_after_24_hours() {
    let mut sc = ts::begin(ADMIN);
    new_treasury(&mut sc, 500_000_000, 400_000_000, 10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    let later = NOW + 86_400_000;
    let (c, loan) = sponsor::borrow_for_testing(&mut t, BLOB_ID, 2457, EP, 230_000_000, 2, later + 60_000, later, sc.ctx());
    sponsor::settle_for_testing(&mut t, loan, object::id_from_address(@0xB2), BLOB_ID, 2457, false, false, EP, END, c, sc.ctx());
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EPaused)]
fun pause_stops_new_loans() {
    let mut sc = setup(10 * WAL);
    sc.next_tx(ADMIN);
    let cap = sc.take_from_sender<AdminCap>();
    let mut t = sc.take_shared<Treasury>();
    sponsor::set_config(&cap, &mut t, true, 500_000_000, 500 * WAL);
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    ts::return_shared(t);
    sc.return_to_sender(cap);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EInsufficientTreasury)]
fun empty_treasury_lends_nothing() {
    let mut sc = setup(100);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EWrongCap)]
fun a_cap_manages_its_own_treasury_only() {
    let mut sc = setup(10 * WAL);
    sc.next_tx(ADMIN);
    let other = sponsor::create(PUBKEY, 1, 1, 1, 1, 1, sc.ctx());
    let mut t = sc.take_shared<Treasury>();
    let c = sponsor::withdraw(&other, &mut t, 1, sc.ctx());
    coin::burn_for_testing(c);
    ts::return_shared(t);
    transfer::public_transfer(other, ADMIN);
    sc.end();
}

#[test]
fun admin_withdraws_rotates_and_reprices() {
    let mut sc = setup(10 * WAL);
    sc.next_tx(ADMIN);
    let cap = sc.take_from_sender<AdminCap>();
    let mut t = sc.take_shared<Treasury>();
    let c = sponsor::withdraw(&cap, &mut t, 4 * WAL, sc.ctx());
    assert!(c.value() == 4 * WAL && sponsor::balance_of(&t) == 6 * WAL, 0);
    coin::burn_for_testing(c);
    sponsor::rotate_signer(&cap, &mut t, x"0000000000000000000000000000000000000000000000000000000000000001");
    sponsor::set_pricing(&cap, &mut t, 300_000_000, 30_000_000, 60);
    let (b, m, e) = sponsor::pricing(&t);
    assert!(b == 300_000_000 && m == 30_000_000 && e == 60, 1);
    ts::return_shared(t);
    sc.return_to_sender(cap);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EBadConfig)]
fun pricing_cannot_be_zeroed() {
    let mut sc = setup(10 * WAL);
    sc.next_tx(ADMIN);
    let cap = sc.take_from_sender<AdminCap>();
    let mut t = sc.take_shared<Treasury>();
    sponsor::set_pricing(&cap, &mut t, 300_000_000, 30_000_000, 0);
    ts::return_shared(t);
    sc.return_to_sender(cap);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EWrongVersion)]
fun migrate_on_current_version_aborts() {
    let mut sc = setup(10 * WAL);
    sc.next_tx(ADMIN);
    let cap = sc.take_from_sender<AdminCap>();
    let mut t = sc.take_shared<Treasury>();
    sponsor::migrate(&cap, &mut t);
    ts::return_shared(t);
    sc.return_to_sender(cap);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::EBadPublicKey)]
fun public_key_must_be_32_bytes() {
    let mut sc = ts::begin(ADMIN);
    let cap = sponsor::create(x"01", 1, 1, 1, 1, 1, sc.ctx());
    transfer::public_transfer(cap, ADMIN);
    sc.end();
}

// === Pulizia dei nonce ===

#[test]
fun expired_nonces_can_be_pruned() {
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    assert!(sponsor::nonce_used(&t, 1), 0);
    // Un nonce mai usato (7) viene ignorato.
    sponsor::prune_for_testing(&mut t, vector[1, 7], NOW + 60_001);
    assert!(!sponsor::nonce_used(&t, 1), 1);
    ts::return_shared(t);
    sc.end();
}

#[test, expected_failure(abort_code = sponsor::ENotExpired)]
fun live_nonces_cannot_be_pruned() {
    // Altrimenti un voucher ancora valido tornerebbe riutilizzabile.
    let mut sc = setup(10 * WAL);
    let mut t = sc.take_shared<Treasury>();
    lend_and_settle(&mut t, 1, @0xB1, &mut sc);
    sponsor::prune_for_testing(&mut t, vector[1], NOW + 60_000);
    ts::return_shared(t);
    sc.end();
}
