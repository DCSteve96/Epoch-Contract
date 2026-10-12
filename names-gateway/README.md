# epoch-names-gateway

Registra un nome `.epoch` pagando in un token partner (SuiCat per primo), tenendo il
token invece di venderlo. Package separato da `walrus-names`: chiama il suo `register`
pubblico pagando la fee in SUI da un float proprio. I token raccolti hanno una sola
uscita, `lock_collected`, che li mette in un vault Epoch di almeno 365 giorni: non esiste
withdraw, nemmeno per l'admin. Design e motivazioni nel commento in cima a
`sources/names_gateway.move`; revisione in `AUDIT.md`.

## Build e test
```bash
cd ~/Desktop/Vesting/epoch-names-gateway
sui move build
sui move test        # 22 test
```

## Publish (mainnet, firmi tu)
```bash
sui client switch --env mainnet
sui client publish --gas-budget 300000000
```
Dall'output: `Gateway` (shared), `GatewayAdminCap` (nel tuo wallet), package id.
Scrivili in `walrus-names-frontend/src/utils/partnerTokens.ts` (`NAMES_GATEWAY.mainnet`).

## Dopo il publish, dal pannello admin (/admin, sezione Partner tokens)
1. Fund float: 20 SUI bastano per 40 nomi lunghi (0,5 SUI l'uno); i SUI tornano nella
   Treasury dei nomi, da dove li ritiri come sempre.
2. Add token: coin type di SuiCat, fee base (25% di sconto sui 0,5 SUI letta dal pool),
   min/max e step per il keeper.
3. Lock: tutto il raccolto finisce in un vault Epoch da 12 mesi (fee 10 SUI dalla tua
   gas). L'ID del vault è quello da annunciare. Un vault per lotto: i vault sono immutabili,
   quindi si fa un lotto al mese o quando la cifra vale la fee.

## Keeper (opzionale, fase due)
`mint_keeper` a un wallet bot; il bot legge il prezzo dal pool e chiama `keeper_set_fee`
quando la deriva supera il 5%, entro il corridoio e lo step fissati dall'admin, al massimo
una volta ogni 6 ore per token. Chiave rubata: `revoke_keeper` dal pannello.
