# epoch-templates, audit interno

Due giri di revisione, 14 set 2026. Il modulo tiene soldi di altri (l'autore
incassa nella stessa transazione, la fee resta al protocollo), quindi vale la
regola degli altri package: quello che non è dimostrato va scritto, non
sottinteso.

**Non compilato nel sandbox**: qui dentro non c'è il binario `sui`. Prima di
pubblicare, sul Mac:

```bash
cd epoch-templates
sui move build
sui move test
```

---

## Cosa fa il modulo, in una riga

Vende copie di un template: 97% all'autore subito, 1,5% a noi, 1,5% in una cassa
che ha **una sola uscita**, `swap_and_burn`, che compra EPT e lo manda a `0x0`.

---

## SECONDO GIRO: tre cose gravi trovate e corrette

Il primo giro aveva lasciato passare un rug dell'admin, una trappola a scoppio
ritardato e una perdita di denaro per chi compra una `AuthorCap`. Sono le tre
cose più importanti di questo documento.

### 1. `set_burn_config` era la porta di servizio della cassa (CRITICA, corretta)
Il modulo prometteva "nemmeno l'admin può toccare la cassa del burn". Era falso:
`set_burn_config` si poteva richiamare quante volte si voleva e accettava
qualsiasi coppia (tipo di coin, pool). Un admin poteva coniare una coin
qualunque, aprire una pool Cetus in cui era l'unico fornitore di liquidità,
puntarci il burn e chiamare `swap_and_burn`: i SUI della cassa finivano nella sua
pool, la coin finta andava a `0x0`, **l'evento diceva "bruciato"**, e lui
richiudeva la position riprendendosi tutto. Il controllo su tipo e pool non
difendeva da niente, perché era lui a scrivere quei due valori.

Correzione: **la configurazione si scrive una volta sola** (`EAlreadyConfigured`).
Dopo la prima chiamata nessuno può far comprare altrove.
Conseguenza accettata e scritta nel codice: se un giorno quella pool muore, la
cassa resta ferma finché non si pubblica un upgrade. Un upgrade è pubblico e
lascia una transazione leggibile, ed è il punto: un cambio del genere deve
costare visibilità.

### 2. Mancava `migrate`: il primo upgrade avrebbe bloccato il burn per sempre (ALTA, corretta)
`VERSION` era controllata in tre funzioni ma niente poteva scrivere
`reg.version`. Il giorno di un upgrade che alza la costante, il Registry
condiviso avrebbe continuato a portare il numero vecchio e ogni funzione gated
sarebbe abortita: vendite ferme e, peggio, `swap_and_burn` ferma per sempre, cioè
la cassa del burn irrecuperabile **per chiunque**. Mentre `withdraw_revenue`, che
il controllo non ce l'aveva, avrebbe continuato a funzionare: nell'unico scenario
di rottura l'admin recuperava la sua quota e il burn moriva. Il contrario esatto
della promessa.

Non serviva un attaccante: bastava fare un upgrade.

Correzione: `migrate(cap, reg)`, e il controllo di versione messo **anche** su
`set_fee`, `set_burn_config` e `withdraw_revenue`, così non c'è più metà modulo
gated e metà no.

### 3. L'`AuthorCap` si vendeva, ma l'incasso restava al primo autore (ALTA, corretta)
Il commento diceva "un template si può vendere come attività" e `set_price`
ubbidiva alla cap, ma il 97% continuava ad andare a `t.author`, scritto una volta
sola alla creazione e mai più modificabile. Chi comprava una cap credendo al
commento comprava il diritto di cambiare il prezzo di un template i cui incassi
restavano a qualcun altro, per sempre.

Correzione: `set_author(cap, t, new_author)` con evento `AuthorChanged`, così
l'incasso segue la cap. L'evento serve a chi sta per comprare: deve poter vedere
che il beneficiario è cambiato un attimo prima.

---

## Altre correzioni del secondo giro

- **Lo slippage confrontava mele e pere.** `expected` era calcolato sullo spot
  **al lordo** della commissione della pool, `got` arriva al netto: su un tier
  alto ogni burn sarebbe abortito per sempre. Ora la commissione si sconta prima
  (`pool::fee_rate`), quindi `MAX_SLIPPAGE_BPS` misura l'impatto e non un
  miscuglio. **Da controllare prima del publish: il `fee_rate` della pool
  `0x298ef34a…`**, altrimenti il primo `swap_and_burn` risponde `ESlippage` e non
  si capisce perché.
- **`expected == 0` spegneva la guardia.** Con un prezzo estremo il pavimento
  diventava zero e lo swap sarebbe passato comunque, svuotando la cassa per
  niente. Ora aborta.
- **`min_out` dal chiamante**, che può solo **stringere** la soglia: il calcolo
  interno resta come pavimento. Chi brucia può usare un prezzo di riferimento
  esterno, e chi passasse 0 sperando in uno swap truccato non ottiene niente.
- **`list_template` non scrive più sul Registry.** Prendeva `&mut` solo per
  incrementare un contatore, e così ogni listing si metteva in coda sullo stesso
  oggetto condiviso di ogni acquisto: chiunque, al costo del gas, poteva inondare
  di listing e far ritardare gli acquisti. Ora prende `&Registry` e il contatore
  non c'è più (quanti template esistono si conta dagli eventi).
- **Le licenze si possono buttare** (`burn_license`). Senza `store` non si
  trasferiscono, che è voluto, ma senza una delete sarebbero rimaste a occupare
  storage per sempre nel wallet di chi non le vuole più.
- **Tetti su stringhe e prezzo.** `template_id` e `digest` finiscono copiati
  dentro **ogni** licenza e **ogni** evento: senza tetto un autore poteva far
  pagare a ogni compratore lo storage di una stringa da decine di KB. Ora 64
  caratteri, e il `digest` deve essere lungo esattamente quanto uno sha256 in
  esadecimale, così "l'oggetto è legato a quei byte" diventa una proprietà del
  contratto e non una convenzione del frontend. `MAX_PRICE` tiene
  `price * fee_bps` dentro un u64 con margine largo.
- **`expected_digest` in `buy_template`.** Non ferma un impostore che copia anche
  il digest (quello si chiude fuori, vedi sotto), ma ferma il caso molto più
  probabile: un link o un frontend che punta all'oggetto sbagliato, e un template
  modificato fra quando è stato guardato e quando è stato comprato.
- **La polvere dentro la fee ora va al burn**, non a noi. Se la frase pubblica è
  "metà si brucia", l'arrotondamento deve pendere da quella parte. (La polvere
  della fee nel suo complesso continua a restare all'autore.)
- **Le mosse dell'admin emettono eventi** (`FeeChanged`, `BurnConfigSet`,
  `RevenueWithdrawn`): prima un cambio di configurazione non lasciava traccia
  leggibile da un indicizzatore, solo dentro il corpo della transazione.

---

## Scelte prese di proposito

### Il burn non sta dentro `buy_template`
Sarebbe una riga più bella da raccontare, ma legherebbe ogni vendita alla pool
Cetus. Su questo progetto è già successo che una funzione Cetus abortisse su
mainnet mentre passava su testnet (`get_position_amounts`, v14, finding 13 di
lp-lock): con lo swap nel percorso critico, quel giorno il negozio chiudeva.
Quindi la vendita accumula e il burn è separato e **permissionless**.

### La cassa del burn non ha una `withdraw`
Non è dimenticanza. `withdraw_revenue` esiste solo per `revenue`. Per `burn_pot`
non esiste nessuna funzione che la sposti se non `swap_and_burn`, e dopo la
correzione 1 nemmeno l'admin può cambiare dove quello swap compra. Un test lo
inchioda (`il_prelievo_prende_solo_la_nostra_quota`).

### `BURN_SHARE_BPS` è una costante, non una configurazione
Se fosse un campo modificabile dall'admin, "metà della fee la bruciamo" sarebbe
una dichiarazione di intenti e non una proprietà del contratto.

### `FEE_BPS_MAX` è un tetto, non un valore
`set_fee` può solo scendere. Alzare oltre il 3% richiede un upgrade pubblico.

### `License` ha `key` e non `store`
Non si trasferisce, non entra in un kiosk, non si rivende. Si vendono copie, non
posti in fila. **Conseguenza da ricordare**: un oggetto senza `store` una PTB non
può spostarlo, quindi `buy_template` non lo restituisce, lo consegna. Una firma
che restituisce una `License` sarebbe elegante e non chiamabile da fuori.

### La polvere della fee resta all'autore
`fee` è una divisione per difetto e il resto va a chi ha fatto il lavoro. La somma
delle tre quote fa sempre il prezzo esatto: nessun MIST orfano nel contratto.
Provato su 101 MIST, che è il caso scomodo.

---

## Non corretto, e lo sa chi legge

### A. Il controllo di slippage non ferma un sandwich
`min_out` interno si calcola dallo spot letto **nella stessa transazione**, e la
funzione è permissionless con `amount` scelto dal chiamante: un attaccante mette
in **una sola transazione** lo spostamento del prezzo, la chiamata e l'unwind.
Non corre nessun rischio di esecuzione, il suo costo è la commissione del giro più
il gas.

Quindi la frase giusta non è "l'attacco costa più di quanto rende", è **"il
bottino è piccolo"**: la cassa è l'1,5% di vendite di template. Le difese vere
sono due e sono già lì: `amount` per spezzare il burn, e `min_out` dal chiamante
per usare un prezzo di riferimento esterno. **Se un giorno quella cassa diventa
grossa, questa funzione va rifatta** con un oracolo o un TWAP.

### B. Il prezzo lo dichiara chi ha interesse a dichiararlo basso
Il 3% si applica a quello che è scritto on chain, e a scriverlo è l'autore. Può
listare a 1 MIST e farsi pagare fuori, oppure, se tiene la cap su un secondo
indirizzo, costruire una sola transazione che fa `set_price(1) → buy → set_price(reale)`
e consegnare una licenza valida con fee quasi zero. `EAuthorCannotBuy` non lo
ferma, perché confronta il mittente con `t.author` e la cap può stare altrove.

Non si chiude in Move senza rendere il prezzo immutabile, che sarebbe peggio. Va
guardato dall'indicizzatore: un Template il cui prezzo scende e risale nella
stessa transazione, o nello stesso minuto, è un segnale.

### C. Chiunque può creare un `Template` con il `template_id` di un altro
Il contratto non sa chi è il vero autore di un pacchetto su Walrus: `template_id`
e `digest` sono stringhe scelte dal chiamante.

**Non si chiude in Move, si chiude fuori.** Fatto il 14 set 2026, e scritto qui
com'è finito davvero, perché in due punti è diverso da come era stato previsto.

1. La riga su Supabase tiene gli oggetti di vendita, e a scriverli è **solo
   l'autore della riga**, con la sua firma (`POST /template/:id/sale`).
   **È una lista, non un id solo**: il contratto inchioda il `digest` alla
   creazione del `Template`, quindi riscrivere il pacchetto obbliga a rilistare,
   e chi aveva comprato ieri ha una licenza verso l'oggetto vecchio. Con un
   campo solo, rilistare avrebbe chiuso fuori chi aveva pagato.
   Regola che ne consegue e che il worker applica: **un solo annuncio aperto per
   volta**. Registrarne uno nuovo mentre il precedente è ancora `for_sale`
   viene rifiutato, altrimenti resterebbe comprabile il prezzo di ieri (o il
   pacchetto di ieri) da chi passa dal link vecchio.
2. I **tre controlli stanno alla registrazione, non alla consegna della
   chiave**, ed è il punto in cui il piano iniziale era sbagliato. Alla
   registrazione si pretende: tipo del nostro package, `template_id` uguale a
   quello della riga, `author` uguale a chi sta firmando, `digest` uguale a
   quello dei byte conservati. Alla consegna si pretende solo che la `License`
   punti a un oggetto **in quella lista**. Motivo: due di quelle tre cose
   cambiano per motivi leciti (`set_author` sposta l'incasso, un rilisting
   cambia l'oggetto e il digest), e ricontrollarle alla consegna vorrebbe dire
   chiudere fuori chi ha pagato. Si è severi dove nulla può ancora essere
   derivato, non dove l'unico effetto è negare una cosa comprata.
3. Il frontend costruisce il Buy dall'oggetto registrato, mai cercando per
   `template_id`.

Due conseguenze scoperte scrivendo il worker, e chiuse lì:
- **"a pagamento" non è `price_mist > 0`**, è `price_mist > 0` **oppure** avere
  un oggetto di vendita. Con la sola prima condizione, l'autore che si toglie dal
  mercato (prezzo che torna a zero sulla riga) avrebbe regalato a chiunque la
  chiave di un template che altri hanno pagato.
- **il prezzo si dichiara alla pubblicazione**, prima che l'oggetto esista.
  Così, se la transazione di listing fallisce, il template resta "con un prezzo
  ma non in vendita" (402) invece di restare protetto e gratis per chiunque lo
  chieda. Un prezzo si accetta solo su un pacchetto cifrato.

Limite noto, non un buco: la `AuthorCap` si vende, ma la riga del catalogo resta
intestata a chi l'ha pubblicata, quindi chi compra la cap incassa le vendite e
non può ancora cambiare prezzo dalla vetrina né modificare la scheda. Serve un
passaggio di consegne firmato dal vecchio autore, e non c'è.

E una regola per il futuro: **l'indicizzatore non deve creare righe di catalogo
dall'evento `TemplateListed`**. Quell'evento porta stringhe scelte da chiunque, e
"ingest dagli eventi, così il catalogo è trustless" sarebbe la porta aperta.

### C-bis. Il contatore delle vendite si può gonfiare, e costa solo gas
Trovato mentre si rileggevano le correzioni del secondo giro, quindi è un buco
**aperto proprio da una di esse**. Ora che `set_author` esiste, un autore può
spostare l'incasso su un secondo indirizzo suo e comprare il proprio template
dal primo (`EAuthorCannotBuy` confronta il mittente con `t.author`, che nel
frattempo è cambiato). E siccome il prezzo lo decide lui, può metterlo a 1 MIST:
a quel punto `fee = 1 * 300 / 10000 = 0`, quindi ogni finta vendita **non paga
nemmeno la fee**, solo il gas.

Non si chiude in Move senza rompere cose sane (un prezzo minimo non serve: la
fee su cifre piccole è comunque zero per arrotondamento, e vietare il cambio di
autore toglie la possibilità legittima di vendere un template).

Si chiude in vetrina, ed è una regola per il frontend e per l'indicizzatore:
**`sold` non è un segnale di popolarità**. Quello che vale è il numero di
**compratori distinti** (indirizzi diversi negli eventi `TemplateSold`) e il
**volume in SUI**, che non si gonfia a costo zero perché passa dal wallet. Se un
giorno si ordina il catalogo "per più installati", va ordinato su quelli.

### C-ter. Le recensioni ereditano il finding C, e la cura è la stessa
`add_review` è nata nella v2 (14 set 2026) e non ha bisogno di nessun `assert`
per la parte difficile: vuole una `License` per riferimento, e in una PTB un
oggetto posseduto lo può mettere solo il suo proprietario. Quindi "recensisce
solo chi ha comprato" lo garantisce la catena.

Quello che la catena **non** garantisce è **cosa** si sta recensendo, ed è
esattamente il finding C visto dall'altra parte: chiunque può listare un
`Template` che dichiara il `template_id` di un altro, comprarselo da sé, e da
quel momento ha una licenza legittima verso un oggetto che parla di una riga non
sua. Con l'evento preso per buono, un'assicurazione da una stella a testa
costerebbe il gas e nient'altro, e colpirebbe il catalogo di un altro.

Non si chiude in Move (il contratto non sa chi ha scritto un blob su Walrus) e
non ha senso provarci. Si chiude dove è già chiusa la consegna della chiave:
**l'indicizzatore accetta un `ReviewPosted` solo se il campo `template` è fra i
`sale_objects` registrati su quella riga**, cioè fra gli oggetti che l'autore ha
collegato con la sua firma. Una recensione scartata **non ferma il cursore**:
l'evento resta on chain, semplicemente non è di quel template.

Conseguenza voluta: un template gratuito non ha licenze, quindi non ha
recensioni. È coerente, non è una svista.

### C-quater. Il voto medio si può gonfiare come `sold`, e per la stessa strada
Stesso trucco di C-bis, applicato alle stelle: l'autore lista a 1 MIST, si
compra N licenze da altri indirizzi suoi, e ognuna vale una recensione da cinque
stelle. La fee resta zero per arrotondamento, quindi costa solo il gas.

In Move non si chiude, per i motivi già scritti in C-bis. In vetrina si mitiga e
non si risolve: la classifica "Top rated" chiede almeno **3 recensioni** e
ordina su `rating_rank` (null sotto la soglia, quindi quei template finiscono in
fondo invece che in testa), il che alza il costo senza azzerarlo. Va detto come
sta: **il voto è un'opinione di chi ha una licenza, non una prova**. Il segnale
che non si gonfia a costo zero resta il volume in SUI.

### D. Comprare due volte è permesso
Non teniamo la lista di chi ha comprato: sarebbe stato che cresce senza limite
dentro un oggetto condiviso. Una licenza in più non fa male a nessuno, e il
frontend può avvisare chi ne ha già una.

### E. `swap_and_burn` non è provato dai test
La copia locale dell'interfaccia Cetus ha i corpi che fanno `abort 0`: simularla
vorrebbe dire provare un finto invece del loro vero. Si prova on chain, con un
importo minimo, subito dopo il publish. Fino ad allora i test dimostrano che
**la cassa non ha altre uscite**, non che lo swap funziona.

### F. "Mandato a 0x0" non è un burn di supply
Rende quei token irrecuperabili, non riduce il totale sul contratto del token. Le
pagine pubbliche devono dirlo con queste parole.

---

## Verificato e NON è un problema

- **Ordine dei tipi e direzione dello swap su Cetus**: `Pool<E, SUI>` con EPT
  coin A e SUI coin B combacia con la pool già in uso in produzione
  (`eptSwap.ts`). `a2b = false` con `by_amount_in = true` significa "spendi
  esattamente questi SUI", che è il caso giusto qui. Il limite
  `max_sqrt_price() - 1` è quello corretto per il verso b2a, e `repay_flash_swap`
  paga sul lato B, coerente.
- **La matematica di `expected`**: `sqrt_price` è Q64.64 e vale sqrt(SUI per EPT),
  quindi `ept = sui * 2^128 / sqrt^2` è l'inversa corretta. In u256 non trabocca
  (`MAX_SQRT_PRICE_X64` sta appena sotto 2^96). La troncatura sottostima
  `expected`, cioè va nella direzione sicura.
- **`owed` non può svuotare più della cassa**: `spend <= pot` e con
  `by_amount_in = true` Cetus chiede al massimo `amount`.
- **Nessun underflow nelle quote**: con `fee_bps <= 300` i due `split` non
  superano mai il valore pagato, e la somma delle tre quote fa sempre `price`.
- **`GlobalConfig` non è falsificabile**: `new_global_config_for_test` è
  `#[test_only]`, quindi on chain non esiste. Non pinnarne l'id non è un buco.

---

## Da fare prima di pubblicare

1. `sui move build` e `sui move test` sul Mac (nel sandbox manca il binario).
2. Leggere il **`fee_rate` della pool EPT/SUI** e verificare che stia comodamente
   sotto `MAX_SLIPPAGE_BPS`.
3. Publish su mainnet, annotare PACKAGE_ID, Registry, AdminCap, UpgradeCap.
4. `set_burn_config` con la pool `0x298ef34a…`. **Si scrive una volta sola**:
   controllare due volte tipo e pool prima di firmare. Subito dopo, richiamarla e
   verificare che risponda `EAlreadyConfigured` (14): è la prova che la porta è
   chiusa davvero.
5. Collaudo con cifre minime: una vendita vera fra i due wallet di test, poi una
   `swap_and_burn` da pochi SUI, e leggere l'evento `EptBurned`.
6. **La UpgradeCap resta viva** finché il modulo non ha rodaggio, come per
   lp-lock: un negozio di due giorni che brucia la cap può solo dichiarare il
   primo bug, non correggerlo. I docs devono dirlo.
