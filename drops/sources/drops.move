/// Epoch Drops: un airdrop con vesting da un vault solo.
///
/// IL PROBLEMA: ogni progetto che distribuisce token (community, KOL, early
/// holder) si prende il dump il giorno dopo. Con un vault per destinatario la
/// cosa costa una fee a testa, quindi non lo fa nessuno.
///
/// LA FORMA: il progetto deposita il totale UNA volta, dichiara la lista
/// `indirizzo → importo` come radice di Merkle, sceglie lo stesso schedule dei
/// vault (cliff, percentuale al cliff, finestra lineare) e paga UNA fee. Ogni
/// destinatario ritira la parte maturata presentando la sua prova. La lista
/// intera sta in un blob pubblico su Walrus, il cui id è scritto qui dentro:
/// chiunque può ricostruire l'albero, verificare che la radice combaci e
/// contare quanto è stato promesso.
///
/// COSA NON PUO' FARE NESSUNO, creatore e admin compresi: cancellare il drop,
/// cambiare la lista, cambiare lo schedule, riprendersi quello che la lista
/// promette. Il creatore può solo ritirare l'EVENTUALE surplus, cioè quello che
/// ha depositato in più rispetto a `declared_total`, e anche quello mai a scapito
/// di chi deve ancora ritirare (vedi `withdraw_surplus`). L'admin del package
/// tocca solo la tesoreria delle fee.
///
/// DA DOVE VIENE IL CODICE: l'albero è quello di `epoch_farm` (foglia con tag,
/// nodi ordinati, dispari che sale intero), la maturazione è
/// `vesting::compute_vested_total` copiata riga per riga. Due cose già
/// collaudate su mainnet, messe insieme.
///
/// UNA COSA CHE IL CONTRATTO NON PUO' VERIFICARE, e va detta: che la somma delle
/// foglie sia davvero `declared_total`. Il Move vede solo la radice. Se il
/// creatore dichiara meno di quello che la lista promette, gli ultimi a
/// ritirare trovano il vuoto. La difesa è fuori: il frontend calcola la somma
/// e la passa lui, e la pagina di claim ricostruisce l'albero dal blob e
/// mostra "sottofinanziato" se i conti non tornano, prima che qualcuno firmi.
module epoch_drops::drops;

use std::ascii;
use std::string::String;
use std::type_name;
use sui::balance::{Self, Balance};
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::hash;
use sui::sui::SUI;
use sui::table::{Self, Table};

// ── Errori ───────────────────────────────────────────────────────────────
const EInsufficientFee:    u64 = 0;
const EBadRoot:            u64 = 1;
const EZeroAmount:         u64 = 2;
const EUnderfunded:        u64 = 3;
const EInvalidParams:      u64 = 4;
const EInvalidTimestamps:  u64 = 5;
const EAlreadyEnded:       u64 = 6;
const EBadProof:           u64 = 7;
const ENothingToClaim:     u64 = 8;
const ENotCreator:         u64 = 9;
const ENoSurplus:          u64 = 10;
const ETitleTooLong:       u64 = 11;
const EBlobIdTooLong:      u64 = 12;
const EExpired:            u64 = 13;
const ENotExpired:         u64 = 14;

const BPS_BASE: u64 = 10_000;
const HASH_LEN: u64 = 32;
const LEAF_TAG: u8 = 0;
const NODE_TAG: u8 = 1;
const MAX_TITLE_BYTES: u64 = 64;
const MAX_BLOB_ID_BYTES: u64 = 128;

/// 10 SUI, come il deploy fee dei vault. Si muove con `update_fee`.
const DEFAULT_FEE_MIST: u64 = 10_000_000_000;

// ── Oggetti ──────────────────────────────────────────────────────────────

public struct AdminCap has key, store { id: UID }

/// Shared. Solo le fee: non tocca mai i token di un Drop.
public struct Treasury has key {
    id: UID,
    balance: Balance<SUI>,
    fee: u64,
}

/// Shared, immutabile per costruzione: non esiste una funzione che ne cambi
/// lista, schedule o beneficiari dopo la creazione.
public struct Drop<phantom T> has key {
    id: UID,
    creator: address,
    title: String,
    /// Sale scelto dal creatore, dentro ogni foglia. Serve a legare la lista a
    /// QUESTO drop: l'id dell'oggetto non si conosce prima della transazione
    /// che lo crea, e la radice va scritta in quella stessa transazione.
    salt: address,
    root: vector<u8>,
    /// Blob Walrus con la lista intera (`indirizzo, importo`), pubblico.
    leaves_blob: String,
    balance: Balance<T>,
    /// Quanto è entrato alla creazione (più i `top_up`). Serve a misurare il
    /// surplus senza guardare i ritiri: vedi `withdraw_surplus`.
    deposited: u64,
    /// Somma delle foglie, dichiarata dal creatore. Vedi la nota in testa.
    declared_total: u64,
    paid_total: u64,
    surplus_taken: u64,
    /// Dopo questa data (ms) nessuno ritira più e il creatore riprende il
    /// residuo. Zero = mai: i token restano ritirabili per sempre. È scritta
    /// alla creazione, quindi chi sta nella lista la conosce dal primo giorno.
    claim_deadline_ms: u64,
    /// Quanti indirizzi ci sono nella lista. Solo informativo.
    recipients: u64,
    /// Cumulativo già ritirato, per indirizzo.
    claimed: Table<address, u64>,
    // Schedule: identico ai vault.
    cliff_ts_ms: u64,
    cliff_bps: u64,
    linear_start_ms: u64,
    linear_end_ms: u64,
    created_at_ms: u64,
}

// ── Eventi ───────────────────────────────────────────────────────────────

public struct DropCreated has copy, drop {
    drop: address,
    creator: address,
    coin_type: ascii::String,
    title: String,
    salt: address,
    root: vector<u8>,
    leaves_blob: String,
    deposited: u64,
    declared_total: u64,
    recipients: u64,
    cliff_ts_ms: u64,
    cliff_bps: u64,
    linear_start_ms: u64,
    linear_end_ms: u64,
    claim_deadline_ms: u64,
    created_at_ms: u64,
}

public struct DropClaimed has copy, drop {
    drop: address,
    who: address,
    amount: u64,
    cumulative_paid: u64,
    /// Il totale della foglia: quanto questo indirizzo prenderà in tutto.
    allocation: u64,
}

public struct SurplusWithdrawn has copy, drop { drop: address, amount: u64 }

public struct ToppedUp has copy, drop { drop: address, from: address, amount: u64, pot: u64 }

public struct Reclaimed has copy, drop { drop: address, amount: u64 }

public struct FeeUpdated has copy, drop { old_fee: u64, new_fee: u64 }

// ── Init ─────────────────────────────────────────────────────────────────

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(Treasury {
        id: object::new(ctx),
        balance: balance::zero<SUI>(),
        fee: DEFAULT_FEE_MIST,
    });
}

// ── Creazione ────────────────────────────────────────────────────────────

/// Deposita i token, scrive la radice e lo schedule, paga la fee. Tutto in una
/// chiamata: dopo, il drop è di chi sta nella lista.
///
/// `tokens` può superare `declared_total` (arrotondamenti, o un margine): la
/// parte in più resta ritirabile dal creatore con `withdraw_surplus`. Non può
/// essere inferiore: un drop che nasce già insolvente si rifiuta qui.
///
/// `claim_deadline_ms`: zero vuol dire "ritirabile per sempre". Altrimenti deve
/// stare strettamente DOPO la fine dello schedule (altrimenti l'ultima quota
/// non sarebbe mai ritirabile) e dopo quella data il creatore può riprendersi il residuo con
/// `reclaim_expired`. Un airdrop con scadenza è normale; una scadenza che
/// compare dopo non lo sarebbe, per questo si fissa qui e non si cambia più.
public fun create<T>(
    treasury: &mut Treasury,
    fee: Coin<SUI>,
    tokens: Coin<T>,
    title: String,
    salt: address,
    root: vector<u8>,
    leaves_blob: String,
    declared_total: u64,
    recipients: u64,
    cliff_ts_ms: u64,
    cliff_bps: u64,
    linear_start_ms: u64,
    linear_end_ms: u64,
    claim_deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // --- Fee: si prende quella esatta, il resto torna al mittente ---
    assert!(fee.value() >= treasury.fee, EInsufficientFee);
    let mut fee_balance = fee.into_balance();
    let exact = fee_balance.split(treasury.fee);
    treasury.balance.join(exact);
    if (fee_balance.value() > 0) {
        transfer::public_transfer(coin::from_balance(fee_balance, ctx), ctx.sender());
    } else {
        fee_balance.destroy_zero();
    };

    // --- Lista ---
    assert!(root.length() == HASH_LEN, EBadRoot);
    assert!(declared_total > 0, EZeroAmount);
    assert!(recipients > 0, EInvalidParams);
    assert!(title.length() <= MAX_TITLE_BYTES, ETitleTooLong);
    assert!(leaves_blob.length() <= MAX_BLOB_ID_BYTES, EBlobIdTooLong);
    let deposited = tokens.value();
    assert!(deposited >= declared_total, EUnderfunded);

    // --- Schedule: le stesse regole di `vesting::create_vault` ---
    assert!(cliff_bps <= BPS_BASE, EInvalidParams);
    assert!(linear_end_ms >= linear_start_ms, EInvalidTimestamps);
    if (cliff_bps > 0) { assert!(cliff_ts_ms > 0, EInvalidParams); };
    if (cliff_ts_ms > 0 && cliff_bps < BPS_BASE) {
        assert!(linear_start_ms >= cliff_ts_ms, EInvalidTimestamps);
    };
    let now_ms = clock::timestamp_ms(clock);
    let end_ts = if (cliff_bps == BPS_BASE) { cliff_ts_ms } else { linear_end_ms };
    assert!(end_ts > now_ms, EAlreadyEnded);
    // Strettamente dopo: la quota finale matura a `now >= end_ts`, e con una
    // scadenza uguale a `end_ts` quel millisecondo sarebbe già "scaduto".
    if (claim_deadline_ms > 0) { assert!(claim_deadline_ms > end_ts, EInvalidTimestamps); };

    let uid = object::new(ctx);
    let drop_addr = uid.to_address();
    let creator = ctx.sender();

    event::emit(DropCreated {
        drop: drop_addr,
        creator,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        title,
        salt,
        root,
        leaves_blob,
        deposited,
        declared_total,
        recipients,
        cliff_ts_ms,
        cliff_bps,
        linear_start_ms,
        linear_end_ms,
        claim_deadline_ms,
        created_at_ms: now_ms,
    });

    transfer::share_object(Drop<T> {
        id: uid,
        creator,
        title,
        salt,
        root,
        leaves_blob,
        balance: tokens.into_balance(),
        deposited,
        declared_total,
        paid_total: 0,
        surplus_taken: 0,
        claim_deadline_ms,
        recipients,
        claimed: table::new(ctx),
        cliff_ts_ms,
        cliff_bps,
        linear_start_ms,
        linear_end_ms,
        created_at_ms: now_ms,
    });
}

// ── Ritiro ───────────────────────────────────────────────────────────────

/// `allocation` è il numero nella foglia: quanto questo indirizzo prende in
/// tutto. Si paga la parte maturata a oggi meno quella già presa, quindi
/// chiamarla due volte di fila la seconda volta aborta invece di pagare due
/// volte.
///
/// Restituisce la coin per poterla comporre in una PTB; `claim_and_transfer`
/// è la stessa cosa col trasferimento in fondo.
public fun claim<T>(
    drop: &mut Drop<T>,
    allocation: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let who = ctx.sender();
    assert!(verify(&drop.root, &proof, drop.salt, who, allocation), EBadProof);

    let now_ms = clock::timestamp_ms(clock);
    if (drop.claim_deadline_ms > 0) { assert!(now_ms < drop.claim_deadline_ms, EExpired); };
    let vested = compute_vested_total(
        allocation, drop.cliff_ts_ms, drop.cliff_bps,
        drop.linear_start_ms, drop.linear_end_ms, now_ms,
    );
    let already = if (drop.claimed.contains(who)) *drop.claimed.borrow(who) else 0;
    assert!(vested > already, ENothingToClaim);

    let mut amount = vested - already;
    // Il serbatoio è la verità finale. Ci si arriva solo se il creatore ha
    // dichiarato meno di quello che la lista promette (vedi la nota in testa).
    let pot = drop.balance.value();
    if (amount > pot) amount = pot;
    assert!(amount > 0, ENothingToClaim);

    if (drop.claimed.contains(who)) {
        let slot = drop.claimed.borrow_mut(who);
        *slot = already + amount;
    } else {
        drop.claimed.add(who, amount);
    };
    drop.paid_total = drop.paid_total + amount;

    event::emit(DropClaimed {
        drop: drop.id.to_address(),
        who,
        amount,
        cumulative_paid: already + amount,
        allocation,
    });

    coin::from_balance(drop.balance.split(amount), ctx)
}

#[allow(lint(self_transfer))]
public fun claim_and_transfer<T>(
    drop: &mut Drop<T>,
    allocation: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let c = claim(drop, allocation, proof, clock, ctx);
    transfer::public_transfer(c, ctx.sender());
}

// ── Surplus, ricarica, scadenza ──────────────────────────────────────────

/// Il creatore riprende SOLO quello che ha depositato oltre `declared_total`.
/// Il conto si fa su quello che è entrato, non su quello che è uscito:
/// `deposited - declared_total - surplus_taken`. Così, anche se la lista
/// promettesse più del dichiarato (vedi la nota in testa), il creatore non può
/// mai portare via un token che un ritiro sta contendendo.
public fun withdraw_surplus<T>(drop: &mut Drop<T>, ctx: &mut TxContext): Coin<T> {
    assert!(ctx.sender() == drop.creator, ENotCreator);
    let margin = drop.deposited - drop.declared_total - drop.surplus_taken;
    let pot = drop.balance.value();
    let amount = if (margin > pot) pot else margin;
    assert!(amount > 0, ENoSurplus);
    drop.surplus_taken = drop.surplus_taken + amount;
    event::emit(SurplusWithdrawn { drop: drop.id.to_address(), amount });
    coin::from_balance(drop.balance.split(amount), ctx)
}

#[allow(lint(self_transfer))]
public fun withdraw_surplus_and_transfer<T>(drop: &mut Drop<T>, ctx: &mut TxContext) {
    let c = withdraw_surplus(drop, ctx);
    transfer::public_transfer(c, ctx.sender());
}

/// Permissionless. Serve a una cosa sola: se un drop è nato sottofinanziato
/// (dichiarato meno della somma delle foglie), chiunque, di solito il creatore,
/// può rimettere la differenza senza rifare niente. Non alza `declared_total`
/// e quindi non alza il surplus ritirabile: quello che entra qui è per la lista.
public fun top_up<T>(drop: &mut Drop<T>, payment: Coin<T>, ctx: &TxContext) {
    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
    drop.balance.join(payment.into_balance());
    // Non tocca `deposited`: un top up non è un margine del creatore.
    event::emit(ToppedUp { drop: drop.id.to_address(), from: ctx.sender(), amount, pot: drop.balance.value() });
}

/// Dopo la scadenza scritta alla creazione, il creatore riprende tutto quello
/// che non è stato ritirato. Prima di quella data, o se la scadenza è zero,
/// questa funzione non esiste di fatto.
public fun reclaim_expired<T>(drop: &mut Drop<T>, clock: &Clock, ctx: &mut TxContext): Coin<T> {
    assert!(ctx.sender() == drop.creator, ENotCreator);
    assert!(drop.claim_deadline_ms > 0, ENotExpired);
    assert!(clock::timestamp_ms(clock) >= drop.claim_deadline_ms, ENotExpired);
    let amount = drop.balance.value();
    assert!(amount > 0, EZeroAmount);
    event::emit(Reclaimed { drop: drop.id.to_address(), amount });
    coin::from_balance(drop.balance.split(amount), ctx)
}

#[allow(lint(self_transfer))]
public fun reclaim_expired_and_transfer<T>(drop: &mut Drop<T>, clock: &Clock, ctx: &mut TxContext) {
    let c = reclaim_expired(drop, clock, ctx);
    transfer::public_transfer(c, ctx.sender());
}

// ── Albero (identico a epoch_farm) ───────────────────────────────────────

/// Foglia: `blake2b256(0x00 || salt || indirizzo || allocazione)`.
public fun leaf_hash(salt: address, who: address, allocation: u64): vector<u8> {
    let mut bytes = vector[LEAF_TAG];
    bytes.append(bcs::to_bytes(&salt));
    bytes.append(bcs::to_bytes(&who));
    bytes.append(bcs::to_bytes(&allocation));
    hash::blake2b256(&bytes)
}

/// Nodo: `blake2b256(0x01 || min(a,b) || max(a,b))`.
fun node_hash(a: &vector<u8>, b: &vector<u8>): vector<u8> {
    let mut bytes = vector[NODE_TAG];
    if (lte(a, b)) { bytes.append(*a); bytes.append(*b); }
    else { bytes.append(*b); bytes.append(*a); };
    hash::blake2b256(&bytes)
}

fun lte(a: &vector<u8>, b: &vector<u8>): bool {
    let n = a.length();
    let mut i = 0;
    while (i < n) {
        let x = *a.borrow(i);
        let y = *b.borrow(i);
        if (x < y) return true;
        if (x > y) return false;
        i = i + 1;
    };
    true
}

public fun verify(
    root: &vector<u8>,
    proof: &vector<vector<u8>>,
    salt: address,
    who: address,
    allocation: u64,
): bool {
    let n = proof.length();
    let mut i = 0;
    while (i < n) {
        if (proof.borrow(i).length() != HASH_LEN) return false;
        i = i + 1;
    };
    let mut acc = leaf_hash(salt, who, allocation);
    i = 0;
    while (i < n) {
        acc = node_hash(&acc, proof.borrow(i));
        i = i + 1;
    };
    acc == *root
}

// ── Maturazione (identica a vesting::compute_vested_total) ───────────────

fun compute_vested_total(
    total: u64,
    cliff_ts_ms: u64,
    cliff_bps: u64,
    linear_start_ms: u64,
    linear_end_ms: u64,
    now_ms: u64,
): u64 {
    let mut vested: u64 = 0;
    let cliff_amount = (((total as u128) * (cliff_bps as u128) / (BPS_BASE as u128)) as u64);
    if (cliff_amount > 0 && cliff_ts_ms > 0 && now_ms >= cliff_ts_ms) {
        vested = vested + cliff_amount;
    };
    let linear_amount = total - cliff_amount;
    if (linear_amount > 0) {
        let start = linear_start_ms;
        let end = linear_end_ms;
        if (start == end) {
            if (now_ms >= start) { vested = vested + linear_amount; }
        } else if (now_ms >= end) {
            vested = vested + linear_amount;
        } else if (now_ms > start) {
            let elapsed = now_ms - start;
            let duration = end - start;
            vested = vested + (((linear_amount as u128) * (elapsed as u128) / (duration as u128)) as u64);
        }
    };
    if (vested > total) { total } else { vested }
}

// ── Tesoreria ────────────────────────────────────────────────────────────

public fun withdraw_fees(_cap: &AdminCap, treasury: &mut Treasury, ctx: &mut TxContext): Coin<SUI> {
    let amount = treasury.balance.value();
    assert!(amount > 0, EZeroAmount);
    coin::from_balance(treasury.balance.split(amount), ctx)
}

public fun update_fee(_cap: &AdminCap, treasury: &mut Treasury, new_fee: u64) {
    let old_fee = treasury.fee;
    treasury.fee = new_fee;
    event::emit(FeeUpdated { old_fee, new_fee });
}

// ── Letture ──────────────────────────────────────────────────────────────

public fun fee(treasury: &Treasury): u64 { treasury.fee }
public fun creator<T>(d: &Drop<T>): address { d.creator }
public fun salt<T>(d: &Drop<T>): address { d.salt }
public fun root<T>(d: &Drop<T>): vector<u8> { d.root }
public fun leaves_blob<T>(d: &Drop<T>): String { d.leaves_blob }
public fun pot<T>(d: &Drop<T>): u64 { d.balance.value() }
public fun declared_total<T>(d: &Drop<T>): u64 { d.declared_total }
public fun paid_total<T>(d: &Drop<T>): u64 { d.paid_total }
public fun recipients<T>(d: &Drop<T>): u64 { d.recipients }
public fun deposited<T>(d: &Drop<T>): u64 { d.deposited }
public fun claim_deadline_ms<T>(d: &Drop<T>): u64 { d.claim_deadline_ms }
public fun schedule<T>(d: &Drop<T>): (u64, u64, u64, u64) {
    (d.cliff_ts_ms, d.cliff_bps, d.linear_start_ms, d.linear_end_ms)
}
public fun claimed_of<T>(d: &Drop<T>, who: address): u64 {
    if (d.claimed.contains(who)) *d.claimed.borrow(who) else 0
}
/// Quanto `who` può ritirare adesso, data la sua allocazione. Non verifica la
/// prova: serve alla pagina, la verità la dice `claim`.
public fun claimable<T>(d: &Drop<T>, who: address, allocation: u64, clock: &Clock): u64 {
    let vested = compute_vested_total(
        allocation, d.cliff_ts_ms, d.cliff_bps, d.linear_start_ms, d.linear_end_ms,
        clock::timestamp_ms(clock),
    );
    let already = claimed_of(d, who);
    if (vested > already) { vested - already } else { 0 }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun node_hash_for_testing(a: &vector<u8>, b: &vector<u8>): vector<u8> { node_hash(a, b) }

#[test_only]
public fun vested_for_testing(
    total: u64, cliff_ts_ms: u64, cliff_bps: u64, linear_start_ms: u64, linear_end_ms: u64, now_ms: u64,
): u64 {
    compute_vested_total(total, cliff_ts_ms, cliff_bps, linear_start_ms, linear_end_ms, now_ms)
}
