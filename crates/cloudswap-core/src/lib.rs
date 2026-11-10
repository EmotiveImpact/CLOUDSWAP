//! Portable acknowledgement policy for sealed blocks. No OS swap hooks.
//! Backend implementations must enforce deadlines and authenticate payloads.
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error { Offline, UncertainWrite, Poisoned, Missing, InvalidBlock, Capacity }

pub trait ObjectStore {
    fn put(&mut self, key: u64, sealed: &[u8]) -> Result<(), Error>;
    fn get(&mut self, key: u64) -> Result<Vec<u8>, Error>;
}

pub struct Pager<B> {
    backend: B,
    index: BTreeMap<u64, u64>,
    generation: u64,
    poisoned: bool,
    max_blocks: u64,
    max_payload: usize,
}
impl<B: ObjectStore> Pager<B> {
    pub fn new(backend: B, max_blocks: u64, max_payload: usize) -> Self {
        Self { backend, index: BTreeMap::new(), generation: 0, poisoned: false, max_blocks, max_payload }
    }
    pub fn write(&mut self, block: u64, sealed: &[u8]) -> Result<(), Error> {
        if self.poisoned { return Err(Error::Poisoned); }
        if block >= self.max_blocks || sealed.is_empty() || sealed.len() > self.max_payload {
            return Err(Error::InvalidBlock);
        }
        let key = self.generation.checked_add(1).ok_or(Error::Capacity)?;
        self.generation = key;
        // Index changes only after acknowledgement. An error could follow a
        // remotely committed PUT, so this ephemeral export then stops all I/O.
        if let Err(e) = self.backend.put(key, sealed) {
            self.poisoned = true;
            return Err(e);
        }
        self.index.insert(block, key);
        Ok(())
    }
    pub fn read(&mut self, block: u64) -> Result<Vec<u8>, Error> {
        if self.poisoned { return Err(Error::Poisoned); }
        if block >= self.max_blocks { return Err(Error::InvalidBlock); }
        let key = *self.index.get(&block).ok_or(Error::Missing)?;
        self.backend.get(key)
    }
    pub fn backend_mut(&mut self) -> &mut B { &mut self.backend }
}

/// Deterministic transport emulator, never a real cloud backend.
#[derive(Default)]
pub struct SimulatedStore {
    pub offline: bool,
    pub lose_ack: bool,
    objects: BTreeMap<u64, Vec<u8>>,
}
impl ObjectStore for SimulatedStore {
    fn put(&mut self, key: u64, data: &[u8]) -> Result<(), Error> {
        if self.offline { return Err(Error::Offline); }
        self.objects.insert(key, data.to_vec());
        if self.lose_ack { return Err(Error::UncertainWrite); }
        Ok(())
    }
    fn get(&mut self, key: u64) -> Result<Vec<u8>, Error> {
        if self.offline { return Err(Error::Offline); }
        self.objects.get(&key).cloned().ok_or(Error::Missing)
    }
}

pub fn scenarios() -> Vec<(&'static str, bool)> {
    let mut p = Pager::new(SimulatedStore::default(), 8, 8192);
    let payload = vec![0x73; 4096]; // synthetic bytes, not application memory
    let write_ok = p.write(0, &payload).is_ok();
    let roundtrip = write_ok && p.read(0).ok().as_ref() == Some(&payload);
    p.backend_mut().offline = true;
    let outage = p.read(0) == Err(Error::Offline);
    p.backend_mut().offline = false;
    let recovery = p.read(0).ok().as_ref() == Some(&payload);
    p.backend_mut().lose_ack = true;
    let uncertain = p.write(0, &[0x42; 4096]) == Err(Error::UncertainWrite);
    let stopped = p.read(0) == Err(Error::Poisoned);
    vec![("round_trip", roundtrip), ("read_outage", outage),
         ("read_reconnection", recovery), ("lost_write_ack", uncertain),
         ("uncertain_write_stops_export", stopped)]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn failure_scenarios() { for (name, passed) in scenarios() { assert!(passed, "{name}"); } }
    #[test] fn reject_out_of_range_and_oversized() {
        let mut p = Pager::new(SimulatedStore::default(), 2, 4);
        assert_eq!(p.write(2, &[1]), Err(Error::InvalidBlock));
        assert_eq!(p.write(0, &[1;5]), Err(Error::InvalidBlock));
        assert_eq!(p.write(0, &[]), Err(Error::InvalidBlock));
        assert_eq!(p.read(2), Err(Error::InvalidBlock));
    }
    #[test] fn overwrite_reads_new_generation() {
        let mut p = Pager::new(SimulatedStore::default(), 2, 4);
        p.write(0, &[1]).unwrap(); p.write(0, &[2]).unwrap();
        assert_eq!(p.read(0).unwrap(), vec![2]);
    }
    #[test] fn missing_never_becomes_zero() {
        let mut p = Pager::new(SimulatedStore::default(), 2, 4);
        assert_eq!(p.read(0), Err(Error::Missing));
        p.write(0, &[1]).unwrap(); p.backend_mut().objects.clear();
        assert_eq!(p.read(0), Err(Error::Missing));
    }
    #[test] fn outage_write_stays_poisoned_after_reconnect() {
        let mut p = Pager::new(SimulatedStore::default(), 2, 4);
        p.backend_mut().offline = true;
        assert_eq!(p.write(0, &[1]), Err(Error::Offline));
        p.backend_mut().offline = false;
        assert_eq!(p.write(0, &[2]), Err(Error::Poisoned));
    }
    #[test] fn generation_overflow_fails_without_mutation() {
        let mut p = Pager::new(SimulatedStore::default(), 2, 4);
        p.generation = u64::MAX;
        assert_eq!(p.write(0, &[1]), Err(Error::Capacity));
        assert!(p.backend_mut().objects.is_empty());
    }
}
