# epoch-agent-pay: internal audit notes (first pass, 24 Sep 2026)

Module: `epoch_agent_pay::mandate`. Not compiled yet in this pass (the `sui` binary is not
available in the sandbox): `sui move build` and `sui move test` must be run before any
publish. 38 tests in `tests/` (23 mandate, 15 service).

## What the module promises

- **I-1. Only the agent spends, and only within the rules.** `pay` requires
  `sender == agent`, `agent != @0x0`, not paused, not expired, `0 < amount <=
  max_per_payment`, recipient allowed, `spent_in_period + amount <= max_per_period`,
  nonce unused, enough balance. Every other function that moves funds requires
  `sender == owner`.
- **I-2. The owner can always take everything back.** `withdraw`, `withdraw_all` and
  `close` check only the owner. They do not look at `paused`, `expires_ms`, the agent or
  the period. There is no delay and no path by which the agent can block them.
- **I-3. No admin, no fee.** The package has no capability. A mandate is controlled only by
  the two addresses stored in it.

Consequence of I-1 and I-2: a leaked agent key loses at most `max_per_period` per period
(see A-1 for the boundary case), and only to allowed recipients, until the owner pauses,
rotates the key or withdraws.

## Findings and design notes

- **A-1 (accepted, documented). Fixed window, not sliding.** A period restarts at the first
  payment after `period_start_ms + period_ms`. An agent can spend `max_per_period` just
  before the boundary and again just after it: worst case `2 x max_per_period` in a short
  time. A sliding window would need a queue of payments per mandate. The UI must state the
  real worst case.
- **A-2 (fixed before first compile). Lowering the cap below what was already spent.**
  `set_limits` may set `max_per_period` below `spent_in_period`. `remaining_in_period`
  used to compute `max - spent` and would abort on underflow; it now saturates at zero.
  `pay` is unaffected (it adds, then compares). Test
  `lowering_cap_below_spent_does_not_underflow`.
- **A-3 (accepted). Nonce table grows.** Used nonces are kept forever to block double
  payment on retries; storage is paid by the agent in the paying transaction and freed by
  `close`. An empty nonce skips the check, at the agent's choice. Nonces are capped at
  64 bytes.
- **A-4 (accepted). `any_recipient` removes the recipient check.** With it on, a leaked key
  can pay any address, still bounded by the caps. The UI must present it as the less safe
  option and default to a recipient list.
- **A-5 (by design). Removing the last recipient silently disables the mandate.** Allowed
  on purpose, since it is a valid way to switch it off; `create` rejects a mandate that can
  pay nobody because there it is always a mistake.
- **A-6 (by design). `top_up` is permissionless.** Adding funds grants no power, and lets
  another app or a second wallet refill a mandate.
- **A-7 (open question for the x402 layer). Shared-object contention.** Every `pay`
  mutates the mandate, so payments from one mandate are sequenced by consensus. This is
  fine for one agent per mandate at human-visible rates. For thousands of payments per
  second the right tool is Sui's payment channels ("tunnels"), not this module.
- **A-8 (confirmed on mainnet, 24 Sep 2026). x402 `exact` compatibility.** The Sui `exact`
  scheme verifies by simulating the signed transaction and checking the balance change of
  `payTo`. `pay` uses `public_transfer` of a fresh `Coin<T>`, and the check holds: a
  facilitator that verified the signature, simulated the transaction and required a balance
  change to `payTo` of exactly `amount` accepted it and settled it (tx
  `4M9NXoqUh1c21ZxWcyJvdos8MSprEcm61iD4SXhRQcjV`, 0.001 SUI from mandate
  `0x96462e9e…a747`). Gas is paid by the agent, so `payTo` sees exactly `amount`. The same
  run confirmed that a repeated request id is refused on chain (abort 8).
- **A-9 (accepted). Gas is not covered by the mandate.** The agent address needs SUI for
  gas, unless a sponsor (gas station) signs as gas owner. Keep only a small amount of SUI
  on the agent key; it is outside the mandate's protection.
- **A-10 (accepted). The owner is a plain address.** There is no ownership transfer in v1.
  Losing the owner key means the funds stay in the mandate: the agent can still spend them
  within the caps, nobody else can withdraw.

## Services (second pass, 24 Sep 2026)

Module `epoch_agent_pay::service`: a seller lists `Service<T>` with its own price, payout
address and endpoint; `mandate::pay_service` pays exactly the listed price.

- **S-1 (by design). The price comes from the listing, bounded by the payer.** `pay_service`
  reads `price` from the `Service` and requires `price <= max_price`. A seller who raises the
  price while a payment is in flight makes it abort instead of charging more. Tests
  `pays_the_listed_price_to_pay_to`, `price_raised_in_flight_fails`.
- **S-2 (accepted). Allowing a service means trusting its owner's `pay_to`.** A mandate may
  list a service id instead of an address. The seller can later change `pay_to`; payments
  then go to the new address, still bounded by the price check and the mandate caps. Owners
  who want to pin the payee list the `pay_to` address instead. The UI must say which one
  is stored.
- **S-3 (accepted). `name` is a claim.** The contract does not check that the seller holds
  the `.epoch` NameCap it declares; readers must verify it (NameCap holder == `owner`) before
  showing the name as verified. Doing it in Move would add a dependency on walrus-names.
- **S-4 (by design). No contention on the service.** `pay_service` takes `&Service<T>`, and
  the service has no counter, so concurrent buyers do not serialize on it. Per-service
  statistics come from `Paid` events, which carry the service id.
- **S-5 (by design). Receipts are events.** `Paid<T>` carries a per-mandate `receipt_no`,
  payer, agent, recipient, service, amount, nonce, memo (<= 128 bytes) and timestamp. The
  coin is the event's type argument. No receipt object is created: on micro-payments its
  storage would cost more than the payment.
- **S-6 (to remember). Struct layouts are final at publish.** Upgrades can add functions and
  new objects, not fields. Anything added later (seller tax details, protocol fee config)
  goes into dynamic fields or new objects.

- **S-7 (by design). Two kinds, fixed at creation.** `KIND_API` is paid per call
  (`mandate::pay_service` or `service::buy`); `KIND_JOB` is a deliverable and neither path
  accepts it (`EServiceNotApi`, `ENotApi`), so a job can only be paid through the escrow
  module that comes later. `update` cannot change `kind`: a buyer who paid for an API must
  never find a job behind the same id. Tests `a_job_is_not_bought_directly`,
  `a_job_is_not_paid_from_a_mandate`, `unknown_kind_rejected`.
- **S-8 (accepted). `buy` has no double-payment guard.** A nonce table would make every
  purchase write the shared service and queue all buyers on it (the opposite of S-4). The
  nonce travels in `ServicePaid` so the seller can reconcile. Buyers who need the guard pay
  from a mandate. Exact amount only (`EWrongAmount`), so there is no change to refund.
- **S-9 (accepted). `category` and `doc` are the seller's claims.** `doc` is a Walrus blob
  id; the app reads it through the blob proxy and treats its content as untrusted text (no
  HTML rendered from it). `category` is free text on chain, the app maps it to a closed list
  and files anything unknown under "other".

38 tests after this pass (23 mandate, 15 service).

## Upgrade v2: deleting a listing (24 Sep 2026)

Additive: `service::delete<T>(s: Service<T>, ctx)` and the event `ServiceDeleted`. No struct
change, no `VERSION`, every v1 function keeps working.

- **Owner only** (`ENotOwner`), checked against the current owner, so after
  `transfer_ownership` the old owner can no longer delete (test
  `the_old_owner_cannot_delete_after_a_transfer`).
- **Mandates that allow the deleted id.** They keep an id that points to nothing:
  `pay_service` cannot be built any more, because the object is gone. Nothing is paid and
  nothing is locked: the mandate's funds are untouched and the owner can still withdraw.
- **What deleting does not stop.** x402 payments go to the `pay_to` address, not to the
  service object. A seller who deletes the listing but keeps answering 402 can still be paid
  by any mandate that allows that address. Said on the page next to the delete button.
- **Receipts survive.** `Paid` and `ServicePaid` are events; deleting the object does not touch them.
- **Type tag rule.** `ServiceDeleted` is introduced in v2, so its type carries the v2 package
  address. Anyone filtering that event must use v2, not the origin.
- Tests: 3 new (delete by owner, delete by stranger rejected, delete by previous owner rejected).

## Before publish

1. `sui move build` and `sui move test` on the Mac, all green.
2. Dry run of `create` + `pay` on mainnet with USDC, and the x402 balance-change check (A-8).
3. Keep the UpgradeCap until an external review; state it in SECURITY.md like the others.
