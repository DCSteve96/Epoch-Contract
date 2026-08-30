# Epoch EPT Gateway: internal security review

Scope: `sources/ept_gateway.move`, `tests/ept_gateway_tests.move`, `Move.toml`.
Reviewed before the mainnet deploy. Testnet package (pre-guards):
`0xafaf4b58cf98cada219c98bee145b592dbac0ef9961b7821657b05992b4d6c20`.
Reviewer: internal (pre-bounty). Date: 2026-08-30.

## What this package does, and what it deliberately does not do

The gateway lets a user pay the vesting protocol fee in $EPT instead of SUI. It
burns the EPT, advances the SUI fee out of its own float, and calls the existing
`vesting::create_vault` / `create_multi_vault`. It exists as a separate package so
that the vesting package, which custodies user tokens, does not have to be
republished for a payment feature.

The gateway never holds user tokens. The only asset it owns is the SUI float. The
vaults it creates are indistinguishable from directly created ones, because
`creator` and the emitted events use `ctx.sender()`, which is the transaction
signer, not this module.

## Summary

| # | Severity | Issue | Status |
|---|---|---|---|
| 1 | Medium | No ceiling on the SUI fee read from another contract: raising the vesting deploy fee drains the float | fixed |
| 2 | Medium | No kill switch: a large EPT price move could only be answered by setting an absurd fee | fixed |
| 3 | Low | `withdraw_sui` emitted no event, making float accounting one-sided | fixed |
| 4 | Info | `fund` is permissionless: funds sent there cannot be reclaimed by the funder | by design, documented |
| 5 | Info | The float can be depleted by legitimate use, disabling the feature until refilled | accepted |
| 6 | Info | The gateway's own UpgradeCap is live | accepted for now, see below |

## 1. Medium: the SUI fee came from a contract we do not control here

`take_sui_fee` reads `vesting::deploy_fee(treasury)` at call time. That value lives
in the vesting Treasury and can be changed with the vesting AdminCap. If it were
raised to, say, 100 SUI (deliberately or by a mistyped amount), the gateway would
pay 100 SUI per vault while still collecting a fee priced for 10 SUI, and the
float would be emptied on the next few calls.

This is the classic "external parameter used without a bound" pattern. It does not
need a malicious actor to hurt: a fat-fingered fee update is enough.

**Fix:** `max_sui_fee` in the Gateway, default 20 SUI (twice the current fee), with
`assert!(needed <= gw.max_sui_fee, ESuiFeeTooHigh)` before taking anything, and an
admin setter. Above the cap the call aborts and nothing moves: the user keeps their
EPT, the float keeps its SUI.

## 2. Medium: no way to stop the EPT path

The EPT fee is a fixed amount, chosen against the SUI price of the day. If EPT
fell hard, the discount would silently become far larger than intended. Without a
switch, the only lever was to set the fee to an absurd number, which is a hack
that also lies to anyone reading the configured fee.

**Fix:** a `paused` flag checked at the start of the payment path, with
`set_paused`. Paying the vesting fee in SUI directly is unaffected: pausing only
turns off this gateway.

## 3. Low: float accounting was one-sided

`fund` emitted `FloatFunded` but `withdraw_sui` emitted nothing, so the public
record of float movements only showed money going in. Since the float is part of
the protocol revenue loop we publish, both directions should be visible.

**Fix:** `FloatWithdrawn { amount, new_total }`.

## 4. Info: `fund` is permissionless

Anyone can top up the float, and there is no way to take it back except with the
admin cap. That is intentional: it lets us (or a partner) refill the gateway from
any wallet without moving the cap around. Anyone else sending SUI there is making
a donation, and should know it. There is no path by which a funder's SUI reaches
anything other than the vesting Treasury or the admin.

## 5. Info: the float can be depleted by ordinary use

Each vault created through the gateway costs the float one deploy fee, recovered
later by withdrawing from the vesting Treasury. Someone who wanted the feature
offline could create vaults until the float ran out, but every one of those calls
burns their own EPT, at roughly the market value of the fee. Griefing that
requires the griefer to buy and burn the token is griefing we can live with. When
the float is empty the call aborts cleanly: no vault, no burn, no partial state.

## 6. Info: the gateway is upgradeable

The UpgradeCap for this package is live. Unlike object-lock, which we made
immutable, this one holds a working balance and a fee configuration that we expect
to tune, so keeping it upgradeable is deliberate. The exposure is bounded by what
the package holds, which is the float and nothing else. Once the fee level and the
flow have settled, the cap should be burned and this note updated.

## Verified as safe

- **The user's EPT either burns exactly the fee or the call aborts.** The split is
  exact, the change goes back to `ctx.sender()`, and a zero remainder is destroyed
  rather than transferred.
- **The wrong coin cannot be used.** The configured `TypeName` is compared with
  `type_name::with_defining_ids<E>()`, so a lookalike coin from another package
  does not pass.
- **A free vault is impossible.** Both payment paths go through
  `take_and_burn_ept`, which asserts the amount before anything is created, and
  the fee cannot be configured to zero.
- **No vault is ever created without the protocol fee reaching the Treasury**, and
  a test now asserts that by withdrawing the fees and checking the amount.
- **The gateway cannot mint, freeze or redirect a vault.** It has no privileged
  access to vesting objects; it is an ordinary caller of a public function.
- **Composition is safe.** Calling this from another package or a PTB does not
  change `ctx.sender()`, so the vault still belongs to the signer.
- **No arithmetic risk:** two counters and one comparison, no multiplication, no
  scaling.

## Tests

13 Move tests: happy path single and multi, change returned, wrong coin,
underpayment, empty float, unconfigured gateway, zero fee, fee above the cap,
paused, unpause, float withdrawal, and the fee reaching the Treasury.
