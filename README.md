# Epoch Contracts

The Move smart contracts powering the [Epoch](https://epochsui.com) ecosystem on Sui:
trustless vesting, `.epoch` names with on-chain Walrus sites, and object/LP locking.

All contracts are live on Sui mainnet. This repository exists for transparency and
for the **Epoch Bug Bounty** (see [SECURITY.md](./SECURITY.md)).

## Packages

### 1. `vesting/` — Epoch Vesting
Trustless, non-custodial token vesting vaults.
- Cliff, linear and hybrid schedules
- Single and multi-beneficiary vaults (up to 20 wallets, basis-point shares)
- Immutable after deploy: no admin keys, no upgrade, no cancellation

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
| v4 (current) | `0xc868bfcfc7aeee0fc3938b632fce15856882092554d1068ce4cdddbd7b23fcd8` | + pay-in-EPT |

Shared objects: Registry `0xa6d9e91daa40dbff259838c9f5bd6448d8f08e9b2a3da02c5d4d3c88ce5666d1`,
Treasury `0xb3c54987a9f45aa194ebcbaee979fc8654c2deeb7e5824a61ce2faff41573436`.

### 3. `object-lock/` — Epoch Object Lock (LP locking)
Time-lock ANY `key + store` object (LP positions, NFTs) until a date.
- Cliff-only, zero admin, zero fees
- Shared locks: public proof-of-lock, verifiable by anyone
- Unlock date can only be extended, never shortened
- No function ever hands out `&mut T`, so liquidity cannot be pulled out of a
  locked LP position

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

### 4. `ept-gateway/` — Epoch EPT Gateway
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
cd object-lock  && sui move test   # 11 tests: lock, claim, extend, aborts
cd ept-gateway  && sui move test   # 13 tests: burn, float, cap, pause (needs ../vesting)
```

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
