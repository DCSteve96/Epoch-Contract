/// Epoch Walrus Sponsor: Epoch pays for a user's Walrus blob, the user signs
/// and owns it.
///
/// Why this exists (30 Sep 2026). Until now every Epoch Names site was uploaded
/// by one protocol wallet, which paid and therefore OWNED every blob and SENT
/// every transaction. On chain, Epoch Names looked like one very busy user.
/// The fix: the user sends the register transaction and receives the Blob,
/// Epoch pays the gas (sponsored transaction) and the WAL (from this treasury).
///
/// WAL leaves the treasury only as a LOAN that must be closed in the same
/// transaction by a Walrus Blob that is new, bought for the full storage
/// period, and exactly the content the Epoch server signed.
///
/// The flow, all in ONE programmable transaction sent by the user:
///   1. `borrow`  checks the server voucher and lends exactly `amount` WAL,
///                returning the coin and a `Loan` hot potato;
///   2. the PTB calls Walrus `reserve_space` + `register_blob` with that coin;
///   3. `settle`  consumes the `Loan` and the Blob BY VALUE, checks it, gives
///                the Blob to the sender and takes back what is left of the coin.
///
/// What `settle` requires of the Blob, and the attack each check closes
/// (v2, after the audit of 30 Sep 2026):
/// - blob id + size of the voucher: the WAL buys storage for the content the
///   server saw and priced;
/// - taken BY VALUE: a frozen or shared Blob of somebody else cannot be
///   passed, so a third party's long-lived blob can never close a loan;
/// - not deletable: a deletable blob can be deleted to recover its `Storage`,
///   which is transferable and worth WAL;
/// - not certified and registered no earlier than the voucher's epoch: the
///   Blob is new. Without this, a user could extend an OLD blob of the same
///   content for a few epochs, close the loan with it and keep the WAL;
/// - lasting at least `min_epochs` from its registration: storage for fewer
///   epochs would cost less and leave WAL over;
/// - never used before: an uncertified Blob that closed one loan cannot close
///   another.
/// `borrow` also refuses an `amount` above `price_base + price_per_mib * MiB`
/// of the signed size, so even a leaked server key cannot sign a price far
/// above what Walrus charges: whatever is not spent comes back as change.
///
/// What remains, by design: a user who obtains a new qualifying Blob more
/// cheaply than list price (a Walrus buyer subsidy, storage bought earlier at
/// a lower price) keeps the difference. It is bounded by the pricing slack.
///
/// This module NEVER calls the Walrus system. Walrus checks its own package
/// version inside `System`, so a module linked to an older Walrus version
/// would break at every Walrus upgrade. Here the PTB calls the current Walrus
/// package and this module only READS the Blob through its accessors, which
/// have no version check.
module epoch_walrus_sponsor::sponsor;

use sui::balance::{Self, Balance};
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::ed25519;
use sui::event;
use wal::wal::WAL;
use walrus::blob::Blob;

// === Errors ===

const EPaused: u64 = 0;
const EExpired: u64 = 1;
const EBadSignature: u64 = 2;
const ENonceUsed: u64 = 3;
const EAboveLoanCap: u64 = 4;
const EAboveDayCap: u64 = 5;
const EInsufficientTreasury: u64 = 6;
const EZeroAmount: u64 = 7;
const EWrongTreasury: u64 = 8;
const EWrongBlobId: u64 = 9;
const EWrongSize: u64 = 10;
const EDeletable: u64 = 11;
const ETooShort: u64 = 12;
const EBlobAlreadyUsed: u64 = 13;
const EWrongCap: u64 = 14;
const EBadPublicKey: u64 = 15;
const EWrongVersion: u64 = 16;
const EAbovePrice: u64 = 17;
const ECertified: u64 = 18;
const EOldBlob: u64 = 19;
const EBadConfig: u64 = 20;
const ENotExpired: u64 = 21;

// === Constants ===

const VERSION: u64 = 1;
const DAY_MS: u64 = 86_400_000;
const MIB: u64 = 1_048_576;
/// Domain separator: a signature made for anything else can never be a voucher.
const DOMAIN: vector<u8> = b"epoch-walrus-sponsor/voucher/v2";

// === Objects ===

/// Shared. Holds the WAL that pays for users' blobs.
public struct Treasury has key {
    id: UID,
    version: u64,
    balance: Balance<WAL>,
    /// Ed25519 public key (32 bytes) of the Epoch server that signs vouchers.
    signer_pubkey: vector<u8>,
    paused: bool,
    /// Absolute ceiling of one loan.
    max_per_loan: u64,
    /// Ceiling per day window: an emergency brake, set well above normal use.
    day_cap: u64,
    day_start_ms: u64,
    day_spent: u64,
    /// Price ceiling of one loan: price_base + price_per_mib * ceil(size / MiB).
    price_base: u64,
    price_per_mib: u64,
    /// Storage period the Blob must have, from its registration epoch.
    min_epochs: u32,
    /// Lifetime totals, for anyone reading the chain.
    total_lent: u64,
    total_returned: u64,
    loans: u64,
}

/// Admin of one treasury.
public struct AdminCap has key, store {
    id: UID,
    treasury: ID,
}

/// Hot potato: no abilities, so it can only disappear through `settle`,
/// in the same transaction that created it.
public struct Loan {
    treasury: ID,
    blob_id: u256,
    size: u64,
    epoch: u32,
    amount: u64,
}

/// Dynamic field keys on the treasury. A used nonce stores its voucher's
/// expiry, so it can be pruned once the voucher is dead anyway.
public struct NonceKey has copy, drop, store { nonce: u64 }
public struct BlobKey has copy, drop, store { blob: ID }

// === Events ===

public struct TreasuryCreated has copy, drop { treasury: ID, admin: address }
public struct Lent has copy, drop { treasury: ID, user: address, blob_id: u256, size: u64, amount: u64, nonce: u64 }
public struct Settled has copy, drop { treasury: ID, user: address, blob: ID, blob_id: u256, size: u64, spent: u64, returned: u64 }
public struct Deposited has copy, drop { treasury: ID, amount: u64 }
public struct Withdrawn has copy, drop { treasury: ID, amount: u64 }
public struct ConfigChanged has copy, drop { treasury: ID, paused: bool, max_per_loan: u64, day_cap: u64 }
public struct PricingChanged has copy, drop { treasury: ID, price_base: u64, price_per_mib: u64, min_epochs: u32 }
public struct SignerRotated has copy, drop { treasury: ID }

// === Setup ===

/// Creates and shares a treasury; the caller gets its AdminCap.
public fun create(
    signer_pubkey: vector<u8>,
    max_per_loan: u64,
    day_cap: u64,
    price_base: u64,
    price_per_mib: u64,
    min_epochs: u32,
    ctx: &mut TxContext,
): AdminCap {
    assert!(signer_pubkey.length() == 32, EBadPublicKey);
    assert!(price_base > 0 && min_epochs > 0, EBadConfig);
    let treasury = Treasury {
        id: object::new(ctx),
        version: VERSION,
        balance: balance::zero(),
        signer_pubkey,
        paused: false,
        max_per_loan,
        day_cap,
        day_start_ms: 0,
        day_spent: 0,
        price_base,
        price_per_mib,
        min_epochs,
        total_lent: 0,
        total_returned: 0,
        loans: 0,
    };
    let tid = object::id(&treasury);
    event::emit(TreasuryCreated { treasury: tid, admin: ctx.sender() });
    transfer::share_object(treasury);
    AdminCap { id: object::new(ctx), treasury: tid }
}

// === The loan ===

/// The exact bytes the server signs. Public so off-chain code can be tested
/// against it: any difference in encoding is a signature that never verifies.
/// `epoch` is the Walrus epoch when the server priced the blob.
public fun voucher_message(
    treasury: ID,
    user: address,
    blob_id: u256,
    size: u64,
    epoch: u32,
    amount: u64,
    nonce: u64,
    expires_ms: u64,
): vector<u8> {
    let mut m = DOMAIN;
    m.append(bcs::to_bytes(&treasury));
    m.append(bcs::to_bytes(&user));
    m.append(bcs::to_bytes(&blob_id));
    m.append(bcs::to_bytes(&size));
    m.append(bcs::to_bytes(&epoch));
    m.append(bcs::to_bytes(&amount));
    m.append(bcs::to_bytes(&nonce));
    m.append(bcs::to_bytes(&expires_ms));
    m
}

/// The most one loan may lend for a blob of `size` bytes.
public fun price_ceiling(t: &Treasury, size: u64): u64 {
    let mib = (size + MIB - 1) / MIB;
    t.price_base + t.price_per_mib * mib
}

/// Lends exactly `amount` WAL for one blob, against a voucher signed by the
/// Epoch server for this sender.
public fun borrow(
    t: &mut Treasury,
    blob_id: u256,
    size: u64,
    epoch: u32,
    amount: u64,
    nonce: u64,
    expires_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<WAL>, Loan) {
    let msg = voucher_message(object::id(t), ctx.sender(), blob_id, size, epoch, amount, nonce, expires_ms);
    assert!(ed25519::ed25519_verify(&signature, &t.signer_pubkey, &msg), EBadSignature);
    borrow_impl(t, blob_id, size, epoch, amount, nonce, expires_ms, clock.timestamp_ms(), ctx)
}

fun borrow_impl(
    t: &mut Treasury,
    blob_id: u256,
    size: u64,
    epoch: u32,
    amount: u64,
    nonce: u64,
    expires_ms: u64,
    now_ms: u64,
    ctx: &mut TxContext,
): (Coin<WAL>, Loan) {
    assert!(t.version == VERSION, EWrongVersion);
    assert!(!t.paused, EPaused);
    assert!(now_ms <= expires_ms, EExpired);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= t.max_per_loan, EAboveLoanCap);
    assert!(amount <= price_ceiling(t, size), EAbovePrice);
    assert!(!df::exists(&t.id, NonceKey { nonce }), ENonceUsed);

    // Day window: an emergency brake on what a leaked key or a bug could spend.
    if (now_ms >= t.day_start_ms + DAY_MS) {
        t.day_start_ms = now_ms;
        t.day_spent = 0;
    };
    assert!(t.day_spent + amount <= t.day_cap, EAboveDayCap);
    assert!(t.balance.value() >= amount, EInsufficientTreasury);

    df::add(&mut t.id, NonceKey { nonce }, expires_ms);
    t.day_spent = t.day_spent + amount;
    t.total_lent = t.total_lent + amount;
    t.loans = t.loans + 1;

    let tid = object::id(t);
    event::emit(Lent { treasury: tid, user: ctx.sender(), blob_id, size, amount, nonce });
    let coin = coin::from_balance(t.balance.split(amount), ctx);
    (coin, Loan { treasury: tid, blob_id, size, epoch, amount })
}

/// Closes the loan with the Blob the WAL paid for, gives the Blob to the
/// sender and takes back what is left of the coin. The transfer happens here,
/// not in the PTB, on purpose: taking the Blob by value is what keeps frozen
/// or shared Blobs out, and the sender is the user the voucher was signed for.
#[allow(lint(self_transfer))]
public fun settle(t: &mut Treasury, loan: Loan, blob: Blob, change: Coin<WAL>, ctx: &TxContext) {
    settle_impl(
        t, loan, object::id(&blob),
        walrus::blob::blob_id(&blob), walrus::blob::size(&blob),
        walrus::blob::is_deletable(&blob), walrus::blob::certified_epoch(&blob).is_some(),
        walrus::blob::registered_epoch(&blob), walrus::blob::end_epoch(&blob),
        change, ctx,
    );
    transfer::public_transfer(blob, ctx.sender());
}

fun settle_impl(
    t: &mut Treasury,
    loan: Loan,
    blob_object: ID,
    blob_id: u256,
    size: u64,
    deletable: bool,
    certified: bool,
    registered_epoch: u32,
    end_epoch: u32,
    change: Coin<WAL>,
    ctx: &TxContext,
) {
    let Loan { treasury, blob_id: want_id, size: want_size, epoch, amount } = loan;
    assert!(t.version == VERSION, EWrongVersion);
    assert!(treasury == object::id(t), EWrongTreasury);
    assert!(blob_id == want_id, EWrongBlobId);
    assert!(size == want_size, EWrongSize);
    assert!(!deletable, EDeletable);
    assert!(!certified, ECertified);
    assert!(registered_epoch >= epoch, EOldBlob);
    assert!((end_epoch as u64) >= (registered_epoch as u64) + (t.min_epochs as u64), ETooShort);
    assert!(!df::exists(&t.id, BlobKey { blob: blob_object }), EBlobAlreadyUsed);
    df::add(&mut t.id, BlobKey { blob: blob_object }, true);

    let returned = change.value();
    t.total_returned = t.total_returned + returned;
    t.balance.join(change.into_balance());
    let spent = if (returned >= amount) { 0 } else { amount - returned };
    event::emit(Settled { treasury, user: ctx.sender(), blob: blob_object, blob_id, size, spent, returned });
}

/// Anyone may remove nonces whose voucher has expired: an expired voucher is
/// refused by `borrow` anyway, so the nonce no longer protects anything, and
/// the caller gets the storage rebate.
public fun prune_nonces(t: &mut Treasury, nonces: vector<u64>, clock: &Clock) {
    prune_impl(t, nonces, clock.timestamp_ms())
}

fun prune_impl(t: &mut Treasury, nonces: vector<u64>, now_ms: u64) {
    nonces.do!(|nonce| {
        let key = NonceKey { nonce };
        if (df::exists(&t.id, key)) {
            let expires: &u64 = df::borrow(&t.id, key);
            assert!(now_ms > *expires, ENotExpired);
            let _: u64 = df::remove(&mut t.id, key);
        }
    });
}

// === Funding and admin ===

/// Anyone can top up the treasury.
public fun deposit(t: &mut Treasury, coin: Coin<WAL>) {
    let amount = coin.value();
    t.balance.join(coin.into_balance());
    event::emit(Deposited { treasury: object::id(t), amount });
}

public fun withdraw(cap: &AdminCap, t: &mut Treasury, amount: u64, ctx: &mut TxContext): Coin<WAL> {
    assert!(cap.treasury == object::id(t), EWrongCap);
    event::emit(Withdrawn { treasury: object::id(t), amount });
    coin::from_balance(t.balance.split(amount), ctx)
}

public fun set_config(cap: &AdminCap, t: &mut Treasury, paused: bool, max_per_loan: u64, day_cap: u64) {
    assert!(cap.treasury == object::id(t), EWrongCap);
    t.paused = paused;
    t.max_per_loan = max_per_loan;
    t.day_cap = day_cap;
    event::emit(ConfigChanged { treasury: object::id(t), paused, max_per_loan, day_cap });
}

/// Walrus prices change by governance: keep the ceiling a little above them.
public fun set_pricing(cap: &AdminCap, t: &mut Treasury, price_base: u64, price_per_mib: u64, min_epochs: u32) {
    assert!(cap.treasury == object::id(t), EWrongCap);
    assert!(price_base > 0 && min_epochs > 0, EBadConfig);
    t.price_base = price_base;
    t.price_per_mib = price_per_mib;
    t.min_epochs = min_epochs;
    event::emit(PricingChanged { treasury: object::id(t), price_base, price_per_mib, min_epochs });
}

/// New server key: every voucher signed with the old one stops working at once.
public fun rotate_signer(cap: &AdminCap, t: &mut Treasury, signer_pubkey: vector<u8>) {
    assert!(cap.treasury == object::id(t), EWrongCap);
    assert!(signer_pubkey.length() == 32, EBadPublicKey);
    t.signer_pubkey = signer_pubkey;
    event::emit(SignerRotated { treasury: object::id(t) });
}

/// After a package upgrade that bumps VERSION: moves the treasury to the new
/// code, and the old code stops working on it.
public fun migrate(cap: &AdminCap, t: &mut Treasury) {
    assert!(cap.treasury == object::id(t), EWrongCap);
    assert!(t.version < VERSION, EWrongVersion);
    t.version = VERSION;
}

// === Reads ===

public fun balance_of(t: &Treasury): u64 { t.balance.value() }
public fun is_paused(t: &Treasury): bool { t.paused }
public fun limits(t: &Treasury): (u64, u64, u64, u64) { (t.max_per_loan, t.day_cap, t.day_start_ms, t.day_spent) }
public fun pricing(t: &Treasury): (u64, u64, u32) { (t.price_base, t.price_per_mib, t.min_epochs) }
public fun totals(t: &Treasury): (u64, u64, u64) { (t.total_lent, t.total_returned, t.loans) }
public fun nonce_used(t: &Treasury, nonce: u64): bool { df::exists(&t.id, NonceKey { nonce }) }
public fun blob_used(t: &Treasury, blob: ID): bool { df::exists(&t.id, BlobKey { blob }) }

// === Test-only entry points (the same checks, minus the signature and the Blob type) ===

#[test_only]
public fun borrow_for_testing(
    t: &mut Treasury, blob_id: u256, size: u64, epoch: u32, amount: u64, nonce: u64,
    expires_ms: u64, now_ms: u64, ctx: &mut TxContext,
): (Coin<WAL>, Loan) {
    borrow_impl(t, blob_id, size, epoch, amount, nonce, expires_ms, now_ms, ctx)
}

#[test_only]
public fun settle_for_testing(
    t: &mut Treasury, loan: Loan, blob_object: ID, blob_id: u256, size: u64, deletable: bool,
    certified: bool, registered_epoch: u32, end_epoch: u32, change: Coin<WAL>, ctx: &TxContext,
) {
    settle_impl(t, loan, blob_object, blob_id, size, deletable, certified, registered_epoch, end_epoch, change, ctx)
}

#[test_only]
public fun prune_for_testing(t: &mut Treasury, nonces: vector<u64>, now_ms: u64) {
    prune_impl(t, nonces, now_ms)
}

#[test_only]
public fun mint_wal_for_testing(amount: u64, ctx: &mut TxContext): Coin<WAL> {
    coin::from_balance(balance::create_for_testing<WAL>(amount), ctx)
}
