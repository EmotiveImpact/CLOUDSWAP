//! Synthetic-data NFS lab. Loopback only; not a system swap service.
use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD, Engine};
use nfsserve::{nfs::*, tcp::{NFSTcp, NFSTcpListener}, vfs::*};
use serde_json::{json, Value};
use std::{process::Stdio, sync::atomic::{AtomicU64, Ordering}, time::{Duration, SystemTime, UNIX_EPOCH}};
use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, process::{Child, ChildStdin, ChildStdout, Command}, sync::Mutex};

const CAPACITY: u64 = 4 * 1024 * 1024;
const CHUNK: usize = 65536;
const FRAME: usize = 100000;
type Result<T> = std::result::Result<T, nfsstat3>;
fn ioerr() -> nfsstat3 { nfsstat3::NFS3ERR_IO }

struct Bridge {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    sequence: u64,
    failed: bool,
}
impl Bridge {
    async fn start(helper: &str, mode: &str, directory: &str) -> Result<Self> {
        if !["local-create", "local-open", "remote-create", "remote-open", "mirror-create", "mirror-open"].contains(&mode) {
            return Err(nfsstat3::NFS3ERR_INVAL);
        }
        let mut child = Command::new(helper).args(["--file-server", mode, directory])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true)
            .spawn().map_err(|_| ioerr())?;
        let input = child.stdin.take().ok_or_else(ioerr)?;
        let output = BufReader::new(child.stdout.take().ok_or_else(ioerr)?);
        let mut bridge = Self { child, input, output, sequence: 0, failed: false };
        let hello = tokio::time::timeout(Duration::from_secs(10), bridge.frame()).await.map_err(|_| ioerr())??;
        if hello != json!({"id":0,"ok":true,"capacity":CAPACITY}) { return Err(ioerr()); }
        Ok(bridge)
    }
    async fn frame(&mut self) -> Result<Value> {
        let mut frame = Vec::new();
        loop {
            let available = self.output.fill_buf().await.map_err(|_| ioerr())?;
            if available.is_empty() { return Err(ioerr()); }
            let newline = available.iter().position(|b| *b == b'\n');
            let count = newline.map_or(available.len(), |p| p + 1);
            if frame.len() + count > FRAME { return Err(ioerr()); }
            frame.extend_from_slice(&available[..count]);
            self.output.consume(count);
            if newline.is_some() { return serde_json::from_slice(&frame).map_err(|_| ioerr()); }
        }
    }
    async fn call(&mut self, mut request: Value) -> Result<Value> {
        if self.failed { return Err(ioerr()); }
        self.sequence += 1;
        request["id"] = json!(self.sequence);
        let mut bytes = serde_json::to_vec(&request).map_err(|_| ioerr())?;
        bytes.push(b'\n');
        if bytes.len() > FRAME { return Err(nfsstat3::NFS3ERR_INVAL); }
        let exchange = async {
            self.input.write_all(&bytes).await.map_err(|_| ioerr())?;
            self.input.flush().await.map_err(|_| ioerr())?;
            let response = self.frame().await?;
            if response["id"].as_u64() != Some(self.sequence) || response["ok"].as_bool().is_none() { return Err(ioerr()); }
            Ok(response)
        };
        let response = match tokio::time::timeout(Duration::from_secs(30), exchange).await {
            Ok(Ok(value)) => value,
            _ => { self.failed = true; let _ = self.child.start_kill(); return Err(ioerr()); }
        };
        if response["ok"] != true { return Err(ioerr()); }
        Ok(response)
    }
    fn poison(&mut self) { self.failed = true; let _ = self.child.start_kill(); }
}

struct PageFS {
    bridge: Mutex<Bridge>,
    modified: AtomicU64,
    uid: u32,
    gid: u32,
}
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos() as u64 }
fn checked_read(offset: u64, count: u32) -> Result<usize> {
    if count as usize > CHUNK { return Err(nfsstat3::NFS3ERR_INVAL); }
    Ok((count as u64).min(CAPACITY.saturating_sub(offset)) as usize)
}
fn checked_write(offset: u64, count: usize) -> Result<()> {
    if count > CHUNK || offset > CAPACITY || count as u64 > CAPACITY - offset { return Err(nfsstat3::NFS3ERR_FBIG); }
    Ok(())
}
#[async_trait]
impl NFSFileSystem for PageFS {
    fn capabilities(&self) -> VFSCapabilities { VFSCapabilities::ReadWrite }
    fn root_dir(&self) -> fileid3 { 1 }
    async fn lookup(&self, dir: fileid3, name: &filename3) -> Result<fileid3> {
        if dir != 1 { return Err(nfsstat3::NFS3ERR_NOTDIR); }
        match &name[..] { b"." | b".." => Ok(1), b"pages" => Ok(2), _ => Err(nfsstat3::NFS3ERR_NOENT) }
    }
    async fn getattr(&self, id: fileid3) -> Result<fattr3> {
        if id != 1 && id != 2 { return Err(nfsstat3::NFS3ERR_NOENT); }
        let nanos = self.modified.load(Ordering::Relaxed);
        let time = nfstime3 { seconds: (nanos / 1_000_000_000) as u32, nseconds: (nanos % 1_000_000_000) as u32 };
        Ok(fattr3 { ftype: if id == 1 { ftype3::NF3DIR } else { ftype3::NF3REG },
            mode: if id == 1 { 0o700 } else { 0o600 }, nlink: if id == 1 { 2 } else { 1 },
            uid: self.uid, gid: self.gid, size: if id == 1 { 0 } else { CAPACITY },
            used: if id == 1 { 0 } else { CAPACITY }, rdev: specdata3::default(), fsid: 1, fileid: id,
            atime: time, mtime: time, ctime: time })
    }
    async fn read(&self, id: fileid3, offset: u64, count: u32) -> Result<(Vec<u8>, bool)> {
        if id != 2 { return Err(nfsstat3::NFS3ERR_INVAL); }
        let length = checked_read(offset, count)?;
        if length == 0 { return Ok((Vec::new(), offset >= CAPACITY)); }
        let mut bridge = self.bridge.lock().await;
        let response = bridge.call(json!({"op":"read","offset":offset,"count":length})).await?;
        let bytes = response["data"].as_str().and_then(|s| STANDARD.decode(s).ok());
        match bytes {
            Some(data) if data.len() == length && response["count"].as_u64() == Some(length as u64) => Ok((data, offset + length as u64 >= CAPACITY)),
            _ => { bridge.poison(); Err(ioerr()) }
        }
    }
    async fn write(&self, id: fileid3, offset: u64, data: &[u8]) -> Result<fattr3> {
        if id != 2 { return Err(nfsstat3::NFS3ERR_INVAL); }
        checked_write(offset, data.len())?;
        let mut bridge = self.bridge.lock().await;
        let result = bridge.call(json!({"op":"write","offset":offset,"data":STANDARD.encode(data)})).await;
        match result {
            Ok(response) if response["count"].as_u64() == Some(data.len() as u64) => (),
            _ => { bridge.poison(); return Err(ioerr()); }
        }
        // nfsserve reports FILE_SYNC, so validate the synchronous commit before return.
        if bridge.call(json!({"op":"flush"})).await.is_err() { bridge.poison(); return Err(ioerr()); }
        self.modified.store(now(), Ordering::Relaxed);
        self.getattr(id).await
    }
    async fn commit(&self, id: fileid3) -> Result<()> {
        if id != 2 { return Err(nfsstat3::NFS3ERR_INVAL); }
        let mut bridge = self.bridge.lock().await;
        if bridge.call(json!({"op":"flush"})).await.is_err() { bridge.poison(); return Err(ioerr()); }
        Ok(())
    }
    async fn setattr(&self, id: fileid3, attr: sattr3) -> Result<fattr3> {
        // Fixed size and permissions. No silent metadata mutation acknowledgement.
        if !matches!(attr.mode, set_mode3::Void) || !matches!(attr.uid, set_uid3::Void) || !matches!(attr.gid, set_gid3::Void)
            || !matches!(attr.size, set_size3::Void) || !matches!(attr.atime, set_atime::DONT_CHANGE)
            || !matches!(attr.mtime, set_mtime::DONT_CHANGE) { return Err(nfsstat3::NFS3ERR_NOTSUPP); }
        self.getattr(id).await
    }
    async fn readdir(&self, dir: fileid3, after: fileid3, max: usize) -> Result<ReadDirResult> {
        if dir != 1 { return Err(nfsstat3::NFS3ERR_NOTDIR); }
        if after != 0 && after != 2 { return Err(nfsstat3::NFS3ERR_BAD_COOKIE); }
        if after == 2 { return Ok(ReadDirResult { entries: vec![], end: true }); }
        if max == 0 { return Ok(ReadDirResult { entries: vec![], end: false }); }
        Ok(ReadDirResult { entries: vec![DirEntry { fileid: 2, name: b"pages".as_slice().into(), attr: self.getattr(2).await? }], end: true })
    }
    async fn fsinfo(&self, id: fileid3) -> Result<fsinfo3> {
        Ok(fsinfo3 { obj_attributes: post_op_attr::attributes(self.getattr(id).await?),
            rtmax: CHUNK as u32, rtpref: CHUNK as u32, rtmult: 4096,
            wtmax: CHUNK as u32, wtpref: CHUNK as u32, wtmult: 4096,
            dtpref: 4096, maxfilesize: CAPACITY, time_delta: nfstime3 { seconds: 0, nseconds: 1 }, properties: FSF_HOMOGENEOUS })
    }
    async fn create(&self, _: fileid3, _: &filename3, _: sattr3) -> Result<(fileid3, fattr3)> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn create_exclusive(&self, _: fileid3, _: &filename3) -> Result<fileid3> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn mkdir(&self, _: fileid3, _: &filename3) -> Result<(fileid3, fattr3)> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn remove(&self, _: fileid3, _: &filename3) -> Result<()> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn rename(&self, _: fileid3, _: &filename3, _: fileid3, _: &filename3) -> Result<()> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn symlink(&self, _: fileid3, _: &filename3, _: &nfspath3, _: &sattr3) -> Result<(fileid3, fattr3)> { Err(nfsstat3::NFS3ERR_ROFS) }
    async fn readlink(&self, _: fileid3) -> Result<nfspath3> { Err(nfsstat3::NFS3ERR_INVAL) }
}

#[tokio::main]
async fn main() {
    if run().await.is_err() { eprintln!("CLOUDSWAP NFS lab failed; check helper, directory and configuration."); std::process::exit(1); }
}
async fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 4 || args[0] != "--synthetic-lab" { return Err(nfsstat3::NFS3ERR_INVAL); }
    let bridge = Bridge::start(&args[1], &args[2], &args[3]).await?;
    let fs = PageFS { bridge: Mutex::new(bridge), modified: AtomicU64::new(now()), uid: unsafe { libc::getuid() }, gid: unsafe { libc::getgid() } };
    let listener = NFSTcpListener::bind("127.0.0.1:0", fs).await.map_err(|_| ioerr())?;
    println!("{}", json!({"port":listener.get_listen_port(),"capacity":CAPACITY,"synthetic_only":true}));
    std::io::Write::flush(&mut std::io::stdout()).map_err(|_| ioerr())?;
    tokio::select! {
        result = listener.handle_forever() => result.map_err(|_| ioerr()),
        _ = tokio::signal::ctrl_c() => Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn read_bounds_and_eof() {
        assert_eq!(checked_read(CAPACITY - 1, 10).unwrap(), 1);
        assert_eq!(checked_read(u64::MAX, 10).unwrap(), 0);
        assert!(checked_read(0, 65537).is_err());
    }
    #[test] fn no_write_growth_or_overflow() {
        assert!(checked_write(u64::MAX, 1).is_err());
        assert!(checked_write(CAPACITY, 1).is_err());
        assert!(checked_write(0, 65537).is_err());
        assert!(checked_write(CAPACITY, 0).is_ok());
    }
}
