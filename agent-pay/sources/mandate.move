/// Epoch Agent Pay: un budget per un agente, con limiti che fa rispettare la catena.
///
/// IL PROBLEMA: un agente che paga ha bisogno di una chiave, e una chiave che sta
/// su una macchina che gira da sola prima o poi la legge qualcuno. Dare all'agente
/// un wallet vuol dire che quel giorno si perde il wallet.
///
/// LA FORMA: il proprietario deposita un budget in un `Mandate` e nomina una chiave
/// d'agente. L'agente può solo `pay`, e solo dentro le regole scritte qui: tetto per
/// pagamento, tetto per periodo, destinatari ammessi, scadenza, pausa. Quindi chi
/// ruba la chiave dell'agente perde al massimo il tetto del periodo, mai il saldo.
///
/// QUELLO CHE L'AGENTE NON PUO' FARE, mai: cambiare le regole, prelevare, impedire
/// al proprietario di riprendersi tutto. Il proprietario ritira quando vuole, anche
/// a mandato scaduto o in pausa, senza ritardi. Non esiste un admin del package e non
/// esiste una fee: questo modulo non ha nessuna capability oltre agli indirizzi
/// scritti dentro ogni mandato.
///
/// x402: lo schema `exact` su Sui verifica un pagamento simulando la transazione e
/// guardando che `payTo` riceva esattamente l'importo. `pay` manda una `Coin<T>` a
/// `recipient` con `public_transfer`, quindi una transazione che la chiama è un
/// pagamento x402 valido senza estensioni.
///
/// UNA COSA DA SAPERE: il periodo è una finestra fissa, non scorrevole. A cavallo del
/// confine l'agente può spendere fino a due tetti in poco tempo. È il prezzo di un
/// campo invece di una coda di pagamenti, ed è scritto nella UI.
module epoch_agent_pay::mandate;

use std::string::{Self, String};
use sui::balance::Balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};
use epoch_agent_pay::service::{Self, Service};

// ── Errori ───────────────────────────────────────────────────────────────
const ENotOwner:          u64 = 0;
const ENotAgent:          u64 = 1;
const EPaused:            u64 = 2;
const EExpired:           u64 = 3;
const EZeroAmount:        u64 = 4;
const EOverPaymentCap:    u64 = 5;
const EOverPeriodCap:     u64 = 6;
const ERecipientNotAllowed: u64 = 7;
const ENonceUsed:         u64 = 8;
const ENonceTooLong:      u64 = 9;
const EInsufficientBalance: u64 = 10;
const EBadLimits:         u64 = 11;
const EBadPeriod:         u64 = 12;
const EBadExpiry:         u64 = 13;
const ENoRecipients:      u64 = 14;
const ETooManyRecipients: u64 = 15;
const ELabelTooLong:      u64 = 16;
const EServiceInactive:   u64 = 17;
const EPriceAboveMax:     u64 = 18;
const EMemoTooLong:       u64 = 19;
/// Il servizio è un lavoro da consegnare (`KIND_JOB`): si paga solo passando da un escrow.
const EServiceNotApi:     u64 = 20;

const MIN_PERIOD_MS: u64 = 60_000;                 // 1 minuto
const MAX_PERIOD_MS: u64 = 365 * 24 * 3_600_000;   // 1 anno
const MAX_RECIPIENTS: u64 = 32;
const MAX_NONCE_BYTES: u64 = 64;
const MAX_LABEL_BYTES: u64 = 64;
const MAX_MEMO_BYTES: u64 = 128;

// ── Oggetto ──────────────────────────────────────────────────────────────

/// Shared. Uno per coppia proprietario-agente.
public struct Mandate<phantom T> has key {
    id: UID,
    owner: address,
    /// L'unica chiave che può chiamare `pay`. `@0x0` = nessun agente.
    agent: address,
    balance: Balance<T>,
    max_per_payment: u64,
    max_per_period: u64,
    period_ms: u64,
    period_start_ms: u64,
    spent_in_period: u64,
    total_spent: u64,
    payments: u64,
    /// 0 = nessuna scadenza.
    expires_ms: u64,
    paused: bool,
    any_recipient: bool,
    recipients: VecSet<address>,
    used_nonces: Table<vector<u8>, bool>,
    label: String,
}

// ── Eventi ───────────────────────────────────────────────────────────────

public struct MandateCreated has copy, drop {
    mandate: ID, owner: address, agent: address, amount: u64,
    max_per_payment: u64, max_per_period: u64, period_ms: u64,
    expires_ms: u64, any_recipient: bool, recipients: vector<address>,
}
/// La RICEVUTA. Ogni pagamento ne emette una, e contiene tutto quello che serve a
/// scrivere una fattura: chi ha pagato (`payer`, il proprietario del mandato) e con
/// quale chiave (`agent`), chi ha incassato, per quale servizio, quanto, in che moneta
/// (il `T` del tipo dell'evento), quando, il numero progressivo della ricevuta dentro
/// il mandato, e i riferimenti del venditore (`nonce`, `memo`).
/// È un evento e non un oggetto di proposito: su un pagamento da un centesimo, un
/// oggetto ricevuta costerebbe di storage più del pagamento stesso.
public struct Paid<phantom T> has copy, drop {
    mandate: ID,
    receipt_no: u64,
    payer: address,
    agent: address,
    recipient: address,
    service: Option<ID>,
    amount: u64,
    nonce: vector<u8>,
    memo: String,
    timestamp_ms: u64,
    spent_in_period: u64,
    balance_after: u64,
}
public struct ToppedUp has copy, drop { mandate: ID, from: address, amount: u64, balance_after: u64 }
public struct Withdrawn has copy, drop { mandate: ID, amount: u64, balance_after: u64 }
public struct AgentChanged has copy, drop { mandate: ID, old_agent: address, new_agent: address }
public struct LimitsChanged has copy, drop { mandate: ID, max_per_payment: u64, max_per_period: u64, period_ms: u64 }
public struct ExpiryChanged has copy, drop { mandate: ID, expires_ms: u64 }
public struct RecipientsChanged has copy, drop { mandate: ID, any_recipient: bool, recipients: vector<address> }
public struct PauseChanged has copy, drop { mandate: ID, paused: bool }
public struct MandateClosed has copy, drop { mandate: ID, refunded: u64 }

// ── Creazione ────────────────────────────────────────────────────────────

public fun create<T>(
    funds: Coin<T>,
    agent: address,
    max_per_payment: u64,
    max_per_period: u64,
    period_ms: u64,
    expires_ms: u64,
    recipients: vector<address>,
    any_recipient: bool,
    label: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock::timestamp_ms(clock);
    check_limits(max_per_payment, max_per_period, period_ms);
    assert!(expires_ms == 0 || expires_ms > now, EBadExpiry);
    assert!(label.length() <= MAX_LABEL_BYTES, ELabelTooLong);

    let mut set = vec_set::empty<address>();
    let n = recipients.length();
    assert!(n <= MAX_RECIPIENTS, ETooManyRecipients);
    let mut i = 0;
    while (i < n) {
        let r = recipients[i];
        if (!set.contains(&r)) set.insert(r);
        i = i + 1;
    };
    // Un mandato che non può pagare nessuno è un errore di chi lo crea.
    assert!(any_recipient || !set.is_empty(), ENoRecipients);

    let amount = coin::value(&funds);
    let owner = ctx.sender();
    let m = Mandate<T> {
        id: object::new(ctx),
        owner,
        agent,
        balance: coin::into_balance(funds),
        max_per_payment,
        max_per_period,
        period_ms,
        period_start_ms: now,
        spent_in_period: 0,
        total_spent: 0,
        payments: 0,
        expires_ms,
        paused: false,
        any_recipient,
        recipients: set,
        used_nonces: table::new(ctx),
        label: string::utf8(label),
    };
    event::emit(MandateCreated {
        mandate: object::id(&m), owner, agent, amount,
        max_per_payment, max_per_period, period_ms, expires_ms,
        any_recipient, recipients: *m.recipients.keys(),
    });
    transfer::share_object(m);
}

// ── L'unica cosa che fa l'agente ─────────────────────────────────────────

/// Paga `amount` a `recipient`. Solo la chiave `agent`, solo dentro le regole.
/// `nonce` vuoto = nessun controllo sui doppi pagamenti. `memo` finisce nella
/// ricevuta (numero d'ordine, riferimento di fattura del venditore).
public fun pay<T>(
    m: &mut Mandate<T>,
    amount: u64,
    recipient: address,
    nonce: vector<u8>,
    memo: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(m.any_recipient || m.recipients.contains(&recipient), ERecipientNotAllowed);
    do_pay(m, amount, recipient, option::none(), nonce, memo, clock, ctx);
}

/// Paga una chiamata a un servizio al prezzo scritto nel suo listino. Il prezzo lo
/// legge il contratto, non lo sceglie l'agente; `max_price` è il massimo che l'agente
/// accetta, così un aumento del venditore mentre la transazione è in volo la fa
/// fallire invece di costare di più. Il destinatario è ammesso se il mandato elenca il
/// servizio (il suo id) oppure il suo `pay_to`.
public fun pay_service<T>(
    m: &mut Mandate<T>,
    s: &Service<T>,
    max_price: u64,
    nonce: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(service::is_api(s), EServiceNotApi);
    assert!(service::is_active(s), EServiceInactive);
    let price = service::price(s);
    assert!(price <= max_price, EPriceAboveMax);
    let recipient = service::pay_to(s);
    let sid = object::id(s);
    assert!(
        m.any_recipient || m.recipients.contains(&object::id_to_address(&sid)) || m.recipients.contains(&recipient),
        ERecipientNotAllowed,
    );
    do_pay(m, price, recipient, option::some(sid), nonce, vector[], clock, ctx);
}

fun do_pay<T>(
    m: &mut Mandate<T>,
    amount: u64,
    recipient: address,
    svc: Option<ID>,
    nonce: vector<u8>,
    memo: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock::timestamp_ms(clock);
    assert!(ctx.sender() == m.agent && m.agent != @0x0, ENotAgent);
    assert!(!m.paused, EPaused);
    assert!(m.expires_ms == 0 || now < m.expires_ms, EExpired);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= m.max_per_payment, EOverPaymentCap);
    assert!(memo.length() <= MAX_MEMO_BYTES, EMemoTooLong);

    roll_period(m, now);
    assert!(m.spent_in_period + amount <= m.max_per_period, EOverPeriodCap);

    if (!nonce.is_empty()) {
        assert!(nonce.length() <= MAX_NONCE_BYTES, ENonceTooLong);
        assert!(!m.used_nonces.contains(nonce), ENonceUsed);
        m.used_nonces.add(nonce, true);
    };
    assert!(m.balance.value() >= amount, EInsufficientBalance);

    m.spent_in_period = m.spent_in_period + amount;
    m.total_spent = m.total_spent + amount;
    m.payments = m.payments + 1;
    let c = coin::take(&mut m.balance, amount, ctx);
    transfer::public_transfer(c, recipient);

    event::emit(Paid<T> {
        mandate: object::id(m),
        receipt_no: m.payments,
        payer: m.owner,
        agent: m.agent,
        recipient,
        service: svc,
        amount,
        nonce,
        memo: string::utf8(memo),
        timestamp_ms: now,
        spent_in_period: m.spent_in_period,
        balance_after: m.balance.value(),
    });
}

// ── Chiunque ─────────────────────────────────────────────────────────────

/// Aggiunge fondi e basta. Aperto a tutti: ricaricare non dà nessun potere.
public fun top_up<T>(m: &mut Mandate<T>, funds: Coin<T>, ctx: &TxContext) {
    let amount = coin::value(&funds);
    assert!(amount > 0, EZeroAmount);
    m.balance.join(coin::into_balance(funds));
    event::emit(ToppedUp { mandate: object::id(m), from: ctx.sender(), amount, balance_after: m.balance.value() });
}

// ── Solo il proprietario ─────────────────────────────────────────────────

/// Sempre disponibile: in pausa, scaduto, con l'agente che fa qualunque cosa.
public fun withdraw<T>(m: &mut Mandate<T>, amount: u64, ctx: &mut TxContext) {
    assert_owner(m, ctx);
    assert!(amount > 0, EZeroAmount);
    assert!(m.balance.value() >= amount, EInsufficientBalance);
    let c = coin::take(&mut m.balance, amount, ctx);
    transfer::public_transfer(c, m.owner);
    event::emit(Withdrawn { mandate: object::id(m), amount, balance_after: m.balance.value() });
}

public fun withdraw_all<T>(m: &mut Mandate<T>, ctx: &mut TxContext) {
    assert_owner(m, ctx);
    let amount = m.balance.value();
    assert!(amount > 0, EZeroAmount);
    let c = coin::take(&mut m.balance, amount, ctx);
    transfer::public_transfer(c, m.owner);
    event::emit(Withdrawn { mandate: object::id(m), amount, balance_after: 0 });
}

/// Chiude il mandato: rimborsa il saldo e libera lo storage.
public fun close<T>(m: Mandate<T>, ctx: &mut TxContext) {
    assert_owner(&m, ctx);
    let Mandate {
        id, owner, agent: _, balance, max_per_payment: _, max_per_period: _, period_ms: _,
        period_start_ms: _, spent_in_period: _, total_spent: _, payments: _, expires_ms: _,
        paused: _, any_recipient: _, recipients: _, used_nonces, label: _,
    } = m;
    let refunded = balance.value();
    if (refunded > 0) {
        transfer::public_transfer(coin::from_balance(balance, ctx), owner);
    } else {
        balance.destroy_zero();
    };
    used_nonces.drop();
    event::emit(MandateClosed { mandate: id.to_inner(), refunded });
    id.delete();
}

/// Ruota la chiave dell'agente. `@0x0` spegne l'agente senza toccare il resto.
public fun set_agent<T>(m: &mut Mandate<T>, new_agent: address, ctx: &TxContext) {
    assert_owner(m, ctx);
    let old_agent = m.agent;
    m.agent = new_agent;
    event::emit(AgentChanged { mandate: object::id(m), old_agent, new_agent });
}

/// Il nuovo tetto vale anche per quanto già speso nel periodo in corso.
public fun set_limits<T>(
    m: &mut Mandate<T>, max_per_payment: u64, max_per_period: u64, period_ms: u64, ctx: &TxContext,
) {
    assert_owner(m, ctx);
    check_limits(max_per_payment, max_per_period, period_ms);
    m.max_per_payment = max_per_payment;
    m.max_per_period = max_per_period;
    m.period_ms = period_ms;
    event::emit(LimitsChanged { mandate: object::id(m), max_per_payment, max_per_period, period_ms });
}

public fun set_expiry<T>(m: &mut Mandate<T>, expires_ms: u64, clock: &Clock, ctx: &TxContext) {
    assert_owner(m, ctx);
    assert!(expires_ms == 0 || expires_ms > clock::timestamp_ms(clock), EBadExpiry);
    m.expires_ms = expires_ms;
    event::emit(ExpiryChanged { mandate: object::id(m), expires_ms });
}

public fun add_recipient<T>(m: &mut Mandate<T>, r: address, ctx: &TxContext) {
    assert_owner(m, ctx);
    if (!m.recipients.contains(&r)) {
        assert!(m.recipients.length() < MAX_RECIPIENTS, ETooManyRecipients);
        m.recipients.insert(r);
    };
    emit_recipients(m);
}

public fun remove_recipient<T>(m: &mut Mandate<T>, r: address, ctx: &TxContext) {
    assert_owner(m, ctx);
    if (m.recipients.contains(&r)) m.recipients.remove(&r);
    // Togliere l'ultimo destinatario con any_recipient spento lascia un mandato che
    // non paga nessuno: è permesso (è un modo di spegnerlo), non un errore.
    emit_recipients(m);
}

public fun set_any_recipient<T>(m: &mut Mandate<T>, any: bool, ctx: &TxContext) {
    assert_owner(m, ctx);
    m.any_recipient = any;
    emit_recipients(m);
}

public fun pause<T>(m: &mut Mandate<T>, ctx: &TxContext) {
    assert_owner(m, ctx);
    m.paused = true;
    event::emit(PauseChanged { mandate: object::id(m), paused: true });
}

public fun resume<T>(m: &mut Mandate<T>, ctx: &TxContext) {
    assert_owner(m, ctx);
    m.paused = false;
    event::emit(PauseChanged { mandate: object::id(m), paused: false });
}

// ── Letture ──────────────────────────────────────────────────────────────

public fun owner<T>(m: &Mandate<T>): address { m.owner }
public fun agent<T>(m: &Mandate<T>): address { m.agent }
public fun balance<T>(m: &Mandate<T>): u64 { m.balance.value() }
public fun total_spent<T>(m: &Mandate<T>): u64 { m.total_spent }
public fun payments<T>(m: &Mandate<T>): u64 { m.payments }
public fun is_paused<T>(m: &Mandate<T>): bool { m.paused }
public fun max_per_payment<T>(m: &Mandate<T>): u64 { m.max_per_payment }
public fun max_per_period<T>(m: &Mandate<T>): u64 { m.max_per_period }
public fun nonce_used<T>(m: &Mandate<T>, nonce: vector<u8>): bool { m.used_nonces.contains(nonce) }

/// Quanto può ancora spendere l'agente in questo periodo, contando il rinnovo.
public fun remaining_in_period<T>(m: &Mandate<T>, clock: &Clock): u64 {
    let now = clock::timestamp_ms(clock);
    let spent = if (now >= m.period_start_ms + m.period_ms) 0 else m.spent_in_period;
    // set_limits può abbassare il tetto sotto quanto già speso: niente sottrazione negativa.
    let room = if (spent >= m.max_per_period) 0 else m.max_per_period - spent;
    let bal = m.balance.value();
    if (room < bal) room else bal
}

/// Stessi controlli di `pay` tranne firma e nonce: serve alle UI e agli agenti per
/// sapere prima di firmare se un pagamento passerebbe.
public fun can_pay<T>(m: &Mandate<T>, amount: u64, recipient: address, clock: &Clock): bool {
    let now = clock::timestamp_ms(clock);
    if (m.agent == @0x0 || m.paused) return false;
    if (m.expires_ms != 0 && now >= m.expires_ms) return false;
    if (amount == 0 || amount > m.max_per_payment) return false;
    if (!m.any_recipient && !m.recipients.contains(&recipient)) return false;
    amount <= remaining_in_period(m, clock)
}

// ── Interne ──────────────────────────────────────────────────────────────

fun assert_owner<T>(m: &Mandate<T>, ctx: &TxContext) {
    assert!(ctx.sender() == m.owner, ENotOwner);
}

fun check_limits(max_per_payment: u64, max_per_period: u64, period_ms: u64) {
    assert!(max_per_payment > 0 && max_per_period > 0, EBadLimits);
    assert!(max_per_payment <= max_per_period, EBadLimits);
    assert!(period_ms >= MIN_PERIOD_MS && period_ms <= MAX_PERIOD_MS, EBadPeriod);
}

fun roll_period<T>(m: &mut Mandate<T>, now: u64) {
    if (now >= m.period_start_ms + m.period_ms) {
        m.period_start_ms = now;
        m.spent_in_period = 0;
    }
}

fun emit_recipients<T>(m: &Mandate<T>) {
    event::emit(RecipientsChanged {
        mandate: object::id(m), any_recipient: m.any_recipient, recipients: *m.recipients.keys(),
    });
}
