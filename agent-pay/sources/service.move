/// Epoch Agent Pay, il lato di chi vende: un servizio con il suo prezzo.
///
/// Un `Service<T>` è un listino di una riga scritto on chain: chi lo vende, dove
/// arrivano i soldi (`pay_to`), quanto costa una chiamata e in quale moneta, dove si
/// chiama (`endpoint`). Il prezzo lo decide il venditore e lo può cambiare, ma chi
/// paga passa sempre un `max_price` (vedi `mandate::pay_service`), quindi un aumento
/// mentre la transazione è in volo fa fallire il pagamento invece di costare di più.
///
/// L'agente lo legge per riferimento (`&Service<T>`), mai lo modifica: un oggetto
/// condiviso scritto da ogni pagamento metterebbe in coda tutti i clienti dello stesso
/// servizio. Per lo stesso motivo qui non c'è nessun contatore di chiamate: i conti si
/// fanno dagli eventi `Paid`, che portano l'id del servizio.
///
/// Due tipi di servizio, fissati alla creazione (`kind`):
/// - `KIND_API` (0): una chiamata a pagamento, x402. Si paga con `mandate::pay_service`
///   da un agente o con `buy` da un wallet, e la risposta arriva subito;
/// - `KIND_JOB` (1): un lavoro da consegnare. Si paga solo passando da un escrow (modulo
///   a parte, dopo la v1), quindi qui nessuna delle due strade di pagamento lo accetta.
///
/// Descrizione lunga, schema dell'input, esempi e immagini stanno in un documento su
/// Walrus (`doc`, il blob id). On chain restano solo i campi che servono a filtrare la
/// vetrina senza scaricare un blob per ogni riga (`category`) e quelli che decidono i
/// soldi (`price`, `pay_to`, `active`).
///
/// COSA NON PROVA: che `name` sia davvero un nome .epoch di chi ha creato il servizio.
/// Qui è una dichiarazione. La verifica la fa chi legge (pagina, facilitator x402):
/// mostra il nome come verificato solo se il detentore della NameCap di quel nome è
/// `owner`. Farlo in Move vorrebbe dire dipendere dal package walrus-names.
module epoch_agent_pay::service;

use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;

const ENotOwner:     u64 = 100;
const EZeroPrice:    u64 = 101;
const ETooLong:      u64 = 102;
const EZeroPayTo:    u64 = 103;
const EBadKind:      u64 = 104;
const ENotApi:       u64 = 105;
const EWrongAmount:  u64 = 106;
const ENonceTooLong: u64 = 107;
const EInactive:     u64 = 108;
const EPriceAboveMax: u64 = 109;

const KIND_API: u8 = 0;
const KIND_JOB: u8 = 1;

const MAX_NAME_BYTES:     u64 = 63;
const MAX_TITLE_BYTES:    u64 = 80;
const MAX_ENDPOINT_BYTES: u64 = 256;
const MAX_CATEGORY_BYTES: u64 = 32;
/// Un blob id Walrus sono 43 caratteri base64url: 64 lascia margine a formati futuri.
const MAX_DOC_BYTES:      u64 = 64;
const MAX_NONCE_BYTES:    u64 = 64;

/// Shared. `T` è la moneta in cui il servizio si fa pagare.
public struct Service<phantom T> has key {
    id: UID,
    owner: address,
    pay_to: address,
    /// Nome .epoch dichiarato, senza suffisso. Vuoto = nessuno.
    name: String,
    title: String,
    endpoint: String,
    /// Categoria della vetrina (es. "data", "ai-models"). Lista chiusa lato app, qui è testo.
    category: String,
    /// Blob id Walrus del documento del servizio. Vuoto = nessun documento.
    doc: String,
    /// `KIND_API` o `KIND_JOB`, non cambia mai.
    kind: u8,
    /// Prezzo di una chiamata (o del lavoro), in unità minime di `T`.
    price: u64,
    active: bool,
    created_ms: u64,
}

public struct ServiceCreated has copy, drop {
    service: ID, owner: address, pay_to: address, name: String, title: String,
    endpoint: String, category: String, doc: String, kind: u8, price: u64,
}
public struct ServiceUpdated has copy, drop {
    service: ID, pay_to: address, title: String, endpoint: String, category: String,
    doc: String, price: u64, active: bool,
}
/// Pagamento diretto da wallet (`buy`). Quello da un mandato è l'evento `mandate::Paid`.
public struct ServicePaid<phantom T> has copy, drop {
    service: ID, payer: address, pay_to: address, amount: u64, nonce: vector<u8>, timestamp_ms: u64,
}
public struct ServiceOwnerChanged has copy, drop { service: ID, old_owner: address, new_owner: address }

public fun create<T>(
    pay_to: address,
    name: vector<u8>,
    title: vector<u8>,
    endpoint: vector<u8>,
    category: vector<u8>,
    doc: vector<u8>,
    kind: u8,
    price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(kind == KIND_API || kind == KIND_JOB, EBadKind);
    assert!(price > 0, EZeroPrice);
    assert!(pay_to != @0x0, EZeroPayTo);
    assert!(name.length() <= MAX_NAME_BYTES, ETooLong);
    assert!(title.length() <= MAX_TITLE_BYTES, ETooLong);
    assert!(endpoint.length() <= MAX_ENDPOINT_BYTES, ETooLong);
    assert!(category.length() <= MAX_CATEGORY_BYTES, ETooLong);
    assert!(doc.length() <= MAX_DOC_BYTES, ETooLong);
    let s = Service<T> {
        id: object::new(ctx),
        owner: ctx.sender(),
        pay_to,
        name: string::utf8(name),
        title: string::utf8(title),
        endpoint: string::utf8(endpoint),
        category: string::utf8(category),
        doc: string::utf8(doc),
        kind,
        price,
        active: true,
        created_ms: clock::timestamp_ms(clock),
    };
    event::emit(ServiceCreated {
        service: object::id(&s), owner: s.owner, pay_to, name: s.name, title: s.title,
        endpoint: s.endpoint, category: s.category, doc: s.doc, kind, price,
    });
    transfer::share_object(s);
}

/// Cambia prezzo, destinatario, testi e stato in una volta sola: un evento, una
/// fotografia completa del listino, invece di sette funzioni e sette eventi.
/// `kind` e `name` non si cambiano: chi ha pagato un'API non deve ritrovarsi un lavoro,
/// e il nome è il negozio (se cambia, è un servizio nuovo).
public fun update<T>(
    s: &mut Service<T>,
    pay_to: address,
    title: vector<u8>,
    endpoint: vector<u8>,
    category: vector<u8>,
    doc: vector<u8>,
    price: u64,
    active: bool,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == s.owner, ENotOwner);
    assert!(price > 0, EZeroPrice);
    assert!(pay_to != @0x0, EZeroPayTo);
    assert!(title.length() <= MAX_TITLE_BYTES, ETooLong);
    assert!(endpoint.length() <= MAX_ENDPOINT_BYTES, ETooLong);
    assert!(category.length() <= MAX_CATEGORY_BYTES, ETooLong);
    assert!(doc.length() <= MAX_DOC_BYTES, ETooLong);
    s.pay_to = pay_to;
    s.title = string::utf8(title);
    s.endpoint = string::utf8(endpoint);
    s.category = string::utf8(category);
    s.doc = string::utf8(doc);
    s.price = price;
    s.active = active;
    event::emit(ServiceUpdated {
        service: object::id(s), pay_to, title: s.title, endpoint: s.endpoint,
        category: s.category, doc: s.doc, price, active,
    });
}

/// Pagamento diretto da wallet di un'API, per chi non usa un mandato (una persona dal
/// browser, o un agente che tiene la chiave di un wallet suo). Importo esatto, niente
/// resto da restituire: la PTB stacca la coin giusta prima di chiamare.
///
/// Il nonce qui NON blocca un doppio pagamento: servirebbe una tabella dentro il
/// servizio, cioè scriverlo a ogni pagamento, cioè mettere in coda tutti i clienti.
/// Chi vuole la protezione paga da un mandato. Il nonce viaggia nell'evento, così il
/// venditore lo riconcilia con la sua richiesta.
public fun buy<T>(
    s: &Service<T>,
    payment: Coin<T>,
    max_price: u64,
    nonce: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(s.kind == KIND_API, ENotApi);
    assert!(s.active, EInactive);
    assert!(s.price <= max_price, EPriceAboveMax);
    assert!(coin::value(&payment) == s.price, EWrongAmount);
    assert!(nonce.length() <= MAX_NONCE_BYTES, ENonceTooLong);
    event::emit(ServicePaid<T> {
        service: object::id(s), payer: ctx.sender(), pay_to: s.pay_to, amount: s.price,
        nonce, timestamp_ms: clock::timestamp_ms(clock),
    });
    transfer::public_transfer(payment, s.pay_to);
}

public fun transfer_ownership<T>(s: &mut Service<T>, new_owner: address, ctx: &TxContext) {
    assert!(ctx.sender() == s.owner, ENotOwner);
    assert!(new_owner != @0x0, EZeroPayTo);
    let old_owner = s.owner;
    s.owner = new_owner;
    event::emit(ServiceOwnerChanged { service: object::id(s), old_owner, new_owner });
}

/// Upgrade v2 (24 set 2026, additivo). Evento nuovo: il suo type tag porta
/// l'indirizzo del package v2, non dell'origin (regola dei type tag).
public struct ServiceDeleted has copy, drop { service: ID, owner: address }

/// Toglie il listino dalla catena, per sempre. Solo il proprietario.
///
/// Cosa succede a chi lo usava: i mandati che lo avevano fra i destinatari tengono
/// il suo id, che adesso non punta a niente, quindi `pay_service` non si può più
/// chiamare (manca l'oggetto) e nessun pagamento parte. I pagamenti x402 invece
/// vanno all'indirizzo `pay_to`, non al servizio: se il venditore continua a
/// rispondere 402 da quell'endpoint, un mandato che ammette quell'indirizzo può
/// ancora pagarlo. Cancellare il listino toglie la vetrina, non spegne il server.
/// Le ricevute (eventi `Paid`) restano on chain.
///
/// Per fermarsi senza perdere niente c'è `update` con `active = false`.
public fun delete<T>(s: Service<T>, ctx: &TxContext) {
    assert!(ctx.sender() == s.owner, ENotOwner);
    let Service { id, owner, .. } = s;
    event::emit(ServiceDeleted { service: object::uid_to_inner(&id), owner });
    object::delete(id);
}

public fun owner<T>(s: &Service<T>): address { s.owner }
public fun pay_to<T>(s: &Service<T>): address { s.pay_to }
public fun price<T>(s: &Service<T>): u64 { s.price }
public fun is_active<T>(s: &Service<T>): bool { s.active }
public fun name<T>(s: &Service<T>): String { s.name }
public fun kind<T>(s: &Service<T>): u8 { s.kind }
public fun is_api<T>(s: &Service<T>): bool { s.kind == KIND_API }
public fun category<T>(s: &Service<T>): String { s.category }
public fun doc<T>(s: &Service<T>): String { s.doc }
public fun kind_api(): u8 { KIND_API }
public fun kind_job(): u8 { KIND_JOB }
