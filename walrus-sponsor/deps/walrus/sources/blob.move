// Interfaccia di mainnet-contracts/walrus/sources/system/blob.move.
module walrus::blob;

use walrus::storage_resource::Storage;

public struct Blob has key, store {
    id: UID,
    registered_epoch: u32,
    blob_id: u256,
    size: u64,
    encoding_type: u8,
    // Stores the epoch first certified.
    certified_epoch: option::Option<u32>,
    storage: Storage,
    // Marks if this blob can be deleted.
    deletable: bool,
}

public fun object_id(_self: &Blob): ID { abort 0 }
public fun registered_epoch(_self: &Blob): u32 { abort 0 }
public fun blob_id(_self: &Blob): u256 { abort 0 }
public fun size(_self: &Blob): u64 { abort 0 }
public fun certified_epoch(_self: &Blob): &Option<u32> { abort 0 }
public fun is_deletable(_self: &Blob): bool { abort 0 }
public fun end_epoch(_self: &Blob): u32 { abort 0 }
