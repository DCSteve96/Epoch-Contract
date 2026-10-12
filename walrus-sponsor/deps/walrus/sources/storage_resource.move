// Interfaccia di mainnet-contracts/walrus/sources/system/storage_resource.move.
module walrus::storage_resource;

/// Reservation for storage for a given period, which is inclusive start, exclusive end.
public struct Storage has key, store {
    id: UID,
    start_epoch: u32,
    end_epoch: u32,
    storage_size: u64,
}

public fun start_epoch(_self: &Storage): u32 { abort 0 }
public fun end_epoch(_self: &Storage): u32 { abort 0 }
public fun size(_self: &Storage): u64 { abort 0 }
