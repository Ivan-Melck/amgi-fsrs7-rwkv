//! The persisted resident state: the desktop keeps its equivalent in
//! `<profile>/rwkv-state-cache/`; here it lives in a directory the app picks.
//!
//! Layout: magic, u32 header length, JSON header, then the four state maps
//! (u64 count, then i64 id + u32 length + bytes per entry), the optional
//! global state, and the runtime feature/curve cache. Written to a temporary
//! file and renamed, so a crash never leaves a torn cache behind.

use std::fs;
use std::fs::File;
use std::io;
use std::io::BufReader;
use std::io::BufWriter;
use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;

use anki::rwkv::RwkvInference;
use anki::rwkv::RwkvWarmUpSnapshot;
use serde::Deserialize;
use serde::Serialize;

use super::Identity;

const MAGIC: &[u8] = b"AMGIRWKVSTATE1\n";
const FILE_NAME: &str = "rwkv-state.bin";

#[derive(Serialize, Deserialize)]
pub(super) struct Header {
    pub version: u32,
    pub replay_key: String,
    pub model_digest: String,
    pub identity: Identity,
    /// `Engine::lineage`; absent in caches written before it existed.
    #[serde(default)]
    pub lineage: Option<String>,
}

fn path(dir: &Path) -> PathBuf {
    dir.join(FILE_NAME)
}

pub(super) fn read_header(dir: &Path) -> io::Result<Option<Header>> {
    let file = match File::open(path(dir)) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };
    let mut reader = BufReader::new(file);
    Ok(read_header_from(&mut reader).ok())
}

fn read_header_from(reader: &mut impl Read) -> io::Result<Header> {
    let mut magic = [0u8; MAGIC.len()];
    reader.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(invalid("not an RWKV state cache"));
    }
    let len = read_u32(reader)? as usize;
    let mut json = vec![0u8; len];
    reader.read_exact(&mut json)?;
    serde_json::from_slice(&json).map_err(|e| invalid(&e.to_string()))
}

pub(super) fn write(dir: &Path, header: &Header, inference: &RwkvInference) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let final_path = path(dir);
    let tmp_path = final_path.with_extension("tmp");
    {
        let mut out = BufWriter::with_capacity(1 << 20, File::create(&tmp_path)?);
        out.write_all(MAGIC)?;
        let json = serde_json::to_vec(header).map_err(|e| invalid(&e.to_string()))?;
        out.write_all(&(json.len() as u32).to_le_bytes())?;
        out.write_all(&json)?;

        let snapshot = inference.warm_up_snapshot();
        for map in [
            &snapshot.card_states,
            &snapshot.note_states,
            &snapshot.deck_states,
            &snapshot.preset_states,
        ] {
            out.write_all(&(map.len() as u64).to_le_bytes())?;
            for (id, bytes) in map {
                out.write_all(&id.to_le_bytes())?;
                write_bytes(&mut out, bytes)?;
            }
        }
        match &snapshot.global_state {
            Some(bytes) => {
                out.write_all(&[1])?;
                write_bytes(&mut out, bytes)?;
            }
            None => out.write_all(&[0])?,
        }
        write_bytes(&mut out, &inference.cache_state())?;
        out.into_inner().map_err(|e| e.into_error())?.sync_all()?;
    }
    fs::rename(tmp_path, final_path)
}

/// Restores the state written by `write` into a freshly loaded runtime.
pub(super) fn restore(dir: &Path, inference: &mut RwkvInference) -> io::Result<()> {
    let mut reader = BufReader::with_capacity(1 << 20, File::open(path(dir))?);
    read_header_from(&mut reader)?;
    let mut maps: [Vec<(i64, Vec<u8>)>; 4] = Default::default();
    for map in &mut maps {
        let count = read_u64(&mut reader)?;
        for _ in 0..count {
            let id = read_i64(&mut reader)?;
            map.push((id, read_bytes(&mut reader)?));
        }
    }
    let mut flag = [0u8];
    reader.read_exact(&mut flag)?;
    let global_state = match flag[0] {
        0 => None,
        1 => Some(read_bytes(&mut reader)?),
        _ => return Err(invalid("bad global state flag")),
    };
    let runtime = read_bytes(&mut reader)?;
    let mut rest = [0u8];
    if reader.read(&mut rest)? != 0 {
        return Err(invalid("trailing bytes in RWKV state cache"));
    }
    let [card_states, note_states, deck_states, preset_states] = maps;
    inference.restore_warm_up_snapshot(RwkvWarmUpSnapshot {
        card_states,
        note_states,
        deck_states,
        preset_states,
        global_state,
    })?;
    inference.restore_cache_state(&runtime)
}

fn write_bytes(out: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    out.write_all(&(bytes.len() as u32).to_le_bytes())?;
    out.write_all(bytes)
}

fn read_bytes(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let len = read_u32(reader)? as usize;
    let mut bytes = vec![0u8; len];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn read_u32(reader: &mut impl Read) -> io::Result<u32> {
    let mut buf = [0u8; 4];
    reader.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

fn read_u64(reader: &mut impl Read) -> io::Result<u64> {
    let mut buf = [0u8; 8];
    reader.read_exact(&mut buf)?;
    Ok(u64::from_le_bytes(buf))
}

fn read_i64(reader: &mut impl Read) -> io::Result<i64> {
    let mut buf = [0u8; 8];
    reader.read_exact(&mut buf)?;
    Ok(i64::from_le_bytes(buf))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}
