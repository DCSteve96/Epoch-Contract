# Epoch Bug Bounty

We pay for responsibly disclosed vulnerabilities in the Epoch smart contracts.
Rewards are paid in **$EPT** per accepted finding.

## Scope

**In scope** (the Move code in this repository, as deployed on Sui mainnet):

- `vesting/` — vault creation, claim math, multi-beneficiary shares, fee handling
- `walrus-names/` — registry integrity, whitelist/comp logic, fee and EPT payment
  paths, marketplace escrow, offers, royalty enforcement, partner launch routing
- `object-lock/` — lock/claim/extend invariants, beneficiary checks
- `ept-gateway/` — fee burn correctness, float accounting, coin-type check,
  anything that gets a vault created without the fee being paid and burned

Vulnerability classes we care about: loss or theft of funds, unauthorized access
to locked assets, claim-math errors, bypass of fees or of the whitelist/premium
gates, registry corruption, marketplace escrow issues, griefing that permanently
blocks user assets.

**Out of scope:**

- Frontends, indexer, gateway, MCP server and any off-chain infrastructure
- Third-party protocols (Sui framework, Cetus, SuiPump, Walrus)
- Issues already known or already reported by someone else (first report wins),
  including anything already disclosed in this file or in the docs on epochsui.com
- Trust assumptions we disclose, in particular the live UpgradeCaps listed below:
  "the deployer could publish malicious code" is a known property, not a finding
- Gas-only griefing with no user-asset impact, and purely theoretical issues
  with no plausible exploit path

## Rewards

Paid in $EPT per accepted finding, at the severity we assess:

| Severity | Reward |
|---|---|
| Critical (direct loss/theft of user funds) | 250,000 $EPT |
| High (conditional loss, asset lock-up, gate bypass) | 130,000 $EPT |
| Medium (logic errors with limited impact) | 50,000 $EPT |
| Low (best-practice issues with a concrete path) | 30,000 $EPT |

## How to report

1. **Do not exploit the issue on mainnet and do not disclose it publicly.**
   That includes GitHub: **never open an issue or a pull request for a
   vulnerability.** Both are public the moment you create them, and these
   contracts are live, with real funds locked in them. A public report burns your
   own reward and puts users at risk.
2. Send it privately, through any of these:
   - the bounty form at https://contest.epochsui.com (submissions are
     write-only: nobody, not even other participants, can read them)
   - a Discord DM to the team: https://discord.gg/mBKgWWcB4p
   - email: info@epochsui.com
3. Include: affected module and function, description, impact, and a proof of
   concept or reproduction steps (testnet or a Move unit test preferred). A test
   that fails against the current source is the fastest thing for us to verify.
4. We acknowledge within 48 hours and pay out once the finding is validated
   (and, where needed, mitigated).

A pull request is welcome for a *fix* only after a finding has been reported
privately and we have agreed it is safe to discuss in the open, and for anything
that is not a vulnerability (typos, docs, test coverage).

## Upgrade status of each package (read this before reporting)

Be precise about what is and is not immutable today. This is public information
and is stated the same way in the docs on epochsui.com.

| Package | UpgradeCap | What that means |
|---|---|---|
| `object-lock` | **burned** (tx `3bFTDJwWpyPDKzKPRLhMQs65AXbwpHZJtRwpLrcw34tZ`) | immutable, no upgrade is possible by anyone |
| `vesting` | live, `0xe8d105c0f1d8b2508cd0404c2094f29ae46b0dd3929390f102ddae8278764bc3`, policy 0 (compatible), held by the deployer | the deployer can publish a new version of the package; existing vaults keep their layout and would be callable by it |
| `walrus-names` | live, `0x4f6b58209dabcbb6fda96367727edff2dc396a88ce4afbaf7f81957b4b68f263`, policy 0 (compatible), held by the deployer | same; in practice we have only ever shipped additive upgrades (v2, v3, v4) |
| `ept-gateway` | live, `0xf379a9563a118edf90f9faa1786553c4c597b55aa42770fd6663592eceb17358`, policy 0 (compatible), held by the deployer | deliberate while the fee level settles; this package holds no user tokens, only its SUI float |

Immutability of a *vault* (no cancel, no admin override, no way for us to redirect
tokens) is a property of the code as deployed. It is not the same as immutability
of the *package*. For vesting and walrus-names, the trust assumption that the
deployer will not publish malicious bytecode is real and is not covered by the
on-chain guarantees. We do not consider that assumption a vulnerability for this
bounty, because it is disclosed rather than hidden, but we will not pretend it is
absent either.

Rewards apply regardless of whether a fix is possible.

Thank you for helping keep Epoch users safe.
