#[test_only]
module epoch_agent_pay::service_tests;

use epoch_agent_pay::mandate::{Self, Mandate};
use epoch_agent_pay::service::{Self, Service};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const OWNER: address = @0xA;
const AGENT: address = @0xB;
const SELLER: address = @0xC;
const PAYOUT: address = @0xE;
const OTHER: address = @0xD;

const DAY: u64 = 86_400_000;

fun clock_at(ms: u64, s: &mut Scenario): Clock {
    let mut c = clock::create_for_testing(ts::ctx(s));
    clock::set_for_testing(&mut c, ms);
    c
}

/// Il venditore mette un servizio a 3, pagato su PAYOUT.
fun list_service(s: &mut Scenario) {
    ts::next_tx(s, SELLER);
    let c = clock_at(500, s);
    service::create<SUI>(PAYOUT, b"datafeed", b"Price feed", b"https://datafeed.epochsui.com/api", b"data", b"", service::kind_api(), 3, &c, ts::ctx(s));
    clock::destroy_for_testing(c);
}

fun service_id(s: &mut Scenario): address {
    ts::next_tx(s, OWNER);
    let svc = ts::take_shared<Service<SUI>>(s);
    let id = object::id_to_address(&object::id(&svc));
    ts::return_shared(svc);
    id
}

/// Mandato che ammette `allowed`: 100 di budget, 10 per pagamento, 30 al giorno.
fun open_mandate(s: &mut Scenario, allowed: vector<address>) {
    ts::next_tx(s, OWNER);
    let funds = coin::mint_for_testing<SUI>(100, ts::ctx(s));
    let c = clock_at(1_000, s);
    mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 0, allowed, false, b"", &c, ts::ctx(s));
    clock::destroy_for_testing(c);
}

fun pay_service_as(s: &mut Scenario, who: address, max_price: u64, nonce: vector<u8>, at: u64) {
    ts::next_tx(s, who);
    let mut m = ts::take_shared<Mandate<SUI>>(s);
    let svc = ts::take_shared<Service<SUI>>(s);
    let c = clock_at(at, s);
    mandate::pay_service(&mut m, &svc, max_price, nonce, &c, ts::ctx(s));
    clock::destroy_for_testing(c);
    ts::return_shared(svc);
    ts::return_shared(m);
}

fun balance_of(s: &mut Scenario, who: address): u64 {
    ts::next_tx(s, who);
    let mut total = 0;
    let ids = ts::ids_for_sender<Coin<SUI>>(s);
    let mut i = 0;
    while (i < ids.length()) {
        let c = ts::take_from_sender_by_id<Coin<SUI>>(s, ids[i]);
        total = total + coin::value(&c);
        ts::return_to_sender(s, c);
        i = i + 1;
    };
    total
}

#[test]
fun pays_the_listed_price_to_pay_to() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    pay_service_as(&mut s, AGENT, 5, b"call-1", 2_000);
    pay_service_as(&mut s, AGENT, 3, b"call-2", 3_000);
    assert!(balance_of(&mut s, PAYOUT) == 6, 0);
    ts::next_tx(&mut s, OWNER);
    {
        let m = ts::take_shared<Mandate<SUI>>(&s);
        assert!(mandate::balance(&m) == 94, 1);
        assert!(mandate::payments(&m) == 2, 2);
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test]
fun pay_to_in_the_list_is_enough() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    open_mandate(&mut s, vector[PAYOUT]);
    pay_service_as(&mut s, AGENT, 3, b"", 2_000);
    assert!(balance_of(&mut s, PAYOUT) == 3, 0);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EPriceAboveMax)]
fun price_raised_in_flight_fails() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    ts::next_tx(&mut s, SELLER);
    {
        let mut svc = ts::take_shared<Service<SUI>>(&s);
        service::update(&mut svc, PAYOUT, b"Price feed", b"https://datafeed.epochsui.com/api", b"data", b"", 9, true, ts::ctx(&mut s));
        ts::return_shared(svc);
    };
    // L'agente aveva visto 3 e accetta al massimo 3.
    pay_service_as(&mut s, AGENT, 3, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EServiceInactive)]
fun inactive_service_cannot_be_paid() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    ts::next_tx(&mut s, SELLER);
    {
        let mut svc = ts::take_shared<Service<SUI>>(&s);
        service::update(&mut svc, PAYOUT, b"Price feed", b"", b"data", b"", 3, false, ts::ctx(&mut s));
        ts::return_shared(svc);
    };
    pay_service_as(&mut s, AGENT, 3, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ERecipientNotAllowed)]
fun service_not_in_mandate_list() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    open_mandate(&mut s, vector[OTHER]);
    pay_service_as(&mut s, AGENT, 3, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EOverPeriodCap)]
fun service_payments_count_against_the_period_cap() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    let mut i = 0;
    // 10 chiamate da 3 = 30, la undicesima sfora il tetto di 30.
    while (i < 11) {
        pay_service_as(&mut s, AGENT, 3, b"", 2_000 + i);
        i = i + 1;
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotAgent)]
fun seller_cannot_pull_from_the_mandate() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    pay_service_as(&mut s, SELLER, 3, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::ENotOwner)]
fun only_the_seller_updates_the_listing() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    ts::next_tx(&mut s, OTHER);
    {
        let mut svc = ts::take_shared<Service<SUI>>(&s);
        service::update(&mut svc, OTHER, b"x", b"", b"", b"", 1, true, ts::ctx(&mut s));
        ts::return_shared(svc);
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = service::EZeroPrice)]
fun zero_price_rejected() {
    let mut s = ts::begin(SELLER);
    let c = clock_at(500, &mut s);
    service::create<SUI>(PAYOUT, b"", b"free?", b"", b"", b"", service::kind_api(), 0, &c, ts::ctx(&mut s));
    clock::destroy_for_testing(c);
    ts::end(s);
}

/// Un lavoro da consegnare, a 3.
fun list_job(s: &mut Scenario) {
    ts::next_tx(s, SELLER);
    let c = clock_at(500, s);
    service::create<SUI>(PAYOUT, b"", b"Logo", b"", b"creative", b"", service::kind_job(), 3, &c, ts::ctx(s));
    clock::destroy_for_testing(c);
}

fun buy_as(s: &mut Scenario, who: address, amount: u64, max_price: u64) {
    ts::next_tx(s, who);
    let svc = ts::take_shared<Service<SUI>>(s);
    let pay = coin::mint_for_testing<SUI>(amount, ts::ctx(s));
    let c = clock_at(2_000, s);
    service::buy(&svc, pay, max_price, b"req-1", &c, ts::ctx(s));
    clock::destroy_for_testing(c);
    ts::return_shared(svc);
}

#[test]
fun wallet_buy_pays_pay_to() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    buy_as(&mut s, OTHER, 3, 3);
    assert!(balance_of(&mut s, PAYOUT) == 3, 0);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::EWrongAmount)]
fun wallet_buy_needs_the_exact_amount() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    buy_as(&mut s, OTHER, 5, 5);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::EPriceAboveMax)]
fun wallet_buy_respects_max_price() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    buy_as(&mut s, OTHER, 3, 2);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::ENotApi)]
fun a_job_is_not_bought_directly() {
    let mut s = ts::begin(OWNER);
    list_job(&mut s);
    buy_as(&mut s, OTHER, 3, 3);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EServiceNotApi)]
fun a_job_is_not_paid_from_a_mandate() {
    let mut s = ts::begin(OWNER);
    list_job(&mut s);
    let sid = service_id(&mut s);
    open_mandate(&mut s, vector[sid]);
    pay_service_as(&mut s, AGENT, 3, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::EBadKind)]
fun unknown_kind_rejected() {
    let mut s = ts::begin(SELLER);
    let c = clock_at(500, &mut s);
    service::create<SUI>(PAYOUT, b"", b"x", b"", b"", b"", 7, 1, &c, ts::ctx(&mut s));
    clock::destroy_for_testing(c);
    ts::end(s);
}

// ── Upgrade v2: cancellazione ─────────────────────────────────────

#[test]
fun the_seller_deletes_the_listing() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    ts::next_tx(&mut s, SELLER);
    {
        let svc = ts::take_shared<Service<SUI>>(&s);
        service::delete(svc, ts::ctx(&mut s));
    };
    ts::next_tx(&mut s, SELLER);
    assert!(!ts::has_most_recent_shared<Service<SUI>>(), 0);
    ts::end(s);
}

#[test, expected_failure(abort_code = service::ENotOwner)]
fun only_the_seller_deletes_the_listing() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    ts::next_tx(&mut s, OTHER);
    {
        let svc = ts::take_shared<Service<SUI>>(&s);
        service::delete(svc, ts::ctx(&mut s));
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = service::ENotOwner)]
fun the_old_owner_cannot_delete_after_a_transfer() {
    let mut s = ts::begin(OWNER);
    list_service(&mut s);
    ts::next_tx(&mut s, SELLER);
    {
        let mut svc = ts::take_shared<Service<SUI>>(&s);
        service::transfer_ownership(&mut svc, OTHER, ts::ctx(&mut s));
        ts::return_shared(svc);
    };
    ts::next_tx(&mut s, SELLER);
    {
        let svc = ts::take_shared<Service<SUI>>(&s);
        service::delete(svc, ts::ctx(&mut s));
    };
    ts::end(s);
}
