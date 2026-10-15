//! RWKV scheduling on iOS: a Rust port of the desktop orchestration in
//! `anki-upstream/qt/aqt/rwkv_scheduler.py` (JSChoreels/anki fork).
//!
//! The fork's Rust core already owns inference (`anki::rwkv`) and every
//! scheduler hook (score maps, Curve intervals, `CardAnswer.rwkv_*`); the
//! desktop drives them from Python. This module drives the same RPCs, with
//! the same inputs, from the bridge:
//!
//! - history replay into resident model state (`RwkvHistoricalReviewInputs`),
//!   persisted next to the collection and revalidated with
//!   `RwkvHistoricalReviewFingerprint`;
//! - RWKV-Instant queue scores (`SetRwkvReviewQueueScores`);
//! - RWKV-Curve answer states (`SchedulingStatesWithIntervals` + S90s);
//! - answer metadata (`rwkv_review_kind`, `rwkv_retrievability`, `rwkv_s90`)
//!   and advancing the resident state, with undo and redo frames.
//!
//! Methods are app-only aux RPCs (service 200, JSON in/out); see `dispatch`.

mod cache;
mod calibration;
pub mod inputs;
mod views;
mod workload;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::time::Instant;
use std::time::SystemTime;

use anki::backend::Backend;
use anki::collection::Collection;
use anki::rwkv::ReviewInput;
use anki::rwkv::ReviewState;
use anki::rwkv::ReviewStateOwned;
use anki::rwkv::RwkvInference;
use anki::rwkv::RwkvInferenceState;
use anki::rwkv::StatePrecision;
use anki::services::CardsService;
use anki::services::CollectionService;
use anki::services::ConfigService;
use anki::services::DeckConfigService;
use anki::services::DecksService;
use anki::services::SchedulerService;
use anki_proto::cards::Card;
use anki_proto::deck_config::DeckConfig;
use anki_proto::scheduler as pb;
use data_encoding::BASE64;
use prost::Message;
use serde::Deserialize;
use serde::Serialize;

use self::inputs::*;

pub const PREPARE: u32 = 100;
pub const SCORE_DECK: u32 = 101;
pub const SCHEDULING_STATES: u32 = 102;
pub const ANSWER_CARD: u32 = 103;
pub const UNDO_ANSWER: u32 = 104;
pub const INVALIDATE: u32 = 105;
pub const SAVE: u32 = 106;
pub const DECK_COUNTS: u32 = 107;
pub const SEARCH_SCORES: u32 = 108;
pub const FILTERED_DECK_SCORES: u32 = 109;
pub const CARD_INFO: u32 = 110;
pub const RESCHEDULE: u32 = 111;
pub const SEARCH_NOTE_IDS: u32 = 112;
pub const REBUILD_FILTERED_DECK: u32 = 113;
pub const REBUILD_STATE: u32 = 114;
pub const SIMULATE_WORKLOAD: u32 = 115;
pub const CANCEL_WORKLOAD: u32 = 116;
pub const WORKLOAD_PROGRESS: u32 = 117;
pub const REDO_ANSWER: u32 = 118;
pub const RECOMPUTE_CALIBRATION: u32 = 120;
pub const REBUILD_FSRS_CALIBRATION: u32 = 121;
pub const CALIBRATION_DATA: u32 = 122;
pub const CALIBRATION_PROGRESS: u32 = 123;

pub fn handles(method: u32) -> bool {
    (PREPARE..=CALIBRATION_PROGRESS).contains(&method)
}

/// `_RWKV_REVIEW_UNDO_LIMIT`.
const UNDO_LIMIT: usize = 30;
/// `_RUST_STATE_ONLY_WARMUP_CHUNK_SIZE`.
const WARM_UP_CHUNK: usize = 16_384;
/// Resident retrievability batch size.
const PREDICT_CHUNK: usize = 2_048;
/// Bump when replay inputs or the cache layout change meaning.
const REPLAY_VERSION: u32 = 1;
/// Matches the desktop runtime constructor.
const TARGET_RETENTION: f32 = 0.9;
const MAX_INTERVAL_DAYS: u32 = 36_500;
const OVERLAY_KEY: &str = "fsrsPresetOverlay";
const DYNAMIC_PRESET_REPLAY_KEY: &str = "rwkvDynamicPresetReplay";

pub fn dispatch(backend: &Backend, method: u32, input: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    // A running workload simulation holds the engine; these must not wait.
    match method {
        CANCEL_WORKLOAD => {
            workload::CANCEL.store(true, std::sync::atomic::Ordering::SeqCst);
            return call(input, |_: Empty| Ok(Empty {}))
                .map_err(|err| crate::aux::error(crate::aux::ErrorKind::InvalidInput, err.0));
        }
        WORKLOAD_PROGRESS => {
            return call(input, |_: Empty| Ok(workload::progress()))
                .map_err(|err| crate::aux::error(crate::aux::ErrorKind::InvalidInput, err.0));
        }
        CALIBRATION_PROGRESS => {
            return call(input, |req| Ok(calibration::progress(backend, req)))
                .map_err(|err| crate::aux::error(crate::aux::ErrorKind::InvalidInput, err.0));
        }
        // Needs no model; like the desktop's, it doesn't hold up reviews.
        REBUILD_FSRS_CALIBRATION => {
            return call(input, |req| calibration::rebuild_fsrs(backend, req)).map_err(|err| {
                crate::aux::error(
                    crate::aux::ErrorKind::InvalidInput,
                    format!("rwkv: {}", err.0),
                )
            });
        }
        _ => {}
    }
    // The deck list, graphs and card info must not wait behind a history
    // replay; like the desktop while its state cache loads, they show
    // due-date / FSRS values until the model is ready. Searches whose
    // matches depend on RWKV scores do wait.
    if REPLAYING.load(std::sync::atomic::Ordering::SeqCst) && answers_without_waiting(method, input)
    {
        return busy(backend, method, input);
    }
    let mut engines = engines().lock().unwrap_or_else(|e| e.into_inner());
    let engine = engines.entry(backend_key(backend)).or_default();
    let result = match method {
        PREPARE => call(input, |req| engine.prepare(backend, req)),
        SCORE_DECK => call(input, |req| engine.score_deck_request(backend, req)),
        SCHEDULING_STATES => call(input, |req| engine.scheduling_states(backend, req)),
        ANSWER_CARD => call(input, |req| engine.answer_card(backend, req)),
        UNDO_ANSWER => call(input, |req| engine.undo_answer(backend, req)),
        REDO_ANSWER => call(input, |req| engine.redo_answer(backend, req)),
        INVALIDATE => call(input, |_: Empty| engine.invalidate()),
        SAVE => call(input, |_: Empty| engine.save(backend)),
        DECK_COUNTS => call(input, |_: Empty| engine.deck_counts(backend)),
        SEARCH_SCORES => call(input, |req| engine.search_scores(backend, req)),
        FILTERED_DECK_SCORES => call(input, |req| engine.filtered_deck_scores(backend, req)),
        CARD_INFO => call(input, |req| engine.card_info(backend, req)),
        RESCHEDULE => call(input, |req| engine.reschedule(backend, req)),
        SEARCH_NOTE_IDS => call(input, |req| engine.search_note_ids(backend, req)),
        REBUILD_FILTERED_DECK => call(input, |req| engine.rebuild_filtered_deck(backend, req)),
        REBUILD_STATE => call(input, |req| engine.rebuild_state(backend, req)),
        SIMULATE_WORKLOAD => call(input, |req| engine.simulate_workload(backend, req)),
        RECOMPUTE_CALIBRATION => call(input, |req| engine.recompute_calibration(backend, req)),
        CALIBRATION_DATA => call(input, |req| engine.calibration_data(backend, req)),
        other => Err(Error(format!("unknown rwkv method {other}"))),
    };
    result.map_err(|err| {
        crate::aux::error(
            crate::aux::ErrorKind::InvalidInput,
            format!("rwkv: {}", err.0),
        )
    })
}

fn answers_without_waiting(method: u32, input: &[u8]) -> bool {
    match method {
        DECK_COUNTS | CARD_INFO => true,
        SEARCH_SCORES => {
            serde_json::from_slice::<views::SearchScoresRequest>(input).is_ok_and(|r| !r.wait)
        }
        _ => false,
    }
}

/// The engine is busy (a replay is running): answer without it.
fn busy(backend: &Backend, method: u32, input: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    let to_bytes = |err: Error| {
        crate::aux::error(
            crate::aux::ErrorKind::InvalidInput,
            format!("rwkv: {}", err.0),
        )
    };
    match method {
        DECK_COUNTS => call(input, |_: Empty| {
            views::clear_deck_counts_without_engine(backend)
        })
        .map_err(to_bytes),
        CARD_INFO => call(input, |_: views::CardInfoRequest| {
            Ok(views::loading_card_info())
        })
        .map_err(to_bytes),
        _ => call(input, |req: views::SearchScoresRequest| {
            views::pending_search_scores(backend, &req.search)
        })
        .map_err(to_bytes),
    }
}

/// Drops the engine of a backend that is being closed.
pub fn forget_backend(backend: &Backend) {
    engines()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&backend_key(backend));
}

fn engines() -> &'static Mutex<HashMap<usize, Engine>> {
    static ENGINES: OnceLock<Mutex<HashMap<usize, Engine>>> = OnceLock::new();
    ENGINES.get_or_init(Default::default)
}

fn backend_key(backend: &Backend) -> usize {
    backend as *const Backend as usize
}

fn call<Req, Resp>(
    input: &[u8],
    f: impl FnOnce(Req) -> Result<Resp, Error>,
) -> Result<Vec<u8>, Error>
where
    Req: for<'de> Deserialize<'de>,
    Resp: Serialize,
{
    let req = if input.is_empty() {
        serde_json::from_slice(b"{}")
    } else {
        serde_json::from_slice(input)
    }
    .map_err(|e| Error(format!("decoding request: {e}")))?;
    serde_json::to_vec(&f(req)?).map_err(|e| Error(format!("encoding response: {e}")))
}

#[derive(Debug)]
pub struct Error(String);

impl From<anki::error::AnkiError> for Error {
    fn from(err: anki::error::AnkiError) -> Self {
        Error(format!("{err:?}"))
    }
}

impl From<std::io::Error> for Error {
    fn from(err: std::io::Error) -> Self {
        Error(err.to_string())
    }
}

type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Deserialize, Serialize, Default)]
struct Empty {}

// MARK: - Requests and responses

#[derive(Deserialize)]
struct PrepareRequest {
    /// The bundled `RWKV_trained_on_5000_10000.bin`.
    model_path: String,
    /// Where the resident state is persisted; none disables persistence.
    #[serde(default)]
    cache_dir: Option<String>,
    /// `f32`, `int8` or `int4`; the desktop default is `int8`.
    #[serde(default)]
    precision: Option<String>,
}

#[derive(Serialize)]
struct PrepareResponse {
    /// Some deck preset uses RWKV-Curve or RWKV-Instant.
    active: bool,
    ready: bool,
    /// How the resident state was obtained this call.
    source: &'static str,
    replayed_reviews: u64,
    elapsed_ms: u64,
}

#[derive(Deserialize)]
struct ScoreDeckRequest {
    deck_id: i64,
    /// A new review session: forget the previous session's answers.
    #[serde(default)]
    new_session: bool,
}

#[derive(Serialize)]
struct ScoreDeckResponse {
    instant: bool,
    scored: u32,
}

#[derive(Deserialize)]
struct SchedulingStatesRequest {
    card_id: i64,
    /// Serialized `SchedulingStates`, base64.
    states: String,
}

#[derive(Serialize)]
struct SchedulingStatesResponse {
    /// Serialized `SchedulingStates`, base64; unchanged unless Curve applied.
    states: String,
    /// The card's deck uses RWKV; answer through `ANSWER_CARD`.
    active: bool,
    curve: bool,
    retrievability: Option<f32>,
}

#[derive(Deserialize)]
struct AnswerCardRequest {
    card_id: i64,
    /// 1 (Again) to 4 (Easy).
    rating: u8,
    milliseconds_taken: u32,
    /// Serialized `SchedulingState`s, base64.
    current_state: String,
    new_state: String,
}

#[derive(Serialize)]
struct AnswerCardResponse {
    /// The resident state could not follow this answer and will be rebuilt.
    state_invalidated: bool,
}

/// `record_collection_undo` / `record_collection_redo`: the collection's
/// `OpChangesAfterUndo.counter` and `new_status.last_step`. Without a
/// counter, the most recent frame is used.
#[derive(Deserialize)]
struct UndoRequest {
    #[serde(default)]
    counter: Option<u32>,
    #[serde(default)]
    next_counter: Option<u32>,
}

#[derive(Serialize, Default)]
struct UndoResponse {
    /// The state followed the undo/redo of one of our answers.
    restored: bool,
    /// That answer's card.
    card_id: Option<i64>,
}

#[derive(Serialize)]
struct SaveResponse {
    saved: bool,
}

// MARK: - Engine

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
struct Identity {
    last_review_id: i64,
    review_count: u64,
    history_hash: String,
}

impl From<&pb::RwkvHistoricalReviewIdentity> for Identity {
    fn from(identity: &pb::RwkvHistoricalReviewIdentity) -> Self {
        Self {
            last_review_id: identity.last_review_id,
            review_count: identity.review_count,
            history_hash: identity.history_hash.clone(),
        }
    }
}

impl From<&Identity> for pb::RwkvHistoricalReviewIdentity {
    fn from(identity: &Identity) -> Self {
        Self {
            last_review_id: identity.last_review_id,
            review_count: identity.review_count,
            history_hash: identity.history_hash.clone(),
        }
    }
}

struct Model {
    inference: RwkvInference,
    path: PathBuf,
    precision: StatePrecision,
    precision_name: String,
    /// sha256 of the weights, so a cache from other weights is never restored.
    digest: String,
}

/// The replay parameters `full_review_inputs` sends the desktop history RPC.
struct HistoryParams {
    request: pb::RwkvHistoricalReviewFingerprintRequest,
    /// Changes whenever the replayed inputs would change meaning.
    replay_key: String,
}

#[derive(Default)]
struct Session {
    deck_id: Option<i64>,
    prediction: Option<Prediction>,
    /// The states last shown for a card (`_scheduling_states(reviewer)`),
    /// whose dynamic desired retentions the answer input reuses.
    shown_states: Option<(i64, pb::SchedulingStates)>,
}

/// `RwkvReviewerPrediction`.
#[derive(Clone, Copy)]
struct Prediction {
    card_id: i64,
    retrievability: f32,
    interval_override_used: bool,
    s90s: [Option<f32>; 4],
}

/// `RwkvReviewRollbackFrame`: enough to take one answer back (`before`)
/// and to apply it again (`after`).
struct UndoFrame {
    /// The collection's undo step (`undo_status().last_step`) that undoes
    /// (in `undo`) or redoes (in `redo`) this answer.
    counter: u32,
    review_id: i64,
    card_id: i64,
    note_id: Option<i64>,
    deck_id: Option<i64>,
    preset_id: Option<i64>,
    before: ReviewStateOwned,
    runtime: RwkvInferenceState,
    after: ReviewStateOwned,
    runtime_after: RwkvInferenceState,
}

/// `_rwkv_review_queue_score_maps` for one deck: card id to retrievability
/// and target retention. Like the desktop's, the map is only reused on the
/// day it was made and until the study queue changes; the collection's
/// modification time stands in for the desktop's study-queue generation, as
/// every operation but our own answers bumps it.
struct InstalledScores {
    deck_id: i64,
    scores: HashMap<i64, (f32, Option<f32>)>,
    days_elapsed: u32,
    collection_mod: i64,
}

#[derive(Default)]
struct Engine {
    model: Option<Model>,
    cache_dir: Option<PathBuf>,
    /// History the resident state reflects, before `own_review_ids`.
    base: Option<Identity>,
    /// Revlog ids of the answers applied live since `base`, oldest first.
    own_review_ids: Vec<i64>,
    replay_key: Option<String>,
    /// False when the collection may have changed behind our back.
    trusted: bool,
    /// The collection file and its modification time when the state was
    /// last known to match it. Any operation (sync, import, edits, undo,
    /// card actions) bumps the time, so a mismatch means "revalidate".
    collection_path: Option<String>,
    collection_mod: Option<i64>,
    unsaved: bool,
    session: Session,
    /// `reviewer._answeredIds`, oldest first; like the desktop reviewer's,
    /// kept across review sessions.
    answered_ids: Vec<i64>,
    /// Same-day states this bridge synthesised (`_RwkvSyntheticAnswerState`),
    /// kept across review sessions like the desktop reviewer's.
    synthetic: HashMap<i64, SyntheticAnswer>,
    /// A refresh the desktop runs after showing the next card.
    deferred_refresh: Option<i64>,
    /// The queue scores installed in the backend.
    installed_scores: Option<InstalledScores>,
    /// Set by `rebuild_state`: replay the whole history, ignoring the
    /// resident and saved states.
    force_replay: bool,
    /// Names the full replay the resident state descends from (kept across
    /// suffix replays, answers and saves), like the desktop state cache's
    /// store generation; calibration epochs refer to it.
    lineage: Option<String>,
    undo: Vec<UndoFrame>,
    /// Frames of undone answers, newest last (`_redo_frames`).
    redo: Vec<UndoFrame>,
}

impl Engine {
    // MARK: prepare / readiness

    fn prepare(&mut self, backend: &Backend, req: PrepareRequest) -> Result<PrepareResponse> {
        let started = Instant::now();
        self.follow_collection(backend)?;
        self.cache_dir = req.cache_dir.as_ref().map(PathBuf::from);
        let configs = all_deck_configs(backend)?;
        let active = configs.iter().any(rwkv_active);
        if !active {
            // Nothing to schedule: don't load the model at all.
            return Ok(PrepareResponse {
                active,
                ready: false,
                source: "inactive",
                replayed_reviews: 0,
                elapsed_ms: started.elapsed().as_millis() as u64,
            });
        }

        self.load_model(&req)?;
        let (source, replayed_reviews) = self.ensure_ready(backend)?;
        Ok(PrepareResponse {
            active,
            ready: true,
            source,
            replayed_reviews,
            elapsed_ms: started.elapsed().as_millis() as u64,
        })
    }

    /// Loads the model (once per path and precision), without touching the
    /// resident state's history.
    fn load_model(&mut self, req: &PrepareRequest) -> Result<()> {
        // `state_precision_for_profile`: unknown values fall back to int8.
        let precision_name = req
            .precision
            .clone()
            .filter(|p| StatePrecision::parse(p).is_ok())
            .unwrap_or_else(|| "int8".into());
        let precision = StatePrecision::parse(&precision_name).map_err(|e| Error(e.to_string()))?;
        let path = PathBuf::from(&req.model_path);
        let reload = self
            .model
            .as_ref()
            .is_none_or(|m| m.path != path || m.precision_name != precision_name);
        if reload {
            let bytes = std::fs::read(&path)?;
            let digest = hex_sha256(&bytes);
            self.model = Some(Model {
                inference: RwkvInference::load_with_precision(
                    path.clone(),
                    TARGET_RETENTION,
                    MAX_INTERVAL_DAYS,
                    precision,
                )?,
                path,
                precision,
                precision_name,
                digest,
            });
            self.forget_state();
        }
        Ok(())
    }

    /// The deck options' "Build Cache" (`force_build_rwkv_state_cache`):
    /// the state replayed from the whole review history (which saves it).
    fn rebuild_state(&mut self, backend: &Backend, req: PrepareRequest) -> Result<PrepareResponse> {
        self.installed_scores = None;
        self.force_replay = true;
        let prepared = self.prepare(backend, req);
        self.force_replay = false;
        prepared
    }

    /// Drops everything tied to the resident state's history.
    fn forget_state(&mut self) {
        self.base = None;
        self.lineage = None;
        self.own_review_ids.clear();
        self.trusted = false;
        self.collection_mod = None;
        self.undo.clear();
        self.redo.clear();
        self.session.prediction = None;
    }

    /// Another collection was opened on this backend (profile switch, full
    /// download): its history, cache and reviewer bookkeeping don't apply.
    fn follow_collection(&mut self, backend: &Backend) -> Result<()> {
        let path = collection_path(backend)?;
        if self.collection_path.as_deref() != Some(path.as_str()) {
            if self.collection_path.is_some() {
                self.forget_state();
                self.cache_dir = None;
                self.session = Session::default();
                self.answered_ids.clear();
                self.synthetic.clear();
                self.deferred_refresh = None;
            }
            self.collection_path = Some(path);
        }
        Ok(())
    }

    /// Whether the resident state matches the collection right now, without
    /// rebuilding anything: the collection is unchanged since we last
    /// checked, or its history is exactly what we replayed plus our own
    /// answers. Cheap (one fingerprint at most); what the desktop requires
    /// before review-time predictions, deck counts, graphs and card info.
    fn current(&mut self, backend: &Backend) -> Result<bool> {
        self.follow_collection(backend)?;
        if self.model.is_none() {
            return Ok(false);
        }
        let Some(base) = self.base.clone() else {
            return Ok(false);
        };
        let modified = collection_mod(backend)?;
        if self.trusted && self.collection_mod == Some(modified) {
            return Ok(true);
        }
        let params = history_params(backend, self.model_precision_name())?;
        if self.replay_key.as_deref() != Some(&params.replay_key) {
            self.trusted = false;
            return Ok(false);
        }
        let fingerprint = fingerprint(backend, &params, Some(&base))?;
        let current = (fingerprint.history_is_valid || fingerprint.history_prefix_is_valid)
            && fingerprint.review_count == base.review_count + self.own_review_ids.len() as u64
            && self.own_reviews_are_the_suffix(backend, &base)?;
        self.trusted = current;
        self.collection_mod = current.then_some(modified);
        Ok(current)
    }

    /// The eligible reviews after `base` are exactly the answers we applied:
    /// equal counts alone could hide a skipped answer plus an undone one.
    fn own_reviews_are_the_suffix(&self, backend: &Backend, base: &Identity) -> Result<bool> {
        let sql = format!(
            "select id from revlog where id > ? and {} order by id",
            historical_answer_condition("revlog")
        );
        let ids: Vec<i64> =
            db_query::<(i64,)>(backend, &sql, vec![serde_json::json!(base.last_review_id)])?
                .into_iter()
                .map(|(id,)| id)
                .collect();
        let mut own = self.own_review_ids.clone();
        own.sort_unstable();
        Ok(ids == own)
    }

    /// Makes the resident state match the collection's canonical history,
    /// cheapest way first: current as is, newer reviews replayed on top,
    /// restored from disk (plus newer reviews), or a full replay.
    fn ensure_ready(&mut self, backend: &Backend) -> Result<(&'static str, u64)> {
        if self.model.is_none() {
            return Err(Error("model not loaded; call prepare first".into()));
        }
        let was_trusted = self.trusted;
        if self.force_replay {
            let params = history_params(backend, self.model_precision_name())?;
            let replayed = self.replay_full(backend, &params)?;
            return Ok(("replayed", replayed));
        }
        if self.current(backend)? {
            return Ok((
                if was_trusted {
                    "resident"
                } else {
                    "revalidated"
                },
                0,
            ));
        }
        let params = history_params(backend, self.model_precision_name())?;
        if self.replay_key.as_deref() != Some(&params.replay_key) {
            self.forget_state();
        }
        if let (Some(base), true) = (self.base.clone(), self.own_review_ids.is_empty()) {
            if let Some(replayed) = self.replay_suffix(backend, &params, &base)? {
                return Ok(("suffix", replayed));
            }
        }
        if let Some(restored) = self.restore_from_disk(backend, &params)? {
            return Ok(restored);
        }
        let replayed = self.replay_full(backend, &params)?;
        Ok(("replayed", replayed))
    }

    fn model_precision_name(&self) -> &str {
        self.model
            .as_ref()
            .map_or("", |m| m.precision_name.as_str())
    }

    fn adopt(
        &mut self,
        backend: &Backend,
        params: &HistoryParams,
        identity: Identity,
    ) -> Result<()> {
        self.base = Some(identity);
        self.own_review_ids.clear();
        self.replay_key = Some(params.replay_key.clone());
        self.trusted = true;
        self.collection_mod = Some(collection_mod(backend)?);
        Ok(())
    }

    fn model_mut(&mut self) -> Result<&mut RwkvInference> {
        self.model
            .as_mut()
            .map(|m| &mut m.inference)
            .ok_or_else(|| Error("model not loaded".into()))
    }

    fn reload_model(&mut self) -> Result<()> {
        let model = self
            .model
            .as_mut()
            .ok_or_else(|| Error("model not loaded".into()))?;
        model.inference = RwkvInference::load_with_precision(
            model.path.clone(),
            TARGET_RETENTION,
            MAX_INTERVAL_DAYS,
            model.precision,
        )?;
        Ok(())
    }

    /// `_warm_up_reviewer_backend` from scratch, on a fresh runtime.
    fn replay_full(&mut self, backend: &Backend, params: &HistoryParams) -> Result<u64> {
        self.forget_state();
        self.reload_model()?;
        let response = history_inputs(backend, params)?;
        let identity = response
            .metadata
            .as_ref()
            .and_then(|m| m.identity.as_ref())
            .map(Identity::from)
            .ok_or_else(|| Error("history response has no identity".into()))?;
        let count = response.reviews.len() as u64;
        self.warm_up(response.reviews.iter().map(history_review_input).collect())?;
        self.adopt(backend, params, identity)?;
        self.lineage = Some(calibration::new_lineage());
        self.unsaved = true;
        self.save_now(backend);
        Ok(count)
    }

    /// Replays only the reviews after `known`, if the collection's history
    /// still starts with it. The prefix check and the inputs come from one
    /// collection lock, so a sync can't slip in between. `None` when the
    /// prefix no longer holds.
    fn replay_suffix(
        &mut self,
        backend: &Backend,
        params: &HistoryParams,
        known: &Identity,
    ) -> Result<Option<u64>> {
        let (fingerprint, response) = backend.with_col(|col| {
            let mut request = params.request.clone();
            request.expected_identity = Some(known.into());
            let fingerprint = SchedulerService::rwkv_historical_review_fingerprint(col, request)?;
            if !(fingerprint.history_is_valid || fingerprint.history_prefix_is_valid) {
                return Ok((fingerprint, None));
            }
            let response =
                SchedulerService::rwkv_historical_review_inputs(col, history_request(params))?;
            Ok((fingerprint, Some(response)))
        })?;
        let Some(response) = response else {
            return Ok(None);
        };
        let identity = response
            .metadata
            .as_ref()
            .and_then(|m| m.identity.as_ref())
            .map(Identity::from)
            .ok_or_else(|| Error("history response has no identity".into()))?;
        debug_assert_eq!(identity.review_count, fingerprint.review_count);
        let suffix: Vec<_> = response
            .reviews
            .iter()
            .skip(known.review_count as usize)
            .map(history_review_input)
            .collect();
        let count = suffix.len() as u64;
        let lineage = self.lineage.clone();
        // A failed replay leaves the state partly advanced: never reuse it.
        self.forget_state();
        self.warm_up(suffix)?;
        self.adopt(backend, params, identity)?;
        self.lineage = lineage;
        self.unsaved = true;
        self.save_now(backend);
        Ok(Some(count))
    }

    fn warm_up(&mut self, reviews: Vec<ReviewInput>) -> Result<()> {
        let _replaying = ReplayGuard::start();
        let model = self.model_mut()?;
        for chunk in reviews.chunks(WARM_UP_CHUNK) {
            model.warm_up_reviews(chunk.to_vec(), false)?;
        }
        Ok(())
    }

    fn restore_from_disk(
        &mut self,
        backend: &Backend,
        params: &HistoryParams,
    ) -> Result<Option<(&'static str, u64)>> {
        let (Some(dir), Some(model)) = (self.cache_dir.clone(), self.model.as_ref()) else {
            return Ok(None);
        };
        let Some(header) = cache::read_header(&dir)? else {
            return Ok(None);
        };
        if header.replay_key != params.replay_key || header.model_digest != model.digest {
            return Ok(None);
        }
        let fingerprint = fingerprint(backend, params, Some(&header.identity))?;
        if !fingerprint.history_is_valid && !fingerprint.history_prefix_is_valid {
            return Ok(None);
        }
        self.forget_state();
        self.reload_model()?;
        let restored = {
            let _replaying = ReplayGuard::start();
            let model = self.model_mut()?;
            cache::restore(&dir, model).is_ok()
        };
        if !restored {
            self.reload_model()?;
            return Ok(None);
        }
        if fingerprint.history_is_valid && fingerprint.review_count == header.identity.review_count
        {
            self.adopt(backend, params, header.identity)?;
            self.lineage = header.lineage;
            self.unsaved = false;
            return Ok(Some(("restored", 0)));
        }
        // The cached state is the prefix; it stays the base until the suffix
        // replay adopts the full history.
        self.base = Some(header.identity.clone());
        self.replay_key = Some(params.replay_key.clone());
        self.lineage = header.lineage.clone();
        match self.replay_suffix(backend, params, &header.identity)? {
            Some(replayed) => Ok(Some(("restored+suffix", replayed))),
            None => {
                self.forget_state();
                self.reload_model()?;
                Ok(None)
            }
        }
    }

    /// Persists the resident state if it is ahead of the saved copy.
    fn save(&mut self, backend: &Backend) -> Result<SaveResponse> {
        Ok(SaveResponse {
            saved: self.save_now(backend),
        })
    }

    /// Saves under the identity of the full current history, without
    /// rebasing: our answers stay undoable after a save.
    fn save_now(&mut self, backend: &Backend) -> bool {
        if !self.unsaved || !matches!(self.current(backend), Ok(true)) {
            return false;
        }
        let (Some(dir), Some(model), Some(base), Some(key)) = (
            self.cache_dir.clone(),
            self.model.as_ref(),
            self.base.clone(),
            self.replay_key.clone(),
        ) else {
            return false;
        };
        let digest = model.digest.clone();
        let identity = if self.own_review_ids.is_empty() {
            base
        } else {
            // Our answers appended reviews; the saved identity must name them.
            let Ok(params) = history_params(backend, self.model_precision_name()) else {
                return false;
            };
            let Ok(fp) = fingerprint(backend, &params, Some(&base)) else {
                return false;
            };
            Identity::from_fingerprint(&fp)
        };
        let header = cache::Header {
            version: REPLAY_VERSION,
            replay_key: key,
            model_digest: digest,
            identity,
            lineage: self.lineage.clone(),
        };
        let Some(model) = self.model.as_ref() else {
            return false;
        };
        match cache::write(&dir, &header, &model.inference) {
            Ok(()) => {
                self.unsaved = false;
                true
            }
            Err(_) => false,
        }
    }

    fn invalidate(&mut self) -> Result<Empty> {
        self.trusted = false;
        self.session.prediction = None;
        Ok(Empty {})
    }

    /// Whether resident state may be used now, rebuilding it if needed. For
    /// session starts and explicit actions; review-time paths use `current`.
    fn ready(&mut self, backend: &Backend) -> bool {
        self.model.is_some() && self.ensure_ready(backend).is_ok()
    }

    // MARK: queue scores (RWKV-Instant)

    fn score_deck_request(
        &mut self,
        backend: &Backend,
        req: ScoreDeckRequest,
    ) -> Result<ScoreDeckResponse> {
        if req.new_session || self.session.deck_id != Some(req.deck_id) {
            self.session = Session {
                deck_id: Some(req.deck_id),
                ..Default::default()
            };
            self.deferred_refresh = None;
        }
        self.score_deck(backend, req.deck_id, None)
    }

    /// `_prepare_rwkv_review_scores_for_deck`: the whole deck, or with
    /// candidate refresh only the cards next in line. `current_card` is the
    /// reviewer's card, always rescored by a candidate refresh.
    fn score_deck(
        &mut self,
        backend: &Backend,
        deck_id: i64,
        current_card: Option<i64>,
    ) -> Result<ScoreDeckResponse> {
        let config = deck_config_for_deck(backend, deck_id)?;
        let instant = config.as_ref().is_some_and(instant_enabled);
        if !instant || !self.current(backend)? {
            self.clear_queue_scores(backend, deck_id)?;
            return Ok(ScoreDeckResponse { instant, scored: 0 });
        }
        let config = config.ok_or_else(|| Error("missing deck config".into()))?;
        let include_new_cards = new_gather_uses_retrievability(&config);
        let candidates = self.refresh_candidates(backend, deck_id, &config, current_card)?;
        let rows = backend.with_col(|col| match &candidates {
            // `_rwkv_review_queue_score_result`, which (unlike a full
            // rescore) leaves new cards out, so new candidates drop out of
            // the map, and keeps cards in learning.
            Some(card_ids) => SchedulerService::rwkv_review_input_rows_for_cards(
                col,
                pb::RwkvReviewInputRowsForCardsRequest {
                    card_ids: card_ids.clone(),
                    include_suspended_review: false,
                    include_disabled_decks: false,
                    include_new_cards: false,
                },
            ),
            None => SchedulerService::rwkv_review_input_rows_for_deck_review_queue(
                col,
                pb::RwkvReviewInputRowsForDeckReviewQueueRequest {
                    deck_id,
                    include_disabled_decks: false,
                    include_new_cards,
                },
            ),
        })?;
        let inputs: Vec<ReviewInput> = rows.rows.iter().map(query_input_from_row).collect();
        let scores = match self.predict_many(&inputs) {
            Ok(scores) => scores,
            Err(err) => {
                self.clear_queue_scores(backend, deck_id)?;
                return Err(err);
            }
        };
        let fresh: HashMap<i64, (f32, Option<f32>)> = inputs
            .iter()
            .zip(scores)
            .map(|(input, r)| (input.card_id, (r, input_target_retention(input))))
            .collect();
        let scored = fresh.len() as u32;
        let merged = match (candidates, self.installed_scores.take()) {
            // `_candidate_refreshed_rwkv_review_queue_scores_for_deck`.
            (Some(card_ids), Some(mut installed)) => {
                for card_id in card_ids {
                    match fresh.get(&card_id) {
                        Some(score) => installed.scores.insert(card_id, *score),
                        None => installed.scores.remove(&card_id),
                    };
                }
                installed.scores
            }
            _ => fresh,
        };
        let intervening = self.intervening_reviews(backend, deck_id, &config)?;
        let mut request: Vec<pb::rwkv_review_queue_scores_request::Score> = merged
            .iter()
            .map(|(card_id, (retrievability, target_retention))| {
                pb::rwkv_review_queue_scores_request::Score {
                    card_id: *card_id,
                    retrievability: *retrievability,
                    intervening_reviews: intervening.get(card_id).copied(),
                    target_retention: *target_retention,
                }
            })
            .collect();
        request.sort_by_key(|score| score.card_id);
        set_queue_scores(backend, deck_id, request)?;
        self.installed_scores = Some(InstalledScores {
            deck_id,
            scores: merged,
            days_elapsed: backend
                .with_col(SchedulerService::sched_timing_today)?
                .days_elapsed,
            collection_mod: collection_mod(backend)?,
        });
        Ok(ScoreDeckResponse { instant, scored })
    }

    /// `_rwkv_review_candidate_refresh_card_ids`: with candidate refresh on
    /// and the deck's scores still current, the first `batch_size` cards in
    /// review order, plus the current card; otherwise None (score it all).
    fn refresh_candidates(
        &self,
        backend: &Backend,
        deck_id: i64,
        config: &DeckConfig,
        current_card: Option<i64>,
    ) -> Result<Option<Vec<i64>>> {
        let inner = config_inner(config);
        if !inner.rwkv_review_candidate_refresh_enabled {
            return Ok(None);
        }
        let Some(installed) = self
            .installed_scores
            .as_ref()
            .filter(|s| s.deck_id == deck_id && !s.scores.is_empty())
        else {
            return Ok(None);
        };
        let days_elapsed = backend
            .with_col(SchedulerService::sched_timing_today)?
            .days_elapsed;
        if installed.days_elapsed != days_elapsed
            || installed.collection_mod != collection_mod(backend)?
        {
            return Ok(None);
        }
        let batch_size =
            if (MIN_BATCH_SIZE..=MAX_BATCH_SIZE).contains(&inner.rwkv_review_batch_size) {
                inner.rwkv_review_batch_size as usize
            } else {
                DEFAULT_BATCH_SIZE
            };
        Ok(Some(candidate_card_ids(
            &installed.scores,
            inner.review_order,
            batch_size,
            current_card,
        )))
    }

    /// `_clear_rwkv_review_queue_scores`; a no-op when none are installed, so
    /// collections without RWKV-Instant keep their cached queues.
    fn clear_queue_scores(&mut self, backend: &Backend, deck_id: i64) -> Result<()> {
        if self.installed_scores.take().is_some() {
            set_queue_scores(backend, deck_id, vec![])?;
        }
        Ok(())
    }

    /// `predict_retrievability_inputs_from_warm_up`, validated like
    /// `_scores_from_input_predictions`.
    fn predict_many(&mut self, inputs: &[ReviewInput]) -> Result<Vec<f32>> {
        let model = self.model_mut()?;
        let mut out = Vec::with_capacity(inputs.len());
        for chunk in inputs.chunks(PREDICT_CHUNK) {
            out.extend(model.predict_retrievability_many_from_warm_up(chunk.to_vec())?);
        }
        if let Some(bad) = out.iter().find(|r| !valid_probability(**r)) {
            return Err(Error(format!("invalid retrievability {bad}")));
        }
        Ok(out)
    }

    /// `_queue_intervening_reviews_by_card_id`.
    fn intervening_reviews(
        &self,
        backend: &Backend,
        deck_id: i64,
        config: &DeckConfig,
    ) -> Result<HashMap<i64, u32>> {
        let min = config_inner(config).rwkv_review_min_intervening_reviews;
        if min == 0 {
            return Ok(HashMap::new());
        }
        let deck_ids = backend.with_col(|col| {
            DecksService::get_deck_and_child_names(col, anki_proto::decks::DeckId { did: deck_id })
        })?;
        let ids: Vec<String> = deck_ids.entries.iter().map(|e| e.id.to_string()).collect();
        let deck_clause = if ids.is_empty() {
            String::new()
        } else {
            format!(
                "and (case when c.odid != 0 then c.odid else c.did end) in ({})",
                ids.join(",")
            )
        };
        let sql = format!(
            "select r.cid from revlog r join cards c on c.id = r.cid \
             where {} {deck_clause} order by r.id desc, r.cid desc limit ?",
            historical_answer_condition("r"),
        );
        let recent: Vec<i64> = db_query::<(i64,)>(backend, &sql, vec![serde_json::json!(min)])?
            .into_iter()
            .map(|(cid,)| cid)
            .collect();
        Ok(inputs::intervening_reviews(
            min,
            &self.answered_ids,
            &recent,
        ))
    }

    // MARK: scheduling states (prediction before the answer buttons)

    /// `update_reviewer_scheduling_states`.
    fn scheduling_states(
        &mut self,
        backend: &Backend,
        req: SchedulingStatesRequest,
    ) -> Result<SchedulingStatesResponse> {
        // The reviewer's deferred refresh runs once the next card is chosen,
        // and keeps that card in front (`rebuild_queued_cards_preserving_current_card`).
        if let Some(deck_id) = self.deferred_refresh.take() {
            if self.score_deck(backend, deck_id, Some(req.card_id)).is_ok() {
                let _ = backend.with_col(|col| {
                    SchedulerService::rebuild_queued_cards_preserving_current_card(
                        col,
                        anki_proto::cards::CardId { cid: req.card_id },
                    )
                });
            }
        }
        let states_bytes = BASE64
            .decode(req.states.as_bytes())
            .map_err(|e| Error(format!("states: {e}")))?;
        let mut states = pb::SchedulingStates::decode(states_bytes.as_slice())
            .map_err(|e| Error(e.to_string()))?;
        if !states.dynamic_desired_retention_enabled {
            // Callers may pass the button states alone; Dynamic DR targets
            // come from the backend's own states for the card.
            if let Ok(full) = backend.with_col(|col| {
                SchedulerService::get_scheduling_states(
                    col,
                    anki_proto::cards::CardId { cid: req.card_id },
                )
            }) {
                states.dynamic_desired_retention_enabled = full.dynamic_desired_retention_enabled;
                states.dynamic_desired_retentions = full.dynamic_desired_retentions;
            }
        }
        self.session.shown_states = Some((req.card_id, states.clone()));
        let unchanged = |active, curve| SchedulingStatesResponse {
            states: req.states.clone(),
            active,
            curve,
            retrievability: None,
        };
        self.session.prediction = None;

        let card = get_card(backend, req.card_id)?;
        let Some(config) = deck_config_for_deck(backend, current_deck_id(&card))? else {
            return Ok(unchanged(false, false));
        };
        if !rwkv_active(&config) {
            return Ok(unchanged(false, false));
        }
        let curve = curve_enabled(&config);
        // Like the desktop, never rebuild here: until the state is current
        // the card keeps its FSRS states and the answer its plain metadata.
        if !self.current(backend)? {
            return Ok(unchanged(true, curve));
        }
        let context = LiveContext::load(backend, &card, &config, &self.synthetic)?;
        let input = context.query_input(&card, &config, &states);

        if !curve {
            let retrievability = self.predict_many(std::slice::from_ref(&input))?[0];
            self.session.prediction = Some(Prediction {
                card_id: card.id,
                retrievability,
                interval_override_used: false,
                s90s: [None; 4],
            });
            return Ok(SchedulingStatesResponse {
                retrievability: Some(retrievability),
                ..unchanged(true, false)
            });
        }

        let model = self.model_mut()?;
        let state = model.warm_up_state(&input);
        let output = model.review(input, review_state(&state))?;
        validate_output(&output)?;
        // `_has_interval_overrides`: all four buttons.
        let has_intervals = output.intervals.iter().all(Option::is_some);
        self.session.prediction = Some(Prediction {
            card_id: card.id,
            retrievability: output.retrievability,
            interval_override_used: has_intervals,
            s90s: output.s90s,
        });
        if !has_intervals {
            return Ok(SchedulingStatesResponse {
                retrievability: Some(output.retrievability),
                ..unchanged(true, true)
            });
        }
        let [again, hard, good, easy] = output.intervals;
        let mut rebuilt = backend.with_col(|col| {
            SchedulerService::scheduling_states_with_intervals(
                col,
                pb::SchedulingStatesWithIntervalsRequest {
                    card_id: card.id,
                    again,
                    hard,
                    good,
                    easy,
                },
            )
        })?;
        apply_s90_overrides(&mut rebuilt, &output.intervals, &output.s90s);
        Ok(SchedulingStatesResponse {
            states: BASE64.encode(&rebuilt.encode_to_vec()),
            active: true,
            curve: true,
            retrievability: Some(output.retrievability),
        })
    }

    // MARK: answering

    /// `set_answer_rwkv_metadata`, `answer_card`, `record_reviewer_answer`
    /// and the reviewer's `_after_answering` refresh, in that order.
    fn answer_card(
        &mut self,
        backend: &Backend,
        req: AnswerCardRequest,
    ) -> Result<AnswerCardResponse> {
        if !(1..=4).contains(&req.rating) {
            return Err(Error(format!("invalid rating {}", req.rating)));
        }
        let decode = |s: &str| -> Result<pb::SchedulingState> {
            let bytes = BASE64
                .decode(s.as_bytes())
                .map_err(|e| Error(e.to_string()))?;
            pb::SchedulingState::decode(bytes.as_slice()).map_err(|e| Error(e.to_string()))
        };
        let current_state = decode(&req.current_state)?;
        let new_state = decode(&req.new_state)?;
        let card = get_card(backend, req.card_id)?;
        let config = deck_config_for_deck(backend, current_deck_id(&card))
            .ok()
            .flatten()
            .filter(rwkv_active);
        let answered_at_millis = now_millis();

        // Before the answer changes the collection: is the resident state
        // current (so the answer can be applied on top), and what did the
        // queue look like (`_answered_card_was_last_queued_*`)?
        let current = self.model.is_some() && self.current(backend).unwrap_or(false);
        let queue_before = self.queue_snapshot(backend);
        let identity_before = if current && overlay_has_routing_rules(backend).unwrap_or(false) {
            Some(answer_identity(backend, card.id)?)
        } else {
            None
        };

        let mut answer = pb::CardAnswer {
            card_id: card.id,
            current_state: Some(current_state.clone()),
            new_state: Some(new_state),
            rating: i32::from(req.rating) - 1,
            answered_at_millis,
            milliseconds_taken: req.milliseconds_taken,
            ..Default::default()
        };

        // set_answer_rwkv_metadata. A failure here answers without RWKV
        // metadata rather than failing the answer.
        let synthetic_state = match &config {
            Some(_) => {
                match self.answer_state(backend, &card, &current_state, answered_at_millis) {
                    Ok(state) => state,
                    Err(_) => {
                        self.trusted = false;
                        None
                    }
                }
            }
            None => None,
        };
        if let Some((state, _)) = synthetic_state {
            answer.rwkv_review_kind = raw_review_kind(state);
        }
        if let Some(prediction) = self
            .session
            .prediction
            .filter(|p| p.card_id == card.id && config.is_some())
        {
            if valid_probability(prediction.retrievability) {
                answer.rwkv_retrievability = Some(prediction.retrievability);
            }
            if prediction.interval_override_used {
                if let Some(s90) = prediction.s90s[usize::from(req.rating) - 1] {
                    if s90.is_finite() && s90 > 0.0 {
                        answer.rwkv_s90 = Some(s90);
                    }
                }
            }
        }

        // Our own answer doesn't make the installed scores stale; anything
        // else that changed the collection since they were made does.
        let scores_current = self.installed_scores.as_ref().is_some_and(|scores| {
            collection_mod(backend).is_ok_and(|m| m == scores.collection_mod)
        });
        // The answer's undo step (`_current_undo_counter`), read with the
        // answer so nothing can slip in between. Reading it can't fail the
        // committed answer.
        let undo_counter = backend.with_col(|col| {
            let _changes = SchedulerService::answer_card(col, answer)?;
            Ok(CollectionService::get_undo_status(col)
                .ok()
                .map(|status| status.last_step))
        })?;
        if scores_current {
            if let (Some(scores), Ok(m)) = (self.installed_scores.as_mut(), collection_mod(backend))
            {
                scores.collection_mod = m;
            }
        }
        self.session.prediction = None;
        self.session.shown_states = None;
        self.answered_ids.push(card.id);

        // The answer is committed; from here on a failure must not surface as
        // a failed answer (the app would retry it), only invalidate the state.
        let state_invalidated = match self.after_answer(
            backend,
            &card,
            current,
            identity_before,
            synthetic_state,
            answered_at_millis,
            queue_before,
            undo_counter,
        ) {
            Ok(invalidated) => invalidated,
            Err(_) => {
                self.trusted = false;
                true
            }
        };
        Ok(AnswerCardResponse { state_invalidated })
    }

    /// The state an RWKV-preset answer is recorded with, and the state the
    /// scheduler alone would have used: `set_answer_rwkv_metadata` /
    /// `_rwkv_review_state_for_live_context`.
    fn answer_state(
        &self,
        backend: &Backend,
        card: &Card,
        current_state: &pb::SchedulingState,
        answered_at_millis: i64,
    ) -> Result<Option<(i64, i64)>> {
        let timing = backend.with_col(SchedulerService::sched_timing_today)?;
        let base_state = review_state_for_kind(state_kind(Some(current_state)), card.ctype.into());
        let state = review_state_for_live_context(
            base_state,
            latest_eligible_review(backend, card.id)?,
            Timing {
                days_elapsed: timing.days_elapsed.into(),
                next_day_at: timing.next_day_at,
            },
            answered_at_millis,
            self.synthetic.get(&card.id).copied(),
        );
        Ok(raw_review_kind(state).map(|_| (state, base_state)))
    }

    /// `record_reviewer_answer` (for every answered card, as the desktop's
    /// `review_answered`), then the reviewer's `_after_answering` refresh.
    /// The model advances with the input the canonical history derives from
    /// the revlog row just written, so live answers and a fresh replay agree
    /// by construction. Returns whether the resident state was invalidated.
    #[allow(clippy::too_many_arguments)]
    fn after_answer(
        &mut self,
        backend: &Backend,
        card: &Card,
        current: bool,
        identity_before: Option<AnswerIdentity>,
        synthetic_state: Option<(i64, i64)>,
        answered_at_millis: i64,
        queue_before: Option<QueueSnapshot>,
        undo_counter: Option<u32>,
    ) -> Result<bool> {
        clear_card_info_score(backend, card.id)?;
        // `_save_rollback_frame`: a new answer can't be followed by a redo.
        self.redo.clear();

        let mut state_invalidated = false;
        if current {
            match canonical_answer_input(backend, card.id)? {
                CanonicalAnswer::NotInHistory => {
                    // E.g. a preview-only filtered answer: the history skips
                    // it, so the state is still current.
                    self.collection_mod = Some(collection_mod(backend)?);
                }
                CanonicalAnswer::RestartsHistory => {
                    // `_rwkv_live_answer_canonical_recovery_reason`: a new
                    // learning start drops the card's earlier history.
                    self.forget_state();
                    state_invalidated = true;
                }
                CanonicalAnswer::Input { review_id, input } => {
                    let identity = answer_identity(backend, card.id)?;
                    if identity_before.is_some_and(|before| before != identity) {
                        // The answer changed the card's preset routing.
                        self.forget_state();
                        state_invalidated = true;
                    } else {
                        let input = ReviewInput {
                            note_id: Some(identity.note_id),
                            deck_id: Some(identity.deck_id),
                            preset_id: identity.preset_id,
                            ..input
                        };
                        let record_calibration = self.calibration_epoch_current();
                        let model = self.model_mut()?;
                        let before = model.warm_up_state(&input);
                        // `_rwkv_answer_calibration_prediction`: queried
                        // before the answer updates the state.
                        let calibration_prediction = record_calibration
                            .then(|| calibration::answer_prediction(model, &input, &before))
                            .flatten();
                        let runtime = model.state_for_card(input.card_id);
                        let answered = input.clone();
                        model.review(input, review_state(&before))?;
                        let frame = undo_counter.map(|counter| UndoFrame {
                            counter,
                            review_id,
                            card_id: answered.card_id,
                            note_id: answered.note_id,
                            deck_id: answered.deck_id,
                            preset_id: answered.preset_id,
                            before,
                            runtime,
                            after: model.warm_up_state(&answered),
                            runtime_after: model.state_for_card(answered.card_id),
                        });
                        if let Some(prediction) = calibration_prediction {
                            calibration::record_answer_prediction(backend, review_id, prediction);
                        }
                        self.own_review_ids.push(review_id);
                        self.collection_mod = Some(collection_mod(backend)?);
                        self.unsaved = true;
                        if let Some(frame) = frame {
                            append_bounded(&mut self.undo, frame);
                        }
                    }
                }
            }
        } else {
            // Not current: the next readiness check replays this answer.
            self.trusted = false;
            state_invalidated = true;
        }

        if let Some((state, base_state)) = synthetic_state {
            if state != base_state {
                self.synthetic.insert(
                    card.id,
                    SyntheticAnswer {
                        review_state: state,
                        answered_at_millis,
                    },
                );
            } else {
                self.synthetic.remove(&card.id);
            }
        }

        if let Some(deck_id) = self.session.deck_id {
            self.refresh_after_answer(backend, deck_id, card, queue_before)?;
        }
        Ok(state_invalidated)
    }

    /// The reviewer's `_after_answering` queue refresh.
    fn refresh_after_answer(
        &mut self,
        backend: &Backend,
        deck_id: i64,
        card: &Card,
        queue_before: Option<QueueSnapshot>,
    ) -> Result<()> {
        // `reviewer_queue_order_enabled`: the studied deck uses Instant.
        let Some(config) = deck_config_for_deck(backend, deck_id)?.filter(instant_enabled) else {
            // `prepare_reviewer_queue_order`.
            return self.clear_queue_scores(backend, deck_id);
        };
        // `reviewer_queue_order_refresh_due`: the answered card's preset.
        let answered_config =
            deck_config_for_deck(backend, current_deck_id(card))?.filter(rwkv_active);
        let refresh_due = answered_config.as_ref().is_some_and(|c| {
            let interval = config_inner(c).rwkv_review_refresh_interval.max(1) as usize;
            instant_enabled(c)
                && !self.answered_ids.is_empty()
                && self.answered_ids.len().is_multiple_of(interval)
        });
        let last_card = queue_before.is_some_and(|q| q.total <= 1);
        let last_review =
            !last_card && queue_before.is_some_and(|q| q.review_count == 1 && q.top_is_review);
        let min_intervening = answered_config
            .as_ref()
            .map_or(0, |c| config_inner(c).rwkv_review_min_intervening_reviews);

        if refresh_due || last_card || last_review {
            let before_next_card = last_card
                || last_review
                || (refresh_due && new_gather_uses_retrievability(&config));
            if before_next_card {
                self.score_deck(backend, deck_id, Some(card.id))?;
            } else {
                self.update_intervening_reviews(backend, deck_id, card, min_intervening)?;
                self.deferred_refresh = Some(deck_id);
            }
            return Ok(());
        }
        self.update_intervening_reviews(backend, deck_id, card, min_intervening)?;
        self.patch_answered_score(backend, deck_id, card, &config)
    }

    /// `refresh_answered_card_queue_score`.
    fn patch_answered_score(
        &mut self,
        backend: &Backend,
        deck_id: i64,
        card: &Card,
        config: &DeckConfig,
    ) -> Result<()> {
        if self
            .installed_scores
            .as_ref()
            .is_none_or(|s| s.deck_id != deck_id)
        {
            return Ok(());
        }
        let rows = backend.with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_cards(
                col,
                pb::RwkvReviewInputRowsForCardsRequest {
                    card_ids: vec![card.id],
                    ..Default::default()
                },
            )
        })?;
        let score = match rows.rows.first().map(query_input_from_row) {
            Some(input) if self.current(backend)? => {
                let retrievability = self.predict_many(std::slice::from_ref(&input))?[0];
                Some(pb::rwkv_review_queue_scores_request::Score {
                    card_id: card.id,
                    retrievability,
                    intervening_reviews: self
                        .intervening_reviews(backend, deck_id, config)?
                        .get(&card.id)
                        .copied(),
                    target_retention: input_target_retention(&input),
                })
            }
            _ => None,
        };
        if let Some(installed) = self.installed_scores.as_mut() {
            match &score {
                Some(s) => installed
                    .scores
                    .insert(card.id, (s.retrievability, s.target_retention)),
                None => installed.scores.remove(&card.id),
            };
        }
        backend.with_col(|col| {
            SchedulerService::patch_answered_card_rwkv_review_queue_score(
                col,
                pb::RwkvAnsweredCardQueueScorePatchRequest {
                    deck_id,
                    card_id: card.id,
                    score,
                },
            )
        })?;
        Ok(())
    }

    /// `update_reviewer_queue_intervening_reviews`: session spacing for the
    /// cards already in the score map, without rescoring.
    fn update_intervening_reviews(
        &mut self,
        backend: &Backend,
        session_deck_id: i64,
        card: &Card,
        min: u32,
    ) -> Result<()> {
        if min == 0 {
            return Ok(());
        }
        let card_deck_id = current_deck_id(card);
        let Some(InstalledScores {
            deck_id,
            scores: scored,
            ..
        }) = self
            .installed_scores
            .as_ref()
            .filter(|s| s.deck_id == card_deck_id || s.deck_id == session_deck_id)
        else {
            return Ok(());
        };
        let window = &self.answered_ids[self.answered_ids.len().saturating_sub(min as usize + 1)..];
        let mut last_index = HashMap::new();
        for (index, card_id) in window.iter().enumerate() {
            last_index.insert(*card_id, index);
        }
        let mut items: Vec<_> = last_index
            .into_iter()
            .map(|(card_id, index)| (card_id, (window.len() - index - 1) as u32))
            .filter(|(card_id, reviews)| scored.contains_key(card_id) && *reviews <= min)
            .map(
                |(card_id, reviews)| pb::rwkv_review_queue_intervening_reviews_request::Item {
                    card_id,
                    intervening_reviews: reviews.min(min),
                },
            )
            .collect();
        if items.is_empty() {
            return Ok(());
        }
        items.sort_by_key(|item| item.card_id);
        let deck_id = *deck_id;
        backend.with_col(|col| {
            SchedulerService::update_rwkv_review_queue_intervening_reviews(
                col,
                pb::RwkvReviewQueueInterveningReviewsRequest { deck_id, items },
            )
        })?;
        Ok(())
    }

    /// The queue as the answer found it.
    fn queue_snapshot(&self, backend: &Backend) -> Option<QueueSnapshot> {
        self.session.deck_id?;
        let queued = backend
            .with_col(|col| {
                SchedulerService::get_queued_cards(
                    col,
                    pb::GetQueuedCardsRequest {
                        fetch_limit: 1,
                        ..Default::default()
                    },
                )
            })
            .ok()?;
        Some(QueueSnapshot {
            total: queued.new_count + queued.learning_count + queued.review_count,
            review_count: queued.review_count,
            top_is_review: queued
                .cards
                .first()
                .is_some_and(|c| c.queue == pb::queued_cards::Queue::Review as i32),
        })
    }

    /// `record_collection_undo` -> `answer_undone`: the collection's undo
    /// removed the answer recorded under `req.counter` (the most recent one
    /// when none is given). Puts the state back to before it and keeps the
    /// frame for a redo, under the counter the redo step got. Any other undo
    /// only makes the next check revalidate against the collection.
    fn undo_answer(&mut self, backend: &Backend, req: UndoRequest) -> Result<UndoResponse> {
        self.session.prediction = None;
        let Some(index) = rollback_frame_index(&self.undo, req.counter) else {
            self.trusted = false;
            return Ok(UndoResponse::default());
        };
        let mut frame = self.undo.remove(index);
        let card_id = frame.card_id;
        // `queue_reviewer_undo_card_ids`.
        clear_card_info_score(backend, card_id)?;
        if let Some(i) = self.answered_ids.iter().rposition(|id| *id == card_id) {
            self.answered_ids.remove(i);
        }
        self.synthetic.remove(&card_id);
        if review_exists(backend, frame.review_id)?
            || self.own_review_ids.last() != Some(&frame.review_id)
        {
            // Whatever was undone, it was not this answer.
            self.undo.clear();
            self.redo.clear();
            self.trusted = false;
            return Ok(UndoResponse::default());
        }
        let model = self.model_mut()?;
        model.restore_warm_up_state(
            card_id,
            frame.note_id,
            frame.deck_id,
            frame.preset_id,
            clone_state(&frame.before),
        )?;
        model.restore_state(&frame.runtime);
        self.own_review_ids.pop();
        // Revalidate (cheaply) against the post-undo collection.
        self.collection_mod = None;
        self.unsaved = true;
        frame.counter = req.next_counter.or(req.counter).unwrap_or(frame.counter);
        append_bounded(&mut self.redo, frame);
        self.show_undone_card(backend, card_id);
        Ok(UndoResponse {
            restored: true,
            card_id: Some(card_id),
        })
    }

    /// `record_collection_redo` -> `answer_redone`: the collection's redo
    /// put back the answer whose frame `undo_answer` kept under
    /// `req.counter`. The state becomes exactly what that answer produced;
    /// anything else invalidates it.
    fn redo_answer(&mut self, backend: &Backend, req: UndoRequest) -> Result<UndoResponse> {
        self.session.prediction = None;
        let Some(index) = rollback_frame_index(&self.redo, req.counter) else {
            self.trusted = false;
            return Ok(UndoResponse::default());
        };
        let mut frame = self.redo.remove(index);
        let card_id = frame.card_id;
        clear_card_info_score(backend, card_id)?;
        // The answer must come back as the newest review on top of ours.
        let newest = self
            .own_review_ids
            .last()
            .copied()
            .or(self.base.as_ref().map(|base| base.last_review_id));
        if !review_exists(backend, frame.review_id)?
            || newest.is_none_or(|newest| newest >= frame.review_id)
        {
            self.undo.clear();
            self.redo.clear();
            self.trusted = false;
            return Ok(UndoResponse::default());
        }
        let model = self.model_mut()?;
        model.restore_warm_up_state(
            card_id,
            frame.note_id,
            frame.deck_id,
            frame.preset_id,
            clone_state(&frame.after),
        )?;
        model.restore_state(&frame.runtime_after);
        self.own_review_ids.push(frame.review_id);
        // `apply_reviewer_redo_card_ids`.
        self.answered_ids.push(card_id);
        self.collection_mod = None;
        self.unsaved = true;
        frame.counter = req.next_counter.or(req.counter).unwrap_or(frame.counter);
        append_bounded(&mut self.undo, frame);
        Ok(UndoResponse {
            restored: true,
            card_id: Some(card_id),
        })
    }

    /// The reviewer's `_get_rwkv_undo_restored_card`: during a review
    /// session the undone card is shown again, even when a queue refresh
    /// since its answer rebuilt the queue without it. Best effort. Unlike
    /// the desktop, a queue the collection's undo already put the card in
    /// front of is kept: a rebuild would move a learning card that isn't due
    /// yet behind the main queue, which the desktop then logs as a failure.
    fn show_undone_card(&self, backend: &Backend, card_id: i64) {
        if self.session.deck_id.is_none() {
            return;
        }
        let _ = backend.with_col(|col| {
            let head = SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )?;
            if head
                .cards
                .first()
                .and_then(|c| c.card.as_ref())
                .map(|c| c.id)
                != Some(card_id)
            {
                let _counts = SchedulerService::rebuild_queued_cards_preserving_current_card(
                    col,
                    anki_proto::cards::CardId { cid: card_id },
                )?;
            }
            Ok(())
        });
    }
}

/// `_rollback_frame_index`: the newest frame recorded under `counter`, or
/// the newest frame when there is no counter.
fn rollback_frame_index(frames: &[UndoFrame], counter: Option<u32>) -> Option<usize> {
    match counter {
        Some(counter) => frames.iter().rposition(|frame| frame.counter == counter),
        None => frames.len().checked_sub(1),
    }
}

/// `_append_bounded`: keeps the newest `UNDO_LIMIT` frames.
fn append_bounded(frames: &mut Vec<UndoFrame>, frame: UndoFrame) {
    frames.push(frame);
    if frames.len() > UNDO_LIMIT {
        frames.drain(..frames.len() - UNDO_LIMIT);
    }
}

#[derive(Clone, Copy)]
struct QueueSnapshot {
    total: u32,
    review_count: u32,
    top_is_review: bool,
}

/// The identity a card's next review is replayed under.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct AnswerIdentity {
    note_id: i64,
    deck_id: i64,
    preset_id: Option<i64>,
}

fn answer_identity(backend: &Backend, card_id: i64) -> Result<AnswerIdentity> {
    let card = get_card(backend, card_id)?;
    let deck_id = current_deck_id(&card);
    let config = deck_config_for_deck(backend, deck_id)?;
    Ok(AnswerIdentity {
        note_id: card.note_id,
        deck_id,
        preset_id: preset_id_for_card(backend, card_id, config.as_ref())?,
    })
}

enum CanonicalAnswer {
    /// The written row isn't an eligible answer; the history skips it.
    NotInHistory,
    /// A new learning start after earlier history: the canonical history
    /// drops the earlier reviews, so the state must be rebuilt.
    RestartsHistory,
    Input {
        review_id: i64,
        input: ReviewInput,
    },
}

/// The card's newest revlog row as the canonical history encodes it
/// (`RwkvHistoricalReviewInputs`): state from the revlog type, elapsed time
/// from the previous retained answer, the stored duration. Identity fields
/// are filled in by the caller.
fn canonical_answer_input(backend: &Backend, card_id: i64) -> Result<CanonicalAnswer> {
    let rows = db_query::<(i64, i64, i64, i64, i64)>(
        backend,
        "select id, ease, type, factor, time from revlog where cid = ? order by id",
        vec![serde_json::json!(card_id)],
    )?;
    let Some(&(review_id, ease, kind, factor, time)) = rows.last() else {
        return Ok(CanonicalAnswer::NotInHistory);
    };
    let eligible = |ease: i64, kind: i64, factor: i64| {
        (1..=4).contains(&ease) && (0..=5).contains(&kind) && !(kind == 3 && factor == 0)
    };
    if !eligible(ease, kind, factor) {
        return Ok(CanonicalAnswer::NotInHistory);
    }
    // Answers after the latest reset (`type = 4, ease = 0, factor = 0`).
    let after_reset = rows
        .iter()
        .rposition(|&(_, ease, kind, factor, _)| kind == 4 && ease == 0 && factor == 0)
        .map_or(0, |i| i + 1);
    let previous = rows[after_reset..rows.len() - 1]
        .iter()
        .rev()
        .find(|&&(_, ease, kind, factor, _)| eligible(ease, kind, factor))
        .copied();
    let state = if kind == 0 && previous.is_none_or(|p| p.2 != 0) {
        LEARN_START
    } else {
        kind + 1
    };
    if state == LEARN_START && previous.is_some() {
        return Ok(CanonicalAnswer::RestartsHistory);
    }
    let timing = backend.with_col(SchedulerService::sched_timing_today)?;
    let timing = Timing {
        days_elapsed: timing.days_elapsed.into(),
        next_day_at: timing.next_day_at,
    };
    let (day_offset, elapsed_days, elapsed_seconds) = answer_elapsed(
        timing,
        review_id,
        state,
        previous.map(|(id, ease, kind, _, _)| PreviousReview { id, ease, kind }),
    );
    Ok(CanonicalAnswer::Input {
        review_id,
        input: ReviewInput {
            card_id,
            note_id: None,
            deck_id: None,
            preset_id: None,
            is_query: false,
            ease: Some(ease as u8),
            duration_millis: Some(time),
            card_type: Some(state),
            day_offset: Some(day_offset),
            current_elapsed_days: Some(elapsed_days),
            current_elapsed_seconds: Some(elapsed_seconds),
            target_retentions: [None; 4],
            enforce_grade_order: true,
        },
    })
}

fn clear_card_info_score(backend: &Backend, card_id: i64) -> Result<()> {
    Ok(backend.with_col(|col| {
        SchedulerService::set_rwkv_card_info_score(
            col,
            pb::RwkvCardInfoScoreRequest {
                card_id,
                ..Default::default()
            },
        )
    })?)
}

impl Identity {
    fn from_fingerprint(fp: &pb::RwkvHistoricalReviewFingerprintResponse) -> Self {
        Self {
            last_review_id: fp.last_review_id,
            review_count: fp.review_count,
            history_hash: fp.history_hash.clone(),
        }
    }
}

// MARK: - Live inputs

/// Collection facts `rwkv_review_input` reads for one card.
struct LiveContext {
    timing: Timing,
    now_secs: i64,
    previous: Option<PreviousReview>,
    synthetic: Option<SyntheticAnswer>,
    preset_id: Option<i64>,
    preset_desired_retention: Option<f32>,
}

impl LiveContext {
    fn load(
        backend: &Backend,
        card: &Card,
        config: &DeckConfig,
        synthetic: &HashMap<i64, SyntheticAnswer>,
    ) -> Result<Self> {
        let timing = backend.with_col(SchedulerService::sched_timing_today)?;
        let preset = fsrs_preset_for_card(backend, card.id)?;
        Ok(Self {
            timing: Timing {
                days_elapsed: timing.days_elapsed.into(),
                next_day_at: timing.next_day_at,
            },
            now_secs: now_millis().div_euclid(1000),
            previous: latest_eligible_review(backend, card.id)?,
            synthetic: synthetic.get(&card.id).copied(),
            preset_id: preset
                .as_ref()
                .filter(|p| !p.id.is_empty())
                .map(|p| stable_preset_id(&p.id))
                .or(Some(config.id)),
            preset_desired_retention: preset.map(|p| p.desired_retention),
        })
    }

    /// `rwkv_review_input` with `ease=None`.
    fn query_input(
        &self,
        card: &Card,
        config: &DeckConfig,
        states: &pb::SchedulingStates,
    ) -> ReviewInput {
        let current = states.current.as_ref();
        let kind = state_kind(current);
        let (mut elapsed_days, mut elapsed_seconds) = scheduling_state_elapsed(current);
        if kind == StateKind::New && elapsed_seconds.is_none() {
            let seconds = (self.now_secs - card.id.div_euclid(1000)).max(0);
            elapsed_seconds = Some(seconds);
            elapsed_days = Some(seconds.div_euclid(86_400));
        }
        let base_state = review_state_for_kind(kind, card.ctype.into());
        let state = review_state_for_live_context(
            base_state,
            self.previous,
            self.timing,
            self.now_secs * 1000,
            self.synthetic,
        );
        if matches!(state, REVIEW | RELEARNING | FILTERED) {
            (elapsed_days, elapsed_seconds) = self.since_last_review(card);
        }
        ReviewInput {
            card_id: card.id,
            note_id: Some(card.note_id),
            deck_id: Some(current_deck_id(card)),
            preset_id: self.preset_id,
            is_query: true,
            ease: None,
            duration_millis: None,
            card_type: Some(state),
            day_offset: Some(self.timing.days_elapsed),
            current_elapsed_days: elapsed_days,
            current_elapsed_seconds: elapsed_seconds,
            target_retentions: self.target_retentions(config, Some(states)),
            enforce_grade_order: config_inner(config).rwkv_review_enforce_grade_order,
        }
    }

    /// `_elapsed_since_card_last_review`.
    fn since_last_review(&self, card: &Card) -> (Option<i64>, Option<i64>) {
        let last = card
            .last_review_time_secs
            .or_else(|| self.previous.map(|p| p.id.div_euclid(1000)));
        elapsed_since_review_time(last, self.timing.next_day_at, self.now_secs)
    }

    /// `_rwkv_target_retentions`.
    fn target_retentions(
        &self,
        config: &DeckConfig,
        states: Option<&pb::SchedulingStates>,
    ) -> [Option<f32>; 4] {
        if let Some(states) = states.filter(|s| s.dynamic_desired_retention_enabled) {
            let valid: Vec<f32> = states
                .dynamic_desired_retentions
                .iter()
                .copied()
                .filter(|v| valid_probability(*v))
                .collect();
            if let [a, b, c, d] = valid[..] {
                return [Some(a), Some(b), Some(c), Some(d)];
            }
        }
        let target = self
            .preset_desired_retention
            .filter(|v| valid_probability(*v))
            .or_else(|| {
                Some(config_inner(config).desired_retention).filter(|v| valid_probability(*v))
            })
            .unwrap_or(DEFAULT_TARGET_RETENTION);
        [Some(target); 4]
    }
}

/// `_rwkv_historical_answer_sql_condition`.
fn historical_answer_condition(alias: &str) -> String {
    format!(
        "{a}.ease between 1 and 4 and {a}.type in (0, 1, 2, 3, 4, 5) and not ({a}.type = 3 and {a}.factor = 0)",
        a = alias
    )
}

fn history_review_input(row: &pb::rwkv_historical_review_inputs_response::Review) -> ReviewInput {
    ReviewInput {
        card_id: row.card_id,
        note_id: Some(row.note_id),
        deck_id: Some(row.deck_id),
        preset_id: Some(row.preset_id),
        is_query: false,
        ease: Some(row.ease as u8),
        duration_millis: Some(row.duration_millis),
        card_type: Some(row.card_type),
        day_offset: Some(row.day_offset),
        current_elapsed_days: Some(row.elapsed_days),
        current_elapsed_seconds: Some(row.elapsed_seconds),
        target_retentions: [None; 4],
        enforce_grade_order: true,
    }
}

fn review_state(state: &ReviewStateOwned) -> ReviewState<'_> {
    ReviewState {
        card: state.card.as_deref(),
        deck: state.deck.as_deref(),
        note: state.note.as_deref(),
        preset: state.preset.as_deref(),
        global: state.global.as_deref(),
    }
}

fn clone_state(state: &ReviewStateOwned) -> ReviewStateOwned {
    ReviewStateOwned {
        card: state.card.clone(),
        deck: state.deck.clone(),
        note: state.note.clone(),
        preset: state.preset.clone(),
        global: state.global.clone(),
    }
}

/// `_validate_prediction` for the fields the answer path uses.
fn validate_output(output: &anki::rwkv::ReviewOutput) -> Result<()> {
    if !valid_probability(output.retrievability) {
        return Err(Error("retrievability must be between 0 and 1".into()));
    }
    for value in output.intervals.iter().chain(&output.s90s).flatten() {
        if !value.is_finite() || *value <= 0.0 {
            return Err(Error(
                "interval overrides must be positive numbers of days".into(),
            ));
        }
    }
    Ok(())
}

/// `apply_review_s90_overrides`: each overridden button's review memory state
/// takes RWKV's S90 as its stability.
fn apply_s90_overrides(
    states: &mut pb::SchedulingStates,
    intervals: &[Option<f32>; 4],
    s90s: &[Option<f32>; 4],
) {
    let buttons = [
        &mut states.again,
        &mut states.hard,
        &mut states.good,
        &mut states.easy,
    ];
    for ((state, interval), s90) in buttons.into_iter().zip(intervals).zip(s90s) {
        let (Some(_), Some(s90), Some(state)) = (interval, s90, state.as_mut()) else {
            continue;
        };
        use pb::scheduling_state::normal::Kind as N;
        use pb::scheduling_state::Kind;
        let review = match state.kind.as_mut() {
            Some(Kind::Normal(normal)) => match normal.kind.as_mut() {
                Some(N::Review(review)) => Some(review),
                Some(N::Relearning(relearning)) => relearning.review.as_mut(),
                _ => None,
            },
            _ => None,
        };
        let Some(review) = review else { continue };
        let memory = review.memory_state.get_or_insert_with(Default::default);
        if memory.difficulty <= 0.0 {
            memory.difficulty = 5.0;
        }
        memory.stability = *s90;
    }
}

// MARK: - Collection access

fn get_card(backend: &Backend, card_id: i64) -> Result<Card> {
    Ok(backend
        .with_col(|col| CardsService::get_card(col, anki_proto::cards::CardId { cid: card_id }))?)
}

/// `card.current_deck_id()`.
fn current_deck_id(card: &Card) -> i64 {
    if card.original_deck_id != 0 {
        card.original_deck_id
    } else {
        card.deck_id
    }
}

/// `_deck_config_for_deck_id`: none for filtered decks.
fn deck_config_for_deck(backend: &Backend, deck_id: i64) -> Result<Option<DeckConfig>> {
    backend
        .with_col(|col| -> anki::error::Result<Option<DeckConfig>> {
            let deck = DecksService::get_deck(col, anki_proto::decks::DeckId { did: deck_id })?;
            let Some(anki_proto::decks::deck::Kind::Normal(normal)) = deck.kind else {
                return Ok(None);
            };
            Ok(Some(DeckConfigService::get_deck_config(
                col,
                anki_proto::deck_config::DeckConfigId {
                    dcid: normal.config_id,
                },
            )?))
        })
        .map_err(Into::into)
}

fn all_deck_configs(backend: &Backend) -> Result<Vec<DeckConfig>> {
    let configs = backend.with_col(|col| {
        DeckConfigService::get_deck_configs_for_update(col, anki_proto::decks::DeckId { did: 1 })
    })?;
    Ok(configs
        .all_config
        .into_iter()
        .filter_map(|c| c.config)
        .collect())
}

fn config_inner(config: &DeckConfig) -> anki_proto::deck_config::deck_config::Config {
    config.config.clone().unwrap_or_default()
}

/// `_rwkv_review_config_active`.
fn rwkv_active(config: &DeckConfig) -> bool {
    curve_enabled(config) || instant_enabled(config)
}

fn curve_enabled(config: &DeckConfig) -> bool {
    config
        .config
        .as_ref()
        .is_some_and(|c| c.rwkv_review_enabled)
}

fn instant_enabled(config: &DeckConfig) -> bool {
    config
        .config
        .as_ref()
        .is_some_and(|c| c.rwkv_review_instant_order_enabled)
}

/// `_new_gather_uses_retrievability`.
fn new_gather_uses_retrievability(config: &DeckConfig) -> bool {
    use anki_proto::deck_config::deck_config::config::NewCardGatherPriority as P;
    matches!(
        config.config.as_ref().map(|c| c.new_card_gather_priority()),
        Some(P::DescendingRetrievability | P::AscendingRetrievability)
    )
}

fn fsrs_preset_for_card(
    backend: &Backend,
    card_id: i64,
) -> Result<Option<pb::FsrsPresetForCardResponse>> {
    Ok(backend
        .with_col(|col| {
            SchedulerService::get_fsrs_preset_for_card(
                col,
                anki_proto::cards::CardId { cid: card_id },
            )
        })
        .ok())
}

/// `_preset_id`.
fn preset_id_for_card(
    backend: &Backend,
    card_id: i64,
    config: Option<&DeckConfig>,
) -> Result<Option<i64>> {
    Ok(fsrs_preset_for_card(backend, card_id)?
        .filter(|p| !p.id.is_empty())
        .map(|p| stable_preset_id(&p.id))
        .or(config.map(|c| c.id)))
}

/// `_DEFAULT_RWKV_REVIEW_BATCH_SIZE` and its valid range.
const DEFAULT_BATCH_SIZE: usize = 512;
const MIN_BATCH_SIZE: u32 = 64;
const MAX_BATCH_SIZE: u32 = 8192;

/// `_rwkv_review_candidate_refresh_card_ids` and
/// `_unique_rwkv_candidate_card_ids`: the cards the review order would show
/// first, ties by card id, then the current card.
fn candidate_card_ids(
    scores: &HashMap<i64, (f32, Option<f32>)>,
    review_order: i32,
    limit: usize,
    current_card: Option<i64>,
) -> Vec<i64> {
    use anki_proto::deck_config::deck_config::config::ReviewCardOrder;
    let mut ordered: Vec<(i64, f32)> = match ReviewCardOrder::try_from(review_order) {
        Ok(ReviewCardOrder::RetrievabilityDescending) => {
            scores.iter().map(|(id, (r, _))| (*id, -r)).collect()
        }
        Ok(ReviewCardOrder::RelativeOverdueness) => scores
            .iter()
            .map(|(id, (r, target))| {
                // `_rwkv_relative_overdueness`.
                let target = target.filter(|t| valid_probability(*t)).unwrap_or(1.0);
                (*id, r / target.max(0.0001))
            })
            .collect(),
        _ => scores.iter().map(|(id, (r, _))| (*id, *r)).collect(),
    };
    ordered.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
    let mut card_ids: Vec<i64> = ordered.into_iter().take(limit).map(|(id, _)| id).collect();
    if let Some(card_id) = current_card.filter(|id| !card_ids.contains(id)) {
        card_ids.push(card_id);
    }
    card_ids
}

fn set_queue_scores(
    backend: &Backend,
    deck_id: i64,
    scores: Vec<pb::rwkv_review_queue_scores_request::Score>,
) -> Result<()> {
    Ok(backend.with_col(|col| {
        SchedulerService::set_rwkv_review_queue_scores(
            col,
            pb::RwkvReviewQueueScoresRequest { deck_id, scores },
        )
    })?)
}

fn config_json(col: &mut Collection, key: &str) -> Option<serde_json::Value> {
    ConfigService::get_config_json(col, anki_proto::generic::String { val: key.into() })
        .ok()
        .and_then(|json| serde_json::from_slice(&json.json).ok())
}

/// `_rwkv_history_stable_preset_ids`, `_rwkv_dynamic_preset_replay_enabled_for_collection`
/// and `_rwkv_first_review_uses_creation_by_config_id`.
fn history_params(backend: &Backend, precision: &str) -> Result<HistoryParams> {
    let configs = all_deck_configs(backend)?;
    let (overlay, dynamic_setting) = backend.with_col(|col| {
        Ok((
            config_json(col, OVERLAY_KEY),
            config_json(col, DYNAMIC_PRESET_REPLAY_KEY),
        ))
    })?;

    let mut stable_preset_ids = HashMap::new();
    if let Some(overlay) = overlay.as_ref().and_then(|o| o.as_object()) {
        for (key, field) in [
            ("presets", "id"),
            ("rules", "preset_id"),
            ("simulator_rules", "preset_id"),
        ] {
            for item in overlay
                .get(key)
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
            {
                if let Some(id) = item
                    .get(field)
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                {
                    stable_preset_ids.insert(id.to_string(), stable_preset_id(id));
                }
            }
        }
    }
    let mut dynamic_preset_replay = configs
        .iter()
        .filter(|c| rwkv_active(c))
        .any(|c| config_inner(c).rwkv_review_dynamic_preset_replay);
    if let Some(setting) = dynamic_setting.and_then(|v| v.as_bool()) {
        dynamic_preset_replay = setting;
    }
    // Creation time is always used for first-review queries now.
    let first_review_uses_creation_by_config_id: HashMap<i64, bool> =
        configs.iter().map(|c| (c.id, true)).collect();

    // The history hash already covers every replayed input (presets,
    // routing, elapsed times); the key adds what it cannot see: how the
    // state is stored, and the replay settings themselves.
    let mut sorted_ids: Vec<_> = stable_preset_ids.iter().collect();
    sorted_ids.sort();
    let replay_key = hex_sha256(
        serde_json::json!({
            "version": REPLAY_VERSION,
            "statePrecision": precision,
            "dynamicPresetReplay": dynamic_preset_replay,
            "stablePresetIds": sorted_ids,
            "overlay": if dynamic_preset_replay { overlay.clone() } else { None },
        })
        .to_string()
        .as_bytes(),
    );

    Ok(HistoryParams {
        request: pb::RwkvHistoricalReviewFingerprintRequest {
            ignored_review_ids: vec![],
            dynamic_preset_replay,
            stable_preset_ids,
            first_review_uses_creation_by_config_id,
            expected_identity: None,
        },
        replay_key,
    })
}

fn fingerprint(
    backend: &Backend,
    params: &HistoryParams,
    expected: Option<&Identity>,
) -> Result<pb::RwkvHistoricalReviewFingerprintResponse> {
    let mut request = params.request.clone();
    request.expected_identity = expected.map(Into::into);
    Ok(backend
        .with_col(|col| SchedulerService::rwkv_historical_review_fingerprint(col, request))?)
}

fn history_request(params: &HistoryParams) -> pb::RwkvHistoricalReviewInputsRequest {
    pb::RwkvHistoricalReviewInputsRequest {
        history: Some(params.request.clone()),
        // Each deck's policy, as the desktop's DECK_CONFIG source.
        first_review_uses_creation: None,
        ..Default::default()
    }
}

fn history_inputs(
    backend: &Backend,
    params: &HistoryParams,
) -> Result<pb::RwkvHistoricalReviewInputsResponse> {
    Ok(backend.with_col(|col| {
        SchedulerService::rwkv_historical_review_inputs(col, history_request(params))
    })?)
}

/// The open collection's file, to notice another collection being opened on
/// the same backend. Must start with SELECT: the DB proxy treats anything
/// else as a write, which clears the study queues and undo.
fn collection_path(backend: &Backend) -> Result<String> {
    Ok(db_query::<(String,)>(
        backend,
        "select file from pragma_database_list where name = 'main'",
        vec![],
    )?
    .into_iter()
    .next()
    .map(|(file,)| file)
    .unwrap_or_default())
}

/// The collection's modification time; every operation bumps it, and undo
/// restores it.
fn collection_mod(backend: &Backend) -> Result<i64> {
    Ok(db_query::<(i64,)>(backend, "select mod from col", vec![])?
        .into_iter()
        .next()
        .map_or(0, |(m,)| m))
}

/// Set while a history replay or cache restore runs, so the deck list,
/// graphs and card info answer without waiting for the engine, as the
/// desktop does while its state cache loads.
static REPLAYING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

struct ReplayGuard;

impl ReplayGuard {
    fn start() -> Self {
        REPLAYING.store(true, std::sync::atomic::Ordering::SeqCst);
        ReplayGuard
    }
}

impl Drop for ReplayGuard {
    fn drop(&mut self) {
        REPLAYING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

/// `_latest_eligible_review_for_card`.
fn latest_eligible_review(backend: &Backend, card_id: i64) -> Result<Option<PreviousReview>> {
    let sql = format!(
        "select id, ease, type from revlog where cid = ? and {} order by id desc limit 1",
        historical_answer_condition("revlog")
    );
    Ok(
        db_query::<(i64, i64, i64)>(backend, &sql, vec![serde_json::json!(card_id)])?
            .into_iter()
            .next()
            .map(|(id, ease, kind)| PreviousReview { id, ease, kind }),
    )
}

fn review_exists(backend: &Backend, review_id: i64) -> Result<bool> {
    Ok(!db_query::<(i64,)>(
        backend,
        "select id from revlog where id = ?",
        vec![serde_json::json!(review_id)],
    )?
    .is_empty())
}

fn overlay_has_routing_rules(backend: &Backend) -> Result<bool> {
    let overlay = backend.with_col(|col| Ok(config_json(col, OVERLAY_KEY)))?;
    Ok(overlay
        .as_ref()
        .and_then(|o| o.get("rules"))
        .and_then(|r| r.as_array())
        .is_some_and(|r| !r.is_empty()))
}

fn db_query<T: for<'de> Deserialize<'de>>(
    backend: &Backend,
    sql: &str,
    args: Vec<serde_json::Value>,
) -> Result<Vec<T>> {
    let request = serde_json::to_vec(&serde_json::json!({
        "kind": "query",
        "sql": sql,
        "args": args,
        "first_row_only": false,
    }))
    .map_err(|e| Error(e.to_string()))?;
    let bytes = backend
        .run_db_command_bytes(&request)
        .map_err(|_| Error(format!("db query failed: {sql}")))?;
    serde_json::from_slice(&bytes).map_err(|e| Error(format!("decoding rows: {e}")))
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

fn hex_sha256(bytes: &[u8]) -> String {
    use sha2::Digest;
    data_encoding::HEXLOWER.encode(&sha2::Sha256::digest(bytes))
}

#[cfg(test)]
mod tests;
