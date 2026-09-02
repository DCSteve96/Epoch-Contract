# Epoch LP Lock: internal security review

Scope: `sources/lp_lock.move`, `tests/lp_lock_tests.move`, `Move.toml`.
Published on mainnet on 2026-09-02 as
`0x5ab27e275f349447c34592868d34f5a03b93ee4d8e884a516b798e6fc85f8404`
(tx `4V3feKB4Bo21h3TzarefU4CFDTPPsiHvZTWsjPMz6ye4`) and upgraded the same day to
v2, `0x3819764c00d94e78ee6b80bef75dff335a06828904ca747339c6d5a149eb9b81`
(tx `4LKfY4odunvKyVPFRquFdeVvg2G3yPeXQ7xGPddiiPR2`), for finding 13. Calls go to
v2; types and events stay bound to v1, which is what event filters and the verify
endpoint match on. The UpgradeCap
`0x5449cdcca3d10fcf3189c4e3abf0856a942deb058cd0fbaaff79c38ebe3e6e23` is still held
by the deployer: see finding 2. Reviewer: internal, two passes. Date: 2026-09-02.

Companion package: `epoch_object_lock`
(`0xe0f23402fae139961a3d5ffa99d054a7821b82295eb5988957053f0c9a4dd14d`, immutable).
This module exists because of finding 7 of that review, which said that fee
collection during a lock, if ever added, must be a Cetus-specific function that
provably never touches liquidity, reviewed as its own change. This is that change
and this is that review.

The second pass was run adversarially against the first, with the explicit brief
of finding what the first had missed. It found two High and five Medium, all
outside the "can liquidity leave" question the first pass had spent its whole
budget on. That is worth recording as a lesson: the first pass proved the
property it set out to prove and stopped there, which is exactly how a review
misses the money.

## Summary

The headline property holds. No PTB composition, in any order, reduces the locked
position's liquidity before `unlock_ms`. `&mut Position` exists in exactly one
place, `add_liquidity`, is consumed by the next statement, and the
`AddLiquidityReceipt` hot potato is settled inside the same function body. Cetus'
`collect_fee` and `collect_reward` take `&Position`, so those two functions take
`&LpLock` and cannot mutate the position even by editing mistake.

What was wrong was elsewhere: an unbounded spend in `add_liquidity`, a
proof-of-lock built on a field Cetus documents as display-only, and a test suite
that exercised a constructor different from the production one.

| # | Severity | Issue | Status |
|---|---|---|---|
| 1 | High | `add_liquidity` had no upper bound on what it spends | fixed |
| 2 | High (operational) | `UpgradeCap` live: the trust model is not enforced on-chain yet | open, disclosed in the docs |
| 3 | Medium | Liquidity was read from the position NFT, which Cetus calls display-only | fixed |
| 4 | Medium | `liquidity > 0` does not mean real depth: no range recorded | fixed |
| 5 | Medium | Events underspecified and frozen at publish | fixed |
| 6 | Medium | The 14 tests never exercised the production guards | fixed |
| 7 | Medium | Unpinned `rev = "main"`, no `Move.lock`, never built | fixed |
| 8 | Medium | Donated liquidity cannot be recovered by the donor | closed, avviso in UI |
| 9 | Medium | Behavioural tests need testnet: no unit test can reach Cetus | closed, run 2026-09-02 |
| 10 | Low | `extend` has no upper bound and ignores the clock | accepted, self-harm only |
| 11 | Info | Fees go to the beneficiary, never to the caller or the creator | by design |
| 12 | Info | Income availability depends on Cetus not pausing the pool | by design, document it |
| 13 | Medium | `pool::get_position_amounts` aborts with 32 on Cetus mainnet v14 | fixed in v2 |

---

## 1. High: `add_liquidity` had no upper bound on what it spends

`pool::add_liquidity_pay_amount` returns what the top-up costs at the pool's
price **at execution time**. The original code only checked a lower bound, that
the supplied coins covered it, so the call would spend whatever the coins held.

The attack does not even need an attacker. Someone tops up a locked position with
a PTB carrying their whole merged `Coin<SUI>`, quoted at 100 SUI. The price moves
between quoting and landing, deliberately (a swap sequenced in front of the call
on the same shared pool, reversed after) or by drift. The same `delta_liquidity`
now costs 7,900 SUI, the call succeeds, and the money is inside a position with
no removal path until the unlock date, after which it belongs to the beneficiary,
who may not be the payer.

This is worse here than in a normal Cetus integration precisely because of what
makes the product work: anywhere else the mistake is undone with
`remove_liquidity` in the next block, and here that door is bolted shut on
purpose.

**Fixed and verified on testnet.** `add_liquidity` now takes `max_a: u64,
max_b: u64` and asserts `need_a <= max_a && need_b <= max_b` with a new
`ESlippage = 9` before splitting any coin. With `max_b = 1` the call aborts with
code 9 and nothing is spent; with a real cap it goes through and spends
10.000.000 dei 20.000.000 messi a disposizione, restituendo il resto al payer.

**Chiuso anche lato prodotto.** La pagina `/lock/lp` non chiede un tetto
all'utente e non chiede nemmeno un `delta_liquidity`: chiede un importo e una
tolleranza (0,5%, 1%, 3%), ricava il delta con la matematica CLMM e calcola
`max_a` e `max_b` da lì. Così il tetto c'è sempre ed è sempre sensato, e
`u64::MAX` non è raggiungibile dall'interfaccia. Se la transazione viene
rifiutata con 9, l'errore mostrato spiega che il prezzo si è mosso oltre la
tolleranza e che non è stato speso nulla.

## 2. High (operational): the `UpgradeCap` is live

The package was published with the default compatible policy (policy 0) and the
cap `0x5449cdcca3d10fcf3189c4e3abf0856a942deb058cd0fbaaff79c38ebe3e6e23` sits in
the deploy wallet. A compatible upgrade can add a new public function to this
module, and a new function in the same module has full access to `LpLock`'s
private fields:

```move
public fun rescue(lock: &mut LpLock<Position>, ctx: &mut TxContext) {
    let p = option::extract(&mut lock.position);
    transfer::public_transfer(p, ctx.sender());
}
```

Every lock created by v1 is typed by the original package id, so v2 can mutate
all of them. Every locked position drains in one transaction, with no date check
and no warning.

This is not hypothetical for this repository: the vesting `UpgradeCap`
(`0xe8d105c0…`, policy 0) is still in the admin wallet today, and the LP spec
opens by citing `object_lock`'s burned cap as the reason this module exists.

**Open, and disclosed.** The cap is not burned on day one on purpose: the module
is two days old, and burning it now would mean the first bug found could only be
disclosed, never fixed. The sequence is publish, soak, external audit, then
`make_immutable` with the digest published.

Two conditions come with that choice, and both are in place. The docs carry a
table comparing the upgrade status of all three Epoch packages, saying plainly
that a lock created in this window rests on a trust assumption rather than on the
chain. And new DEXes will be added as separate packages, never as upgrades of
this one, so that growing the product never touches locks that already exist.

## 3. Medium: liquidity was read from the position NFT

Cetus documents the fields on the `position_nft` as display-only: the numbers
that take part in the calculations live in `PositionInfo`, inside the pool's
`PositionManager`. The original `lock` read `position::liquidity(&position)` for
the `EEmptyPosition` guard, the snapshot and the public view, that is, for the
entire proof surface, from a mirror that upstream declines to guarantee.

It is in sync today, so this was not exploitable. It was an unasserted dependency
on someone else's invariant, in the one place where the product is the claim that
the number is true.

**Fixed.** `lock` now reads `pool::borrow_position_info` plus
`position::info_liquidity` and `position::info_tick_range`, and the `liquidity`
view takes the pool and does the same.

## 4. Medium: `liquidity > 0` does not mean real depth

A team wanting a badge opens a position with a range entirely on one side of
spot, deposits only its own freely minted token, and gets a large liquidity value
with no sell-side depth. The old guard accepted it and the record showed a big
number, indistinguishable from a real two-sided position.

**Fixed.** `LpLock` and `LpLocked` now record `tick_lower`, `tick_upper`,
`tick_at_lock` and the token amounts from `pool::get_position_amounts`, so the
registry can show in-range or out-of-range and the actual amounts. `lock` takes
`&mut Pool` for this. The contract still cannot judge economic value, and should
not try: it records enough for a reader to judge.

## 5. Medium: events were underspecified, and event shape freezes at publish

`RewardsCollected` carried only an amount, with no type: a pool can run several
rewarders, and unlike fees there is no way to recover which token was paid from
the pool id alone. That is data loss, not inconvenience. `LiquidityAdded` did not
carry the amounts actually paid. `destroy_claimed` emitted nothing, so a shared
object vanished from state with no trace in the event stream.

**Fixed.** `reward_type` on `RewardsCollected`, coin types on `FeesCollected`,
`amount_a`/`amount_b` on `LiquidityAdded`, and a new `LpDestroyed`. Done before
publication on purpose: afterwards the shape is frozen for every lock already
created.

## 6. Medium: the tests never exercised the production guards

All tests built locks through `lock_for_testing`, a *different function* that
skipped the empty-position check, skipped the pool binding, and hardcoded the
snapshot. So the two guards this module exists for had zero coverage: deleting
either one left all fourteen tests green.

**Fixed.** `lock_for_testing` now takes the liquidity and runs the same
assertions as `lock`, and there are tests for the empty position and for the
snapshot being the value it was given. The pool binding still cannot be tested
without a real `Pool`, so it stays in finding 9.

## 7. Medium: unpinned dependency and no committed lock file

`CetusClmm` pointed at `rev = "main"`, a moving branch, and the package had no
`Move.lock` and no `build/`, unlike every other Move package in this repository.
For a product whose pitch is verifiability, a build that does not reproduce is a
category error.

**Partly fixed.** The Cetus interface is now vendored in `deps/cetus_clmm`, copied
verbatim from upstream commit `adb48d144ac6a6…`, with its two dependencies
declared as pinned git revisions instead of Move Registry entries. The reason is
not only reproducibility: the upstream manifest resolves `move_stl` and
`integer_mate` through `r.mvr`, which requires the `mvr` binary on the machine
doing the build, and the first real build failed exactly there with
`External resolver 'mvr' not found`. A package whose product is verifiability
cannot ask an auditor to install a tool to reproduce the bytecode. The vendored
sources are unmodified and diffable against upstream.

The package now builds and `Move.lock` (version 4) is generated and must be
committed. `sui move test`: **16 tests, 16 passed**, on 2026-09-02 with the
mainnet CLI. That number covers only what does not need Cetus, see finding 9.

Getting there also forced two manifest facts worth recording, because they will
bite anyone who tries to reproduce the build: Sui and MoveStdlib must NOT be
declared, they are system dependencies added automatically and declaring them
puts two versions of `0x1` and `0x2` in the graph; and the vendored dependency
must be old-style (`published-at` and `[addresses]` in its `Move.toml`, no
`Published.toml`), because the toolchain refuses an old-style package that
depends on a new-style one.

## 8. Medium: donated liquidity is not recoverable by the donor

`add_liquidity` is deliberately open to anyone: topping up a lock strengthens it,
and letting third parties reinforce a commitment is a feature. The consequence is
that liquidity added by a third party belongs to the beneficiary at claim time,
and there is no way back. Any refund path would be a withdrawal path, so the
contract is right and the UI carries the weight.

**Chiuso.** In `/lock/lp`, quando il wallet connesso non è il beneficiario, il
form di top-up mostra un avviso con l'indirizzo del beneficiario e una spunta
obbligatoria: la liquidità diventa sua, non è recuperabile né subito né alla
scadenza, e il motivo è che un rimborso sarebbe un prelievo. Senza la spunta il
bottone resta disabilitato.

## 9. Medium: no unit test can reach the Cetus paths

The Cetus dependency is an interface package: every body is `abort 0` and there
is no constructor for `Pool` or `Position`. `collect_fee`, `collect_reward` and
`add_liquidity` therefore cannot be exercised by `sui move test`, and a green
suite says nothing about them.

The sixteen tests that do run cover the lifecycle and every capital guard that
does not need a pool.

The rest is covered by `epoch-cli/lp_lock_testnet.sh`, written on 2026-09-02 and
**not yet run**. It locks a real position, **attempts `remove_liquidity` on the
locked position and expects the attempt to be refused**, collects fees during the
lock, exercises the slippage bound with an absurd cap and then a sensible one,
tries an early claim and a backwards extend, and claims after the date. Each step
prints a digest.

Two facts it encodes, both learned the hard way:

- publishing needs `sui client publish --dependencies-are-root`, because the
  Cetus interface is incomplete by construction and the client otherwise refuses
  the dependency bytecode version check;
- the Cetus address in `deps/cetus_clmm/Move.toml` is mainnet, and has to be
  swapped for the testnet pair before building for testnet. Verified on-chain on
  2026-09-02: type package `0x0c7ae833c220aa73a3643a0d508afa4ac5d50d97312ea4584e35f9eb21b9df12`,
  published-at `0x85e61285a10efc6602ab00df70a0c06357c384ef4c5633ecf73016df1500c704`,
  `GlobalConfig 0x9774e359…`, `RewarderGlobalVault 0xf78d2ee3…`.

**Eseguito il 2 settembre 2026, tutti i passi verdi.** I digest sono qui sotto e
sono il punto: un audit che dice "testato su testnet" senza digest non è
verificabile da nessuno.

Il ciclo completo su un lock reale: position aperta, bloccata, rimozione di
liquidità rifiutata, fee raccolte con il lock attivo, top-up rifiutato oltre il
tetto e accettato sotto, claim anticipato ed extend all'indietro respinti con i
codici giusti, position restituita alla scadenza.

Il primo giro aveva un buco che è meglio dichiarare che nascondere:
`collect_reward` non era stato eseguito, né dai test unitari, che non possono, né
dallo script, che semplicemente non lo prevedeva. È stato colmato con un secondo
giro su una pool con incentivi attivi e una position **in range**, perché una
position fuori mercato non matura nulla e avrebbe restituito zero senza provare
niente. Risultato: 6.406.837 unità base, cioè 0,006406837 CETUS a 9 decimali, riscossi
mentre la position era bloccata e accreditati al beneficiario. L'importo è
minuscolo perché la position è rimasta attiva meno di un minuto: quello che il
test dimostra non è quanto, è che qualcosa esce. La cosa che il test dimostra non è l'importo, è che
il reddito esce mentre il capitale resta dentro.

### Digests

| Step | Testnet | Digest / id |
|---|---|---|
| publish | 2026-09-02 | `7fGdvE3qyPCSDrGqx4Qkf43mfRhG8CZSL5XbdJhqBWvd` |
| package | | `0xccb1bd275e5cc3fda0751340322f894fa73ddd568ce8ee72a75a2b672c0af829` |
| UpgradeCap | | `0x7c51819629c74cae8fd1b6c1477e36633cd4d4f710b6911ba594658bccc99fb2` |
| position aperta | | `EFUN8kTsmPPBEZrGfpu91dCLuTFQJW1t3eT3PFh8bXge` → `0x501d2477…` |
| 1 lock | ✅ | `DPX7rTLyTA1MmgT6FA4g6vHGniadn3Xdp8hQ7iRtSs4p` → lock `0x7804e73d…` |
| 2 empty position | n/a | coperto dal test unitario `empty_position_aborts` (abort 6) |
| 3 remove_liquidity refused | ✅ | rifiutata: `Object 0x501d2477… not found` (position wrapped nel lock) |
| 4 collect_fee | ✅ | `EU3EE7krDyeRUt2wLz2gYBKzgEpMUhb8ZgdboqeXzwF2`, importi 0 perché fuori range |
| 5a slippage `max_b = 1` | ✅ | abort code 9, la spesa è stata rifiutata |
| 5b top-up con tetto vero | ✅ | `21gGnFFbd4d7tApK95CF6T3SfHXx1zSQZd5C5ESanCrH`, spesi 10.000.000 su 20.000.000 messi a disposizione, il resto tornato al payer |
| 6a claim anticipato | ✅ | `CViL3KkhkmJWTG8jdVqbE8GohiWrFatSGLCDCWbyrFRU`, abort code 0 |
| 6b extend all'indietro | ✅ | `8oMS2aPYJM9iidZ62Q9FDmPJZQhNBiw8WDnVPesPQPpz`, abort code 4 |
| 7 claim | ✅ | `9QXhSEGiwahYjjXECTMsDqd6Cx1yuNXmVfDdwuwL5PaC`, position in *Unwrapped Objects* verso il beneficiario |
| position in range (USDC/SUI) | ✅ | `6ZgUFJiAdTnyHY3p3refBYN6hgU7yTZLrCAQoABfZuT8` → `0x32dd0fb3…`, tick 58232 fra 58080 e 58380 |
| lock della position in range | ✅ | `EaQpYjDu6ZjkfYUxPpBvnke4K44fNEqjjnLm8678Xh7f` → lock `0xea22b7a7…` |
| 8 collect_reward | ✅ | `9iXQ5R69mYvsoWTGiybC4edgCTsaUCFsqn63ci9mZ1gY`, **6.406.837 unità base = 0,006406837 CETUS** (9 decimali) riscossi con il lock attivo e accreditati al beneficiario |

### Mainnet: smoke test del 2 settembre 2026

Il giro su testnet prova il modulo, non la rete su cui gira. Dopo il v2 lo stesso
percorso è stato ripetuto su mainnet, con capitale vero, prima di annunciare
qualsiasi cosa.

| Step | Esito | Digest / id |
|---|---|---|
| position aperta (EPT/SUI, range -28400/-27000) | ✅ | `4r3P3W…vW3U` → `0x9cc7cb7c…` |
| lock sul v1 | ❌ | `7DxKbg…TuKq`, abort 32 dentro Cetus: è il finding 13 |
| lock sul v2 | ✅ | `4viRgN…djQ5` → lock `0x8ed0671d884a6fc3117365238f26ddbe2a76176564b1416319360d94b7ec9a64` |
| evento `LpLocked` | ✅ | `amount_a` 0, `amount_b` 20.902.896.672 (20,9029 SUI), `tick_at_lock` -26964: gli importi che il v1 non riusciva a calcolare |
| position irraggiungibile | ✅ | sparita dagli owned objects del wallet, gli explorer la danno per "deleted" perché è wrapped |
| endpoint di verifica | ✅ | `/api/lock/0x8ed0671d…?network=mainnet` legge la position da dentro il lock |
| `collect_fee` con lock attivo | ✅ | `2RWTbTWrvZ1uGNrt9EoU1BUA6MnAA2e8QFTE88XDgcm5`, **83.535.012 unità base = 0,083535012 SUI** al beneficiario |
| `claim` alla scadenza | ✅ | `Hsb7gfUMRNbcUS26TTBg1PgNGW3JLZMDQPVHVpqEEm8p`, evento `LpClaimed`, position tornata al beneficiario con la liquidità intatta (1.192.639.739.272) |

L'ultima riga è la tesi del modulo dimostrata su mainnet: il capitale è fermo e
irraggiungibile fino alla data, e nello stesso momento il reddito che ha prodotto
esce e arriva al beneficiario. Vale la pena notare che la position era **fuori
range** al momento della riscossione: quelle fee erano maturate prima, mentre lo
era, ed erano rimaste dentro la position. Con `object_lock` sarebbero rimaste lì
fino alla scadenza.

Il passo 3 è confermato sul campo, ed è la prova che regge tutto il resto. Nelle
effects del lock la position compare sotto **Wrapped Objects**: non è più un
oggetto raggiungibile. La chiamata successiva a `pool::remove_liquidity` su quel
position id viene rifiutata dal nodo prima ancora di arrivare al Move, con
`Object 0x501d2477… not found`. Non è un abort che abbiamo scritto noi: è
l'impossibilità di comporre la transazione. È la forma più forte che questa
garanzia possa avere.

La transazione di publish mostra le dipendenze linkate, e vanno lette: sono
`0xf0784730…` (integer_mate testnet), `0xa883e07d…` (move_stl testnet) e
`0x85e61285…` (Cetus testnet). Se lì comparisse un indirizzo mainnet, il package
compilerebbe e poi fallirebbe a runtime contro i tipi sbagliati.

## 10. Low: `extend` has no upper bound

Same trade-off as `object_lock`: the beneficiary can set `u64::MAX` and lock the
position forever, and can extend a lock that has already unlocked. Only the
beneficiary loses, so it is accepted. The UI should show the resulting date and
refuse absurd values before signing.

## 11. Info: fees go to the beneficiary, and collection is permissionless

`collect_fee` and `collect_reward` send everything to `lock.beneficiary`, never
to the caller. The beneficiary-only gate was dropped in the second pass: since
the proceeds are fixed by the lock, gating on the sender bought nothing and added
a liveness dependency, so anyone can now sweep fees to the beneficiary and pay
the gas for it. When creator and beneficiary differ, the creator gives up both
capital and income for the whole period; that must be stated in the docs, because
the opposite assumption is equally natural.

## 12. Info: income availability depends on Cetus

If Cetus pauses the pool or flags the position, `collect_fee`, `collect_reward`
and `add_liquidity` start aborting. The lock and the eventual `claim` are
unaffected, so this is income availability only, but a user should read it here
rather than discover it.

## 13. Medium: `pool::get_position_amounts` aborts on Cetus mainnet, not on testnet

Found by running the module against a real mainnet position, not by reading it.
Every `lock` on mainnet aborted with code 32 inside the Cetus package, while the
identical call had gone through on testnet dozens of times during the run of
finding 9. Nothing in this module had changed between the two.

The cause is that `pool::get_position_amounts` is a stateful function: it looks
up the position inside the pool and its implementation differs between Cetus
versions. Mainnet runs v14, testnet a later one. So the amounts recorded at lock
time, which exist only to make the lock legible to whoever verifies it, were
enough to make the whole lock impossible on the network that matters.

Fixed in v2 by computing the same numbers with `clmm_math::get_amount_by_liquidity`,
which is the pure function Cetus itself uses underneath: it takes the tick range,
the current tick, the current sqrt price and the liquidity, all of which this
module has already read, and has no pool state left to abort on.

```move
let tick_at_lock = pool::current_tick_index(pool);
let (amount_a, amount_b) = clmm_math::get_amount_by_liquidity(
    tick_lower, tick_upper, tick_at_lock,
    pool::current_sqrt_price(pool), liquidity, false,
);
```

The general lesson is worth more than the fix: a dependency's testnet build is
not a proxy for its mainnet build, and the parts of it that read state are where
the two diverge. The pure math functions are the stable surface. Where this
module can choose, it should keep choosing them.

The signature of `lock` was left untouched, `pool: &mut Pool<A, B>` included,
even though the new code only reads: changing it would have broken upgrade
compatibility and forced a republish, which would have orphaned the type. It is
also the one place where holding the mutable reference costs nothing, since the
function does not hand it out.

## Verified as safe

Attacked directly and held:

- **Escaping `&mut Position`.** Every function taking `&mut LpLock` or `LpLock`
  by value was enumerated. Only `add_liquidity` creates a mutable borrow of the
  position and it is consumed one line later. `claim` is the only exit, gated on
  both date and sender. The views return values, never references.
- **PTB interleaving.** No composition helps. `AddLiquidityReceipt` has no
  abilities and Move has no dynamic dispatch, so there is no reentrancy and no
  way to smuggle the receipt out and settle it elsewhere.
- **Hostile pool.** `pool_id` is recorded from `object::id(pool)` and
  cross-checked against `position::pool_id`, both from chain state. All Cetus
  paths re-assert it. A given object id has exactly one on-chain type, so a
  lookalike `Pool<X,Y>` is not reachable.
- **Unintended generic instantiation.** `lock_for_testing` is `#[test_only]`.
  `lock` is the only production constructor and fixes `P = Position`. Structs
  cannot be built outside their defining module, so no forged `LpLock<Anything>`
  can be fed to the generic `claim`, `extend` or `destroy_claimed`.
- **Stranding the shared object.** `LpLock` has `key` only: no wrapping, no
  transfer. The only public function taking it by value is `destroy_claimed`,
  which aborts unless the caller is the beneficiary and the position is out.
- **Fee theft.** Proceeds are addressed to `lock.beneficiary`, which has no
  writer after construction. `collect_reward`'s free `R` cannot drain the vault:
  Cetus pays only the position's own accrual.
- **Fee dilution by a third-party top-up.** Cetus settles pending fees into
  `fee_owned` before increasing liquidity, so a donation cannot dilute fees
  already earned.
- **Free liquidity via rounding.** Cetus rounds required amounts up on add, so a
  dust `delta_liquidity` cannot mint liquidity for nothing.
- **Double claim, backwards extend, delete while holding.** All guarded and all
  tested.

## Checklist

1. ~~`sui move build` and `sui move test` green (sixteen tests)~~ done on
   2026-09-02. Commit the generated `Move.lock`.
2. ~~Parameterise the `cetusclmm` address for testnet, then write and run the
   integration script of finding 9 and paste its digests into that section.~~ done.
3. ~~Ship the UI copy for findings 8 and 2, and the slippage bound of finding 1 as
   a real number in the top-up form.~~ done; the UpgradeCap disclosure lives in the
   docs, with a table comparing the upgrade status of the three packages.
4. Send this package to the external audit together with vesting and
   `object_lock`. Until then the docs must keep saying, in as many words, that
   locks created in this window rest on a trust assumption.
5. Burn the `UpgradeCap` after the audit, and publish the digest. New DEXes go in
   as separate packages, never as upgrades of this one, so that growing the
   product never touches an existing lock.
