# Epoch Farm, specifica

Stato: **progetto, nessuna riga di Move scritta.** Scritta il 17 set 2026, dopo lo
scambio con Amy di Cetus (gli incentivi di pool loro richiedono una liquidità che
EPT non ha ancora) e dopo aver letto come è fatta la loro farm, on chain e non per
sentito dire.

---

## 1. Cosa fa, e soprattutto cosa non fa

Distribuisce EPT a chi fornisce liquidità alla pool EPT/SUI su Cetus, in proporzione
al capitale utile tenuto nel tempo.

**Non tocca la liquidità di nessuno.** Non c'è deposito, non c'è staking, non c'è
approvazione da firmare. La position resta nel wallet del suo proprietario, su Cetus,
e lui la chiude, la sposta o la ribilancia quando gli pare senza dircelo. Il contratto
tiene **solo EPT nostro** ed espone una funzione per ritirare.

Conseguenza da tenere in mente in tutte le decisioni che seguono: **nel caso peggiore,
cioè un bug nostro, l'unico denaro a rischio è il nostro.** È la ragione per cui questa
architettura è stata scelta al posto di quella di Cetus, che invece prende la position
in custodia.

Seconda conseguenza, meno comoda: non avendo la custodia non possiamo nemmeno
**correggere un pagamento sbagliato**. Quello che esce è uscito. Da lì vengono le
ventiquattr'ore di attesa, il tetto per indirizzo e la pausa di emergenza.

### Non è un obiettivo

- Aumentare il volume. Questa farm compra **TVL**, non scambi. Serve a superare la
  soglia di liquidità che Cetus chiede per aprire i suoi incentivi, che sono soldi
  loro. Il volume lo portano i prodotti pagati in EPT (ogni registrazione e ogni
  vault pagati in EPT fanno un acquisto sul mercato dentro la PTB), non questa pagina.
- Promettere un rendimento. Vedi §7.

---

## 2. Perché non copiamo la farm di Cetus

Letto on chain il 17 set 2026, package `stable_farming` v10
`0xb5d821af5d3d4d40f1f1890502d73e3d7f61edb75e664ff8e827fa01a006f39f`
(moduli `acl`, `config`, `pool`, `rewarder`, `router`):

- `deposit` prende la `Position` **per valore** e restituisce un `WrappedPositionNFT`:
  mentre farmi, l'LP non è più nel tuo wallet. La farm espone `collect_fee`,
  `collect_clmm_reward`, `add_liquidity`, `remove_liquidity`, `close_position` per
  restituirti quello che il wrapper ti toglie.
- `update_effective_tick_range` (solo operatore) fissa una **finestra valida**;
  `calculate_position_share(tick_lower, tick_upper, liquidity, sqrt_price,
  eff_lower, eff_upper) -> u128` calcola il peso, e prende **il prezzo corrente**.
- Dai loro esempi pubblici: 100 dollari su [0,9-1,1] e 100 dollari su [0,95-1,05]
  pesano **uguale**, e una posizione per metà fuori dalla finestra conta metà. Quindi
  il peso è il **capitale dentro la finestra**, non la liquidità grezza `L`. È la
  risposta giusta al trucco della banda da un tick: una banda sottilissima ha una `L`
  enorme per pochi dollari, e chi paga per `L` regala tutto a chi non fa da controparte
  a nessuno scambio.
- `withdraw` fallisce se non hai prima fatto `harvest` (errore 4), così non restano
  premi orfani in contabilità.

Di tutto questo **prendiamo la finestra valida e il peso per capitale**, e lasciamo la
custodia. Il prezzo che paghiamo è che il nostro contratto non può maturare da solo:
il punteggio lo calcola un worker fuori dalla catena, e il contratto si limita a pagare
quello che una radice firmata dichiara.

---

## 3. Architettura

```
worker (cron)  →  fotografa la pool a orari imprevedibili
               →  calcola il punteggio di ogni indirizzo
               →  una volta al giorno costruisce l'albero e pubblica la radice
contratto      →  tiene EPT, verifica la prova, paga la differenza
pagina Farm    →  mostra posizioni, maturato, ritirabile, tasto Collect
```

### 3.1 Radice **cumulativa**, non per round

La foglia è `(indirizzo, totale maturato da sempre)`, non `(indirizzo, premio di oggi)`.
`claim` paga `cumulativo - già_ritirato`.

Non è un dettaglio implementativo, risolve tre problemi in un colpo: chi non ritira per
tre settimane prende tutto insieme con una transazione sola; non serve tenere una mappa
di bit per ogni round; e **una radice sbagliata si corregge con la successiva**, purché
nessuno abbia già ritirato il numero gonfiato.

---

## 4. Il contratto (`epoch_farm::farm`)

```move
struct Farm has key {                 // shared
    id: UID,
    version: u64,
    reward: Balance<EPT>,             // il serbatoio
    root: vector<u8>,                 // radice corrente (32 byte)
    root_epoch: u64,                  // sale a ogni pubblicazione
    root_at_ms: u64,                  // quando è stata pubblicata
    declared_total: u64,              // somma dichiarata dentro la radice
    paid_total: u64,                  // somma davvero uscita
    claimed: Table<address, u64>,     // cumulativo già ritirato per indirizzo
    max_per_claim: u64,               // interruttore, vedi A-4
    claims_paused: bool,
}
struct AdminCap has key, store { id: UID }
```

### 4.1 Funzioni

| funzione | chi | cosa fa |
|---|---|---|
| `fund(farm, Coin<EPT>)` | **chiunque** | versa nel serbatoio, emette `Funded` |
| `set_root(&AdminCap, farm, root, declared_total, &Clock)` | noi | pubblica la radice, `root_epoch += 1` |
| `claim(farm, cumulative, proof, ctx)` | il beneficiario | paga `cumulative - claimed[sender]` |
| `set_paused(&AdminCap, farm, bool)` | noi | ferma **solo** i ritiri |
| `set_max_per_claim(&AdminCap, farm, u64)` | noi | alza o abbassa l'interruttore |
| `burn_leftover(farm, &Clock)` | **chiunque** | manda a `0x0` **solo la parte mai promessa**, dopo 180 giorni senza segni di vita |
| `migrate(&AdminCap, farm)` | noi | version gating, la lezione di `epoch-templates` |

**Non esiste un prelievo.** L'admin non può togliere EPT dal serbatoio, mai. Chiudere
il programma vuol dire smettere di pubblicare radici. Una funzione di prelievo
renderebbe la frase "questi premi sono vostri" un annuncio invece che una proprietà,
ed è lo stesso ragionamento della cassa del burn in `epoch-templates`.

**Due frasi che sembravano compatibili e non lo erano** (terzo giro di audit, C-2):
"quello che hai maturato resta ritirabile per sempre" e "dopo sei mesi chiunque può
bruciare il residuo". Nella prima stesura `burn_leftover` portava via **tutto**, quindi
un estraneo poteva cancellare il credito di chi era stato via sette mesi. Ora brucia
**solo la parte che nessuna radice ha promesso** (`pot - (declared_total - paid_total)`):
il promesso resta lì finché non lo ritira il suo, anche fra anni, e la farm non può
diventare insolvente verso la propria radice.

### 4.2 Errori

```
0 EWrongVersion      1 EPaused           2 ENothingToClaim
3 EBadProof          4 EPotTooSmall      5 ETooEarlyToBurn
6 ENotUpgrade        7 EBadRoot          8 EZeroAmount
```

---

## 5. Il punteggio

### 5.1 Finestra valida

Da **metà prezzo a prezzo doppio** rispetto al momento in cui la si apre. Al 17 set
2026, con EPT a 0,0001236 dollari, la finestra parte da circa **0,0000618** a
**0,0002472** dollari per EPT. Si sposta quando il prezzo esce e ci resta fuori,
annunciandolo prima: spostarla cambia i pesi di tutti, quindi non si fa di nascosto.

Conta solo il capitale **dentro la finestra**. Fuori vale zero.

### 5.2 Peso, e perché non al prezzo corrente

Per ogni posizione si calcolano gli importi delle due monete nella parte di range che
sta **dentro la finestra**, e si valorizzano in SUI.

La differenza rispetto a Cetus: loro usano il **prezzo corrente**, noi usiamo il
**prezzo di riferimento della finestra** (il suo centro geometrico), fisso finché la
finestra non si sposta. Motivo, ed è una nostra decisione consapevole: con 25.000
dollari di TVL spostare il prezzo dentro la propria transazione costa poche centinaia
di dollari, e un peso calcolato sullo spot si gonfia di conseguenza. Su pool da milioni
l'attacco non si ripaga, sulla nostra sì.

### 5.3 Tempo

Il punteggio è `peso × tempo`. Gli snapshot si prendono a intervalli **irregolari e non
annunciati**; chi c'è un'ora su ventiquattro matura un ventiquattresimo di giornata.

### 5.4 Consolidamento giornaliero

Quello che matura durante il giorno resta **in maturazione**. Diventa ritirabile nella
radice di fine giornata, e **solo se in quel momento quell'indirizzo ha ancora una
posizione valida dentro la finestra**. Chi è uscito prima perde la giornata, e quell'EPT
resta nel serbatoio, quindi torna agli altri nei giorni successivi.

Il controllo di presenza è **sull'indirizzo, non sull'id della posizione**: chi
ribilancia chiude una position e ne apre un'altra con un id nuovo, e punirlo vorrebbe
dire punire proprio chi gestisce bene la sua liquidità.

### 5.5 Chi non matura

- I nostri wallet: admin `0x9ed3b9ca…` e secondario `0x4ac24849…`. Senza questa riga ci
  paghiamo da soli col nostro serbatoio.
- La posizione bruciata `0xeb5d2a04…` è dentro il burn proof e non è di nessun wallet,
  quindi è esclusa da sola. Resta scritto qui perché "è escluso da solo" è il genere di
  cosa che smette di essere vera dopo un upgrade di qualcun altro.
- Sotto una soglia minima di capitale non si matura, per non riempire l'albero di
  polvere: i costi di gas li paghiamo noi a ogni radice.

---

## 6. Il serbatoio

Si ricarica **man mano che riscuotiamo le fee** della posizione bruciata
(`lp_burn::collect_fee` sul burn proof `0xeb5d2a04…`), e chiunque può aggiungerne
(`fund` è permissionless, noi compresi).

Numeri veri del 17 set 2026, perché la dimensione cambia il tono di tutto quello che
si annuncia: pool EPT/SUI da **25.565 dollari** di TVL, **3.558 dollari** di volume
nelle 24 ore, fee dell'**1%**, quindi circa **36 dollari al giorno** a tutti gli LP. La
nostra posizione bruciata è full range e vale circa metà della liquidità della pool,
quindi la nostra parte è **circa 125 dollari a settimana**, lato EPT più lato SUI.

Due cose che quei numeri impongono:

1. **Non è una campagna, è una condivisione.** Diviso fra dieci fornitori sono dodici
   dollari a testa a settimana. Va detto così, e va detto prima.
2. **Il montepremi si rimpicciolisce proprio quando il programma funziona.** Le fee che
   incassiamo sono proporzionali alla nostra fetta di liquidità: se arrivano altri 25k
   di TVL e il volume resta fermo, la nostra fetta si dimezza e le persone da pagare
   raddoppiano. Il giro si chiude solo se il volume cresce più in fretta della TVL: con
   la fee all'1%, a TVL doppia serve volume doppio per tenere lo stesso montepremi.

---

## 7. Cosa si scrive sulla pagina, e cosa no

**No:** un APR. Il tasso dipende da quanti entrano e crolla appena arrivano; un numero
che scende del 75% nella settimana in cui la gente si presenta è il modo classico di
farsi accusare di aver mentito.

**Sì:**

- il serbatoio adesso, e ogni ricarica con la sua transazione;
- due numeri distinti per ogni utente, **In maturazione** (sale in continuo) e
  **Ritirabile** (si aggiorna al consolidamento), col tasto Collect che tocca solo il
  secondo;
- per ogni posizione, quanta parte è dentro la finestra, in percentuale, calcolata sulla
  sua, non in generale;
- la scelta della forma, detta per intero: **concentrata dentro la finestra** prende il
  massimo dei premi e il massimo delle fee finché il prezzo resta lì, e smette di
  guadagnare appena esce; **full range** non esce mai dal mercato e incassa fee per
  sempre, ma della finestra ne occupa solo una fetta (con la finestra da metà a doppio,
  circa il **29%** del suo capitale), quindi prende meno premi;
- che fornire liquidità **ha un rischio suo**, indipendente da noi: se EPT scende, chi è
  in pool si ritrova con più EPT e meno SUI di quanti ne ha messi. Sopra il tasto, non
  in fondo alla pagina;
- che **i punteggi li calcoliamo noi**, con la formula pubblicata e gli snapshot
  scaricabili, così chiunque può rifare il conto e confrontarlo con la radice;
- che possiamo **fermare i ritiri** in emergenza, e che è l'unico potere che ci teniamo.

Il moltiplicatore per chi blocca l'LP da noi **non entra nella v1**. Quando entrerà non
servirà un upgrade del contratto, perché il punteggio lo calcola il worker e i lock si
leggono già on chain: sarà un bonus aggiunto, non una regola cambiata in corsa.

---

## 8. Lavoro

1. `AUDIT.md`: i buchi, prima del codice. **Fatto, vedi file accanto.**
2. Move: `sources/farm.move` più `tests/farm_tests.move`. **Scritto il 17 set 2026**,
   con il secondo giro di audit già fatto sul codice (B-1, il serbatoio che si poteva
   chiudere per sempre, è uscito da lì). **Da compilare e testare sul Mac**, perché nel
   sandbox il binario `sui` non c'è: `sui move build` e `sui move test`.
3. Worker: snapshot su Supabase (`farm_snapshots`, `farm_scores`), consolidamento,
   costruzione dell'albero, `set_root`.
4. Pagina `/farm` sul frontend vesting: posizioni, i due numeri, Collect, la finestra
   disegnata sul range di ognuno.
5. Collaudo: prima su testnet con una pool finta, poi mainnet con un serbatoio piccolo e
   un solo partecipante che non siamo noi.
