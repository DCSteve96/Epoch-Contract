#[test_only]
module epoch_farm::farm_tests;

use epoch_farm::farm::{Self, Farm, AdminCap};
use sui::clock;
use sui::coin;
use sui::test_scenario as ts;

/// Moneta finta dei premi. Il modulo è generico apposta: qui non serve
/// dipendere dal package di EPT per provare la macchina.
public struct REWARD has drop {}

const ADMIN: address = @0xA1;
const ALICE: address = @0xB2;
const BOB:   address = @0xC3;

const DAY_MS: u64 = 86_400_000;

fun setup(): ts::Scenario {
    let mut sc = ts::begin(ADMIN);
    farm::init_for_testing(sc.ctx());
    sc.next_tx(ADMIN);
    {
        let cap = sc.take_from_sender<AdminCap>();
        farm::create<REWARD>(&cap, 1_000_000, sc.ctx());
        sc.return_to_sender(cap);
    };
    sc
}

fun fund_farm(sc: &mut ts::Scenario, amount: u64) {
    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = coin::mint_for_testing<REWARD>(amount, sc.ctx());
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS);
        farm::fund(&mut farm, c, &clk, sc.ctx());
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
}

/// Radice di un albero con una foglia sola: la foglia stessa.
fun single_root(sc: &mut ts::Scenario, who: address, cumulative: u64): vector<u8> {
    sc.next_tx(ADMIN);
    let farm = sc.take_shared<Farm<REWARD>>();
    let id = object::id_address(&farm);
    ts::return_shared(farm);
    farm::leaf_hash(id, who, cumulative)
}

fun publish_root(sc: &mut ts::Scenario, root: vector<u8>, declared: u64, at_ms: u64) {
    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let cap = sc.take_from_sender<AdminCap>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(at_ms);
        farm::set_root(&cap, &mut farm, root, declared, &clk);
        clk.destroy_for_testing();
        sc.return_to_sender(cap);
        ts::return_shared(farm);
    };
}

// ── Il giro normale ──────────────────────────────────────────────────────

#[test]
fun claim_pays_once() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        assert!(c.value() == 4_000, 0);
        assert!(farm::pot(&farm) == 6_000, 1);
        assert!(farm::paid_total(&farm) == 4_000, 2);
        assert!(farm::claimed_of(&farm, ALICE) == 4_000, 3);
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

#[test]
#[expected_failure(abort_code = epoch_farm::farm::ENothingToClaim)]
fun claim_twice_gives_nothing() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Il cumulativo è la ragione per cui saltare un giorno non fa perdere niente.
#[test]
fun second_root_pays_only_the_difference() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);

    let r1 = single_root(&mut sc, ALICE, 3_000);
    publish_root(&mut sc, r1, 3_000, DAY_MS);
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 3_000, vector[], sc.ctx());
        assert!(c.value() == 3_000, 0);
        c.burn_for_testing();
        ts::return_shared(farm);
    };

    let r2 = single_root(&mut sc, ALICE, 5_000);
    publish_root(&mut sc, r2, 5_000, 2 * DAY_MS);
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 5_000, vector[], sc.ctx());
        assert!(c.value() == 2_000, 1);
        assert!(farm::claimed_of(&farm, ALICE) == 5_000, 2);
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

// ── A-3: la radice non può promettere più di quello che c'è ───────────────

#[test]
#[expected_failure(abort_code = epoch_farm::farm::EPotTooSmall)]
fun root_cannot_promise_more_than_the_pot() {
    let mut sc = setup();
    fund_farm(&mut sc, 1_000);
    let root = single_root(&mut sc, ALICE, 5_000);
    publish_root(&mut sc, root, 5_000, DAY_MS);
    sc.end();
}

#[test]
#[expected_failure(abort_code = epoch_farm::farm::EBadRoot)]
fun declared_total_cannot_go_below_what_was_paid() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let r1 = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, r1, 4_000, DAY_MS);
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    // Radice nuova che dichiara meno di quanto è già uscito: errore di calcolo,
    // si ferma qui.
    let r2 = single_root(&mut sc, ALICE, 1_000);
    publish_root(&mut sc, r2, 1_000, 2 * DAY_MS);
    sc.end();
}

// ── A-4: il tetto rallenta, non chiude fuori ─────────────────────────────

#[test]
fun cap_splits_a_big_claim_in_two() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let cap = sc.take_from_sender<AdminCap>();
        farm::set_max_per_claim(&cap, &mut farm, 1_000);
        sc.return_to_sender(cap);
        ts::return_shared(farm);
    };
    let root = single_root(&mut sc, ALICE, 2_500);
    publish_root(&mut sc, root, 2_500, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let a = farm::claim(&mut farm, 2_500, vector[], sc.ctx());
        assert!(a.value() == 1_000, 0);
        let b = farm::claim(&mut farm, 2_500, vector[], sc.ctx());
        assert!(b.value() == 1_000, 1);
        let c = farm::claim(&mut farm, 2_500, vector[], sc.ctx());
        assert!(c.value() == 500, 2);
        assert!(farm::claimed_of(&farm, ALICE) == 2_500, 3);
        a.burn_for_testing();
        b.burn_for_testing();
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

// ── A-10: le prove ───────────────────────────────────────────────────────

/// Albero vero a due foglie: Alice porta la foglia di Bob come fratello.
#[test]
fun two_leaf_proof_works() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);

    sc.next_tx(ADMIN);
    let farm_id = {
        let farm = sc.take_shared<Farm<REWARD>>();
        let id = object::id_address(&farm);
        ts::return_shared(farm);
        id
    };
    let leaf_a = farm::leaf_hash(farm_id, ALICE, 1_500);
    let leaf_b = farm::leaf_hash(farm_id, BOB, 2_500);
    let root = farm::node_hash_for_testing(&leaf_a, &leaf_b);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 1_500, vector[leaf_b], sc.ctx());
        assert!(c.value() == 1_500, 0);
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 2_500, vector[leaf_a], sc.ctx());
        assert!(c.value() == 2_500, 1);
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// La foglia di Alice non paga Bob: l'indirizzo è dentro l'hash.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::EBadProof)]
fun another_address_cannot_use_your_leaf() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Un importo più alto di quello dichiarato non passa: il numero è dentro
/// l'hash, non è un parametro libero.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::EBadProof)]
fun cannot_inflate_the_amount() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 9_999, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Un elemento della prova di lunghezza sbagliata è un errore di prova, non
/// una lettura fuori dai byte.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::EBadProof)]
fun short_proof_element_is_rejected() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[vector[1u8, 2u8, 3u8]], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

// ── A-13: la pausa ferma i ritiri ────────────────────────────────────────

#[test]
#[expected_failure(abort_code = epoch_farm::farm::EPaused)]
fun paused_stops_claims() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 4_000);
    publish_root(&mut sc, root, 4_000, DAY_MS);

    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let cap = sc.take_from_sender<AdminCap>();
        farm::set_paused(&cap, &mut farm, true);
        sc.return_to_sender(cap);
        ts::return_shared(farm);
    };
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 4_000, vector[], sc.ctx());
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

// ── Il residuo ───────────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = epoch_farm::farm::ETooEarlyToBurn)]
fun leftover_cannot_be_burned_early() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 1_000);
    publish_root(&mut sc, root, 1_000, DAY_MS);

    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS + 30 * DAY_MS);
        farm::burn_leftover(&mut farm, &clk, sc.ctx());
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// C-2: dopo sei mesi di silenzio il residuo lo brucia chiunque, **ma quello
/// già promesso resta**. Prima della correzione un estraneo poteva portare via
/// il credito di chi era stato via sette mesi, e lasciare la farm insolvente
/// verso la sua stessa radice.
#[test]
fun burn_leaves_what_was_promised() {
    let mut sc = setup();
    fund_farm(&mut sc, 10_000);
    let root = single_root(&mut sc, ALICE, 1_000);
    publish_root(&mut sc, root, 1_000, DAY_MS);

    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS + 181 * DAY_MS);
        farm::burn_leftover(&mut farm, &clk, sc.ctx());
        // Bruciati 9.000, resta in cassa esattamente quello che Alice deve
        // ancora ritirare.
        assert!(farm::pot(&farm) == 1_000, 0);
        assert!(farm::outstanding(&farm) == 1_000, 1);
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    // E Alice lo ritira lo stesso, dopo il burn.
    sc.next_tx(ALICE);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = farm::claim(&mut farm, 1_000, vector[], sc.ctx());
        assert!(c.value() == 1_000, 2);
        assert!(farm::pot(&farm) == 0, 3);
        c.burn_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Se il serbatoio è tutto promesso non c'è niente da bruciare, e la chiamata
/// si ferma invece di svuotare la cassa.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::EZeroAmount)]
fun nothing_to_burn_when_all_is_promised() {
    let mut sc = setup();
    fund_farm(&mut sc, 1_000);
    let root = single_root(&mut sc, ALICE, 1_000);
    publish_root(&mut sc, root, 1_000, DAY_MS);

    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS + 181 * DAY_MS);
        farm::burn_leftover(&mut farm, &clk, sc.ctx());
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// C-1: un tetto a zero sarebbe una pausa silenziosa. Per fermare i ritiri c'è
/// `set_paused`, che emette un evento.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::EZeroAmount)]
fun max_per_claim_cannot_be_zero() {
    let mut sc = setup();
    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let cap = sc.take_from_sender<AdminCap>();
        farm::set_max_per_claim(&cap, &mut farm, 0);
        sc.return_to_sender(cap);
        ts::return_shared(farm);
    };
    sc.end();
}

// ── Il serbatoio ─────────────────────────────────────────────────────────

/// Chiunque può ricaricare: è una proprietà, non una svista.
#[test]
fun anyone_can_fund() {
    let mut sc = setup();
    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = coin::mint_for_testing<REWARD>(777, sc.ctx());
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS);
        farm::fund(&mut farm, c, &clk, sc.ctx());
        assert!(farm::pot(&farm) == 777, 0);
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// B-1: serbatoio caricato e programma mai partito. Prima della correzione i
/// sei mesi si contavano dall'ultima radice, che qui non esiste, quindi quei
/// premi restavano chiusi per sempre senza nessuna funzione per tirarli fuori.
#[test]
fun leftover_burns_even_if_no_root_was_ever_published() {
    let mut sc = setup();
    fund_farm(&mut sc, 5_000);

    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(DAY_MS + 181 * DAY_MS);
        farm::burn_leftover(&mut farm, &clk, sc.ctx());
        assert!(farm::pot(&farm) == 0, 0);
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Una ricarica è un segno di vita: rimanda l'orologio del residuo.
#[test]
#[expected_failure(abort_code = epoch_farm::farm::ETooEarlyToBurn)]
fun funding_pushes_the_burn_clock_forward() {
    let mut sc = setup();
    fund_farm(&mut sc, 1_000);
    let root = single_root(&mut sc, ALICE, 500);
    publish_root(&mut sc, root, 500, DAY_MS);

    // Ricarica al giorno 100: da lì ripartono i sei mesi.
    sc.next_tx(ADMIN);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let c = coin::mint_for_testing<REWARD>(1_000, sc.ctx());
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(100 * DAY_MS);
        farm::fund(&mut farm, c, &clk, sc.ctx());
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    // Giorno 200: sono passati sei mesi dalla radice, ma solo cento giorni
    // dalla ricarica. Non si brucia.
    sc.next_tx(BOB);
    {
        let mut farm = sc.take_shared<Farm<REWARD>>();
        let mut clk = clock::create_for_testing(sc.ctx());
        clk.set_for_testing(200 * DAY_MS);
        farm::burn_leftover(&mut farm, &clk, sc.ctx());
        clk.destroy_for_testing();
        ts::return_shared(farm);
    };
    sc.end();
}

/// Gli stessi hash del frontend, inchiodati.
///
/// I vettori qui sotto li ha calcolati `vesting-frontend/src/utils/farmMerkle.ts`
/// (blake2b256 di @noble/hashes). Se questo test si rompe vuol dire che le due
/// implementazioni hanno smesso di combaciare, cioè che la pagina Farm
/// costruisce prove che la catena rifiuta: un guasto che in produzione si
/// vedrebbe solo come "ho premuto Collect e la transazione aborta".
#[test]
fun same_hashes_as_the_frontend() {
    let farm_id = @0x1111111111111111111111111111111111111111111111111111111111111111;

    let leaf_a = farm::leaf_hash(farm_id, @0xA1, 1_000);
    let leaf_b = farm::leaf_hash(farm_id, @0xB2, 2_000);
    let leaf_c = farm::leaf_hash(farm_id, @0xC3, 3_000);
    assert!(leaf_a == x"69623ab5632cda15083b57e1a85dc53a8de51da848cdcc1a021315d4d0abcd2c", 0);
    assert!(leaf_b == x"fe19a0e6ecbe8b58efd14dc09980f120958eaf28bde182801be053b91184b72b", 1);

    let node_ab = farm::node_hash_for_testing(&leaf_a, &leaf_b);
    assert!(node_ab == x"91f255d1f10585bd09e6f794c47295c54d00caaee9bcb30426b3ce48d429cd21", 2);

    // Tre foglie: il nodo dispari sale intero (regola C-3 dell'audit).
    let root = farm::node_hash_for_testing(&node_ab, &leaf_c);
    assert!(root == x"a5f68eea5ba01a5dd2d4e010edbf4e2017e0fdf45dcbf523df5ce84006a61bbf", 3);

    // Le due prove che il frontend consegna per quella radice.
    assert!(farm::verify(&root, &vector[leaf_b, leaf_c], farm_id, @0xA1, 1_000), 4);
    assert!(farm::verify(&root, &vector[node_ab], farm_id, @0xC3, 3_000), 5);

    // E la strada che NON si prende: duplicare la foglia dispari (`H(X, X)`)
    // dà una radice diversa, quindi le due regole non sono intercambiabili.
    let twin = farm::node_hash_for_testing(&leaf_c, &leaf_c);
    assert!(farm::node_hash_for_testing(&node_ab, &twin) != root, 6);
}
