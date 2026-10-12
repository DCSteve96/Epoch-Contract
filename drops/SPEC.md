# Epoch Drops: spec e runbook (20 set 2026)

Un airdrop con vesting da un vault solo. Il progetto deposita il totale UNA volta,
carica la lista `indirizzo, importo`, sceglie lo schedule dei vault (cliff, quota al
cliff, finestra lineare) e paga UNA fee. Ogni destinatario ritira la parte maturata
con una prova di Merkle. Niente vault per persona, niente dump il giorno dopo.

## Pezzi

- **Contratto** `epoch-drops/sources/drops.move`: `Treasury` (fee, AdminCap),
  `Drop<T>` shared e immutabile. `create`, `claim` / `claim_and_transfer`,
  `withdraw_surplus`, `top_up` (permissionless), `reclaim_expired` (solo con
  scadenza, solo dopo). 25 test, `AUDIT.md` con i finding.
- **Albero** `vesting-frontend/src/utils/dropsMerkle.ts`: gemello del Move, vettori
  inchiodati dal test `same_hashes_as_the_frontend`. Foglia con `salt` (32 byte
  scelti dal creatore, scritti nel Drop) perché l'id dell'oggetto non esiste prima
  della transazione che lo crea.
- **Lista pubblica**: JSON `{ 'epoch-drop': 1, salt, coinType, decimals, entries[],
  root, total }` su Walrus via `POST epoch-walrus/walrus?epochs=26` (un anno, WAL
  nostro, un centesimo), letto da `blob.epochsui.com/<id>`. L'id sta nel Drop
  (`leaves_blob`). La pagina di claim ricostruisce l'albero da lì e **pretende** che
  la radice combaci con quella on chain: altrimenti niente tasto.
- **Pagine** sul vesting: `/drops` (elenco dagli eventi `DropCreated`, niente
  database), `/drops/new` (wizard in 4 passi), `/drop/:id` (claim, strumenti del
  creatore, verifica). Voce **Drops** nel menu Vesting.
- **`claim.epochsui.com/<id>`**: branch `name === 'claim'` nel gateway, proxy alle
  Pages del vesting (`epoch-vesting.pages.dev`) con le meta OG riscritte al bordo
  leggendo titolo e destinatari dall'oggetto. La SPA riconosce l'host
  (`isClaimHost` in `utils/dropsConfig.ts`) e monta `/:id` sulla pagina del drop.
  `claim` aggiunto a `INFRA_SUBDOMAINS` di names. **Da mintare `claim` dal wallet
  admin**, come `send`.

## Il giro della creazione, nell'ordine

1. Albero nel browser, `declared_total` = somma delle foglie (il Move non può
   verificarla: vede solo la radice).
2. Upload della lista su Walrus.
3. **Rilettura dal proxy pubblico** e albero rifatto da quella copia: se la radice o
   la somma non combaciano, niente firma. Più una prova a caso verificata come farà
   il Move.
4. Una PTB: fee dal gas, token con `coinWithBalance` (coin + address balance),
   `create` con radice, blob id, schedule, scadenza. `tx.toJSON({ client })` prima
   del wallet, come nel pannello Admin.
5. L'id del Drop si ricava dall'evento `DropCreated` cercando il `salt`.

## Regole scritte a schermo

- Nessuno cambia lista, schedule o destinatari: né il creatore né Epoch.
- Il creatore ritira solo il surplus oltre la lista (`deposited - declared -
  surplus_taken`) e, se ha messo una scadenza, il residuo dopo di essa.
- Scadenza zero = ritirabile per sempre. Con scadenza, deve stare strettamente dopo
  la fine dello schedule (F-2) ed è visibile a tutti dal primo giorno.
- Lista sottofinanziata (somma foglie > dichiarato) = riquadro ambra con le cifre;
  `top_up` la sistema, da chiunque.

## Publish (sul Mac)

```bash
cd ~/Desktop/Vesting/epoch-drops
sui move test                      # 25/25
sui client publish --gas-budget 200000000
# annotare PACKAGE_ID, Treasury (shared), AdminCap, UpgradeCap
```
Poi: `DROPS.mainnet` in `vesting-frontend/src/utils/dropsConfig.ts`, build e deploy
delle Pages del vesting (`--project-name epoch-vesting --branch main`), `wrangler
deploy` del gateway, mint di `claim` dal wallet admin. Collaudo: un drop di prova da
tre indirizzi nostri con 1 EPT a testa, scadenza a una settimana, e un claim dal
secondario.

## Dopo (non in v1)

- Indexer: `DropCreated`/`DropClaimed` su Supabase per la ricerca e per un contatore
  pubblico "wallet che hanno ritirato". Oggi bastano gli eventi.
- Pagamento in EPT della fee (gateway come quello dei vault) e quota partner.
- Card OG per drop (immagine con titolo e token), oggi l'immagine è quella generica.
