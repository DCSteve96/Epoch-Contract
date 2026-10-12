# Upload sponsorizzato Walrus: checklist (30 set 2026)

Rischi e motivi in `AUDIT.md`. [S] = lo fa Stefano (firme, account), [C] = lo fa Claude.

## Subito, prima di tutto
- [ ] [S] 2FA sull'account Cloudflare (i secret del worker stanno lì)
- [ ] [C] Limitare `POST /walrus` di epoch-walrus: oggi chiunque carica file pagati dal wallet del protocollo, senza limiti

## Deploy mainnet
- [x] [S] Cloudflare > Turnstile: widget "Epoch Names publish" (hostname epochsui.com, Managed). Site key pubblica `0x4AAAAAAFKMzkT6P1lqN1lS` (va nel frontend); secret solo in `3-secrets.sh`
- [x] [S] `cd epoch-walrus-sponsor && ./net.sh mainnet && sui move build`
- [x] [S] `sui client publish ...` 30 set, tx `7L1WCuvPV2iE13dz12Xc68RCkoMXVi6cVJGF9MJvidBs`: package `0x89139211aac66986da056559dcc3010703b22847e1559e8479eba716227db400`, UpgradeCap `0xfcc91adc61b58dc73a273612f2014f5a8f97d222e5e45ce8fd4b9ee533666a26` (oggi sul wallet CLI 0x9ed3…b2ff)
- [x] [S] `node 1-keys.mjs`: gas sponsor `0x051590f0d9b7b30e9420e1cda4d99062f5aadbb021251df0b4d834db0d89bcc2`, voucher pubkey `c2b07c3e65f771d4a7b8f78fcdc455af70016ab9b21c611bc50c8df51cbf31ce`
- [x] [S] `node 2-create.mjs` (tx `QAXeFDpmeQEdogzgh8WEb4ud6X2miobogMWXn5itQBT`): treasury `0x2472d32c8eae445607842c6bc90d89f9a4ec0d44a2d8441400a246b19efb3470`, AdminCap `0x4fe0fb02c7daa145fae31026f7c8c40574d1c9c900dec2b87d4b748109cfb0c6`, 20 coin di gas. Deposito WAL fallito (0 WAL sul wallet CLI)
- [x] [S] Deposito 5 WAL con `2b-deposit.mjs` (tx `HVoe4uGvxy2DNsALo1hnu2qzbBcWmaaMRvQCUohSvrUr`)
- [x] [S] `./3-secrets.sh` (alla fine incollare il secret Turnstile)
- [x] [C] `SPONSOR_PKG` e `SPONSOR_TREASURY` in `wrangler.toml`
- [x] [S] `npx wrangler deploy` in epoch-walrus (versione d433a3d1)
- [x] [S] `node 4-e2e.mjs`: tutte le righe `ok` (30 set). Register `ByPKLcHE…X8Ct`, certify `66CskDAi…a7e`: mittente l'utente, gas lo sponsor, blob dell'utente, certificato e leggibile. Un blob della prima prova (0,225 WAL) resta registrato e non certificato
- [x] [S] `npx wrangler secret delete SPONSOR_E2E_TOKEN` (30 set)
- [x] [S] AdminCap e UpgradeCap restano sul wallet della CLI `0x9ed3…b2ff` (scelta di Stefano, 30 set): chiave solo nel keystore del suo Mac, non in un server. Il Mac va protetto come un wallet
- [ ] [C+S] Quando Sites.tsx usa lo sponsor e `POST /walrus` è chiuso: togliere `WALRUS_PRIVATE_KEY` dal worker (`npx wrangler secret delete WALRUS_PRIVATE_KEY`, dopo aver spostato altrove snapshot e wrap-site che la usano)

## Prima di aprirlo a tutti
- [x] [C] Quilt nel worker e manifest v2, provato su mainnet con `5-quilt-e2e.mjs` (30 set)
- [ ] [S] Deploy del gateway `walrus-names-gateway` (legge i quilt, siti vecchi invariati)
- [ ] [S] Dopo le prove: `npx wrangler secret delete SPONSOR_E2E_TOKEN` (rimesso per la prova quilt)
- [x] [C] Sites.tsx sullo sponsor (quilt, Turnstile, auth, /execute), dietro `?sponsor=1`; revisione indipendente fatta e correzioni applicate
- [x] [S] Deploy e prove con `?sponsor=1` (30 set): aggiornamento walrussites (tx `5Hg2MEsW…`, foto come `/media/fcff49e3ee68.png` nel quilt) e nome nuovo waghmy (storage `GaQF9i9S…`, nome `35pTRAgo…`). Blob dell'utente, gas dello sponsor, nome registrato e pagato dall'utente
- [ ] [S] Prima di portare i build dei partner sullo sponsor: dirlo a Carlos (SuiPump). Più firme, e `blob` nel return_url diventa un patch id (si legge con `/v1/blobs/by-quilt-patch-id/` o da blob.epochsui.com)
- [x] [C] `SPONSORED_PUBLISH_ALL = true` (30 set, sera), dopo ricarica: cassa 260 WAL, gas 6,9 SUI in 28 coin
- [ ] [S] Deploy del frontend con lo sponsor acceso per tutti
- [x] [C] Endpoint di stato: trovano i blob dell'utente (`sponsored_blobs`)
- [ ] [C] SessionsAdmin sullo sponsor (fase 3)
- [x] [C] Rinnovo per i blob dell'utente: `extend_blob` dal wallet che ha pubblicato, WAL dell'utente
- [ ] [S+C] Prova con un wallet zkLogin (Slush con Google)
- [ ] [S+C] Prova di un publish da circa 10 MB (limiti di CPU del worker)
- [x] [C] `POST /walrus` protetto (walrusGate.ts): chiave per i servizi, Turnstile per le pagine, tetti giornalieri; chiamanti aggiornati
- [ ] [S] `./epoch-walrus/scripts/sponsor/6-walrus-key.sh` (chiave in epoch-walrus, epoch-kairos, epoch-mcp)
- [ ] [S] Deploy: epoch-walrus, epoch-kairos, epoch-mcp, walrus-names-frontend, vesting-frontend, epoch-agents app
- [ ] [S+C] Un giorno di `wrangler tail` su epoch-walrus: nessun `[walrus-gate] would refuse` da chiamanti nostri, poi `WALRUS_UPLOAD_ENFORCE = "1"` e deploy

## Esercizio
- [ ] [C] Avviso quando scendono il SUI del pool gas, il WAL della tesoreria o sale `day_spent`
- [ ] [S] Controllo giornaliero di `day_spent`; se ci sono picchi: `set_config` con pausa
- [ ] [S] Tenere la tesoreria bassa e ricaricarla spesso (`deposit`): il danno massimo di un sybil è il minore fra `day_cap` e saldo
- [ ] [S] Se Walrus alza i prezzi sopra 0,25 WAL + 0,02 per MiB: `set_pricing`
- [ ] [S+C] Regola per i contenuti abusivi: i blob non si cancellano per circa 2 anni, si può solo smettere di servirli dal gateway dei nomi
