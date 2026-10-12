# epoch-names-gateway: revisione (9 ott 2026)

Revisione fatta prima del publish, in due passaggi: una lettura ostile di chi ha scritto il
modulo e una seconda lettura indipendente (stesso modello, contesto separato, con i sorgenti
di `walrus_names` e `vesting` a fianco). 22 test, tutti verdi con sui 1.78.1.

## Trovato e corretto

1. **Keeper: gli step si sommavano dentro una transazione** (medio). Il limite "uno step per
   aggiornamento" non limitava niente: sei chiamate a `keeper_set_fee` nella stessa PTB
   portavano la fee al pavimento del corridoio, e poi si compravano nomi nella stessa tx.
   Corretto con un intervallo minimo di 6 ore fra aggiornamenti per token (orologio di Sui,
   `MIN_KEEPER_INTERVAL_MS`), e con la revoca: le KeeperCap sono registrate nel Gateway e
   l'admin le toglie dalla lista senza doverle riavere (`revoke_keeper`). Test:
   `keeper_cannot_compound_steps`, `keeper_moves_again_after_interval`, `revoked_keeper_aborts`.
2. **Timestamp della fee** (basso). Usava `epoch_timestamp_ms` (inizio epoca, un giorno di
   granularità). Ora `Clock`.
3. **Overflow della fee** (info). `fee_base * 25` per i nomi da 3 caratteri: aggiunto un tetto
   (`MAX_FEE_BASE`, 7e17) così non può traboccare. Test `absurd_fee_aborts`.

## Accettato consapevolmente

- **L'unica uscita dei token dipende dal package vesting** (medio, per scelta). Se il vesting
  venisse aggiornato con version gating o la sua deploy fee alzata oltre il ragionevole,
  i token resterebbero nel Gateway. Il vesting è nostro, la fee la decide la nostra AdminCap,
  e una vecchia versione di un package Sui resta chiamabile se non ha gating. Si accetta:
  un'uscita d'emergenza per l'admin sarebbe esattamente la porta che il contratto promette di
  non avere. Se mai servisse, la via è l'UpgradeCap di questo package, da dichiarare.
- **Un upgrade di walrus_names che alza VERSION** blocca `register_with_token`
  (`EWrongVersion`), non i fondi: float e token restano recuperabili. Prima di un upgrade
  del genere: pausa del gateway, poi republish.
- **Wallet whitelistati rifiutati sempre**, anche per nomi da 3 caratteri dove il registro non
  farebbe comp: più restrittivo del necessario, mai pericoloso.
- **Prezzo manipolabile dal keeper**: il bot legge il pool; un pool spinto gli fa proporre una
  fee sbagliata, ma di uno step ogni 6 ore e dentro il corridoio. Il danno massimo è la
  differenza fra la fee giusta e il bordo del corridoio, per il numero di nomi venduti in
  quelle ore: tenere il corridoio stretto e il float piccolo.
- **Float drenabile solo comprando nomi**: ogni SUI che esce dal float corrisponde a un nome
  pagato in token alla fee corrente. Se la fee è sbagliata di molto, il danno è il float.
  Nomi da 3 caratteri costano 12,5 SUI di float l'uno: `max_sui_fee` a 15 SUI li ammette;
  abbassarlo a 3 SUI esclude i 3 caratteri dal pagamento in token se si preferisce.

## Non trovato
Nessun modo di ricevere SUI dal float senza comprare un nome; nessun nome senza la fee in
token (il conteggio dei caratteri è lo stesso del registro, la coin viene divisa prima di
`register`, ogni abort annulla tutto); nessuna funzione mutante senza cap, a parte `fund`
che è aperta di proposito; chiavi e valori dei dynamic field sempre derivati dallo stesso
`T`; parametri di `create_vault` validi (cliff 100%, istante unico, beneficiario non nullo).
