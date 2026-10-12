/// Epoch Farm: premi in EPT a chi fornisce liquidità alla pool EPT/SUI.
///
/// COSA TIENE QUESTO CONTRATTO: **solo la moneta dei premi, che ci mettiamo
/// noi**. Non riceve position, non chiede approvazioni, non ha nessuna funzione
/// che possa trattenere o spostare roba di qualcun altro. Chi fornisce
/// liquidità non deposita niente: la sua position resta nel suo wallet, su
/// Cetus, e lui la chiude o la ribilancia quando vuole senza chiedere permesso
/// a noi.
///
/// È la differenza con la farm di Cetus (`stable_farming::pool`), dove
/// `deposit` prende la `Position` per valore e restituisce un wrapper: lì l'LP
/// esce dal wallet e il contratto diventa un custode. Conseguenza della nostra
/// scelta, e vale la pena scriverla dove sta il codice: **nel caso peggiore,
/// cioè un bug qui dentro, l'unico denaro a rischio è il nostro.**
///
/// IL PREZZO DELLA SCELTA: non tenendo le position, il contratto non può
/// sapere chi ha fornito quanto e per quanto tempo. Quel conto lo fa un worker
/// fuori dalla catena, che pubblica una **radice di Merkle**; qui si verifica
/// la prova e si paga. La fiducia si sposta su chi calcola i punteggi, e si
/// compensa pubblicando snapshot e formula, non con una riga di Move.
///
/// LA RADICE E' CUMULATIVA. La foglia dice "questo indirizzo ha maturato TOT
/// da sempre", non "TOT oggi". Tre problemi risolti insieme:
///   - chi non ritira per settimane prende tutto con una transazione sola;
///   - non serve una mappa di bit per ogni round;
///   - **una radice sbagliata si corregge con la successiva**, purché nessuno
///     abbia ancora ritirato il numero gonfiato.
///
/// IL SERBATOIO NON HA UN PRELIEVO. Non esiste nessuna funzione che tolga
/// premi da qui per darli a noi, e non è una dimenticanza: chiudere il
/// programma vuol dire smettere di pubblicare radici, e quello che resta è
/// ritirabile per sempre. Dopo 180 giorni di silenzio chiunque può mandarlo a
/// `0x0`. Stessa logica della cassa del burn in `epoch-templates`: se l'admin
/// potesse riprendersi i premi, "questi soldi sono vostri" sarebbe un annuncio
/// invece che una proprietà.
///
/// COSA POSSIAMO FARE NOI, detto senza girarci intorno: pubblicare le radici e
/// **fermare i ritiri**. Sono gli unici due poteri, servono a limitare il danno
/// di una radice sbagliata (che non si può correggere dopo che qualcuno ha
/// incassato) e stanno scritti anche sulla pagina pubblica.
///
/// PERCHE' E' GENERICO SU `T` e non inchiodato a EPT: il tipo si fissa alla
/// creazione dell'oggetto e non cambia più, quindi in pratica è inchiodato
/// lo stesso; ma così il modulo si può testare senza dipendere dal package del
/// token, e un domani la stessa macchina serve un altro premio senza upgrade.
module epoch_farm::farm;

use sui::bcs;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::hash;
use sui::table::{Self, Table};

// ── Errori ───────────────────────────────────────────────────────────────
const EWrongVersion:   u64 = 0;
const EPaused:         u64 = 1;
const ENothingToClaim: u64 = 2;
const EBadProof:       u64 = 3;
const EPotTooSmall:    u64 = 4;
const ETooEarlyToBurn: u64 = 5;
const ENotUpgrade:     u64 = 6;
const EBadRoot:        u64 = 7;
const EZeroAmount:     u64 = 8;

const VERSION: u64 = 1;

/// Dopo quanto silenzio il residuo diventa bruciabile da chiunque. Sei mesi:
/// abbastanza perché nessuno possa dire che gli è stato portato via qualcosa
/// mentre era distratto, abbastanza poco perché il serbatoio non resti fermo
/// per sempre se il programma finisce.
const BURN_AFTER_MS: u64 = 15_552_000_000;

/// Byte di separazione fra foglie e nodi dell'albero. Senza, un nodo interno
/// si potrebbe far passare per una foglia e fabbricare una prova per un
/// importo che nessuno ha mai dichiarato.
const LEAF_TAG: u8 = 0;
const NODE_TAG: u8 = 1;

const HASH_LEN: u64 = 32;

// ── Oggetti ──────────────────────────────────────────────────────────────

/// Shared. Uno solo per rete.
public struct Farm<phantom T> has key {
    id: UID,
    version: u64,
    /// I premi. Ci entra chiunque con `fund`, ne esce solo `claim` (e
    /// `burn_leftover` dopo sei mesi di silenzio).
    reward: Balance<T>,
    /// Radice corrente, 32 byte. Vuota finché non se ne pubblica una.
    root: vector<u8>,
    /// Sale a ogni pubblicazione: serve a chi legge gli eventi per sapere
    /// quale radice stava guardando.
    root_epoch: u64,
    root_at_ms: u64,
    /// Ultimo segno di vita: una ricarica o una radice. È da qui che si contano
    /// i sei mesi di silenzio, non dall'ultima radice, se no un serbatoio
    /// caricato prima di pubblicare la prima radice resterebbe chiuso per
    /// sempre (trovato rileggendo il codice, vedi B-1 in AUDIT.md).
    last_activity_ms: u64,
    /// Somma dichiarata dentro la radice corrente. Insieme a `paid_total` è
    /// l'invariante che impedisce alla radice di promettere più di quanto c'è.
    declared_total: u64,
    /// Somma davvero uscita da `claim`.
    paid_total: u64,
    /// Cumulativo già ritirato, per indirizzo.
    claimed: Table<address, u64>,
    /// Tetto per singola chiamata di `claim`. Interruttore, non un limite al
    /// diritto: chi ha un credito più grande chiama due volte (vedi `claim`).
    max_per_claim: u64,
    claims_paused: bool,
}

public struct AdminCap has key, store { id: UID }

// ── Eventi ───────────────────────────────────────────────────────────────

public struct Funded has copy, drop { farm: address, from: address, amount: u64, pot: u64 }

public struct RootSet has copy, drop {
    farm: address,
    root_epoch: u64,
    root: vector<u8>,
    declared_total: u64,
    pot: u64,
    at_ms: u64,
}

public struct Claimed has copy, drop {
    farm: address,
    who: address,
    amount: u64,
    cumulative_paid: u64,
    root_epoch: u64,
}

public struct PausedSet has copy, drop { farm: address, paused: bool }

public struct LeftoverBurned has copy, drop { farm: address, amount: u64, idle_ms: u64 }

// ── Init ─────────────────────────────────────────────────────────────────

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Si crea una volta sola, a mano, subito dopo il publish.
///
/// `max_per_claim` parte da un valore prudente e si può muovere: è la velocità
/// massima con cui il serbatoio si può svuotare se pubblichiamo una radice
/// sbagliata, non una regola su quanto uno ha diritto di prendere.
public fun create<T>(_cap: &AdminCap, max_per_claim: u64, ctx: &mut TxContext) {
    // Zero non è un tetto prudente, è una pausa che non si chiama pausa: con
    // `max_per_claim = 0` ogni `claim` calcola `amount = 0` e aborta, quindi i
    // ritiri sarebbero fermi senza che `claims_paused` lo dica a nessuno.
    // Trovato al terzo giro (C-1).
    assert!(max_per_claim > 0, EZeroAmount);
    transfer::share_object(Farm<T> {
        id: object::new(ctx),
        version: VERSION,
        reward: balance::zero<T>(),
        root: vector[],
        root_epoch: 0,
        root_at_ms: 0,
        last_activity_ms: 0,
        declared_total: 0,
        paid_total: 0,
        claimed: table::new(ctx),
        max_per_claim,
        claims_paused: false,
    });
}

// ── Serbatoio ────────────────────────────────────────────────────────────

/// Permissionless di proposito. Il serbatoio lo ricarichiamo noi con le fee
/// riscosse dalla posizione bruciata, ma chiunque può aggiungerne: costa niente
/// e toglie ogni dubbio su chi controlla il rubinetto.
public fun fund<T>(farm: &mut Farm<T>, payment: Coin<T>, clock: &Clock, ctx: &TxContext) {
    assert!(farm.version == VERSION, EWrongVersion);
    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
    farm.reward.join(payment.into_balance());
    farm.last_activity_ms = clock::timestamp_ms(clock);
    event::emit(Funded {
        farm: farm.id.to_address(),
        from: ctx.sender(),
        amount,
        pot: farm.reward.value(),
    });
}

// ── Radice ───────────────────────────────────────────────────────────────

/// Pubblica la radice del giorno.
///
/// L'ASSERZIONE CHE CONTA è l'ultima: **la radice non può promettere più di
/// quello che il serbatoio contiene in questo momento.** Senza, i primi che
/// arrivano incassano e gli ultimi trovano il vuoto: non paghi tutti e sembri
/// insolvente, che è il modo peggiore di rompersi per una cosa che distribuisce
/// soldi.
///
/// `declared_total` è **cumulativo come le foglie**, quindi non può scendere
/// sotto quello che è già uscito: una radice del genere sarebbe un errore di
/// calcolo, e si ferma qui invece di propagarsi.
public fun set_root<T>(
    _cap: &AdminCap,
    farm: &mut Farm<T>,
    root: vector<u8>,
    declared_total: u64,
    clock: &Clock,
) {
    assert!(farm.version == VERSION, EWrongVersion);
    assert!(root.length() == HASH_LEN, EBadRoot);
    assert!(declared_total >= farm.paid_total, EBadRoot);
    // Quanto resta da pagare secondo questa radice, contro quello che c'è.
    assert!(declared_total - farm.paid_total <= farm.reward.value(), EPotTooSmall);

    farm.root = root;
    farm.declared_total = declared_total;
    farm.root_epoch = farm.root_epoch + 1;
    farm.root_at_ms = clock::timestamp_ms(clock);
    farm.last_activity_ms = farm.root_at_ms;

    event::emit(RootSet {
        farm: farm.id.to_address(),
        root_epoch: farm.root_epoch,
        root,
        declared_total,
        pot: farm.reward.value(),
        at_ms: farm.root_at_ms,
    });
}

// ── Ritiro ───────────────────────────────────────────────────────────────

/// Ritira quello che la radice corrente dichiara, meno quello già preso.
///
/// `cumulative` è il numero che sta nella foglia: il totale maturato da sempre.
/// Si paga la differenza, quindi chiamarla due volte di fila la seconda volta
/// non dà niente invece di pagare il doppio.
///
/// IL TETTO NON CHIUDE FUORI NESSUNO: se il dovuto supera `max_per_claim` si
/// paga il tetto e si aggiorna il cumulativo, così chi ha un credito grande
/// chiama di nuovo. Un tetto che facesse abortire trasformerebbe un
/// interruttore di emergenza in un modo per non pagare, ed è esattamente la
/// cosa che non deve poter fare.
///
/// Restituisce la coin invece di trasferirla, così si può comporre in una PTB
/// (per esempio ritiro più swap). Chi non ha bisogno di comporre usa
/// `claim_and_transfer`, che è la stessa cosa col trasferimento in fondo: una
/// PTB che si dimentica di spostare la coin non compila, ma meglio non
/// costringere nessuno a scoprirlo.
public fun claim<T>(
    farm: &mut Farm<T>,
    cumulative: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(farm.version == VERSION, EWrongVersion);
    assert!(!farm.claims_paused, EPaused);
    assert!(farm.root.length() == HASH_LEN, EBadRoot);

    let who = ctx.sender();
    let farm_addr = farm.id.to_address();
    assert!(verify(&farm.root, &proof, farm_addr, who, cumulative), EBadProof);

    let already = if (farm.claimed.contains(who)) *farm.claimed.borrow(who) else 0;
    assert!(cumulative > already, ENothingToClaim);

    let due = cumulative - already;
    let mut amount = if (due > farm.max_per_claim) farm.max_per_claim else due;
    // Il serbatoio è la verità finale: se `set_root` ha fatto il suo lavoro non
    // ci si arriva mai, ma non si paga comunque più di quello che c'è.
    let pot = farm.reward.value();
    if (amount > pot) amount = pot;
    assert!(amount > 0, ENothingToClaim);

    if (farm.claimed.contains(who)) {
        let slot = farm.claimed.borrow_mut(who);
        *slot = already + amount;
    } else {
        farm.claimed.add(who, amount);
    };
    farm.paid_total = farm.paid_total + amount;

    event::emit(Claimed {
        farm: farm_addr,
        who,
        amount,
        cumulative_paid: already + amount,
        root_epoch: farm.root_epoch,
    });

    coin::from_balance(farm.reward.split(amount), ctx)
}

/// Il percorso normale dalla pagina Farm: ritira e manda al chiamante.
///
/// Niente `entry`: una `public fun` si chiama già da una PTB, e `public entry`
/// insieme non aggiunge permessi (warning WSL01011 del linter).
///
/// Il linter segnala il trasferimento al mittente perché toglie componibilità.
/// Qui è voluto e non toglie niente a nessuno: la versione componibile è
/// `claim`, che la coin la restituisce. Questa è solo la comodità per il tasto
/// Collect, dove la PTB ha un comando solo.
#[allow(lint(self_transfer))]
public fun claim_and_transfer<T>(
    farm: &mut Farm<T>,
    cumulative: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    let coin = claim(farm, cumulative, proof, ctx);
    transfer::public_transfer(coin, ctx.sender());
}

// ── Albero ───────────────────────────────────────────────────────────────

/// Foglia: `blake2b256(0x00 || farm_id || indirizzo || cumulativo)`.
///
/// `farm_id` dentro la foglia impedisce di riusare su questo oggetto una radice
/// costruita per un altro (per esempio quello di testnet, dove i numeri sono
/// finti e li scriviamo a mano).
public fun leaf_hash(farm_id: address, who: address, cumulative: u64): vector<u8> {
    let mut bytes = vector[LEAF_TAG];
    bytes.append(bcs::to_bytes(&farm_id));
    bytes.append(bcs::to_bytes(&who));
    bytes.append(bcs::to_bytes(&cumulative));
    hash::blake2b256(&bytes)
}

/// Nodo: `blake2b256(0x01 || min(a,b) || max(a,b))`.
///
/// La coppia si ordina, così la prova non deve dire da che lato stava il
/// fratello; e il byte davanti separa i nodi dalle foglie (vedi `LEAF_TAG`).
fun node_hash(a: &vector<u8>, b: &vector<u8>): vector<u8> {
    let mut bytes = vector[NODE_TAG];
    if (lte(a, b)) {
        bytes.append(*a);
        bytes.append(*b);
    } else {
        bytes.append(*b);
        bytes.append(*a);
    };
    hash::blake2b256(&bytes)
}

/// Confronto lessicografico fra due hash della stessa lunghezza.
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

/// La prova arriva da fuori, quindi ogni elemento va misurato prima di usarlo:
/// un elemento più corto farebbe leggere `lte` fuori dai suoi byte e la
/// transazione morirebbe con un errore che non dice niente. Meglio `EBadProof`,
/// che è anche la verità.
public fun verify(
    root: &vector<u8>,
    proof: &vector<vector<u8>>,
    farm_id: address,
    who: address,
    cumulative: u64,
): bool {
    let n = proof.length();
    let mut i = 0;
    while (i < n) {
        if (proof.borrow(i).length() != HASH_LEN) return false;
        i = i + 1;
    };

    let mut acc = leaf_hash(farm_id, who, cumulative);
    i = 0;
    while (i < n) {
        acc = node_hash(&acc, proof.borrow(i));
        i = i + 1;
    };
    acc == *root
}

// ── Manutenzione ─────────────────────────────────────────────────────────

/// Ferma **solo** i ritiri, e non ferma la maturazione, che è fuori dalla
/// catena: nessuno perde quello che ha guadagnato mentre siamo in pausa. Serve
/// a una cosa sola, guadagnare il tempo di correggere una radice sbagliata
/// prima che esca altro denaro.
public fun set_paused<T>(_cap: &AdminCap, farm: &mut Farm<T>, paused: bool) {
    assert!(farm.version == VERSION, EWrongVersion);
    farm.claims_paused = paused;
    event::emit(PausedSet { farm: farm.id.to_address(), paused });
}

public fun set_max_per_claim<T>(_cap: &AdminCap, farm: &mut Farm<T>, max_per_claim: u64) {
    assert!(farm.version == VERSION, EWrongVersion);
    // Vedi `create`: a zero i ritiri si fermano senza dirlo. Per fermarli c'è
    // `set_paused`, che emette un evento ed è una cosa che si vede.
    assert!(max_per_claim > 0, EZeroAmount);
    farm.max_per_claim = max_per_claim;
}

/// Il residuo, dopo sei mesi senza segni di vita, va a `0x0`. Chiamabile da
/// **chiunque**: se il programma è finito non deve servire la nostra firma per
/// chiudere il cerchio, e noi non possiamo comunque riprenderci quei soldi.
///
/// **BRUCIA SOLO QUELLO CHE NON E' STATO PROMESSO A NESSUNO** (terzo giro di
/// audit, C-2). Prima portava via tutto il serbatoio, e questo rendeva vere due
/// cose che non possono stare insieme: "quello che hai maturato resta ritirabile
/// per sempre" e "dopo sei mesi chiunque può bruciare il residuo". Chi era stato
/// via sette mesi si trovava il suo credito sparito **per mano di un estraneo**,
/// e la farm restava pure insolvente verso la radice corrente.
///
/// Quello che una radice ha promesso e non è ancora uscito è
/// `declared_total - paid_total`: quella parte non si tocca, e resta lì
/// finché qualcuno la ritira, anche fra dieci anni. Si brucia il resto.
///
/// Onestà sulla parola "bruciato", la stessa già scritta altrove: mandare a
/// `0x0` rende i token irrecuperabili, non riduce la supply sul contratto del
/// token.
public fun burn_leftover<T>(farm: &mut Farm<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(farm.version == VERSION, EWrongVersion);
    let now = clock::timestamp_ms(clock);
    assert!(farm.last_activity_ms > 0, ETooEarlyToBurn);
    assert!(now >= farm.last_activity_ms + BURN_AFTER_MS, ETooEarlyToBurn);

    let outstanding = farm.declared_total - farm.paid_total;
    let pot = farm.reward.value();
    assert!(pot > outstanding, EZeroAmount);
    let amount = pot - outstanding;
    let coin = coin::from_balance(farm.reward.split(amount), ctx);
    transfer::public_transfer(coin, @0x0);
    event::emit(LeftoverBurned {
        farm: farm.id.to_address(),
        amount,
        idle_ms: now - farm.last_activity_ms,
    });
}

/// La lezione di `epoch-templates`, dove la mancanza di `migrate` avrebbe
/// bloccato per sempre la funzione protetta al primo upgrade che alzasse
/// `VERSION`, mentre quelle non protette continuavano a girare. Qui il rischio
/// speculare sarebbe: `claim` bloccato e serbatoio irraggiungibile.
public fun migrate<T>(_cap: &AdminCap, farm: &mut Farm<T>) {
    assert!(farm.version < VERSION, ENotUpgrade);
    farm.version = VERSION;
}

// ── Letture ──────────────────────────────────────────────────────────────

public fun pot<T>(farm: &Farm<T>): u64 { farm.reward.value() }
public fun root<T>(farm: &Farm<T>): vector<u8> { farm.root }
public fun root_epoch<T>(farm: &Farm<T>): u64 { farm.root_epoch }
public fun root_at_ms<T>(farm: &Farm<T>): u64 { farm.root_at_ms }
public fun last_activity_ms<T>(farm: &Farm<T>): u64 { farm.last_activity_ms }
public fun declared_total<T>(farm: &Farm<T>): u64 { farm.declared_total }
public fun paid_total<T>(farm: &Farm<T>): u64 { farm.paid_total }
/// Quello che la radice corrente ha promesso e non è ancora uscito. È la parte
/// del serbatoio che `burn_leftover` non può toccare.
public fun outstanding<T>(farm: &Farm<T>): u64 { farm.declared_total - farm.paid_total }
public fun max_per_claim<T>(farm: &Farm<T>): u64 { farm.max_per_claim }
public fun is_paused<T>(farm: &Farm<T>): bool { farm.claims_paused }
public fun claimed_of<T>(farm: &Farm<T>, who: address): u64 {
    if (farm.claimed.contains(who)) *farm.claimed.borrow(who) else 0
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// I test devono poter costruire un albero vero, non solo una foglia sola,
/// altrimenti la parte che verifica le prove non la prova nessuno.
#[test_only]
public fun node_hash_for_testing(a: &vector<u8>, b: &vector<u8>): vector<u8> {
    node_hash(a, b)
}
