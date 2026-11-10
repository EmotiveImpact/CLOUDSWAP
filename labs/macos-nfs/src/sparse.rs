//! Growable synthetic-file laboratory. No system-swap activation.
use super::*;

pub const CAPACITY: u64 = 4 * 1024 * 1024 * 1024;
pub const MAX_FILE: u64 = 2 * 1024 * 1024 * 1024;

struct SparseFS {
    bridge: Mutex<Bridge>,
    changed: AtomicU64,
    uid: u32,
    gid: u32,
}
fn number(value: &Value, field: &str) -> Result<u64> {
    value[field].as_u64().ok_or_else(ioerr)
}
fn timestamp(nanos: u64) -> nfstime3 {
    nfstime3 {
        seconds: (nanos / 1_000_000_000) as u32,
        nseconds: (nanos % 1_000_000_000) as u32,
    }
}
fn attribute(value: &Value) -> Result<fattr3> {
    let id = number(value, "id")?;
    let size = number(value, "size")?;
    let mode = number(value, "mode")?;
    if id < 2 || size > MAX_FILE || mode > 0o777 {
        return Err(ioerr());
    }
    Ok(fattr3 {
        ftype: ftype3::NF3REG,
        mode: mode as u32,
        nlink: 1,
        uid: u32::try_from(number(value, "uid")?).map_err(|_| ioerr())?,
        gid: u32::try_from(number(value, "gid")?).map_err(|_| ioerr())?,
        size,
        used: number(value, "used")?,
        rdev: specdata3::default(),
        fsid: 1,
        fileid: id,
        atime: timestamp(number(value, "accessed")?),
        mtime: timestamp(number(value, "modified")?),
        ctime: timestamp(number(value, "changed")?),
    })
}
fn name(name: &filename3) -> Result<&str> {
    let name = std::str::from_utf8(name).map_err(|_| nfsstat3::NFS3ERR_INVAL)?;
    if name.is_empty()
        || name.len() > 64
        || name == "."
        || name == ".."
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        return Err(nfsstat3::NFS3ERR_INVAL);
    }
    Ok(name)
}
fn dir(id: fileid3) -> Result<()> {
    if id == 1 {
        Ok(())
    } else {
        Err(nfsstat3::NFS3ERR_NOTDIR)
    }
}
fn client_time(value: nfstime3) -> Result<u64> {
    if value.nseconds >= 1_000_000_000 {
        return Err(nfsstat3::NFS3ERR_INVAL);
    }
    Ok(value.seconds as u64 * 1_000_000_000 + value.nseconds as u64)
}
fn set_attributes(request: &mut Value, attr: sattr3) -> Result<()> {
    if let set_size3::size(size) = attr.size {
        if size > MAX_FILE {
            return Err(nfsstat3::NFS3ERR_FBIG);
        }
        request["size"] = json!(size);
    }
    if let set_mode3::mode(mode) = attr.mode {
        if mode > 0o777 {
            return Err(nfsstat3::NFS3ERR_NOTSUPP);
        }
        request["mode"] = json!(mode);
    }
    if let set_uid3::uid(uid) = attr.uid {
        request["uid"] = json!(uid);
    }
    if let set_gid3::gid(gid) = attr.gid {
        request["gid"] = json!(gid);
    }
    match attr.mtime {
        set_mtime::DONT_CHANGE => (),
        set_mtime::SET_TO_SERVER_TIME => request["modified"] = json!(now()),
        set_mtime::SET_TO_CLIENT_TIME(t) => request["modified"] = json!(client_time(t)?),
    }
    match attr.atime {
        set_atime::DONT_CHANGE => (),
        set_atime::SET_TO_SERVER_TIME => request["accessed"] = json!(now()),
        set_atime::SET_TO_CLIENT_TIME(t) => request["accessed"] = json!(client_time(t)?),
    }
    Ok(())
}
async fn files(bridge: &mut Bridge) -> Result<(Vec<Value>, u64)> {
    let response = bridge.call(json!({"op":"list"})).await?;
    let values = response["files"].as_array().ok_or_else(ioerr)?;
    if values.len() > 8 {
        bridge.poison();
        return Err(ioerr());
    }
    Ok((values.clone(), number(&response, "objectCount")?))
}
impl SparseFS {
    async fn change(&self, request: Value) -> Result<fattr3> {
        let mut bridge = self.bridge.lock().await;
        let response = bridge.call(request).await?;
        match attribute(&response["attributes"]) {
            Ok(attr) => {
                self.changed.store(now(), Ordering::Relaxed);
                Ok(attr)
            }
            Err(error) => {
                bridge.poison();
                Err(error)
            }
        }
    }
    async fn create_kind(
        &self,
        directory: fileid3,
        filename: &filename3,
        attr: sattr3,
        unchecked: bool,
    ) -> Result<(fileid3, fattr3)> {
        dir(directory)?;
        let mut request = json!({"op":"create","name":name(filename)?,"uid":self.uid,"gid":self.gid,"unchecked":unchecked});
        set_attributes(&mut request, attr)?;
        let attr = self.change(request).await?;
        Ok((attr.fileid, attr))
    }
}
#[async_trait]
impl NFSFileSystem for SparseFS {
    fn capabilities(&self) -> VFSCapabilities {
        VFSCapabilities::ReadWrite
    }
    fn root_dir(&self) -> fileid3 {
        1
    }
    async fn lookup(&self, directory: fileid3, filename: &filename3) -> Result<fileid3> {
        dir(directory)?;
        if filename.as_ref() == b"." || filename.as_ref() == b".." {
            return Ok(1);
        }
        let wanted = name(filename)?;
        let (values, _) = files(&mut *self.bridge.lock().await).await?;
        values
            .iter()
            .find(|v| v["name"] == wanted)
            .map(|v| number(v, "id"))
            .unwrap_or(Err(nfsstat3::NFS3ERR_NOENT))
    }
    async fn getattr(&self, id: fileid3) -> Result<fattr3> {
        if id == 1 {
            let time = timestamp(self.changed.load(Ordering::Relaxed));
            return Ok(fattr3 {
                ftype: ftype3::NF3DIR,
                mode: 0o700,
                nlink: 2,
                uid: self.uid,
                gid: self.gid,
                size: 0,
                used: 0,
                rdev: specdata3::default(),
                fsid: 1,
                fileid: 1,
                atime: time,
                mtime: time,
                ctime: time,
            });
        }
        let mut bridge = self.bridge.lock().await;
        let response = bridge.call(json!({"op":"stat","file":id})).await?;
        let attr = attribute(&response["attributes"])?;
        if attr.fileid != id {
            bridge.poison();
            return Err(ioerr());
        }
        Ok(attr)
    }
    async fn read(&self, id: fileid3, offset: u64, count: u32) -> Result<(Vec<u8>, bool)> {
        if id == 1 {
            return Err(nfsstat3::NFS3ERR_ISDIR);
        }
        if count as usize > CHUNK {
            return Err(nfsstat3::NFS3ERR_INVAL);
        }
        let mut bridge = self.bridge.lock().await;
        let stat = bridge.call(json!({"op":"stat","file":id})).await?;
        let attr = attribute(&stat["attributes"])?;
        if offset >= attr.size {
            return Ok((Vec::new(), true));
        }
        let length = (count as u64).min(attr.size - offset) as usize;
        let response = bridge
            .call(json!({"op":"read","file":id,"offset":offset,"count":length}))
            .await?;
        let data = response["data"]
            .as_str()
            .and_then(|v| STANDARD.decode(v).ok());
        match data {
            Some(data)
                if data.len() == length
                    && response["count"].as_u64() == Some(length as u64)
                    && response["eof"].as_bool() == Some(offset + length as u64 >= attr.size) =>
            {
                Ok((data, offset + length as u64 >= attr.size))
            }
            _ => {
                bridge.poison();
                Err(ioerr())
            }
        }
    }
    async fn write(&self, id: fileid3, offset: u64, data: &[u8]) -> Result<fattr3> {
        if id == 1 {
            return Err(nfsstat3::NFS3ERR_ISDIR);
        }
        if offset > MAX_FILE || data.len() > CHUNK || data.len() as u64 > MAX_FILE - offset {
            return Err(nfsstat3::NFS3ERR_FBIG);
        }
        let mut bridge = self.bridge.lock().await;
        // SparseVolume commits immutable payloads, leaves and catalogue before
        // returning. No separate write-back acknowledgement exists here.
        let response = bridge
            .call(json!({"op":"write","file":id,"offset":offset,"data":STANDARD.encode(data)}))
            .await?;
        if response["count"].as_u64() != Some(data.len() as u64) {
            bridge.poison();
            return Err(ioerr());
        }
        let attr = attribute(&response["attributes"])?;
        if attr.fileid != id {
            bridge.poison();
            return Err(ioerr());
        }
        self.changed.store(now(), Ordering::Relaxed);
        Ok(attr)
    }
    async fn commit(&self, id: fileid3) -> Result<()> {
        if id == 1 {
            return Err(nfsstat3::NFS3ERR_ISDIR);
        }
        self.bridge
            .lock()
            .await
            .call(json!({"op":"flush","file":id}))
            .await?;
        Ok(())
    }
    async fn setattr(&self, id: fileid3, attr: sattr3) -> Result<fattr3> {
        if id == 1 {
            return Err(nfsstat3::NFS3ERR_NOTSUPP);
        }
        let mut request = json!({"op":"setattr","file":id});
        set_attributes(&mut request, attr)?;
        self.change(request).await
    }
    async fn create(
        &self,
        directory: fileid3,
        filename: &filename3,
        attr: sattr3,
    ) -> Result<(fileid3, fattr3)> {
        self.create_kind(directory, filename, attr, true).await
    }
    async fn create_guarded(
        &self,
        directory: fileid3,
        filename: &filename3,
        attr: sattr3,
    ) -> Result<(fileid3, fattr3)> {
        self.create_kind(directory, filename, attr, false).await
    }
    async fn create_exclusive(&self, _: fileid3, _: &filename3) -> Result<fileid3> {
        Err(nfsstat3::NFS3ERR_NOTSUPP)
    }
    async fn create_exclusive_verified(
        &self,
        directory: fileid3,
        filename: &filename3,
        verifier: createverf3,
    ) -> Result<fileid3> {
        dir(directory)?;
        let token: String = verifier.iter().map(|byte| format!("{byte:02x}")).collect();
        let attr = self.change(json!({"op":"create","name":name(filename)?,"verifier":token,"uid":self.uid,"gid":self.gid})).await?;
        Ok(attr.fileid)
    }
    async fn remove(&self, directory: fileid3, filename: &filename3) -> Result<()> {
        dir(directory)?;
        let wanted = name(filename)?;
        let mut bridge = self.bridge.lock().await;
        let (values, _) = files(&mut bridge).await?;
        let file = values
            .iter()
            .find(|v| v["name"] == wanted)
            .ok_or(nfsstat3::NFS3ERR_NOENT)?;
        bridge
            .call(json!({"op":"remove","file":number(file,"id")?}))
            .await?;
        self.changed.store(now(), Ordering::Relaxed);
        Ok(())
    }
    async fn rename(
        &self,
        from: fileid3,
        old: &filename3,
        to: fileid3,
        new: &filename3,
    ) -> Result<()> {
        dir(from)?;
        dir(to)?;
        let wanted = name(old)?;
        let new = name(new)?;
        let mut bridge = self.bridge.lock().await;
        let (values, _) = files(&mut bridge).await?;
        let file = values
            .iter()
            .find(|v| v["name"] == wanted)
            .ok_or(nfsstat3::NFS3ERR_NOENT)?;
        bridge
            .call(json!({"op":"rename","file":number(file,"id")?,"name":new}))
            .await?;
        self.changed.store(now(), Ordering::Relaxed);
        Ok(())
    }
    async fn readdir(
        &self,
        directory: fileid3,
        after: fileid3,
        max: usize,
    ) -> Result<ReadDirResult> {
        dir(directory)?;
        let (values, _) = files(&mut *self.bridge.lock().await).await?;
        let mut candidates = Vec::new();
        for value in &values {
            let attr = attribute(value)?;
            if attr.fileid <= after {
                continue;
            }
            let text = value["name"].as_str().ok_or_else(ioerr)?;
            candidates.push(DirEntry {
                fileid: attr.fileid,
                name: text.as_bytes().into(),
                attr,
            });
        }
        candidates.sort_by_key(|entry| entry.fileid);
        let end = candidates.len() <= max;
        candidates.truncate(max);
        Ok(ReadDirResult {
            entries: candidates,
            end,
        })
    }
    async fn fsinfo(&self, id: fileid3) -> Result<fsinfo3> {
        Ok(fsinfo3 {
            obj_attributes: post_op_attr::attributes(self.getattr(id).await?),
            rtmax: CHUNK as u32,
            rtpref: CHUNK as u32,
            rtmult: 4096,
            wtmax: CHUNK as u32,
            wtpref: CHUNK as u32,
            wtmult: 4096,
            dtpref: 4096,
            maxfilesize: MAX_FILE,
            time_delta: nfstime3 {
                seconds: 0,
                nseconds: 1,
            },
            properties: FSF_HOMOGENEOUS | FSF_CANSETTIME,
        })
    }
    async fn fsstats(&self, id: fileid3) -> Result<FileSystemStats> {
        self.getattr(id).await?;
        let (values, objects) = files(&mut *self.bridge.lock().await).await?;
        let mut logical = 0;
        for value in &values {
            logical += number(value, "size")?;
        }
        // Conservative lab headroom: a single-page request needs a page and a
        // new leaf. Retired objects consume the finite budget until offline cleanup.
        let available = CAPACITY
            .saturating_sub(logical)
            .min(16384u64.saturating_sub(objects).saturating_sub(7) / 2 * 16384);
        Ok(FileSystemStats {
            total_bytes: CAPACITY,
            available_bytes: available,
            total_files: 8,
            available_files: 8u64.saturating_sub(values.len() as u64),
        })
    }
    async fn mkdir(&self, _: fileid3, _: &filename3) -> Result<(fileid3, fattr3)> {
        Err(nfsstat3::NFS3ERR_NOTSUPP)
    }
    async fn symlink(
        &self,
        _: fileid3,
        _: &filename3,
        _: &nfspath3,
        _: &sattr3,
    ) -> Result<(fileid3, fattr3)> {
        Err(nfsstat3::NFS3ERR_NOTSUPP)
    }
    async fn readlink(&self, _: fileid3) -> Result<nfspath3> {
        Err(nfsstat3::NFS3ERR_INVAL)
    }
}
pub async fn run(helper: &str, mode: &str, directory: &str) -> Result<()> {
    let bridge = Bridge::start_kind(helper, mode, directory, true).await?;
    let fs = SparseFS {
        bridge: Mutex::new(bridge),
        changed: AtomicU64::new(now()),
        uid: unsafe { libc::getuid() },
        gid: unsafe { libc::getgid() },
    };
    let listener = NFSTcpListener::bind("127.0.0.1:0", fs)
        .await
        .map_err(|_| ioerr())?;
    println!(
        "{}",
        json!({"port":listener.get_listen_port(),"capacity":CAPACITY,"kind":"sparse-volume-v1","synthetic_only":true})
    );
    std::io::Write::flush(&mut std::io::stdout()).map_err(|_| ioerr())?;
    tokio::select! {
        result = listener.handle_forever() => result.map_err(|_| ioerr()),
        _ = tokio::signal::ctrl_c() => Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_invalid_time_and_path_before_helper_request() {
        assert!(client_time(nfstime3 {
            seconds: 1,
            nseconds: 1_000_000_000
        })
        .is_err());
        for path in ["..", "../file", "a/b", ""] {
            assert!(name(&path.as_bytes().into()).is_err());
        }
        assert!(name(&b".nfs123".as_slice().into()).is_ok());
    }
    #[test]
    fn refuse_oversized_and_unsupported_attributes() {
        let mut request = json!({});
        let mut attr = sattr3::default();
        attr.size = set_size3::size(u64::MAX);
        assert!(set_attributes(&mut request, attr).is_err());
        let mut attr = sattr3::default();
        attr.mode = set_mode3::mode(0o4755);
        assert!(set_attributes(&mut request, attr).is_err());
    }
}
