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
//!   and advancing the resident state, with undo frames.
//!
//! Methods are app-only aux RPCs (service 200, JSON in/out); see `dispatch`.

mod cache;
pub mod inputs;

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

pub fn handles(method: u32) -> bool {
    (PREPARE..=SAVE).contains(&method)
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
    let mut engines = engines().lock().unwrap_or_else(|e| e.into_inner());
    let engine = engines.entry(backend_key(backend)).or_default();
    let result = match method {
        PREPARE => call(input, |req| engine.prepare(backend, req)),
        SCORE_DECK => call(input, |req| engine.score_deck_request(backend, req)),
        SCHEDULING_STATES => call(input, |req| engine.scheduling_states(backend, req)),
        ANSWER_CARD => call(input, |req| engine.answer_card(backend, req)),
        UNDO_ANSWER => call(input, |_: Empty| engine.undo_answer(backend)),
        INVALIDATE => call(input, |_: Empty| engine.invalidate()),
        SAVE => call(input, |_: Empty| engine.save(backend)),
        other => Err(Error(format!("unknown rwkv method {other}"))),
    };
    result.map_err(|err| {
        crate::aux::error(
            crate::aux::ErrorKind::InvalidInput,
            format!("rwkv: {}", err.0),
        )
    })
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

#[derive(Serialize)]
struct UndoResponse {
    restored: bool,
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
    /// `reviewer._answeredIds`, oldest first.
    answered_ids: Vec<i64>,
    synthetic: HashMap<i64, SyntheticAnswer>,
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

/// `RwkvReviewRollbackFrame`: enough to put one answer back.
struct UndoFrame {
    review_id: i64,
    card_id: i64,
    note_id: Option<i64>,
    deck_id: Option<i64>,
    preset_id: Option<i64>,
    before: ReviewStateOwned,
    runtime: RwkvInferenceState,
}

#[derive(Default)]
struct Engine {
    model: Option<Model>,
    cache_dir: Option<PathBuf>,
    /// History the resident state reflects, before `own_answers`.
    base: Option<Identity>,
    /// Answers applied live since `base`.
    own_answers: u64,
    replay_key: Option<String>,
    /// False when the collection may have changed behind our back.
    trusted: bool,
    unsaved: bool,
    session: Session,
    undo: Vec<UndoFrame>,
}

impl Engine {
    // MARK: prepare / readiness

    fn prepare(&mut self, backend: &Backend, req: PrepareRequest) -> Result<PrepareResponse> {
        let started = Instant::now();
        self.cache_dir = req.cache_dir.map(PathBuf::from);
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

        let precision_name = req.precision.unwrap_or_else(|| "int8".into());
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
            self.base = None;
        }
        // Sessions start here, so revalidate against the collection: syncs,
        // browser edits and preset changes since the last session all show
        // up in the history fingerprint or the replay key.
        self.trusted = false;
        let (source, replayed_reviews) = self.ensure_ready(backend)?;
        Ok(PrepareResponse {
            active,
            ready: true,
            source,
            replayed_reviews,
            elapsed_ms: started.elapsed().as_millis() as u64,
        })
    }

    /// Makes the resident state match the collection's canonical history,
    /// cheapest way first: trusted as is, revalidated, restored from disk
    /// (plus newer reviews), or a full replay.
    fn ensure_ready(&mut self, backend: &Backend) -> Result<(&'static str, u64)> {
        if self.model.is_none() {
            return Err(Error("model not loaded; call prepare first".into()));
        }
        if self.trusted && self.base.is_some() {
            return Ok(("resident", 0));
        }
        let params = history_params(backend, self.model_precision_name())?;
        if self.replay_key.as_deref() != Some(&params.replay_key) {
            self.base = None;
            self.undo.clear();
        }

        if let Some(base) = self.base.clone() {
            let fingerprint = fingerprint(backend, &params, Some(&base))?;
            let expected = base.review_count + self.own_answers;
            if fingerprint.history_prefix_is_valid || fingerprint.history_is_valid {
                if fingerprint.review_count == expected {
                    self.adopt(&params, Identity::from_fingerprint(&fingerprint));
                    return Ok(("revalidated", 0));
                }
                if self.own_answers == 0 {
                    let replayed = self.replay_suffix(backend, &params, base.review_count)?;
                    return Ok(("suffix", replayed));
                }
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

    fn adopt(&mut self, params: &HistoryParams, identity: Identity) {
        self.base = Some(identity);
        self.own_answers = 0;
        self.replay_key = Some(params.replay_key.clone());
        self.trusted = true;
    }

    fn model_mut(&mut self) -> Result<&mut RwkvInference> {
        self.model
            .as_mut()
            .map(|m| &mut m.inference)
            .ok_or_else(|| Error("model not loaded".into()))
    }

    /// `_warm_up_reviewer_backend` from scratch, on a fresh runtime.
    fn replay_full(&mut self, backend: &Backend, params: &HistoryParams) -> Result<u64> {
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
        self.undo.clear();
        let response = history_inputs(backend, params)?;
        let identity = response
            .metadata
            .as_ref()
            .and_then(|m| m.identity.as_ref())
            .map(Identity::from)
            .ok_or_else(|| Error("history response has no identity".into()))?;
        let count = response.reviews.len() as u64;
        self.warm_up(response.reviews.iter().map(history_review_input).collect())?;
        self.adopt(params, identity);
        self.unsaved = true;
        self.save_now(backend);
        Ok(count)
    }

    /// Replays only the reviews after the first `known` canonical ones; valid
    /// when the fingerprint confirmed the first `known` as a prefix.
    fn replay_suffix(
        &mut self,
        backend: &Backend,
        params: &HistoryParams,
        known: u64,
    ) -> Result<u64> {
        let response = history_inputs(backend, params)?;
        let identity = response
            .metadata
            .as_ref()
            .and_then(|m| m.identity.as_ref())
            .map(Identity::from)
            .ok_or_else(|| Error("history response has no identity".into()))?;
        let suffix: Vec<_> = response
            .reviews
            .iter()
            .skip(known as usize)
            .map(history_review_input)
            .collect();
        let count = suffix.len() as u64;
        self.warm_up(suffix)?;
        self.undo.clear();
        self.adopt(params, identity);
        self.unsaved = true;
        self.save_now(backend);
        Ok(count)
    }

    fn warm_up(&mut self, reviews: Vec<ReviewInput>) -> Result<()> {
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
        if cache::restore(&dir, &mut model.inference).is_err() {
            return Ok(None);
        }
        self.undo.clear();
        if fingerprint.history_is_valid {
            self.adopt(params, header.identity);
            self.unsaved = false;
            return Ok(Some(("restored", 0)));
        }
        let replayed = self.replay_suffix(backend, params, header.identity.review_count)?;
        Ok(Some(("restored+suffix", replayed)))
    }

    /// Persists the resident state if it is ahead of the saved copy.
    fn save(&mut self, backend: &Backend) -> Result<SaveResponse> {
        Ok(SaveResponse {
            saved: self.save_now(backend),
        })
    }

    fn save_now(&mut self, backend: &Backend) -> bool {
        if !self.unsaved || !self.trusted {
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
        let identity = if self.own_answers == 0 {
            base
        } else {
            // Our answers appended reviews; the saved identity must name them.
            let Ok(params) = history_params(backend, self.model_precision_name()) else {
                return false;
            };
            let Ok(fp) = fingerprint(backend, &params, Some(&base)) else {
                return false;
            };
            if !(fp.history_prefix_is_valid || fp.history_is_valid)
                || fp.review_count != base.review_count + self.own_answers
            {
                self.trusted = false;
                return false;
            }
            let identity = Identity::from_fingerprint(&fp);
            self.base = Some(identity.clone());
            self.own_answers = 0;
            identity
        };
        let header = cache::Header {
            version: REPLAY_VERSION,
            replay_key: key,
            model_digest: digest,
            identity,
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

    /// Whether resident state may be used now, rebuilding it if needed.
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
        }
        self.score_deck(backend, req.deck_id)
    }

    /// `_prepare_rwkv_review_scores_for_deck` (full deck scoring).
    fn score_deck(&mut self, backend: &Backend, deck_id: i64) -> Result<ScoreDeckResponse> {
        let config = deck_config_for_deck(backend, deck_id)?;
        let instant = config.as_ref().is_some_and(instant_enabled);
        if !instant || !self.ready(backend) {
            set_queue_scores(backend, deck_id, vec![])?;
            return Ok(ScoreDeckResponse { instant, scored: 0 });
        }
        let config = config.ok_or_else(|| Error("missing deck config".into()))?;
        let include_new_cards = new_gather_uses_retrievability(&config);
        let rows = backend.with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_deck_review_queue(
                col,
                pb::RwkvReviewInputRowsForDeckReviewQueueRequest {
                    deck_id,
                    include_disabled_decks: false,
                    include_new_cards,
                },
            )
        })?;
        let inputs: Vec<ReviewInput> = rows.rows.iter().map(query_input_from_row).collect();
        let scores = match self.predict_many(&inputs) {
            Ok(scores) => scores,
            Err(err) => {
                set_queue_scores(backend, deck_id, vec![])?;
                return Err(err);
            }
        };
        let intervening = self.intervening_reviews(backend, deck_id, &config)?;
        let request: Vec<pb::rwkv_review_queue_scores_request::Score> = inputs
            .iter()
            .zip(scores)
            .map(
                |(input, retrievability)| pb::rwkv_review_queue_scores_request::Score {
                    card_id: input.card_id,
                    retrievability,
                    intervening_reviews: intervening.get(&input.card_id).copied(),
                    target_retention: input_target_retention(input),
                },
            )
            .collect();
        let scored = request.len() as u32;
        set_queue_scores(backend, deck_id, request)?;
        Ok(ScoreDeckResponse { instant, scored })
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
            &self.session.answered_ids,
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
        if !self.ready(backend) {
            return Ok(unchanged(true, curve));
        }
        let context = LiveContext::load(backend, &card, &config, &self.session)?;
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
        let has_intervals = output.intervals.iter().any(Option::is_some);
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
        // metadata and leaves the state to be rebuilt, rather than failing
        // the answer.
        let pending = match &config {
            Some(config) => match self.answer_metadata(
                backend,
                &card,
                config,
                &current_state,
                &req,
                answered_at_millis,
            ) {
                Ok(pending) => pending,
                Err(_) => {
                    self.trusted = false;
                    None
                }
            },
            None => None,
        };
        if let Some((_, state, _)) = &pending {
            answer.rwkv_review_kind = raw_review_kind(*state);
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

        let _changes = backend.with_col(|col| SchedulerService::answer_card(col, answer))?;
        self.session.prediction = None;
        self.session.shown_states = None;
        self.session.answered_ids.push(card.id);

        // The answer is committed; from here on a failure must not surface as
        // a failed answer (the app would retry it), only invalidate the state.
        let state_invalidated = match self.after_answer(backend, &card, pending, answered_at_millis)
        {
            Ok(invalidated) => invalidated,
            Err(_) => {
                self.trusted = false;
                true
            }
        };
        Ok(AnswerCardResponse { state_invalidated })
    }

    /// The state the answer is recorded with and the input that advances the
    /// model: `set_answer_rwkv_metadata` / `_rwkv_pending_answer_review_input`.
    fn answer_metadata(
        &self,
        backend: &Backend,
        card: &Card,
        config: &DeckConfig,
        current_state: &pb::SchedulingState,
        req: &AnswerCardRequest,
        answered_at_millis: i64,
    ) -> Result<Option<(ReviewInput, i64, i64)>> {
        let context = LiveContext::load(backend, card, config, &self.session)?;
        let base_state = review_state_for_kind(state_kind(Some(current_state)), card.ctype.into());
        let state = review_state_for_live_context(
            base_state,
            context.previous,
            context.timing,
            answered_at_millis,
            context.synthetic,
        );
        if raw_review_kind(state).is_none() {
            return Ok(None);
        }
        let shown = self
            .session
            .shown_states
            .as_ref()
            .filter(|(card_id, _)| *card_id == card.id)
            .map(|(_, states)| states);
        let input = context.answer_input(
            card,
            config,
            shown,
            req.rating,
            req.milliseconds_taken,
            state,
            answered_at_millis,
        );
        Ok(Some((input, state, base_state)))
    }

    /// `record_reviewer_answer`, then the reviewer's `_after_answering`
    /// refresh. Returns whether the resident state was invalidated.
    fn after_answer(
        &mut self,
        backend: &Backend,
        card: &Card,
        pending: Option<(ReviewInput, i64, i64)>,
        answered_at_millis: i64,
    ) -> Result<bool> {
        let mut state_invalidated = false;
        if let Some((input, state, base_state)) = pending {
            if self.trusted && self.base.is_some() && self.model.is_some() {
                if self.answer_needs_canonical_recovery(backend, card, &input, state)? {
                    self.trusted = false;
                    self.base = None;
                    self.undo.clear();
                    state_invalidated = true;
                } else {
                    let review_id =
                        latest_review_id(backend, card.id)?.unwrap_or(answered_at_millis);
                    let model = self.model_mut()?;
                    let before = model.warm_up_state(&input);
                    let runtime = model.state_for_card(input.card_id);
                    let frame = UndoFrame {
                        review_id,
                        card_id: input.card_id,
                        note_id: input.note_id,
                        deck_id: input.deck_id,
                        preset_id: input.preset_id,
                        before: clone_state(&before),
                        runtime,
                    };
                    model.review(input, review_state(&before))?;
                    self.own_answers += 1;
                    self.unsaved = true;
                    self.undo.push(frame);
                    if self.undo.len() > UNDO_LIMIT {
                        self.undo.remove(0);
                    }
                }
            } else {
                // Not warm: the next readiness check replays this answer.
                self.trusted = false;
                state_invalidated = true;
            }
            if state != base_state {
                self.session.synthetic.insert(
                    card.id,
                    SyntheticAnswer {
                        review_state: state,
                        answered_at_millis,
                    },
                );
            } else {
                self.session.synthetic.remove(&card.id);
            }
        }

        // _after_answering
        if let Some(deck_id) = self.session.deck_id {
            self.refresh_after_answer(backend, deck_id, card)?;
        }
        Ok(state_invalidated)
    }

    /// `_rwkv_live_answer_canonical_recovery_reason`: answers whose canonical
    /// history differs from "previous history + this answer".
    fn answer_needs_canonical_recovery(
        &self,
        backend: &Backend,
        card: &Card,
        input: &ReviewInput,
        state: i64,
    ) -> Result<bool> {
        if state == LEARN_START && retained_history_rows(backend, card.id)? > 1 {
            return Ok(true);
        }
        if !overlay_has_routing_rules(backend)? {
            return Ok(false);
        }
        let reloaded = get_card(backend, card.id)?;
        let deck_id = current_deck_id(&reloaded);
        let config = deck_config_for_deck(backend, deck_id)?;
        let preset = preset_id_for_card(backend, reloaded.id, config.as_ref())?;
        Ok(Some(reloaded.note_id) != input.note_id
            || Some(deck_id) != input.deck_id
            || preset != input.preset_id)
    }

    /// The reviewer's `_after_answering` queue refresh for RWKV-Instant.
    fn refresh_after_answer(&mut self, backend: &Backend, deck_id: i64, card: &Card) -> Result<()> {
        let Some(config) = deck_config_for_deck(backend, deck_id)? else {
            return Ok(());
        };
        if !instant_enabled(&config) {
            return Ok(());
        }
        let answered_config = deck_config_for_deck(backend, current_deck_id(card))?;
        let interval = answered_config
            .as_ref()
            .map_or(1, |c| config_inner(c).rwkv_review_refresh_interval.max(1))
            as usize;
        let answered = self.session.answered_ids.len();
        let refresh_due = answered > 0 && answered.is_multiple_of(interval);
        if refresh_due || self.queue_is_empty(backend)? {
            self.score_deck(backend, deck_id)?;
            return Ok(());
        }
        // refresh_answered_card_queue_score + intervening-review update.
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
            Some(input) if self.ready(backend) => {
                let retrievability = self.predict_many(std::slice::from_ref(&input))?[0];
                Some(pb::rwkv_review_queue_scores_request::Score {
                    card_id: card.id,
                    retrievability,
                    intervening_reviews: None,
                    target_retention: input_target_retention(&input),
                })
            }
            _ => None,
        };
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
        let intervening = self.intervening_reviews(backend, deck_id, &config)?;
        if !intervening.is_empty() {
            backend.with_col(|col| {
                SchedulerService::update_rwkv_review_queue_intervening_reviews(
                    col,
                    pb::RwkvReviewQueueInterveningReviewsRequest {
                        deck_id,
                        items: intervening
                            .iter()
                            .map(|(card_id, n)| {
                                pb::rwkv_review_queue_intervening_reviews_request::Item {
                                    card_id: *card_id,
                                    intervening_reviews: *n,
                                }
                            })
                            .collect(),
                    },
                )
            })?;
        }
        Ok(())
    }

    fn queue_is_empty(&self, backend: &Backend) -> Result<bool> {
        let queued = backend.with_col(|col| {
            SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )
        })?;
        Ok(queued.cards.is_empty())
    }

    /// `answer_undone`, for the answer most recently applied here. Call after
    /// the collection's undo removed it.
    fn undo_answer(&mut self, backend: &Backend) -> Result<UndoResponse> {
        self.session.prediction = None;
        let Some(frame) = self.undo.pop() else {
            self.trusted = false;
            return Ok(UndoResponse { restored: false });
        };
        if review_exists(backend, frame.review_id)? || self.own_answers == 0 {
            // Whatever was undone, it was not this answer.
            self.undo.clear();
            self.trusted = false;
            return Ok(UndoResponse { restored: false });
        }
        let model = self.model_mut()?;
        model.restore_warm_up_state(
            frame.card_id,
            frame.note_id,
            frame.deck_id,
            frame.preset_id,
            frame.before,
        )?;
        model.restore_state(&frame.runtime);
        self.own_answers -= 1;
        if self.session.answered_ids.last() == Some(&frame.card_id) {
            self.session.answered_ids.pop();
        }
        self.session.synthetic.remove(&frame.card_id);
        if let Some(deck_id) = self.session.deck_id {
            self.score_deck(backend, deck_id)?;
        }
        Ok(UndoResponse { restored: true })
    }
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
        session: &Session,
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
            synthetic: session.synthetic.get(&card.id).copied(),
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

    /// `_rwkv_pending_answer_review_input`.
    #[allow(clippy::too_many_arguments)]
    fn answer_input(
        &self,
        card: &Card,
        config: &DeckConfig,
        shown_states: Option<&pb::SchedulingStates>,
        rating: u8,
        milliseconds_taken: u32,
        state: i64,
        answered_at_millis: i64,
    ) -> ReviewInput {
        let (day_offset, elapsed_days, elapsed_seconds) =
            answer_elapsed(self.timing, answered_at_millis, state, self.previous);
        let limit_millis = i64::from(config_inner(config).cap_answer_time_to_secs) * 1000;
        let duration = i64::from(milliseconds_taken)
            .max(0)
            .min(limit_millis.max(0));
        ReviewInput {
            card_id: card.id,
            note_id: Some(card.note_id),
            deck_id: Some(current_deck_id(card)),
            preset_id: self.preset_id,
            is_query: false,
            ease: Some(rating),
            duration_millis: Some(duration),
            card_type: Some(state),
            day_offset: Some(day_offset),
            current_elapsed_days: Some(elapsed_days),
            current_elapsed_seconds: Some(elapsed_seconds),
            target_retentions: self.target_retentions(config, shown_states),
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
            "overlay": overlay,
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

fn history_inputs(
    backend: &Backend,
    params: &HistoryParams,
) -> Result<pb::RwkvHistoricalReviewInputsResponse> {
    Ok(backend.with_col(|col| {
        SchedulerService::rwkv_historical_review_inputs(
            col,
            pb::RwkvHistoricalReviewInputsRequest {
                history: Some(params.request.clone()),
                // Each deck's policy, as the desktop's DECK_CONFIG source.
                first_review_uses_creation: None,
                ..Default::default()
            },
        )
    })?)
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

fn latest_review_id(backend: &Backend, card_id: i64) -> Result<Option<i64>> {
    Ok(db_query::<(i64,)>(
        backend,
        "select id from revlog where cid = ? order by id desc limit 1",
        vec![serde_json::json!(card_id)],
    )?
    .into_iter()
    .next()
    .map(|(id,)| id))
}

fn review_exists(backend: &Backend, review_id: i64) -> Result<bool> {
    Ok(!db_query::<(i64,)>(
        backend,
        "select id from revlog where id = ?",
        vec![serde_json::json!(review_id)],
    )?
    .is_empty())
}

/// `_historical_rwkv_review_rows(card_ids=[card_id])` count: eligible answers
/// after the card's latest Forget, from its latest learning start.
fn retained_history_rows(backend: &Backend, card_id: i64) -> Result<usize> {
    let rows = db_query::<(i64, i64, i64, i64)>(
        backend,
        "select id, ease, type, factor from revlog where cid = ? order by id",
        vec![serde_json::json!(card_id)],
    )?;
    let after_forget = rows
        .iter()
        .rposition(|(_, ease, kind, factor)| *kind == 4 && *ease == 0 && *factor == 0)
        .map_or(0, |i| i + 1);
    let eligible: Vec<_> = rows[after_forget..]
        .iter()
        .filter(|(_, ease, kind, factor)| {
            (1..=4).contains(ease) && (0..=5).contains(kind) && !(*kind == 3 && *factor == 0)
        })
        .collect();
    // `_benchmark_retained_historical_review_starts`: from the latest type-0
    // answer not preceded by another type-0 answer.
    let start = (0..eligible.len())
        .rev()
        .find(|&i| eligible[i].2 == 0 && (i == 0 || eligible[i - 1].2 != 0))
        .unwrap_or(0);
    Ok(eligible.len() - start)
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
