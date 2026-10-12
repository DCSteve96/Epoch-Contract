/// Test del negozio dei template.
///
/// Cosa NON si prova qui e perché: `swap_and_burn` chiama Cetus, e la copia
/// locale di quell'interfaccia ha i corpi che fanno `abort 0`. Simularla
/// vorrebbe dire scrivere una finta pool, cioè provare il nostro finto invece
/// del loro vero. Quel pezzo si prova on chain, e fino ad allora vale quello
/// che si può dimostrare qui: **la cassa del burn non ha nessun'altra uscita**.
#[test_only]
module epoch_templates::templates_tests;

use std::string;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario as ts;
use epoch_templates::templates::{Self as tpl, Registry, AdminCap, Template, AuthorCap, License};

const ADMIN:  address = @0xA;
const AUTHOR: address = @0xB;
const BUYER:  address = @0xC;
const RANDOM: address = @0xD;

const SUI_1: u64 = 1_000_000_000;

/// 64 caratteri, come uno sha256 in esadecimale: il contratto pretende quella
/// lunghezza esatta.
fun dig(): string::String {
    string::utf8(b"aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111")
}
fun other_dig(): string::String {
    string::utf8(b"99999999bbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111")
}

fun setup(): ts::Scenario {
    let mut s = ts::begin(ADMIN);
    tpl::init_for_testing(ts::ctx(&mut s));
    s
}

/// Mette in vendita e restituisce l'id dell'oggetto Template, che serve a
/// prenderlo con `take_shared_by_id` quando in giro ce n'è più di uno.
fun list_as(s: &mut ts::Scenario, who: address, name: vector<u8>, price: u64): ID {
    ts::next_tx(s, who);
    let reg = ts::take_shared<Registry>(s);
    let cap = tpl::list_template(&reg, string::utf8(name), dig(), price, ts::ctx(s));
    let id = tpl::author_cap_template(&cap);
    transfer::public_transfer(cap, who);
    ts::return_shared(reg);
    id
}

/// `max_price` alto di proposito: qui si vuole provare il resto della funzione,
/// e il tetto del compratore ha un test suo.
fun buy_with(s: &mut ts::Scenario, who: address, t_id: ID, amount: u64) {
    buy_full(s, who, t_id, amount, 1_000_000 * SUI_1, dig())
}

fun buy_full(
    s: &mut ts::Scenario,
    who: address,
    t_id: ID,
    amount: u64,
    max_price: u64,
    digest: string::String,
) {
    ts::next_tx(s, who);
    let mut reg = ts::take_shared<Registry>(s);
    let mut t   = ts::take_shared_by_id<Template>(s, t_id);
    let c   = coin::mint_for_testing<SUI>(amount, ts::ctx(s));
    let clk = clock::create_for_testing(ts::ctx(s));
    tpl::buy_template(&mut reg, &mut t, c, max_price, digest, &clk, ts::ctx(s));
    clock::destroy_for_testing(clk);
    ts::return_shared(reg);
    ts::return_shared(t);
}

/* ── Recensioni ─────────────────────────────────────────────────────────
   La cosa che vale la pena inchiodare con un test non è il caso che funziona,
   è il tetto: il testo finisce dentro un evento, e senza un limite uno ci
   scrive un libro a spese di chiunque lo indicizzi. Che "solo chi ha comprato
   può recensire" non si prova qui perché non è codice nostro: `add_review`
   vuole una `License`, e una PTB può passare un oggetto posseduto solo se chi
   firma ne è il proprietario. ── */

#[test]
fun la_recensione_la_scrive_chi_ha_la_licenza() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);

    ts::next_tx(&mut s, BUYER);
    {
        let lic = ts::take_from_address<License>(&s, BUYER);
        let clk = clock::create_for_testing(ts::ctx(&mut s));
        tpl::add_review(&lic, 5, string::utf8(b"fa quello che dice"), &clk, ts::ctx(&mut s));
        clock::destroy_for_testing(clk);
        ts::return_to_address(BUYER, lic);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EBadStars)]
fun niente_voti_fuori_scala() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);

    ts::next_tx(&mut s, BUYER);
    {
        let lic = ts::take_from_address<License>(&s, BUYER);
        let clk = clock::create_for_testing(ts::ctx(&mut s));
        tpl::add_review(&lic, 6, string::utf8(b"sei"), &clk, ts::ctx(&mut s));
        clock::destroy_for_testing(clk);
        ts::return_to_address(BUYER, lic);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::ETooLong)]
fun niente_recensioni_chilometriche() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);

    ts::next_tx(&mut s, BUYER);
    {
        let lic = ts::take_from_address<License>(&s, BUYER);
        let clk = clock::create_for_testing(ts::ctx(&mut s));
        let mut long = string::utf8(b"");
        let mut i = 0u64;
        while (i < 61) { long.append(string::utf8(b"0123456789")); i = i + 1; };  // 610 caratteri
        tpl::add_review(&lic, 5, long, &clk, ts::ctx(&mut s));
        clock::destroy_for_testing(clk);
        ts::return_to_address(BUYER, lic);
    };
    ts::end(s);
}

#[test]
fun vendita_divide_esattamente() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 100 * SUI_1);
    buy_with(&mut s, BUYER, id, 100 * SUI_1);

    ts::next_tx(&mut s, ADMIN);
    {
        let reg = ts::take_shared<Registry>(&s);
        // 3% di fee, metà al burn: 1,5 e 1,5 su 100.
        assert!(tpl::revenue_value(&reg)  == 15 * SUI_1 / 10, 0);
        assert!(tpl::burn_pot_value(&reg) == 15 * SUI_1 / 10, 1);
        assert!(tpl::total_volume(&reg)   == 100 * SUI_1, 2);
        assert!(tpl::total_sold(&reg)     == 1, 3);
        ts::return_shared(reg);
    };
    ts::next_tx(&mut s, AUTHOR);
    {
        let paid = ts::take_from_address<Coin<SUI>>(&s, AUTHOR);
        assert!(coin::value(&paid) == 97 * SUI_1, 4);
        ts::return_to_address(AUTHOR, paid);
    };
    ts::next_tx(&mut s, BUYER);
    {
        let lic = ts::take_from_address<License>(&s, BUYER);
        assert!(tpl::license_paid(&lic)  == 100 * SUI_1, 5);
        assert!(tpl::license_buyer(&lic) == BUYER, 6);
        assert!(tpl::license_template_id(&lic) == string::utf8(b"uno"), 7);
        assert!(tpl::license_template(&lic) == id, 8);
        ts::return_to_address(BUYER, lic);
    };
    ts::end(s);
}

#[test]
fun il_resto_torna_al_compratore() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 25 * SUI_1);
    ts::next_tx(&mut s, BUYER);
    {
        let change = ts::take_from_address<Coin<SUI>>(&s, BUYER);
        assert!(coin::value(&change) == 15 * SUI_1, 0);
        ts::return_to_address(BUYER, change);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EInsufficientPay)]
fun non_si_compra_a_meta_prezzo() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 9 * SUI_1);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::ENotForSale)]
fun fuori_mercato_non_si_compra() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    ts::next_tx(&mut s, AUTHOR);
    {
        let cap = ts::take_from_address<AuthorCap>(&s, AUTHOR);
        let mut t = ts::take_shared_by_id<Template>(&s, id);
        tpl::set_price(&cap, &mut t, 10 * SUI_1, false);
        assert!(!tpl::is_for_sale(&t), 0);
        ts::return_to_address(AUTHOR, cap);
        ts::return_shared(t);
    };
    buy_with(&mut s, BUYER, id, 10 * SUI_1);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EAuthorCannotBuy)]
fun lautore_non_compra_se_stesso() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, AUTHOR, id, 10 * SUI_1);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::ENotAuthor)]
fun il_prezzo_lo_cambia_solo_chi_ha_la_cap() {
    let mut s = setup();
    let primo = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    list_as(&mut s, RANDOM, b"due", SUI_1);
    ts::next_tx(&mut s, RANDOM);
    {
        let cap_altrui = ts::take_from_address<AuthorCap>(&s, RANDOM);
        let mut t = ts::take_shared_by_id<Template>(&s, primo);
        tpl::set_price(&cap_altrui, &mut t, SUI_1, true);   // cap sbagliata: aborta
        ts::return_to_address(RANDOM, cap_altrui);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EPriceMoved)]
fun il_prezzo_alzato_in_volo_non_passa() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    // L'autore raddoppia mentre il compratore ha già in mano la transazione.
    ts::next_tx(&mut s, AUTHOR);
    {
        let cap = ts::take_from_address<AuthorCap>(&s, AUTHOR);
        let mut t = ts::take_shared_by_id<Template>(&s, id);
        tpl::set_price(&cap, &mut t, 20 * SUI_1, true);
        ts::return_to_address(AUTHOR, cap);
        ts::return_shared(t);
    };
    // Il compratore aveva visto 10 e ha firmato per 10: qui si ferma tutto.
    buy_full(&mut s, BUYER, id, 20 * SUI_1, 10 * SUI_1, dig());
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EWrongDigest)]
fun il_pacchetto_sbagliato_non_si_compra() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    // Il compratore ha ispezionato un altro pacchetto: non è quello che sta
    // comprando, quindi non si compra.
    buy_full(&mut s, BUYER, id, 10 * SUI_1, 10 * SUI_1, other_dig());
    ts::end(s);
}

#[test]
fun lincasso_segue_la_cap() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    // L'autore vende il template: passa la cap e sposta il beneficiario.
    ts::next_tx(&mut s, AUTHOR);
    {
        let cap = ts::take_from_address<AuthorCap>(&s, AUTHOR);
        let mut t = ts::take_shared_by_id<Template>(&s, id);
        tpl::set_author(&cap, &mut t, RANDOM);
        assert!(tpl::author(&t) == RANDOM, 0);
        transfer::public_transfer(cap, RANDOM);
        ts::return_shared(t);
    };
    buy_with(&mut s, BUYER, id, 10 * SUI_1);
    ts::next_tx(&mut s, RANDOM);
    {
        // Il 97% va al nuovo proprietario, non a chi l'ha pubblicato.
        let paid = ts::take_from_address<Coin<SUI>>(&s, RANDOM);
        assert!(coin::value(&paid) == 97 * SUI_1 / 10, 1);
        ts::return_to_address(RANDOM, paid);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EFeeTooHigh)]
fun la_fee_non_si_alza_sopra_il_tetto() {
    let mut s = setup();
    ts::next_tx(&mut s, ADMIN);
    {
        let cap = ts::take_from_address<AdminCap>(&s, ADMIN);
        let mut reg = ts::take_shared<Registry>(&s);
        tpl::set_fee(&cap, &mut reg, 301);
        ts::return_to_address(ADMIN, cap);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
fun la_fee_puo_scendere_e_il_conto_la_segue() {
    let mut s = setup();
    ts::next_tx(&mut s, ADMIN);
    {
        let cap = ts::take_from_address<AdminCap>(&s, ADMIN);
        let mut reg = ts::take_shared<Registry>(&s);
        assert!(tpl::fee_bps(&reg) == tpl::fee_bps_max(), 0);
        tpl::set_fee(&cap, &mut reg, 100);               // 1%
        let (author, protocol, burn) = tpl::quote(&reg, 100 * SUI_1);
        assert!(author   == 99 * SUI_1, 1);
        assert!(protocol == 5 * SUI_1 / 10, 2);
        assert!(burn     == 5 * SUI_1 / 10, 3);
        ts::return_to_address(ADMIN, cap);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
fun la_polvere_va_dove_deve() {
    let mut s = setup();
    // 101 MIST: fee = 3 (per difetto). Dentro la fee: protocollo 1, burn 2,
    // cioè la polvere della fee va al **burn**. All'autore 98.
    let id = list_as(&mut s, AUTHOR, b"uno", 101);
    buy_with(&mut s, BUYER, id, 101);
    ts::next_tx(&mut s, ADMIN);
    {
        let reg = ts::take_shared<Registry>(&s);
        let (a, p, b) = tpl::quote(&reg, 101);
        assert!(a + p + b == 101, 0);
        assert!(b >= p, 1);                       // la polvere pende verso il burn
        assert!(tpl::revenue_value(&reg) == p, 2);
        assert!(tpl::burn_pot_value(&reg) == b, 3);
        ts::return_shared(reg);
    };
    ts::next_tx(&mut s, AUTHOR);
    {
        let paid = ts::take_from_address<Coin<SUI>>(&s, AUTHOR);
        assert!(coin::value(&paid) == 98, 4);
        ts::return_to_address(AUTHOR, paid);
    };
    ts::end(s);
}

#[test]
fun il_prelievo_prende_solo_la_nostra_quota() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 100 * SUI_1);
    buy_with(&mut s, BUYER, id, 100 * SUI_1);
    ts::next_tx(&mut s, ADMIN);
    {
        let cap = ts::take_from_address<AdminCap>(&s, ADMIN);
        let mut reg = ts::take_shared<Registry>(&s);
        let got = tpl::withdraw_revenue(&cap, &mut reg, ts::ctx(&mut s));
        assert!(coin::value(&got) == 15 * SUI_1 / 10, 0);
        // **Il punto del modulo**: la cassa del burn è ancora tutta lì, e non
        // esiste nessuna funzione che la sposti altrove che in `swap_and_burn`.
        assert!(tpl::burn_pot_value(&reg) == 15 * SUI_1 / 10, 1);
        assert!(tpl::revenue_value(&reg) == 0, 2);
        transfer::public_transfer(got, ADMIN);
        ts::return_to_address(ADMIN, cap);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EZeroPrice)]
fun niente_template_a_prezzo_zero() {
    let mut s = setup();
    list_as(&mut s, AUTHOR, b"uno", 0);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EEmptyId)]
fun niente_template_senza_id() {
    let mut s = setup();
    list_as(&mut s, AUTHOR, b"", SUI_1);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::ETooLong)]
fun niente_id_chilometrici() {
    let mut s = setup();
    // Finirebbe copiato dentro ogni licenza e ogni evento, a spese di chi compra.
    list_as(
        &mut s, AUTHOR,
        b"aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffgggggggggg",
        SUI_1,
    );
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EPriceTooHigh)]
fun niente_prezzi_che_traboccano() {
    let mut s = setup();
    list_as(&mut s, AUTHOR, b"uno", 18_000_000_000_000_000_000);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::EBurnNotConfigured)]
fun il_burn_senza_configurazione_si_ferma() {
    let mut s = setup();
    ts::next_tx(&mut s, RANDOM);
    {
        let reg = ts::take_shared<Registry>(&s);
        // Una Pool finta qui non si può costruire: si prova il controllo che
        // viene prima, cioè che senza configurazione il burn non parte.
        tpl::assert_burn_ready_for_testing(&reg);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
fun la_licenza_si_puo_buttare() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", SUI_1);
    buy_with(&mut s, BUYER, id, SUI_1);
    ts::next_tx(&mut s, BUYER);
    {
        let lic = ts::take_from_address<License>(&s, BUYER);
        // Non si trasferisce (per scelta) ma si cancella: altrimenti resterebbe
        // per sempre a occupare storage nel wallet di chi non la vuole più.
        tpl::burn_license(lic);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = epoch_templates::templates::ENotUpgrade)]
fun migrate_non_fa_niente_sulla_versione_corrente() {
    let mut s = setup();
    ts::next_tx(&mut s, ADMIN);
    {
        let cap = ts::take_from_address<AdminCap>(&s, ADMIN);
        let mut reg = ts::take_shared<Registry>(&s);
        assert!(tpl::version(&reg) == 1, 0);
        tpl::migrate(&cap, &mut reg);   // già alla versione giusta: aborta
        ts::return_to_address(ADMIN, cap);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
fun due_acquisti_due_licenze() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);
    // Comprare due volte è permesso: una licenza in più non fa male a nessuno,
    // e impedirlo vorrebbe dire tenere dentro un oggetto condiviso la lista di
    // chi ha comprato, cioè stato che cresce senza limite.
    ts::next_tx(&mut s, ADMIN);
    {
        let reg = ts::take_shared<Registry>(&s);
        assert!(tpl::total_sold(&reg) == 2, 0);
        assert!(tpl::total_volume(&reg) == 20 * SUI_1, 1);
        ts::return_shared(reg);
    };
    ts::end(s);
}

#[test]
fun il_template_tiene_il_conto_suo() {
    let mut s = setup();
    let id = list_as(&mut s, AUTHOR, b"uno", 10 * SUI_1);
    buy_with(&mut s, BUYER, id, 10 * SUI_1);
    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared_by_id<Template>(&s, id);
        assert!(tpl::sold(&t) == 1, 0);
        assert!(tpl::author(&t) == AUTHOR, 1);
        assert!(tpl::price(&t) == 10 * SUI_1, 2);
        assert!(tpl::digest(&t) == dig(), 3);
        assert!(tpl::template_id(&t) == string::utf8(b"uno"), 4);
        ts::return_shared(t);
    };
    ts::end(s);
}

// NOTA sulla non trasferibilità: non è una cosa che si prova a runtime, è una
// proprietà del tipo. `License` ha `key` e NON `store`, quindi da fuori dal
// package non esiste `public_transfer`, non entra in un kiosk e non si mette
// dentro nessun wrapper. Se un domani qualcuno le aggiunge `store` per comodità,
// i test continuano a passare e la promessa cade in silenzio: questo commento è
// il posto dove accorgersene.
//
// NOTA su `set_burn_config`: che sia irripetibile non si prova qui, perché per
// chiamarla serve una `Pool` vera e la copia locale di Cetus non la costruisce.
// Si prova on chain subito dopo il publish, richiamandola una seconda volta e
// aspettandosi `EAlreadyConfigured` (14).
