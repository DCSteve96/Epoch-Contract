# Epoch Contracts

The Move smart contracts powering the [Epoch](https://epochsui.com) ecosystem on Sui:
trustless vesting, `.epoch` names with on-chain Walrus sites, and liquidity locking
that does not force you to give up the fees.

All contracts are live on Sui mainnet. This repository exists for transparency and
for the **Epoch Bug Bounty** (see [SECURITY.md](./SECURITY.md)).

## Packages

### 1. `vesting/` — Epoch Vesting
Trustless, non-custodial token vesting vaults.
- Cliff, linear and hybrid schedules
- Single and multi-beneficiary vaults (up to 20 wallets, basis-point shares)
- Vaults cannot be cancelled or redirected once created: no admin override on a vault
- The package itself is still upgradeable (live UpgradeCap, policy compatible): see the
  upgrade status table in [SECURITY.md](./SECURITY.md#upgrade-status-of-each-package-read-this-before-reporting)

| Network | Package |
|---|---|
| Mainnet | `0x848cb7edf8b5f7650b3188dec459394472c8ccf206a031497bf55fe40c165da2` |
| Testnet | `0xad8aaa22827d18b3a67d6a619cb8475b8ec1f409b1b44457b7ead0c56f184081` |

### 2. `walrus-names/` — Epoch Names
`.epoch` naming registry + kiosk marketplace with 1% royalty.
- One-shot whitelist (comped registrations), 3-char premium gate
- Pay-in-EPT registrations (`register_with_ept`)
- Partner launch revenue routing (`record_partner_launch`)

| Version | Mainnet package | Notes |
|---|---|---|
| v1 (origin) | `0x5dd1fb9f784129f0815c8e54ed917ad698401c0900ebeb1525f37fac98a94dda` | register, marketplace, NameCap type-origin |
| v2 | `0x7a1773e18d571a173bedf17b5e7a01fe7cbb67431246cc6bdb7d997aa03dda90` | + `record_partner_launch` |
| v3 | `0x737cd24ef7abbb1739279916fe88d9bf427ad68567baff74904829d8021f8408` | + 3-char comp gate |
| v4 | `0xc868bfcfc7aeee0fc3938b632fce15856882092554d1068ce4cdddbd7b23fcd8` | + pay-in-EPT |
| v5 (current) | `0x008673e8e3d3580db6335c86895b1fa9bbb428b4a0bd3d7cf8e06c6556cb7ab7` | current register target |

Shared objects: Registry `0xa6d9e91daa40dbff259838c9f5bd6448d8f08e9b2a3da02c5d4d3c88ce5666d1`,
Treasury `0xb3c54987a9f45aa194ebcbaee979fc8654c2deeb7e5824a61ce2faff41573436`.

### 3. `lp-lock/` — Epoch LP Lock
Time-lock a Cetus CLMM position without giving up the income it produces.
- The capital cannot move before the unlock date, by anyone, us included
- Fees and rewards stay collectable for the whole duration and always go to the
  beneficiary, never to the caller
- Anyone can add liquidity to a lock; nobody can take any out before the date
- `&mut Position` exists in exactly one function, `add_liquidity`, where it is
  consumed by the next statement and the Cetus receipt is settled in the same body

It exists because of a limitation of the package below it. Under `object-lock` a
locked position is wrapped, so nothing can call `collect_fee` on it: locking means
forfeiting the income, and that is the real reason teams do not lock their
liquidity. This package separates the two, so the capital is frozen and the income
is not.

| Version | Mainnet package | Notes |
|---|---|---|
| v1 (origin) | `0x5ab27e275f349447c34592868d34f5a03b93ee4d8e884a516b798e6fc85f8404` | defines the types and events, never changes |
| v2 (current) | `0x3819764c00d94e78ee6b80bef75dff335a06828904ca747339c6d5a149eb9b81` | records the amounts with `clmm_math::get_amount_by_liquidity`, because `pool::get_position_amounts` aborts with code 32 on the version of Cetus running on mainnet |

The UpgradeCap `0x5449cdcca3d10fcf3189c4e3abf0856a942deb058cd0fbaaff79c38ebe3e6e23`
is still held by the deployer, on purpose: this package is days old, and burning
the cap now would mean the first bug could only be announced, not fixed. It goes
`make_immutable` after the external audit, with the digest published. Two things
hold that promise honest in the meantime: the docs say plainly that locks created
in this window rest on a trust assumption, and **new DEXes ship as separate
packages, never as upgrades of this one**, so growing the product can never reach
an existing lock.

Cetus only for now. The interface of every other DEX we looked at is not published
as Move source, so support for each one is its own package and its own review.

Our two-pass review is in [lp-lock/AUDIT.md](./lp-lock/AUDIT.md): 2 High and 7
Medium found and closed, the one still open being the cap above, plus the full
testnet run and the mainnet smoke test with every digest.

The Cetus interface and its two dependencies are vendored under `lp-lock/deps/`.
Upstream declares them through the Move Registry, which needs the `mvr` binary
installed to resolve: a package that sells verifiability cannot ask an auditor to
install an extra tool to reproduce the bytecode. The sources are the upstream ones
with the bodies replaced by `abort 0`, since the real logic lives in the Cetus
package on chain.

### 4. `object-lock/` — Epoch Object Lock
Time-lock ANY `key + store` object (NFTs, caps, LP positions) until a date.
- Cliff-only, zero admin, zero fees
- Shared locks: public proof-of-lock, verifiable by anyone
- Unlock date can only be extended, never shortened
- No function ever hands out `&mut T`, so nothing can be pulled out of a locked
  object

Still live, still supported, and immutable, so the locks created with it keep
working and stay verifiable. For liquidity, use `lp-lock/` above instead: it locks
the same position and leaves the fees collectable, which this one cannot do,
because a wrapped object cannot be called at all.

| Version | Mainnet package | Notes |
|---|---|---|
| v1 (origin) | `0xe0f23402fae139961a3d5ffa99d054a7821b82295eb5988957053f0c9a4dd14d` | defines the types and events, never changes |
| v2 (current) | `0x0267556b54173e71b4eefce7c2466770fa52842d0b4242dae49f023022636e89` | rejects a `@0x0` beneficiary |

The UpgradeCap was destroyed on 29 Aug 2026
(tx `3bFTDJwWpyPDKzKPRLhMQs65AXbwpHZJtRwpLrcw34tZ`): this package is immutable and
can never be upgraded, by us or by anyone.

Our own review of this package is in [object-lock/AUDIT.md](./object-lock/AUDIT.md),
including the issues we found and fixed. Findings we listed as open are fair game
for the bounty, as is anything we missed.

### 5. `ept-gateway/` — Epoch EPT Gateway
Pay the vesting deploy fee in $EPT instead of SUI, at a discount.
- The EPT is burned by the contract, in the same call, not by us afterwards
- Not an upgrade of `vesting`: it calls the existing public entry points, so the
  vaults it creates are identical to directly created ones
- Holds no user tokens: only a SUI float used to advance the protocol fee

| Network | Package | Gateway (shared) |
|---|---|---|
| Mainnet | `0xfe47be69142372eacab34f66b936989079840501a0d85209ac68c8ba6f74eea5` | `0x75da1b355776cb2bbb7a5eed89710a63dffb5ff43a1f440bb058c4d31c2fbab3` |
| Testnet | `0xd356dd8d1e409af5d26389bf07507fc0218c01ef83161d1dc17f50cbadb9ad94` | `0xe1c3a2cadea7a0ad9656c0ae7fffeb909c67a09fa25745268ee4e9073cdfd14a` |

Our review, including the two guards it made us add, is in
[ept-gateway/AUDIT.md](./ept-gateway/AUDIT.md).

## Running the tests

Each package ships its Move unit tests:

```bash
cd vesting      && sui move test   # vesting suite
cd walrus-names && sui move test   # 32 tests: names, marketplace, EPT, comp gate
cd lp-lock      && sui move test   # 16 tests: lock, claim, extend, guards, aborts
cd object-lock  && sui move test   # 11 tests: lock, claim, extend, aborts
cd ept-gateway  && sui move test   # 13 tests: burn, float, cap, pause (needs ../vesting)
```

The Cetus paths of `lp-lock` cannot be reached by a unit test, because there is no
way to build a `Pool` or a `Position` outside a live network. They are covered by a
scripted testnet run whose digests are in the audit, and by the mainnet run that
locked a real position, collected its fees while locked and claimed it back.

## Bug bounty

Found a vulnerability? **Do not exploit it on mainnet and do not disclose it
publicly.** Read [SECURITY.md](./SECURITY.md) for scope, rewards (paid in $EPT)
and how to report privately.

## Links

- Website: https://epochsui.com
- Names: https://names.epochsui.com
- X: https://x.com/EpochSui
- Discord: https://discord.gg/mBKgWWcB4p

## License

[MIT](./LICENSE)

### 6. `templates/` — Epoch Names template marketplace
Templates for `.epoch` sites sold as licenses, with a burn of EPT on every sale
and reviews on chain.

| Network | Package |
|---|---|
| Mainnet | `0x197da7e5ec45bdb03a3973e02f0a6f7cdb28dbee1f6864e4da2fafbc70ba8aa7` |

### 7. `drops/` — Epoch Drops
Airdrops with vesting paid from a single vault: one vault, many claimants, each
with their own schedule.

| Network | Package |
|---|---|
| Mainnet | `0xf1739bcbc89a6954e031b6a1ef31809800e1e76d4ec914311bfa9eefefa042c4` |

### 8. `farm/` — Epoch Farm
LP incentives without custody: positions stay with their owners, rewards are paid
from a vault against on chain proofs published by the farm worker.

| Network | Package |
|---|---|
| Mainnet | `0xe11651eb8a9255595e003db29098e7a2d10f0a123d60b031c66ed0c9bb5023c7` |

### 9. `agent-pay/` — Epoch Agent Pay
Budgets for AI agents with limits enforced by the chain: an agent key can only
`pay`, within a per-payment cap, a per-period cap, an allow-list of recipients
and an expiry. The owner withdraws at any time. Services and x402 payments are
built on it.

| Network | Package |
|---|---|
| Mainnet | `0x2d97b3dcf248734bd8f536ea98bc22de71382c1b678f6a70680961b0353903ed` |

### 10. `walrus-sponsor/` — Sponsored Walrus uploads
The user owns the blob, Epoch pays the WAL: an on chain treasury that funds
`register_blob` for sites and templates, with per-blob vouchers signed by the
sponsor and settled in the same transaction.

| Network | Package |
|---|---|
| Mainnet | `0x89139211aac66986da056559dcc3010703b22847e1559e8479eba716227db400` |

### 11. `names-gateway/` — Partner tokens for `.epoch` names
Pay a `.epoch` name in a partner project's token at a discount. The gateway pays
the registry in SUI from its own float and keeps the partner token; the only way
the tokens leave is into an Epoch vesting vault locked for at least 12 months,
enforced by the contract. Fees can be adjusted by a keeper within owner-set
bounds, one step every 6 hours.

| Network | Package |
|---|---|
| Mainnet | `0x7202fca25991c1042669901f5975f33867ffd4ab7a4ab6011b017be030f85abf` |
