/// Epoch Templates: vendita di template per siti .epoch.
///
/// COSA VENDE. Un template è un pacchetto di pagine su Walrus, cifrato. Questo
/// modulo non conosce le pagine e non tiene la chiave: conosce il **prezzo**, chi
/// è l'autore, e chi ha pagato. La prova di acquisto è una `License`, e il resto
/// del sistema (il worker che consegna la chiave) guarda quella.
///
/// PERCHE' UN PACKAGE SEPARATO, mai un upgrade di walrus-names: i nomi sono
/// registrati da mesi e non devono ereditare i bug di un negozio nato oggi. La
/// regola di casa è che si cresce affiancando package, non gonfiando quelli che
/// custodiscono roba altrui.
///
/// COME SI DIVIDONO I SOLDI, su una vendita da 100:
///   - 97   all'autore, subito, nella stessa transazione;
///   - 1,5  a noi, prelevabili con l'AdminCap;
///   - 1,5  in una cassa che ha **una sola uscita**: `swap_and_burn`, che compra
///          EPT sulla pool Cetus e lo manda a `0x0`.
/// Non esiste nessuna funzione che prelevi quella cassa, e la coppia
/// (tipo di coin, pool) su cui il burn compra si fissa **una volta sola**: dopo
/// la prima `set_burn_config` nessuno, admin compreso, può farla comprare
/// altrove. Senza quel vincolo la promessa sarebbe falsa, perché un admin
/// potrebbe puntarla su una pool sua e riprendersi i SUI mentre l'evento dice
/// "bruciato" (trovato al secondo giro di audit, e corretto).
///
/// PERCHE' IL BURN NON STA DENTRO `buy_template`. Sarebbe più bello da
/// raccontare (compra, paga, brucia, tutto in una firma) ma legherebbe **ogni
/// vendita** alla pool Cetus: il giorno che quella aborte, e su questo progetto
/// è già successo (`pool::get_position_amounts` abortiva sulla v14 mainnet
/// mentre passava su testnet), nessuno potrebbe più comprare niente. Quindi la
/// vendita accumula e il burn è una funzione a parte, permissionless: se
/// fallisce salta il burn, non il negozio.
///
/// ONESTA' SU "BRUCIATO": mandare a `0x0` non riduce la supply sul contratto del
/// token, rende quei token irrecuperabili. Le pagine pubbliche devono dirlo così.
module epoch_templates::templates;

use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use cetusclmm::config::GlobalConfig;
use cetusclmm::pool::{Self, Pool};
use cetusclmm::tick_math;

// ── Errori ───────────────────────────────────────────────────────────────
const EWrongVersion:      u64 = 0;
const ENotForSale:        u64 = 1;
const EInsufficientPay:   u64 = 2;
const EFeeTooHigh:        u64 = 3;
const ENotAuthor:         u64 = 4;
const EZeroPrice:         u64 = 5;
const EAuthorCannotBuy:   u64 = 6;
const ENothingToBurn:     u64 = 7;
const EWrongPool:         u64 = 8;
const EWrongEptType:      u64 = 9;
const ESlippage:          u64 = 10;
const EBurnNotConfigured: u64 = 11;
const EEmptyId:           u64 = 12;
const EPriceMoved:        u64 = 13;
const EAlreadyConfigured: u64 = 14;
const EWrongDigest:       u64 = 15;
const ETooLong:           u64 = 16;
const EPriceTooHigh:      u64 = 17;
const EZeroAddress:       u64 = 18;
const ENotUpgrade:        u64 = 19;
const EBadStars:          u64 = 20;

const VERSION: u64 = 1;

/// Tetto della fee, scritto nel bytecode: `set_fee` può solo scendere sotto
/// questo numero, e non esiste modo di alzarlo senza un upgrade pubblico e
/// visibile. Chi pubblica un template oggi sa che non lo si potrà spennare
/// domani cambiando una riga di database.
const FEE_BPS_MAX: u64 = 300;          // 3%

/// Quanta parte della fee va al burn: metà, cioè l'1,5% del prezzo.
/// Costante e non configurabile: è la promessa pubblica, e una promessa che
/// l'admin può cambiare da solo non è una promessa.
/// La **polvere della divisione va al burn**, non a noi: se la frase pubblica è
/// "metà si brucia", l'arrotondamento deve pendere da quella parte.
const BURN_SHARE_BPS: u64 = 5000;      // 50% della fee

/// Scarto massimo accettato dallo swap del burn rispetto al prezzo spot della
/// pool, **al netto della commissione della pool** (che viene scontata prima).
/// Serve contro una pool illiquida o una configurazione sbagliata.
///
/// NON serve contro un sandwich, e il motivo va detto per intero: la funzione è
/// permissionless e `amount` lo sceglie il chiamante, quindi un attaccante mette
/// in **una sola transazione** lo spostamento del prezzo, la chiamata e
/// l'unwind. Non corre nessun rischio di esecuzione: il suo costo è la
/// commissione del giro più il gas. Quello che lo rende non conveniente non è il
/// costo, è che **il bottino è piccolo** (la cassa è l'1,5% di vendite di
/// template). Per questo `swap_and_burn` accetta anche un `min_out` dal
/// chiamante: chi brucia può stringere la soglia usando un prezzo di
/// riferimento esterno, e il calcolo interno resta solo come pavimento.
const MAX_SLIPPAGE_BPS: u64 = 200;     // 2%

/// Denominatore della commissione nelle pool Cetus (1e6: 2500 = 0,25%).
const FEE_RATE_DENOM: u64 = 1_000_000;

const BPS: u64 = 10_000;
const DEAD_ADDRESS: address = @0x0;

/// Tetti. `MAX_PRICE` tiene `price * fee_bps` dentro un u64 con margine largo
/// (il limite vero sarebbe intorno ai 61 milioni di SUI); le due lunghezze
/// perché quelle stringhe finiscono copiate dentro **ogni** licenza e **ogni**
/// evento, e senza tetto un autore può far pagare a ogni compratore lo storage
/// di una stringa da decine di KB.
const MAX_PRICE: u64 = 1_000_000_000_000_000;   // 1.000.000 SUI
const MAX_ID_LEN: u64 = 64;
const DIGEST_LEN: u64 = 64;                     // sha256 in esadecimale
/// Tetto al testo di una recensione. Sta in un evento, che è dentro la
/// transazione di chi scrive: senza un tetto, uno ci infila un libro e lo paga
/// lui, ma poi lo deve leggere ogni indicizzatore.
const MAX_REVIEW_LEN: u64 = 600;

// ── Oggetti ──────────────────────────────────────────────────────────────

/// Shared, uno solo. Tiene la configurazione e le due casse.
public struct Registry has key {
    id: UID,
    version: u64,
    /// Fee in basis points, <= FEE_BPS_MAX.
    fee_bps: u64,
    /// La nostra quota in SUI, prelevabile dall'admin.
    revenue: Balance<SUI>,
    /// La quota destinata al burn. **Non esiste una funzione che la prelevi**:
    /// l'unica uscita è `swap_and_burn`.
    burn_pot: Balance<SUI>,
    /// Cosa il burn deve comprare e dove. Si scrivono una volta sola: vedi
    /// `set_burn_config`.
    ept_type: Option<TypeName>,
    pool_id: Option<ID>,
    sold: u64,
    volume: u64,
    burned: u64,
}

public struct AdminCap has key, store { id: UID }

/// Shared, uno per template in vendita. `template_id` è la chiave della riga
/// su Supabase e `digest` è lo sha256 del pacchetto conservato: insieme legano
/// questo oggetto a quei byte, così "ho comprato questo" e "questo è il file"
/// sono la stessa frase e non due dichiarazioni separate.
public struct Template has key {
    id: UID,
    template_id: String,
    digest: String,
    /// Chi incassa. Segue la `AuthorCap` tramite `set_author`: senza quella
    /// funzione, vendere la cap vorrebbe dire vendere il diritto di cambiare il
    /// prezzo mentre i soldi continuano ad andare al primo autore per sempre.
    author: address,
    /// In MIST. Zero = non in vendita (i gratuiti non passano da qui).
    price: u64,
    /// L'autore può togliersi dal mercato senza cancellare niente.
    for_sale: bool,
    sold: u64,
    revenue: u64,
}

/// Prova di paternità, trasferibile: un template si può vendere come attività,
/// e con `set_author` si sposta anche l'incasso.
public struct AuthorCap has key, store {
    id: UID,
    template: ID,
}

/// Prova d'acquisto. **`key` senza `store`**: non entra in un kiosk, non si
/// trasferisce, non si vende. È deliberato: si vende una copia, non un posto in
/// fila. Chi la vuole la compra dall'autore, che è l'unico che ci guadagna.
/// Si può però **distruggere** (`burn_license`): un oggetto che non si sposta e
/// non si cancella resterebbe a occupare storage nel wallet per sempre.
public struct License has key {
    id: UID,
    template: ID,
    template_id: String,
    buyer: address,
    paid: u64,
    at_ms: u64,
}

// ── Eventi ───────────────────────────────────────────────────────────────

public struct TemplateListed has copy, drop {
    template: ID,
    template_id: String,
    author: address,
    price: u64,
}

public struct PriceChanged has copy, drop {
    template: ID,
    old_price: u64,
    new_price: u64,
    for_sale: bool,
}

public struct AuthorChanged has copy, drop {
    template: ID,
    old_author: address,
    new_author: address,
}

public struct TemplateSold has copy, drop {
    template: ID,
    template_id: String,
    buyer: address,
    author: address,
    price: u64,
    to_author: u64,
    to_protocol: u64,
    to_burn: u64,
    license: ID,
}

public struct EptBurned has copy, drop {
    sui_spent: u64,
    ept_burned: u64,
    caller: address,
}

/// Le mosse dell'admin lasciano una traccia leggibile da un indicizzatore di
/// eventi, non solo dentro il corpo di una transazione.
public struct FeeChanged has copy, drop { old_bps: u64, new_bps: u64 }
public struct BurnConfigSet has copy, drop { coin_type: TypeName, pool: ID }
public struct RevenueWithdrawn has copy, drop { amount: u64, to: address }

// ── Init ─────────────────────────────────────────────────────────────────

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        version: VERSION,
        fee_bps: FEE_BPS_MAX,
        revenue: balance::zero(),
        burn_pot: balance::zero(),
        ept_type: option::none(),
        pool_id: option::none(),
        sold: 0,
        volume: 0,
        burned: 0,
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// ── Autore ───────────────────────────────────────────────────────────────

/// Mette in vendita un template. Non carica niente e non firma niente per conto
/// di nessuno: il pacchetto sta già su Walrus, qui si dichiara solo il prezzo.
///
/// Prende il Registry **per riferimento condiviso**, non mutabile, e non tiene
/// nessun contatore dei template: scrivere sull'oggetto condiviso a ogni listing
/// metterebbe in coda ogni acquisto dietro a chiunque pubblichi, e listare costa
/// solo gas. Quanti template esistono si conta dagli eventi.
public fun list_template(
    reg: &Registry,
    template_id: String,
    digest: String,
    price: u64,
    ctx: &mut TxContext,
): AuthorCap {
    assert!(reg.version == VERSION, EWrongVersion);
    assert!(price > 0, EZeroPrice);
    assert!(price <= MAX_PRICE, EPriceTooHigh);
    assert!(template_id.length() > 0, EEmptyId);
    assert!(template_id.length() <= MAX_ID_LEN, ETooLong);
    // Lo sha256 in esadecimale è lungo esattamente così. Pretenderlo qui rende
    // "l'oggetto è legato a quei byte" una proprietà del contratto invece di una
    // convenzione del frontend.
    assert!(digest.length() == DIGEST_LEN, EWrongDigest);

    let author = ctx.sender();
    let t = Template {
        id: object::new(ctx),
        template_id,
        digest,
        author,
        price,
        for_sale: true,
        sold: 0,
        revenue: 0,
    };
    let tid = object::id(&t);
    let cap = AuthorCap { id: object::new(ctx), template: tid };

    event::emit(TemplateListed { template: tid, template_id: t.template_id, author, price });
    transfer::share_object(t);
    cap
}

/// Cambia prezzo o toglie dal mercato. Serve la cap: l'indirizzo da solo no,
/// perché un autore può vendere il suo template a qualcun altro passandogli la
/// cap, e da quel momento comanda chi ce l'ha.
public fun set_price(cap: &AuthorCap, t: &mut Template, price: u64, for_sale: bool) {
    assert!(cap.template == object::id(t), ENotAuthor);
    assert!(!for_sale || price > 0, EZeroPrice);
    assert!(price <= MAX_PRICE, EPriceTooHigh);
    let old = t.price;
    t.price = price;
    t.for_sale = for_sale;
    event::emit(PriceChanged { template: object::id(t), old_price: old, new_price: price, for_sale });
}

/// Sposta l'incasso su un altro indirizzo. Esiste perché la `AuthorCap` è
/// trasferibile: senza, chi la compra comprerebbe il diritto di cambiare il
/// prezzo mentre il 97% continua ad arrivare al primo autore, cioè pagherebbe
/// per niente. L'evento non è decorativo: chi sta per comprare deve poter vedere
/// che il beneficiario è cambiato un momento prima.
public fun set_author(cap: &AuthorCap, t: &mut Template, new_author: address) {
    assert!(cap.template == object::id(t), ENotAuthor);
    assert!(new_author != @0x0, EZeroAddress);
    let old = t.author;
    t.author = new_author;
    event::emit(AuthorChanged { template: object::id(t), old_author: old, new_author });
}

// ── Acquisto ─────────────────────────────────────────────────────────────

/// Compra una copia. Paga in SUI, riceve una `License` non trasferibile.
///
/// L'eccesso torna indietro nella stessa transazione: si può mandare una coin
/// più grande del prezzo senza perderne il resto, come fa `register_with_ept`
/// dei nomi. Una coin più piccola invece aborta, non si serve a metà.
///
/// **Non restituisce la licenza, la consegna.** Sembra meno elegante di un
/// valore di ritorno, ma una `License` non ha `store` (è il punto), e un oggetto
/// senza `store` una PTB non può né trasferirlo né conservarlo: restituirlo
/// vorrebbe dire scrivere una funzione che dal mondo esterno non si può
/// chiamare. Meglio una firma onesta che una elegante e inutilizzabile.
///
/// Due parametri che sembrano ridondanti e non lo sono:
/// - `max_price` è il prezzo che il compratore ha visto. Senza, l'autore può
///   alzare il prezzo mentre la transazione è in volo e incassare quello che
///   trova nella coin invece di quello che era esposto.
/// - `expected_digest` è il pacchetto che il compratore ha ispezionato. Non
///   ferma un impostore che copia anche il digest (quel caso si chiude fuori
///   dalla catena, vedi AUDIT), ma ferma il caso molto più probabile: un link o
///   un frontend che punta all'oggetto sbagliato, e un template modificato fra
///   quando è stato guardato e quando è stato comprato.
public fun buy_template(
    reg: &mut Registry,
    t: &mut Template,
    mut payment: Coin<SUI>,
    max_price: u64,
    expected_digest: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(reg.version == VERSION, EWrongVersion);
    assert!(t.for_sale && t.price > 0, ENotForSale);
    assert!(t.price <= max_price, EPriceMoved);
    assert!(t.digest == expected_digest, EWrongDigest);
    assert!(payment.value() >= t.price, EInsufficientPay);

    let buyer = ctx.sender();
    // L'autore che compra il proprio template pagherebbe la fee a se stesso per
    // niente: è quasi sempre un errore di click, quindi si ferma.
    assert!(buyer != t.author, EAuthorCannotBuy);

    let price = t.price;
    let mut paid = payment.split(price, ctx).into_balance();
    // Il resto torna subito: `payment` è già l'oggetto del compratore, basta
    // ridarglielo invece di distruggerlo.
    if (payment.value() > 0) { transfer::public_transfer(payment, buyer); }
    else { payment.destroy_zero(); };

    // Due arrotondamenti, e la direzione di ognuno è una scelta:
    // la polvere della **fee** resta all'autore (ha fatto lui il lavoro), la
    // polvere **dentro la fee** va al burn (se in pubblico diciamo "metà si
    // brucia", l'arrotondamento deve pendere da quella parte).
    let fee         = price * reg.fee_bps / BPS;
    let to_protocol = fee * (BPS - BURN_SHARE_BPS) / BPS;
    let to_burn     = fee - to_protocol;

    reg.burn_pot.join(paid.split(to_burn));
    reg.revenue.join(paid.split(to_protocol));
    let to_author = paid.value();
    transfer::public_transfer(coin::from_balance(paid, ctx), t.author);

    let license = License {
        id: object::new(ctx),
        template: object::id(t),
        template_id: t.template_id,
        buyer,
        paid: price,
        at_ms: clock.timestamp_ms(),
    };

    t.sold = t.sold + 1;
    t.revenue = t.revenue + to_author;
    reg.sold = reg.sold + 1;
    reg.volume = reg.volume + price;

    event::emit(TemplateSold {
        template: object::id(t),
        template_id: t.template_id,
        buyer,
        author: t.author,
        price,
        to_author,
        to_protocol,
        to_burn,
        license: object::id(&license),
    });
    transfer::transfer(license, buyer);
}

/// Buttare via una licenza. Una `License` non si trasferisce per scelta, ma se
/// non si potesse nemmeno cancellare resterebbe a occupare storage nel wallet di
/// chi non la vuole più, per sempre.
public fun burn_license(l: License) {
    let License { id, template: _, template_id: _, buyer: _, paid: _, at_ms: _ } = l;
    id.delete();
}

// ── Burn ─────────────────────────────────────────────────────────────────

/// Compra EPT con la cassa e lo manda a `0x0`. **Permissionless**: chiunque può
/// chiamarla, perché non c'è niente da rubare (i SUI escono solo verso la pool
/// fissata e l'EPT solo verso `0x0`) e perché una promessa che dipende dal fatto
/// che noi premiamo un tasto non vale molto.
///
/// `amount` = quanto della cassa spendere, 0 = tutta.
/// `min_out` = quanto EPT il chiamante pretende almeno. Può solo **stringere**
/// la soglia: se è più bassa del pavimento calcolato qui dentro, si usa il
/// pavimento. Così chi brucia può usare un prezzo di riferimento esterno, e chi
/// volesse passare 0 per farsi passare uno swap truccato non ottiene niente.
public fun swap_and_burn<E>(
    reg: &mut Registry,
    config: &GlobalConfig,
    pool: &mut Pool<E, SUI>,
    amount: u64,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(reg.version == VERSION, EWrongVersion);
    assert!(reg.ept_type.is_some() && reg.pool_id.is_some(), EBurnNotConfigured);
    // Il tipo da solo non basta e la pool da sola non basta: servono tutti e due,
    // altrimenti si può far comprare al contratto un token qualsiasi, oppure lo
    // stesso token su una pool fatta in casa.
    assert!(type_name::with_defining_ids<E>() == *reg.ept_type.borrow(), EWrongEptType);
    assert!(object::id(pool) == *reg.pool_id.borrow(), EWrongPool);

    let pot = reg.burn_pot.value();
    assert!(pot > 0, ENothingToBurn);
    let spend = if (amount == 0 || amount > pot) { pot } else { amount };

    // Quanto EPT ci aspettiamo al prezzo corrente, **tolta la commissione della
    // pool**: `got` arriva al netto, quindi confrontarlo con uno spot al lordo
    // brucerebbe il margine di slippage in commissioni e su un tier alto farebbe
    // abortire ogni burn per sempre.
    let spend_net = (spend as u256) * ((FEE_RATE_DENOM - pool::fee_rate(pool)) as u256)
        / (FEE_RATE_DENOM as u256);
    // sqrt_price è Q64.64 e vale sqrt(SUI per EPT), quindi l'inversa è
    // ept = sui * 2^128 / sqrt^2. In u256 non trabocca: sqrt sta sotto 2^96.
    let sqrt_price = pool::current_sqrt_price(pool) as u256;
    let expected = (spend_net << 128) / (sqrt_price * sqrt_price);
    // Con `expected == 0` il pavimento diventa 0 e la guardia si spegne da sola,
    // lasciando passare uno swap che svuota la cassa per niente.
    assert!(expected > 0, ESlippage);
    let floor = (expected * ((BPS - MAX_SLIPPAGE_BPS) as u256) / (BPS as u256)) as u64;
    let want = if (min_out > floor) { min_out } else { floor };

    // SUI è la coin B della pool EPT/SUI, quindi si compra da B verso A:
    // a2b = false, e il limite di prezzo è il massimo perché comprando A il
    // prezzo sale.
    let (ept_out, sui_out, receipt) = pool::flash_swap<E, SUI>(
        config,
        pool,
        false,                              // a2b: da SUI (B) a EPT (A)
        true,                               // by_amount_in: spendiamo esattamente `spend`
        spend,
        tick_math::max_sqrt_price() - 1,
        clock,
    );
    sui_out.destroy_zero();

    let got = ept_out.value();
    assert!(got >= want, ESlippage);

    let owed = pool::swap_pay_amount(&receipt);
    let pay = reg.burn_pot.split(owed);
    pool::repay_flash_swap<E, SUI>(config, pool, balance::zero<E>(), pay, receipt);

    reg.burned = reg.burned + got;
    event::emit(EptBurned { sui_spent: owed, ept_burned: got, caller: ctx.sender() });
    transfer::public_transfer(coin::from_balance(ept_out, ctx), DEAD_ADDRESS);
}

// ── Admin ────────────────────────────────────────────────────────────────

/// Dopo un upgrade che alza `VERSION`, il Registry condiviso porta ancora il
/// numero vecchio e ogni funzione gated aborta. Senza questa, il primo upgrade
/// **blocca il burn per sempre** e la cassa diventa davvero irrecuperabile, per
/// chiunque. Il version gating senza migrazione non è una protezione, è una
/// trappola a scoppio ritardato.
public fun migrate(_cap: &AdminCap, reg: &mut Registry) {
    assert!(reg.version < VERSION, ENotUpgrade);
    reg.version = VERSION;
}

/// Solo verso il basso: `FEE_BPS_MAX` è nel bytecode e nessuna chiamata può
/// superarlo. Alzarla richiederebbe un upgrade del package, che è pubblico e
/// lascia una tx che chiunque può leggere.
public fun set_fee(_cap: &AdminCap, reg: &mut Registry, fee_bps: u64) {
    assert!(reg.version == VERSION, EWrongVersion);
    assert!(fee_bps <= FEE_BPS_MAX, EFeeTooHigh);
    let old = reg.fee_bps;
    reg.fee_bps = fee_bps;
    event::emit(FeeChanged { old_bps: old, new_bps: fee_bps });
}

/// Dice al contratto cosa comprare e dove, **una volta sola**.
///
/// La prima stesura permetteva di richiamarla: sembrava prudenza (una pool può
/// morire) ed era invece la porta di servizio della cassa. Un admin poteva
/// coniare una coin qualsiasi, aprire una pool in cui era l'unico fornitore di
/// liquidità, puntarci il burn e riprendersi i SUI mentre l'evento diceva
/// "bruciato". Con una sola scrittura quella strada è chiusa e la frase "nemmeno
/// l'admin può toccarla" torna vera.
///
/// **Conseguenza accettata**: se un giorno quella pool muore, la cassa resta
/// ferma finché non si pubblica un upgrade. Un upgrade è pubblico e lascia una
/// transazione che chiunque può leggere, e questo è esattamente il punto: un
/// cambio del genere deve costare visibilità.
public fun set_burn_config<E>(_cap: &AdminCap, reg: &mut Registry, pool: &Pool<E, SUI>) {
    assert!(reg.version == VERSION, EWrongVersion);
    assert!(reg.ept_type.is_none() && reg.pool_id.is_none(), EAlreadyConfigured);
    let ty = type_name::with_defining_ids<E>();
    let pid = object::id(pool);
    reg.ept_type = option::some(ty);
    reg.pool_id  = option::some(pid);
    event::emit(BurnConfigSet { coin_type: ty, pool: pid });
}

/// La nostra quota. La cassa del burn **non ha un equivalente di questa
/// funzione**, ed è il punto di tutto il modulo.
public fun withdraw_revenue(_cap: &AdminCap, reg: &mut Registry, ctx: &mut TxContext): Coin<SUI> {
    assert!(reg.version == VERSION, EWrongVersion);
    let all = reg.revenue.value();
    event::emit(RevenueWithdrawn { amount: all, to: ctx.sender() });
    coin::from_balance(reg.revenue.split(all), ctx)
}

// ── Letture ──────────────────────────────────────────────────────────────

public fun version(reg: &Registry): u64 { reg.version }
public fun fee_bps(reg: &Registry): u64 { reg.fee_bps }
public fun fee_bps_max(): u64 { FEE_BPS_MAX }
public fun burn_share_bps(): u64 { BURN_SHARE_BPS }
public fun revenue_value(reg: &Registry): u64 { reg.revenue.value() }
public fun burn_pot_value(reg: &Registry): u64 { reg.burn_pot.value() }
public fun total_burned(reg: &Registry): u64 { reg.burned }
public fun total_sold(reg: &Registry): u64 { reg.sold }
public fun total_volume(reg: &Registry): u64 { reg.volume }
public fun burn_configured(reg: &Registry): bool { reg.ept_type.is_some() }

public fun price(t: &Template): u64 { t.price }
public fun is_for_sale(t: &Template): bool { t.for_sale }
public fun author(t: &Template): address { t.author }
public fun template_id(t: &Template): String { t.template_id }
public fun digest(t: &Template): String { t.digest }
public fun sold(t: &Template): u64 { t.sold }

public fun author_cap_template(cap: &AuthorCap): ID { cap.template }

/* ── Recensioni ───────────────────────────────────────────────────────────
   Scrive una recensione chi ha comprato, e **non c'è nessun controllo che lo
   verifichi**: la funzione vuole una `License`, che è un oggetto posseduto,
   e in una PTB un oggetto posseduto lo può mettere solo il suo proprietario.
   Cioè "solo chi ha comprato può recensire" non è una regola del nostro
   server, è una proprietà della catena.

   La recensione **non viene salvata da nessuna parte**, viene emessa come
   evento, e sono due decisioni in una:
   1. non tocca il `Template`, che è un oggetto condiviso. Se le recensioni ci
      scrivessero sopra, ogni recensione si metterebbe in coda con ogni
      acquisto sullo stesso oggetto, e le recensioni sono la parte che
      volentieri si aspetta mentre gli acquisti no;
   2. non fa crescere niente per sempre. Il testo sta in un evento, quindi
      l'indicizzatore lo legge e lo mette in vetrina, e chi non si fida
      rilegge gli eventi dalla catena.
   Conseguenza da ricordare: **una licenza, una recensione**, e chi ne manda
   due sta solo pagando gas per riscriverla, perché in vetrina l'indicizzatore
   tiene l'ultima per ogni licenza. */
public struct ReviewPosted has copy, drop {
    template:    ID,
    template_id: String,
    license:     ID,
    author:      address,
    stars:       u8,
    text:        String,
    at_ms:       u64,
}

public fun add_review(l: &License, stars: u8, text: String, clock: &Clock, ctx: &TxContext) {
    assert!(stars >= 1 && stars <= 5, EBadStars);
    assert!(text.length() <= MAX_REVIEW_LEN, ETooLong);
    event::emit(ReviewPosted {
        template:    l.template,
        template_id: l.template_id,
        license:     object::id(l),
        author:      ctx.sender(),
        stars,
        text,
        at_ms:       clock.timestamp_ms(),
    });
}

public fun license_template(l: &License): ID { l.template }
public fun license_template_id(l: &License): String { l.template_id }
public fun license_buyer(l: &License): address { l.buyer }
public fun license_paid(l: &License): u64 { l.paid }

/// Quanto incassa davvero l'autore a un dato prezzo, con la fee di adesso.
/// Esiste perché il frontend non deve rifare la divisione per conto suo: due
/// conti separati che devono dare lo stesso numero prima o poi divergono.
public fun quote(reg: &Registry, price: u64): (u64, u64, u64) {
    assert!(price <= MAX_PRICE, EPriceTooHigh);
    let fee = price * reg.fee_bps / BPS;
    let to_protocol = fee * (BPS - BURN_SHARE_BPS) / BPS;
    (price - fee, to_protocol, fee - to_protocol)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// I controlli che `swap_and_burn` fa prima di toccare Cetus, isolati per
/// poterli provare senza una pool. Quello che sta dopo si prova solo on chain.
#[test_only]
public fun assert_burn_ready_for_testing(reg: &Registry) {
    assert!(reg.ept_type.is_some() && reg.pool_id.is_some(), EBurnNotConfigured);
    assert!(reg.burn_pot.value() > 0, ENothingToBurn);
}
