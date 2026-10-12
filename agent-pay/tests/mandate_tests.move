#[test_only]
module epoch_agent_pay::mandate_tests;

use epoch_agent_pay::mandate::{Self, Mandate};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const OWNER: address = @0xA;
const AGENT: address = @0xB;
const SHOP: address = @0xC;
const OTHER: address = @0xD;

const DAY: u64 = 86_400_000;

fun clock_at(ms: u64, s: &mut Scenario): Clock {
    let mut c = clock::create_for_testing(ts::ctx(s));
    clock::set_for_testing(&mut c, ms);
    c
}

/// Mandato standard: 100 di budget, 10 per pagamento, 30 al giorno, solo SHOP.
fun setup(s: &mut Scenario) {
    ts::next_tx(s, OWNER);
    {
        let funds = coin::mint_for_testing<SUI>(100, ts::ctx(s));
        let c = clock_at(1_000, s);
        mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 0, vector[SHOP], false, b"test", &c, ts::ctx(s));
        clock::destroy_for_testing(c);
    };
}

fun pay_as(s: &mut Scenario, who: address, amount: u64, to: address, nonce: vector<u8>, at: u64) {
    ts::next_tx(s, who);
    let mut m = ts::take_shared<Mandate<SUI>>(s);
    let c = clock_at(at, s);
    mandate::pay(&mut m, amount, to, nonce, b"", &c, ts::ctx(s));
    clock::destroy_for_testing(c);
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
fun agent_pays_within_limits() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 10, SHOP, b"req-1", 2_000);
    pay_as(&mut s, AGENT, 7, SHOP, b"", 3_000);
    assert!(balance_of(&mut s, SHOP) == 17, 0);
    ts::next_tx(&mut s, OWNER);
    {
        let m = ts::take_shared<Mandate<SUI>>(&s);
        assert!(mandate::balance(&m) == 83, 1);
        assert!(mandate::total_spent(&m) == 17, 2);
        assert!(mandate::payments(&m) == 2, 3);
        assert!(mandate::nonce_used(&m, b"req-1"), 4);
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotAgent)]
fun owner_cannot_pay_as_agent() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, OWNER, 1, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotAgent)]
fun stranger_cannot_pay() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, OTHER, 1, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EOverPaymentCap)]
fun over_payment_cap() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 11, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EOverPeriodCap)]
fun over_period_cap() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 2_000);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 3_000);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 4_000);
    pay_as(&mut s, AGENT, 1, SHOP, b"", 5_000);
    ts::end(s);
}

#[test]
fun period_rolls_over() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 2_000);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 3_000);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 4_000);
    // Il periodo è partito a 1_000: a 1_000 + DAY si riparte da zero.
    pay_as(&mut s, AGENT, 10, SHOP, b"", 1_000 + DAY);
    assert!(balance_of(&mut s, SHOP) == 40, 0);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ERecipientNotAllowed)]
fun recipient_not_in_list() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 1, OTHER, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENonceUsed)]
fun same_nonce_twice() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 1, SHOP, b"invoice-7", 2_000);
    pay_as(&mut s, AGENT, 1, SHOP, b"invoice-7", 3_000);
    ts::end(s);
}

#[test]
fun empty_nonce_is_not_tracked() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 1, SHOP, b"", 2_000);
    pay_as(&mut s, AGENT, 1, SHOP, b"", 3_000);
    assert!(balance_of(&mut s, SHOP) == 2, 0);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EPaused)]
fun paused_blocks_agent() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, OWNER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::pause(&mut m, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    pay_as(&mut s, AGENT, 1, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EExpired)]
fun expired_blocks_agent() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    {
        let funds = coin::mint_for_testing<SUI>(100, ts::ctx(&mut s));
        let c = clock_at(1_000, &mut s);
        mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 5_000, vector[SHOP], false, b"", &c, ts::ctx(&mut s));
        clock::destroy_for_testing(c);
    };
    pay_as(&mut s, AGENT, 1, SHOP, b"", 5_000);
    ts::end(s);
}

/// Il principio del modulo: con l'agente attivo e in qualunque stato, il
/// proprietario si riprende tutto.
#[test]
fun owner_withdraws_everything_even_when_paused_and_expired() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    {
        let funds = coin::mint_for_testing<SUI>(100, ts::ctx(&mut s));
        let c = clock_at(1_000, &mut s);
        mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 5_000, vector[SHOP], false, b"", &c, ts::ctx(&mut s));
        clock::destroy_for_testing(c);
    };
    pay_as(&mut s, AGENT, 10, SHOP, b"", 2_000);
    ts::next_tx(&mut s, OWNER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::pause(&mut m, ts::ctx(&mut s));
        mandate::withdraw_all(&mut m, ts::ctx(&mut s));
        assert!(mandate::balance(&m) == 0, 0);
        ts::return_shared(m);
    };
    assert!(balance_of(&mut s, OWNER) == 90, 1);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotOwner)]
fun agent_cannot_withdraw() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, AGENT);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::withdraw(&mut m, 1, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotOwner)]
fun agent_cannot_raise_limits() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, AGENT);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::set_limits(&mut m, 100, 100, DAY, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotOwner)]
fun agent_cannot_add_recipient() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, AGENT);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::add_recipient(&mut m, OTHER, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotAgent)]
fun rotated_key_stops_old_agent() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, OWNER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::set_agent(&mut m, OTHER, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    pay_as(&mut s, AGENT, 1, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENotAgent)]
fun zero_agent_cannot_pay() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    ts::next_tx(&mut s, OWNER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::set_agent(&mut m, @0x0, ts::ctx(&mut s));
        ts::return_shared(m);
    };
    pay_as(&mut s, @0x0, 1, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EInsufficientBalance)]
fun cannot_pay_more_than_balance() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    {
        let funds = coin::mint_for_testing<SUI>(5, ts::ctx(&mut s));
        let c = clock_at(1_000, &mut s);
        mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 0, vector[SHOP], false, b"", &c, ts::ctx(&mut s));
        clock::destroy_for_testing(c);
    };
    pay_as(&mut s, AGENT, 6, SHOP, b"", 2_000);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::ENoRecipients)]
fun create_rejects_mandate_that_pays_nobody() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    let funds = coin::mint_for_testing<SUI>(5, ts::ctx(&mut s));
    let c = clock_at(1_000, &mut s);
    mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 0, vector[], false, b"", &c, ts::ctx(&mut s));
    clock::destroy_for_testing(c);
    ts::end(s);
}

#[test, expected_failure(abort_code = mandate::EBadLimits)]
fun create_rejects_payment_cap_over_period_cap() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    let funds = coin::mint_for_testing<SUI>(5, ts::ctx(&mut s));
    let c = clock_at(1_000, &mut s);
    mandate::create<SUI>(funds, AGENT, 31, 30, DAY, 0, vector[SHOP], false, b"", &c, ts::ctx(&mut s));
    clock::destroy_for_testing(c);
    ts::end(s);
}

#[test]
fun lowering_cap_below_spent_does_not_underflow() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 2_000);
    pay_as(&mut s, AGENT, 10, SHOP, b"", 3_000);
    ts::next_tx(&mut s, OWNER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::set_limits(&mut m, 5, 15, DAY, ts::ctx(&mut s));
        let c = clock_at(4_000, &mut s);
        assert!(mandate::remaining_in_period(&m, &c) == 0, 0);
        assert!(!mandate::can_pay(&m, 1, SHOP, &c), 1);
        clock::destroy_for_testing(c);
        ts::return_shared(m);
    };
    ts::end(s);
}

#[test]
fun any_recipient_and_top_up_by_anyone() {
    let mut s = ts::begin(OWNER);
    ts::next_tx(&mut s, OWNER);
    {
        let funds = coin::mint_for_testing<SUI>(1, ts::ctx(&mut s));
        let c = clock_at(1_000, &mut s);
        mandate::create<SUI>(funds, AGENT, 10, 30, DAY, 0, vector[], true, b"", &c, ts::ctx(&mut s));
        clock::destroy_for_testing(c);
    };
    ts::next_tx(&mut s, OTHER);
    {
        let mut m = ts::take_shared<Mandate<SUI>>(&s);
        let more = coin::mint_for_testing<SUI>(9, ts::ctx(&mut s));
        mandate::top_up(&mut m, more, ts::ctx(&mut s));
        assert!(mandate::balance(&m) == 10, 0);
        ts::return_shared(m);
    };
    pay_as(&mut s, AGENT, 10, OTHER, b"", 2_000);
    assert!(balance_of(&mut s, OTHER) == 10, 1);
    ts::end(s);
}

#[test]
fun owner_closes_and_gets_refund() {
    let mut s = ts::begin(OWNER);
    setup(&mut s);
    pay_as(&mut s, AGENT, 10, SHOP, b"n1", 2_000);
    ts::next_tx(&mut s, OWNER);
    {
        let m = ts::take_shared<Mandate<SUI>>(&s);
        mandate::close(m, ts::ctx(&mut s));
    };
    assert!(balance_of(&mut s, OWNER) == 90, 0);
    ts::end(s);
}
