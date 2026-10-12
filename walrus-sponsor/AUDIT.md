# epoch_walrus_sponsor, audit e correzioni (30 set 2026)

Scopo: Epoch paga WAL e gas, l'utente firma la registrazione e possiede il Blob Walrus.
Modulo `sources/sponsor.move` (v2), 28 test in `tests/sponsor_tests.move`, tutti verdi con sui 1.79.1.
Worker: `epoch-walrus/src/sponsorUpload.ts`, `sponsorGate.ts` (Durable Object), `sponsorVoucher.ts`.

Audit in tre passaggi: revisione propria e revisione indipendente della v1, poi una seconda
revisione indipendente delle correzioni (v2), che ha trovato altri problemi nel worker, corretti
anche quelli (tabella "Secondo giro"). La v1 aveva due exploit dimostrati con test Move e un
problema sybil che bloccava il servizio.

## Trovato nella v1 e corretto

| # | Gravità | Problema v1 | Correzione v2 |
|---|---|---|---|
| 1 | Alta | Sybil: `/sponsor/register` accettava qualunque indirizzo e file. Due wallet usa e getta riempivano il tetto giornaliero e bloccavano tutti; chiunque poteva consumare la quota di un altro indirizzo | Cloudflare Turnstile (solo dalla pagina names.epochsui.com) su register e upload; firma del wallet (messaggio valido un'ora) e quota per wallet contata alla costruzione; quote in un Durable Object per IP (IPv6 per /64) e per wallet; filtro di base sui tipi di file, 5 MB per file |
| 2 | Alta | Chiave voucher rubata = WAL liquidi: blob da 1 epoca con importo massimo, circa 49 WAL al giorno (test PoC) | Durata minima imposta on chain (`min_epochs` dalla registrazione) e tetto di prezzo per dimensione (`price_base + price_per_mib * MiB`) in `borrow` |
| 3 | Medio-alta | Prestito tenuto senza spendere: l'utente estrae il voucher, esegue una sua transazione e chiude con un blob ottenuto altrove (vecchio blob esteso, blob di terzi congelato o condiviso), resto zero (test PoC) | `settle` prende il Blob per valore e lo trasferisce lui al mittente (esclusi i blob congelati o condivisi); il Blob deve essere non certificato e registrato non prima dell'epoca del voucher (esclusi i blob vecchi) |
| 4 | Medio-alta | Gas: coin bloccato prima della validazione, `/upload` ripetibile, blocco da 3 minuti contro voucher da 10: stesso coin in due transazioni firmate (equivocazione), pool esauribile | La firma dello sponsor non esce più: `/sponsor/execute` verifica la firma dell'utente su byte costruiti da noi, monouso, e firma ed esegue lato server. Coin prenotati nel Durable Object fino a fine transazione o scadenza, con la versione aggiornata dopo ogni esecuzione |
| 5 | Bassa | `/upload` riconosceva l'evento dal suffisso del nome, non controllava esito né mittente, certificazioni ripetibili | Solo eventi `Settled` del nostro package (tipo esatto, cassa e utente giusti), esito e mittente controllati, blob non ancora certificato, una certificazione per blob |
| 6 | Bassa | Due file identici bloccavano il publish | Deduplica per contenuto |
| 7 | Bassa | Quote consumate anche da richieste fallite; la Cache API non funziona su *.workers.dev (le quote v1 erano finte) | Quote nel Durable Object, quella per wallet solo a esecuzione |
| 8 | Bassa | Voucher da 10 minuti: cambio di prezzo, transazione fallita a nostre spese | Voucher da 2 minuti |
| 9 | Info | Nessun `migrate`, nonce che crescono per sempre, errori interni mostrati al client | `migrate(cap)`, `prune_nonces` (chiunque, solo nonce scaduti, rimborso storage), errori interni solo nei log |

## Secondo giro (verifica indipendente della v2) e correzioni

| # | Gravità | Problema nella v2 | Correzione |
|---|---|---|---|
| A | Alta | `manifestBlobId` finiva senza controlli in `update_blob`: una stringa da 16 KB pagata in storage dallo sponsor, e rimborsata all'utente alla scrittura successiva, circa 0,1 SUI per volta | Deve essere un blob id valido e uno dei blob certificati nella stessa transazione |
| B | Medio-alta | `/upload` senza Turnstile e senza limite di costruzioni aperte: coin del gas tenuti occupati | Turnstile anche su `/upload`, costruzioni aperte limitate per IP e per wallet |
| C | Media | Quote aggirabili: IPv6 (un /64 per persona), e quota per wallet contata a `/execute` saltabile eseguendo da sé la transazione col proprio gas | IPv6 contato per /64; firma del wallet e quota contata alla costruzione |
| D | Media | Stato Walrus in cache per sempre nell'isolate: dopo un cambio di prezzo ogni register falliva fino al riavvio | `reset()` del client Walrus a ogni register e upload |
| E | Bassa | La prenotazione del coin poteva scadere durante un'esecuzione lenta | Prenotazione allungata a 5 minuti all'inizio di `/execute`; su errore di rete si cerca la transazione sulla catena prima di liberare il coin |
| F | Bassa | Scadenza della certificazione calcolata prima delle scritture sul relay | Prenotazione della certificazione di 15 minuti, scadenza della transazione dopo le scritture |
| G | Info | Il tip del relay (SDK `sendUploadRelayTip`) pescava SUI dal wallet dell'utente: con zero SUI il publish falliva | Tip preso dal coin di gas dello sponsor |
| H | Info | Voci "certificato" tenute 400 giorni nel Durable Object | 1 giorno: dopo vale il controllo on chain |

## Proprietà del contratto v2

1. **Il WAL esce solo come prestito chiuso nella stessa transazione** (`Loan` senza abilità).
2. **Il Blob che chiude il prestito è nuovo, pieno e quello firmato**: stesso blob id e dimensione,
   passato per valore, non cancellabile, non certificato, registrato dall'epoca del voucher in poi,
   con almeno `min_epochs` di storage. Viene consegnato al mittente dentro `settle`.
3. **Un Blob chiude un solo prestito** (`BlobKey`).
4. **Voucher legato a cassa, mittente, contenuto, epoca, importo, nonce e scadenza**, dominio
   `epoch-walrus-sponsor/voucher/v2`. Il test `voucher_matches_typescript` fissa l'encoding.
5. **Importo limitato dal prezzo**: mai sopra `price_base + price_per_mib * ceil(size / MiB)`, né
   sopra `max_per_loan`. Il resto non speso torna alla cassa in `settle`.
6. **Nessuna chiamata al sistema Walrus**: gli upgrade di Walrus non rompono il contratto.

Parametri al lancio (2-create.mjs): `max_per_loan` 0,5 WAL, `day_cap` 500 WAL (solo freno
d'emergenza), prezzo 0,25 WAL + 0,02 WAL per MiB (reale al 30 set: 0,225 fino a ~0,1 MiB, 0,383 a
10 MiB), `min_epochs` 52. Se Walrus alza i prezzi sopra il tetto, il worker rifiuta con un
messaggio e l'admin aggiorna con `set_pricing`.

## Rischi residui, accettati

- **Storage più economico del listino.** Chi ottiene un Blob nuovo e valido pagando meno del
  listino (sussidio Walrus all'acquirente, `Storage` comprato prima a prezzo più basso) tiene la
  differenza. Il guadagno è limitato allo scarto di prezzo.
- **Chiave del voucher rubata.** Con i controlli v2 non si incassano WAL liberi: ogni prestito
  deve diventare un blob nuovo da 52 epoche, e lo scarto massimo è il margine del tetto di prezzo
  (circa 0,02-0,07 WAL a blob), sotto `day_cap`. Si ferma con `set_config` (pausa) e `rotate_signer`.
- **Registrazione senza upload.** Chi registra e non carica spreca lo storage pagato, non incassa
  niente. Limitato da quote per wallet e per IP e da Turnstile.
- **Sybil determinato.** Senza legare lo sponsor a qualcosa di scarso (un nome, un pagamento),
  chi è disposto a risolvere Turnstile a mano, creare wallet e cambiare rete può ancora spendere
  il budget: circa 20 file per ogni verifica risolta, 60 al giorno per wallet, 150 al giorno per
  IP. Il danno in WAL resta sotto `day_cap` e il saldo della cassa, e il servizio si mette in
  pausa in un colpo. Per questo `day_cap` va tenuto a un livello che si è disposti a perdere in
  un giorno, e il saldo basso.
- **Filtro sui file.** Il controllo dei tipi è di base: in un .txt, .json o in un'immagine si
  possono comunque nascondere dati arbitrari. Serve contro l'uso ingenuo, non contro chi vuole
  storage gratis a ogni costo (vedi sopra).
- **Rimborsi di storage piccoli.** L'utente può bruciare il suo Blob e incassare il rimborso
  dello storage dell'oggetto (circa 0,003 SUI, pagato come gas dallo sponsor); `prune_nonces` dà
  il rimborso a chi lo chiama.
- **Esito incerto di un'esecuzione** (rete che non risponde): il coin resta prenotato fino a
  scadenza, l'utente vede un errore e controlla il wallet.

## Custodia

- **AdminCap e UpgradeCap valgono uguale** (un upgrade può aggiungere una funzione che svuota la
  cassa): entrambi su un wallet freddo, meglio multisig. La cassa tiene poco saldo, ricaricato spesso.
- `SPONSOR_GAS_KEY` rischia solo il SUI del pool; `SPONSOR_VOUCHER_KEY` vedi sopra;
  `SPONSOR_E2E_TOKEN` salta solo Turnstile (le quote restano): dopo la prova, cancellarlo
  (`npx wrangler secret delete SPONSOR_E2E_TOKEN`).

## Da provare con la prima pubblicazione vera

I test Move passano dalle funzioni `*_for_testing`: la firma in `borrow` e `settle(Blob)` vero
girano solo on chain. `4-e2e.mjs` fa il giro completo su mainnet (registrazione, certificazione,
proprietà, lettura) e prova le difese principali.

## Dipendenze

`deps/walrus` e `deps/wal` sono interfacce minime (tipi identici all'originale, funzioni di
lettura con corpo `abort 0`), da github.com/MystenLabs/walrus commit 460c1fae…
`./net.sh mainnet|testnet` commuta gli indirizzi. Publish con `--skip-dependency-verification`
(il bytecode delle interfacce non coincide con quello on chain, per costruzione).
