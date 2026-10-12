# Epoch Agent Pay: spec (24 set 2026)

Documento interno, in italiano come le altre SPEC. L'AUDIT va in inglese perché finisce
nel repo pubblico.

## Perché

Il post di Adeniyi del 24 set: "agentic commerce requires machine-native payment rails".
Il blog di Sui del 2 set dice che a un agente che spende servono tre cose: regolamento
atomico su più servizi, **autorità di spesa con limiti imposti dalla catena**, costi da
macchina. Le prime e le ultime le dà Sui (PTB, finalità sotto il secondo, stablecoin
senza gas). La seconda la descrive come qualcosa che "i builder concedono": non c'è un
prodotto pronto, ed è il pezzo che facciamo noi.

x402 (HTTP 402, x402 Foundation dal 2 apr 2026) ha lo schema `exact` per Sui, ma su
mainnet ci sono solo facilitator della community (il primo pagamento: 0,01 USDC).

Decisioni del 24 set: niente marketplace stile Fiverr; v1 = **mandato + paywall x402**;
vive **dentro Epoch Pay** (`send.epochsui.com/agents`). Monete: **USDC, SUI ed EPT**
(aggiornato lo stesso giorno). Il Move è già generico (`Mandate<T>`), quindi non cambia
niente: **un mandato, una moneta**, e i tetti sono in quella moneta. La UI mostra accanto
una stima in dollari, e dice che per SUI ed EPT il valore del tetto si muove col prezzo.
Il venditore x402 può offrire più monete nella lista `accepts` e l'agente paga con quella
per cui ha un mandato. L'escrow di Work diventa
lo strato 3 ("lavori tra agenti"), dopo.

## Il prodotto: Epoch Agents su `agents.epoch` (24 set 2026)

Dopo aver guardato t2000.ai (stesso prodotto, già live su Sui) la decisione è farlo anche
noi, come **app Walrus su un nome suo**: `agents.epoch` (registrato il 24 set dal
secondario, NameCap `0xb824baa0…`). App in `epoch-agents/app` (nata da `epoch-work/app`),
niente database, letture da GraphQL e gRPC, pubblicazione con `scripts/publish.mts`
(`SITE_NAME` default `agents`). Pagine: `/services`, `/service/:id` (con "paga una
chiamata dal wallet" e il link che apre un mandato già compilato), `/sell` (crea e modifica
un servizio, documento su Walrus), `/mandates` (crea, elenco), `/mandate/:id` (pausa,
ricarica, ritiro, chiusura, rotazione chiave, limiti, destinatari, ricevute, CSV),
`/receipt/:digest` (stampabile), `/connect` (MCP locale).

Cosa abbiamo in più di loro, deciso il 24 set: limiti imposti dalla catena invece che dal
nostro server; brief e consegne privati con Seal (strato lavori); paga con qualsiasi token;
milestone e pagamento a rate coi vault (strato lavori). Fee 3% metà bruciata sui lavori,
**0% sulle chiamate API**. Per Basecamp prima gli agenti, l'escrow dei lavori dopo.

Cambi al Move prima del publish (i campi restano definitivi): `Service<T>` ha `category`,
`doc` (blob Walrus) e `kind` (0 API, 1 lavoro, fisso); `service::buy` per pagare una
chiamata dal wallet (evento `ServicePaid<T>`); `pay_service` rifiuta i lavori
(`EServiceNotApi`). 38 test.

## I due lati (24 set 2026)

- **Chi usa i servizi** (il cliente): ha un agente, apre un `Mandate` con i SUOI soldi e le
  regole. L'agente paga da lì.
- **Chi fornisce i servizi** (il venditore): crea un `Service` on chain col SUO prezzo per
  chiamata, la moneta, dove arrivano i soldi (`pay_to`, di solito il suo nome .epoch) e
  l'endpoint. Cambia prezzo quando vuole, ma chi paga passa `max_price`: un aumento in volo
  fa fallire il pagamento invece di costare di più.
- Il pagamento a un servizio è `mandate::pay_service(mandato, servizio, max_price, nonce)`:
  **il prezzo lo legge il contratto dal listino**, non lo sceglie l'agente e non lo scrive
  il venditore dentro la risposta 402. Resta `mandate::pay` per pagare un indirizzo senza
  listino (una fattura, una mancia).
- Il servizio si legge per riferimento: nessun contatore dentro, così mille agenti che
  pagano lo stesso servizio non si mettono in coda sullo stesso oggetto.

## Ricevute e fatture

Ogni pagamento emette un evento `Paid<T>`, che **è la ricevuta**: numero progressivo nel
mandato (`receipt_no`), chi paga (`payer`, il proprietario) e con quale chiave (`agent`),
chi incassa, per quale servizio, quanto, in che moneta (il `T` del tipo), quando, e i
riferimenti del venditore (`nonce` = id della richiesta, `memo` = numero d'ordine o di
fattura). È un evento e non un oggetto perché su un pagamento da un centesimo un oggetto
costerebbe di storage più del pagamento.

Sopra gli eventi, fuori dalla catena e senza database:
- pagina ricevuta stampabile `send.epochsui.com/receipt/<digest>` (PDF dal browser), che
  rilegge la transazione e mostra i dati, con il link all'explorer come prova;
- estratto conto del mandato (cliente) e del servizio (venditore), con export CSV per il
  commercialista.

**Non è una fattura fiscale.** In Italia (e non solo) la fattura la emette chi vende, con i
suoi dati fiscali, dal suo sistema. Noi diamo la ricevuta verificabile con tutti i dati per
farla; campi facoltativi del venditore (ragione sociale, partita IVA) si possono aggiungere
al documento del servizio, fuori dalla catena.

## Il principio che decide tutto

**Chi perde la chiave dell'agente perde al massimo il limite del periodo, mai il saldo.**
Una chiave di agente sta per forza su una macchina (un server, un laptop, un container
che gira da solo), quindi prima o poi qualcuno la legge. Il mandato esiste perché quel
giorno la domanda non sia "quanto avevo" ma "quanto era il tetto giornaliero".

Corollario: **il proprietario può sempre riprendersi tutto**, in qualunque momento, e
l'agente non ha nessun modo di impedirlo. Nessun lock, nessun ritardo, nessun admin.

## Strato 1: `mandate` (Move, package nuovo `epoch-agent-pay`)

### Oggetto

`Mandate<phantom T>` shared, con:

- `owner: address`, chi l'ha creato e può fare tutto tranne spendere come agente
- `agent: address`, l'unica chiave che può chiamare `pay`; `@0x0` = nessun agente
- `balance: Balance<T>`
- `max_per_payment: u64`, `max_per_period: u64`, `period_ms: u64`
- `period_start_ms: u64`, `spent_in_period: u64`, `total_spent: u64`, `payments: u64`
- `expires_ms: u64` (0 = nessuna scadenza)
- `paused: bool`
- `any_recipient: bool` e `recipients: VecSet<address>` (tetto 32)
- `used_nonces: Table<vector<u8>, bool>`
- `label: String` (tetto 64, solo per la UI)

Indirizzi e non capability, di proposito: un `AgentCap` è un oggetto che si può
trasferire, avvolgere e perdere, e non aggiunge niente al controllo `sender == agent`.
La rotazione della chiave è `set_agent`, firmata dal proprietario.

### Funzioni

- `create<T>(coin, agent, max_per_payment, max_per_period, period_ms, expires_ms,
  recipients, any_recipient, label, clock, ctx)`: condivide il mandato, emette
  `MandateCreated`. Rifiuta: `max_per_payment == 0`, `max_per_period == 0`,
  `max_per_payment > max_per_period`, `period_ms` fuori da [1 minuto, 365 giorni],
  scadenza nel passato, `any_recipient == false` con lista vuota (un mandato che non
  può pagare nessuno è un errore di chi lo crea, non una configurazione).
- `pay<T>(m, amount, recipient, nonce, memo, clock, ctx)`: solo `agent`. Controlli in
  quest'ordine: non in pausa, non scaduto, `amount > 0`, `amount <= max_per_payment`,
  destinatario ammesso, rinnovo del periodo se è passato, `spent_in_period + amount <=
  max_per_period`, nonce non usato (se non vuoto, lunghezza ≤ 64), saldo sufficiente.
  Poi `coin::take` e `transfer::public_transfer(coin, recipient)`, contatori aggiornati,
  evento `Paid { mandate, agent, recipient, amount, nonce, spent_in_period, balance_after }`.
- `top_up<T>(m, coin)`: **chiunque**, aggiunge e basta (anche un'altra app può ricaricare).
- Solo proprietario: `withdraw(m, amount)`, `withdraw_all(m)`, `set_agent`, `set_limits`,
  `set_expiry`, `add_recipient`, `remove_recipient`, `set_any_recipient`, `pause`,
  `resume`. Ognuna emette un evento: chi guarda un mandato deve poter ricostruire ogni
  cambio di regole, non solo i pagamenti.
- Letture: `balance`, `remaining_in_period(m, clock)`, `can_pay(m, amount, recipient, clock)`.

### Periodo

Finestra fissa, non scorrevole: quando `now >= period_start_ms + period_ms` si riparte
da `period_start_ms = now` e `spent_in_period = 0`. È meno precisa di una finestra
scorrevole (a cavallo del confine si possono spendere fino a due tetti in poco tempo) ma
costa un campo invece di una coda di pagamenti, e il caso peggiore è scritto e limitato:
**2 × max_per_period in un tempo breve**. Va detto nella UI.

### Nonce

L'agente che ritenta una richiesta dopo un timeout rischia di pagare due volte la stessa
cosa. Se passa un nonce (per x402 l'id della richiesta, per una fattura il suo numero) il
contratto rifiuta il secondo pagamento con lo stesso nonce. La tabella cresce e il suo
storage lo paga l'agente, quindi nonce vuoto = nessun controllo, a sua scelta.

### Niente fee in v1

Il mandato non prende niente. Se un giorno ci sarà una fee starà sul facilitator (strato
2), dichiarata, mai dentro `pay`, perché un tetto di spesa che si mangia una percentuale
non è più il tetto che l'utente ha scritto.

## Strato 2: paywall x402 su Sui

Lo schema `exact` su Sui (`scheme_exact_sui.md` nel repo x402) verifica un pagamento
**simulando la transazione firmata e controllando che l'indirizzo `payTo` riceva
esattamente `amount` di `asset`**. Non guarda come ci arriva.

Quindi **una transazione che chiama `mandate::pay` è già un pagamento x402 valido**, senza
estensioni: il balance change verso `payTo` c'è, identico a un trasferimento diretto.
È il punto che tiene insieme i due strati, ed è da provare per primo in simulazione.

Pezzi:
- `epoch-x402` (Cloudflare Worker, open source come il gateway): `/verify` e `/settle`
  dello standard, rete `sui:mainnet`, asset USDC nativo
  `0xdba34672…::usdc::USDC`. Non custodisce niente: inoltra la transazione firmata dal
  pagatore, e se sponsorizza il gas lo dice in `extra.gasStation`.
- `payTo` si può dare come nome .epoch: il facilitator lo risolve **al detentore della
  NameCap** (stessa regola di Pay, `cap_id_of` del v5), mai al record del registro.
- Middleware minimo per chi vende (un file da mettere davanti a un'API) e un esempio vivo
  su un nome .epoch nostro, per la demo.

## Strato 3 (dopo): lavori tra agenti

L'escrow di Work (`epoch-work/SPEC.md`), con pagamento dal mandato invece che dal wallet.
Non in v1.

## Strumenti per l'agente

Il nostro MCP remoto (`epoch-mcp`) resta **senza segreti**, quindi non può firmare. Per far
pagare un agente servono due pezzi:

- **MCP locale** (`npx @epoch/agent-pay` o simile) che gira sulla macchina dell'utente con
  la chiave dell'agente in una variabile d'ambiente: `pay`, `x402_fetch(url)`,
  `mandate_status`. La chiave vale solo dentro il mandato: è per questo che si può tenere lì.
- Sul MCP remoto, solo letture: `mandate_status(id)` e un link per creare o ricaricare un
  mandato dalla pagina di Pay (firma l'utente, come `/sign/register`).

## Pagina in Epoch Pay

`send.epochsui.com/agents`: crea un mandato (agente, tetti, destinatari .epoch, scadenza),
vedi saldo e pagamenti, ricarica, **pausa e ritiro con un tasto**, che deve funzionare dal
telefono: è la promessa del prodotto.

## Demo per Basecamp (7-8 ott)

Claude Desktop con l'MCP locale, un mandato da 5 USDC con tetto 1 USDC al giorno, un'API
sul nome .epoch nostro che costa 0,01 USDC a chiamata. Claude chiama, riceve 402, paga dal
mandato, riceve la risposta. Poi dal telefono: pausa, e la chiamata successiva fallisce.

## Ordine

1. Move `mandate` + test (sul Mac, nel sandbox `sui` non c'è).
2. Simulazione: una `mandate::pay` passa la verifica `exact` (balance change verso payTo).
3. Publish mainnet.
4. Facilitator + middleware + API d'esempio.
5. MCP locale.
6. Pagina `/agents` in Pay.
