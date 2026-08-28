# Epoch Bug Bounty

We pay for responsibly disclosed vulnerabilities in the Epoch smart contracts.
Rewards are paid in **$EPT** per accepted finding.

## Scope

**In scope** (the Move code in this repository, as deployed on Sui mainnet):

- `vesting/` — vault creation, claim math, multi-beneficiary shares, fee handling
- `walrus-names/` — registry integrity, whitelist/comp logic, fee and EPT payment
  paths, marketplace escrow, offers, royalty enforcement, partner launch routing
- `object-lock/` — lock/claim/extend invariants, beneficiary checks

Vulnerability classes we care about: loss or theft of funds, unauthorized access
to locked assets, claim-math errors, bypass of fees or of the whitelist/premium
gates, registry corruption, marketplace escrow issues, griefing that permanently
blocks user assets.

**Out of scope:**

- Frontends, indexer, gateway, MCP server and any off-chain infrastructure
- Third-party protocols (Sui framework, Cetus, SuiPump, Walrus)
- Issues already known or already reported by someone else (first report wins)
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
2. Send a private report via Discord DM to the team (https://discord.gg/mBKgWWcB4p)
   or email info@epochsui.com
3. Include: affected module and function, description, impact, and a proof of
   concept or reproduction steps (testnet or Move unit test preferred).
4. We acknowledge within 48 hours and pay out once the finding is validated
   (and, where needed, mitigated).

Note: the vesting package is immutable by design (no upgrade capability), so
mitigations there may take the form of public disclosure guidance and, if ever
necessary, a migration path. The walrus-names package supports additive
upgrades. Rewards apply regardless of whether a fix is possible.

Thank you for helping keep Epoch users safe.
