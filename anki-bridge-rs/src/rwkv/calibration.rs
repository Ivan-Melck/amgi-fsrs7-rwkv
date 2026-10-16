//! Calibration graph data (predicted vs actual recall, FSRS and RWKV).
//!
//! The desktop splits this in two: the fork's qt/aqt/rwkv_scheduler.py
//! writes the historical predictions (`recompute_rwkv_calibration_data`, the
//! answer-time rows, Build Cache's FSRS rebuild), and the Search Stats
//! Extended add-on reads them for a search (`fsrs_review_retrievability`,
//! `rwkv_review_retrievability`) next to the review samples its
//! `getMemorisedDays` picks. Both halves are here; binning, bootstrap and
//! UM+ are in AnkiKit (`Calibration*.swift`).

use std::collections::HashMap;
use std::collections::HashSet;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

use anki::services::BackendCollectionService;
use anki::services::BackendSchedulerService;
use anki::services::ConfigService;
use anki::services::SchedulerService;
use anki::services::SearchService;
use anki::timestamp::TimestampSecs;
use serde::Deserialize;
use serde::Serialize;

use super::*;

/// `_RWKV_REVIEW_RETRIEVABILITY_CACHE_TABLE` / `RWKV_RETRIEVABILITY_CACHE_TABLE`.
const RWKV_TABLE: &str = "search_stats_rwkv_review_retrievability";
/// `_FSRS_REVIEW_RETRIEVABILITY_CACHE_TABLE` / `FSRS_RETRIEVABILITY_CACHE_TABLE`.
const FSRS_TABLE: &str = "search_stats_fsrs_review_retrievability";
/// `_RWKV_RETRIEVABILITY_SAMPLE_ROLE_*`.
const FINAL_FIT: &str = "final_fit";
const TEST_FOLD: &str = "test_fold";
/// `_RWKV_CALIBRATION_RECOMPUTE_SOURCE`.
const RECOMPUTE_SOURCE: &str = "rwkv_calibration_recompute";
/// Legacy rows a recompute replaces (`_prune_superseded_rwkv_calibration_rows`).
const SUPERSEDED_SOURCE: &str = "rwkv_calibration_train";
/// `_RWKV_CALIBRATION_TRAIN_FRACTION`.
const TRAIN_FRACTION: f64 = 0.70;
/// `_RWKV_CALIBRATION_EPOCH_FILE`.
const EPOCH_FILE: &str = "calibration-epoch-v1.json";
/// `DAY_SECONDS` / `day_ms`.
const DAY_SECONDS: i64 = 86_400;
const DAY_MS: i64 = DAY_SECONDS * 1000;
/// `FSRS_CALIBRATION_CACHE_ROLES`, and with the suppressing role
/// (`FSRS_CACHE_ROLES_WITH_SUPPRESSORS`).
const FSRS_CALIBRATION_ROLES: &str = "'validation_fold', 'post_optimization'";
const FSRS_ROLES_WITH_SUPPRESSORS: &str = "'validation_fold', 'post_optimization', 'final_fit'";
/// `RWKV_CALIBRATION_CACHE_ROLES` and `RWKV_CALIBRATION_SUPPRESSOR_SOURCES`.
const RWKV_CALIBRATION_ROLES: &str = "'test_fold', 'post_optimization'";
const RWKV_SUPPRESSOR_SOURCES: &str = "'rwkv_calibration_train', 'rwkv_calibration_recompute'";

// MARK: - Progress

/// Set to stop a running recompute; read without the engine lock.
static CANCEL: AtomicBool = AtomicBool::new(false);
static PROGRESS: Mutex<ProgressResponse> = Mutex::new(ProgressResponse {
    running: false,
    label: String::new(),
    current: 0,
    total: 0,
});
/// Set while the FSRS rebuild runs: its progress is the backend's.
static FSRS_RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct ProgressRequest {
    /// Stop the running recompute or FSRS rebuild.
    pub cancel: bool,
}

/// The desktop's progress dialog: a label and, while replaying, a count.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct ProgressResponse {
    pub running: bool,
    pub label: String,
    pub current: u64,
    pub total: u64,
}

pub fn progress(backend: &Backend, req: ProgressRequest) -> ProgressResponse {
    if req.cancel {
        CANCEL.store(true, Ordering::SeqCst);
        if FSRS_RUNNING.load(Ordering::SeqCst) {
            let _ = BackendCollectionService::set_wants_abort(backend);
        }
    }
    let mut progress = PROGRESS.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if FSRS_RUNNING.load(Ordering::SeqCst) {
        if let Ok(anki_proto::collection::Progress {
            value: Some(anki_proto::collection::progress::Value::ComputeParams(params)),
        }) = BackendCollectionService::latest_progress(backend)
        {
            progress.current = params.current.into();
            progress.total = params.total.into();
        }
    }
    progress
}

/// Marks an operation running for `progress`, until dropped.
struct ProgressGuard;

impl ProgressGuard {
    fn start(label: &str) -> Self {
        CANCEL.store(false, Ordering::SeqCst);
        set_progress(true, label, 0, 0);
        ProgressGuard
    }
}

impl Drop for ProgressGuard {
    fn drop(&mut self) {
        set_progress(false, "", 0, 0);
    }
}

fn set_progress(running: bool, label: &str, current: u64, total: u64) {
    *PROGRESS.lock().unwrap_or_else(|e| e.into_inner()) = ProgressResponse {
        running,
        label: label.into(),
        current,
        total,
    };
}

const CANCELLED: &str = "cancelled";

/// `_report_rwkv_state_cache_progress`, also where a cancel takes effect.
fn report(label: &str, current: u64, total: u64) -> Result<()> {
    if CANCEL.load(Ordering::SeqCst) {
        return Err(Error(CANCELLED.into()));
    }
    set_progress(true, label, current, total);
    Ok(())
}

/// `_rwkv_replay_progress_label`.
pub(super) fn replay_progress_label(
    label: &str,
    processed: u64,
    total: u64,
    elapsed_seconds: f64,
) -> String {
    let processed = processed.min(total);
    let mut parts = vec![
        format!(
            "{label}: {}/{} reviews",
            thousands(processed),
            thousands(total)
        ),
        format!("elapsed: {}", format_progress_time(elapsed_seconds)),
    ];
    if processed > 0 {
        let remaining = if processed >= total {
            0.0
        } else {
            elapsed_seconds * (total - processed) as f64 / processed as f64
        };
        parts.push(format!("remaining: {}", format_progress_time(remaining)));
    }
    parts.join(" | ")
}

/// Python's `f"{n:,}"`.
fn thousands(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// `_format_rwkv_progress_time`.
pub(super) fn format_progress_time(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    let (minutes, seconds) = (seconds / 60, seconds % 60);
    let (hours, minutes) = (minutes / 60, minutes % 60);
    if hours > 0 {
        format!("{hours}h {minutes:02}m {seconds:02}s")
    } else if minutes > 0 {
        format!("{minutes}m {seconds:02}s")
    } else {
        format!("{seconds}s")
    }
}

// MARK: - Requests and responses

#[derive(Serialize, Debug, Default)]
pub struct RecomputeResponse {
    /// False when the recompute was cancelled.
    pub recomputed: bool,
    pub reviews: u64,
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct RebuildFsrsRequest {
    /// Build Cache first clears both prediction caches and the calibration
    /// epoch, which lives in the RWKV cache directory.
    pub clear: bool,
    pub cache_dir: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct RebuildFsrsResponse {
    pub predictions: u32,
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CalibrationDataRequest {
    pub search: String,
    /// The stats period (`searchLimit`); 0 reads the whole history.
    pub day_range: u32,
    /// For `ensure_rwkv_calibration_data`; without a model RWKV rows are
    /// only read.
    pub model_path: Option<String>,
    pub cache_dir: Option<String>,
    pub precision: Option<String>,
    /// Generate missing RWKV calibration rows, as the add-on does.
    pub ensure: bool,
}

/// Columns of the add-on's `calibration_samples` and its two prediction
/// maps (`predictionsByRevlogId`).
#[derive(Serialize, Default, Debug, PartialEq)]
pub struct CalibrationDataResponse {
    pub sample_revlog_ids: Vec<i64>,
    pub sample_card_ids: Vec<i64>,
    pub sample_actual: Vec<u8>,
    pub fsrs_revlog_ids: Vec<i64>,
    pub fsrs_predictions: Vec<f64>,
    pub rwkv_revlog_ids: Vec<i64>,
    pub rwkv_predictions: Vec<f64>,
    pub rwkv_warnings: Vec<String>,
}

// MARK: - FSRS (Build Cache)

/// Build Cache's first half (`build_rwkv_state_cache_with_progress` with
/// `rebuild_retrievability_cache`): clear both caches and the calibration
/// epoch, then `rebuild_fsrs_review_retrievability_cache`.
pub fn rebuild_fsrs(backend: &Backend, req: RebuildFsrsRequest) -> Result<RebuildFsrsResponse> {
    let _progress = ProgressGuard::start("Clearing historical prediction caches...");
    if req.clear {
        backend.with_col(SchedulerService::clear_review_retrievability_cache)?;
        if let Some(dir) = req.cache_dir {
            let _ = std::fs::remove_file(PathBuf::from(dir).join(EPOCH_FILE));
        }
    }
    report("Rebuilding FSRS calibration predictions...", 0, 0)?;
    FSRS_RUNNING.store(true, Ordering::SeqCst);
    let result = BackendSchedulerService::rebuild_fsrs_review_retrievability_cache(backend);
    FSRS_RUNNING.store(false, Ordering::SeqCst);
    Ok(RebuildFsrsResponse {
        predictions: result?.val,
    })
}

// MARK: - RWKV recompute

impl Engine {
    /// The deck options' "Calculate Calibration Graph Data"
    /// (`recompute_rwkv_calibration_data`): rewrites the historical RWKV
    /// predictions without replacing the resident state.
    pub(super) fn recompute_calibration(
        &mut self,
        backend: &Backend,
        req: PrepareRequest,
    ) -> Result<RecomputeResponse> {
        let _progress = ProgressGuard::start("Recomputing RWKV calibration data...");
        self.load_for_calibration(backend, &req)?;
        match self.recompute(backend, None) {
            Ok(reviews) => Ok(RecomputeResponse {
                recomputed: true,
                reviews,
            }),
            Err(err) if err.0 == CANCELLED => Ok(RecomputeResponse::default()),
            Err(err) => Err(err),
        }
    }

    /// The model, without requiring an RWKV preset (the desktop's backend
    /// is configured from the environment).
    fn load_for_calibration(&mut self, backend: &Backend, req: &PrepareRequest) -> Result<()> {
        self.follow_collection(backend)?;
        if req.cache_dir.is_some() {
            self.cache_dir = req.cache_dir.as_ref().map(PathBuf::from);
        }
        self.load_model(req)
    }

    /// `_recompute_rwkv_calibration_data`: replay the whole history on an
    /// empty state, recording every review's pre-answer prediction under
    /// its fold role, then put the resident state back.
    fn recompute(
        &mut self,
        backend: &Backend,
        history: Option<pb::RwkvHistoricalReviewInputsResponse>,
    ) -> Result<u64> {
        report("Loading RWKV review history...", 0, 0)?;
        let history = match history {
            Some(history) => history,
            None => {
                let params = history_params(backend, self.model_precision_name())?;
                history_inputs(backend, &params)?
            }
        };
        let review_ids: Vec<i64> = history.reviews.iter().map(|r| r.review_id).collect();
        let (roles, folds) = fold_role_maps(backend, &history);

        let replayed = {
            let _replaying = ReplayGuard::start();
            let model = self.model_mut()?;
            // `_rwkv_temporary_replay_snapshot_callables`, then
            // `reset_cache_snapshot()`.
            model.stash_warm_up_state()?;
            model.reset_warm_up_state();
            let replayed = replay_recording(model, backend, &history, &roles, &folds);
            match model.restore_stashed_warm_up_state() {
                Ok(()) => replayed,
                Err(err) => {
                    // The resident state is gone: rebuild it next time.
                    self.forget_state();
                    self.reload_model()?;
                    return Err(err.into());
                }
            }
        };
        replayed?;
        prune_superseded(backend, &review_ids, &roles, &folds);
        self.write_epoch(backend);
        Ok(review_ids.len() as u64)
    }

    /// `ensure_rwkv_calibration_data`: nothing when the rows are complete,
    /// a relabel when only the FSRS folds changed, else a recompute.
    pub(super) fn ensure_calibration_data(&mut self, backend: &Backend) -> Result<bool> {
        let params = history_params(backend, self.model_precision_name())?;
        let history = match history_inputs(backend, &params) {
            Ok(history) => history,
            Err(_) => return self.recompute(backend, None).map(|_| true),
        };
        if self.calibration_data_available(backend, &params) {
            return Ok(true);
        }
        if self.realign(backend, &params, &history) {
            return Ok(true);
        }
        self.recompute(backend, Some(history)).map(|_| true)
    }

    /// `_rwkv_calibration_data_available`, with the saved state's header as
    /// the desktop's state-cache metadata.
    pub(super) fn calibration_data_available(
        &self,
        backend: &Backend,
        params: &HistoryParams,
    ) -> bool {
        let (Some(dir), Some(model)) = (self.cache_dir.as_ref(), self.model.as_ref()) else {
            return false;
        };
        let Ok(Some(header)) = cache::read_header(dir) else {
            return false;
        };
        // `_rwkv_state_cache_metadata_usable`.
        if header.replay_key != params.replay_key || header.model_digest != model.digest {
            return false;
        }
        let Ok(fp) = fingerprint(backend, params, Some(&header.identity)) else {
            return false;
        };
        if !(fp.history_is_valid || fp.history_prefix_is_valid) {
            return false;
        }
        let last_review_id = header.identity.last_review_id;
        let review_count = header.identity.review_count;
        if !cache_complete(backend, last_review_id, review_count) {
            return false;
        }
        if review_count < 2 {
            return true;
        }
        let sql = format!(
            "select 1 from {RWKV_TABLE} where revlog_id <= ? and prediction between 0 and 1 \
             and sample_role = ? limit 1"
        );
        let available =
            db_query::<(i64,)>(backend, &sql, vec![last_review_id.into(), TEST_FOLD.into()])
                .is_ok_and(|rows| rows.first().is_some_and(|(one,)| *one == 1));
        available && test_folds_match_fsrs(backend, last_review_id)
    }

    /// `_realign_rwkv_calibration_data`: give existing predictions of the
    /// current epoch the active FSRS folds.
    fn realign(
        &mut self,
        backend: &Backend,
        params: &HistoryParams,
        history: &pb::RwkvHistoricalReviewInputsResponse,
    ) -> bool {
        if !self.calibration_epoch_current() {
            return false;
        }
        let sql = format!(
            "select revlog_id, prediction, sample_role, fold_index from {RWKV_TABLE} \
             where source = ? and prediction between 0 and 1"
        );
        let Ok(rows) =
            db_query::<(i64, f64, String, i64)>(backend, &sql, vec![RECOMPUTE_SOURCE.into()])
        else {
            return false;
        };
        let predictions: HashMap<i64, f64> = rows.iter().map(|r| (r.0, r.1)).collect();
        let existing: HashSet<(i64, &str, i64)> =
            rows.iter().map(|r| (r.0, r.2.as_str(), r.3)).collect();
        let answered: Vec<i64> = history.reviews.iter().map(|r| r.review_id).collect();
        if answered.iter().any(|id| !predictions.contains_key(id)) {
            return false;
        }
        let (roles, folds) = fold_role_maps(backend, history);
        let rows: Vec<_> = answered
            .iter()
            .filter(|id| {
                let role = roles.get(*id).map_or(FINAL_FIT, String::as_str);
                let fold = folds.get(*id).copied().unwrap_or(-1);
                !existing.contains(&(**id, role, i64::from(fold)))
            })
            .map(|id| (*id, predictions[id] as f32))
            .collect();
        if store_rows(backend, &rows, &roles, &folds).is_err() {
            return false;
        }
        prune_superseded(backend, &answered, &roles, &folds);
        // Also confirms the state lineage still matches the current history.
        self.calibration_data_available(backend, params)
    }

    // MARK: epoch

    /// `_rwkv_calibration_epoch_from_metadata`: what every later answer's
    /// prediction depends on.
    fn calibration_epoch(&self) -> Option<Epoch> {
        let model = self.model.as_ref()?;
        Some(Epoch {
            collection: self.collection_path.clone()?,
            model: model.digest.clone(),
            replay_key: self.replay_key.clone()?,
            lineage: self.lineage.clone()?,
        })
    }

    /// `_write_rwkv_calibration_epoch`: the lineage a completed recompute
    /// matches, if the resident state is current.
    fn write_epoch(&mut self, backend: &Backend) {
        let Some(dir) = self.cache_dir.clone() else {
            return;
        };
        let path = dir.join(EPOCH_FILE);
        let epoch = if self.current(backend).unwrap_or(false) {
            self.calibration_epoch()
        } else {
            None
        };
        let Some(epoch) = epoch else {
            let _ = std::fs::remove_file(&path);
            return;
        };
        let Ok(json) = serde_json::to_vec(&epoch) else {
            return;
        };
        let tmp = path.with_extension("tmp");
        let _ = std::fs::create_dir_all(&dir)
            .and_then(|()| std::fs::write(&tmp, json))
            .and_then(|()| std::fs::rename(&tmp, &path));
    }

    /// `_rwkv_calibration_epoch_current`.
    pub(super) fn calibration_epoch_current(&self) -> bool {
        let Some(dir) = self.cache_dir.as_ref() else {
            return false;
        };
        let Ok(bytes) = std::fs::read(dir.join(EPOCH_FILE)) else {
            return false;
        };
        let Ok(stored) = serde_json::from_slice::<Epoch>(&bytes) else {
            return false;
        };
        self.calibration_epoch()
            .is_some_and(|current| current == stored)
    }

    // MARK: read

    /// The add-on's `fsrsCalibrationStats` / `rwkvCalibrationStats` inputs
    /// for a search: the calibration samples and both prediction maps.
    pub(super) fn calibration_data(
        &mut self,
        backend: &Backend,
        req: CalibrationDataRequest,
    ) -> Result<CalibrationDataResponse> {
        let card_ids = backend.with_col(|col| {
            SearchService::search_cards(
                col,
                anki_proto::search::SearchRequest {
                    search: req.search.clone(),
                    order: None,
                },
            )
        })?;
        if card_ids.ids.is_empty() {
            return Ok(CalibrationDataResponse::default());
        }
        let rollover = backend.with_col(ConfigService::get_preferences)?;
        let rollover = rollover.scheduling.map_or(0, |s| i64::from(s.rollover));
        let target = target_clause(&card_ids.ids, rollover, req.day_range);
        let revlogs: Vec<RevlogRow> = db_query::<(i64, i64, i64, i64, i64)>(
            backend,
            &format!(
                "select id, cid, ease, type, factor from revlog where {} order by id",
                target.sql("id")
            ),
            target.args(),
        )?
        .into_iter()
        .map(|(id, cid, ease, kind, factor)| RevlogRow {
            id,
            cid,
            ease,
            kind,
            factor,
        })
        .collect();
        let samples = calibration_samples(&revlogs, rollover, &mut cached_minutes_west());
        let mut response = CalibrationDataResponse::default();
        if samples.is_empty() {
            return Ok(response);
        }
        for sample in &samples {
            response.sample_revlog_ids.push(sample.revlog_id);
            response.sample_card_ids.push(sample.card_id);
            response.sample_actual.push(sample.actual);
        }
        let sample_ids: HashSet<i64> = samples.iter().map(|s| s.revlog_id).collect();

        // `fsrs_review_retrievability`.
        for (revlog_id, prediction) in read_fsrs(backend, &target) {
            if sample_ids.contains(&revlog_id) {
                response.fsrs_revlog_ids.push(revlog_id);
                response.fsrs_predictions.push(prediction);
            }
        }
        // `fsrsCalibrationStats`: without cached rows, the predictions of
        // `getMemorisedDays`' own ts-fsrs replay.
        if response.fsrs_revlog_ids.is_empty() {
            let replay = super::fsrs_memorised::replay(backend, &card_ids.ids, req.day_range)?;
            let predictions: HashMap<i64, f64> = replay
                .memorised
                .calibration_predictions
                .into_iter()
                .collect();
            for sample in &samples {
                if let Some(prediction) = predictions.get(&sample.revlog_id) {
                    response.fsrs_revlog_ids.push(sample.revlog_id);
                    response.fsrs_predictions.push(*prediction);
                }
            }
        }

        // `rwkv_review_retrievability`.
        let mut rows = read_rwkv(backend, &target, &sample_ids);
        if rows.is_empty() && req.ensure {
            if let Some(model_path) = req.model_path.clone() {
                let prepare = PrepareRequest {
                    model_path,
                    cache_dir: req.cache_dir.clone(),
                    precision: req.precision.clone(),
                };
                let _progress = ProgressGuard::start("Loading RWKV review history...");
                // `_ensure_rwkv_calibration_data` swallows every failure, a
                // cancel included (`except Exception` → False): the FSRS
                // series still shows, next to an empty RWKV one.
                let ensured = self
                    .load_for_calibration(backend, &prepare)
                    .and_then(|()| self.ensure_calibration_data(backend));
                if ensured.is_ok_and(|ensured| ensured) {
                    rows = read_rwkv(backend, &target, &sample_ids);
                }
            }
        }
        // `_rwkv_review_target_ids_for_requested_ids`, which doesn't warn
        // about skipped rows when reading the role-aware cache.
        let by_id: HashMap<i64, &RevlogRow> = revlogs.iter().map(|r| (r.id, r)).collect();
        let targets: HashSet<i64> = samples
            .iter()
            .filter_map(|s| by_id.get(&s.revlog_id))
            .filter(|r| (1..=4).contains(&r.ease) && (0..=4).contains(&r.kind))
            .map(|r| r.id)
            .collect();
        let missing = samples
            .iter()
            .filter(|s| !by_id.contains_key(&s.revlog_id))
            .count();
        if missing > 0 {
            response.rwkv_warnings.push(format!(
                "RWKV calibration ignored {missing} requested revlog id(s) that no longer exist."
            ));
        }
        let mut predictions: Vec<(i64, f64)> = rows
            .into_iter()
            .filter(|(id, _)| targets.contains(id))
            .collect::<HashMap<_, _>>()
            .into_iter()
            .collect();
        predictions.sort_unstable_by_key(|(id, _)| *id);
        for (revlog_id, prediction) in predictions {
            response.rwkv_revlog_ids.push(revlog_id);
            response.rwkv_predictions.push(prediction);
        }
        Ok(response)
    }
}

#[derive(Serialize, Deserialize, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
struct Epoch {
    collection: String,
    model: String,
    replay_key: String,
    lineage: String,
}

/// A fresh `Engine::lineage`.
pub(super) fn new_lineage() -> String {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, Ordering::SeqCst);
    hex_sha256(format!("{}-{}-{count}", now_millis(), std::process::id()).as_bytes())
}

/// `answered_review_retrievability`: the answer's input queried, as the
/// historical replay records it, on the state before the answer.
pub(super) fn answer_prediction(
    model: &mut RwkvInference,
    input: &ReviewInput,
    before: &ReviewStateOwned,
) -> Option<f32> {
    input.ease?;
    let query = ReviewInput {
        is_query: true,
        ease: None,
        duration_millis: None,
        ..input.clone()
    };
    let retrievability = model
        .review(query, review_state(before))
        .ok()?
        .retrievability;
    valid_prediction(retrievability).then_some(retrievability)
}

/// `_record_rwkv_answer_calibration_prediction`. A missing row only makes
/// the next calibration read recompute, so failures are ignored.
pub(super) fn record_answer_prediction(backend: &Backend, review_id: i64, prediction: f32) {
    let _ = store_rows(
        backend,
        &[(review_id, prediction)],
        &HashMap::new(),
        &HashMap::new(),
    );
}

fn valid_prediction(value: f32) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

/// `warm_up(..., prediction_recorder=writer.record)` in chunks.
fn replay_recording(
    model: &mut RwkvInference,
    backend: &Backend,
    history: &pb::RwkvHistoricalReviewInputsResponse,
    roles: &HashMap<i64, String>,
    folds: &HashMap<i64, i32>,
) -> Result<()> {
    let total = history.reviews.len() as u64;
    let started = Instant::now();
    let label = "Recomputing RWKV calibration data";
    let mut processed = 0u64;
    report(
        &replay_progress_label(label, 0, total, 0.0),
        processed,
        total,
    )?;
    for chunk in history.reviews.chunks(WARM_UP_CHUNK) {
        let inputs = chunk.iter().map(history_review_input).collect();
        let predictions = model.warm_up_reviews(inputs, true)?;
        let rows: Vec<(i64, f32)> = predictions
            .into_iter()
            .filter_map(|(index, p)| chunk.get(index).map(|r| (r.review_id, p)))
            .collect();
        // The desktop's writer only logs a failed flush.
        let _ = store_rows(backend, &rows, roles, folds);
        processed += chunk.len() as u64;
        let elapsed = started.elapsed().as_secs_f64();
        report(
            &replay_progress_label(label, processed, total, elapsed),
            processed,
            total,
        )?;
    }
    Ok(())
}

/// `_RwkvReviewRetrievabilityCacheWriter` (source
/// `rwkv_calibration_recompute`, default role `final_fit`, fold -1).
fn store_rows(
    backend: &Backend,
    rows: &[(i64, f32)],
    roles: &HashMap<i64, String>,
    folds: &HashMap<i64, i32>,
) -> Result<()> {
    let rows: Vec<_> = rows
        .iter()
        .filter(|(id, p)| *id > 0 && valid_prediction(*p))
        .map(
            |(id, p)| pb::rwkv_review_retrievability_cache_rows_request::Row {
                revlog_id: *id,
                prediction: *p,
                sample_role: roles.get(id).map_or(FINAL_FIT, String::as_str).into(),
                fold_index: folds.get(id).copied().unwrap_or(-1),
            },
        )
        .collect();
    if rows.is_empty() {
        return Ok(());
    }
    let _stored = backend.with_col(|col| {
        SchedulerService::set_rwkv_review_retrievability_cache_rows(
            col,
            pb::RwkvReviewRetrievabilityCacheRowsRequest {
                source: RECOMPUTE_SOURCE.into(),
                rows,
            },
        )
    })?;
    Ok(())
}

/// `_prune_superseded_rwkv_calibration_rows`. Stale rows only cost space,
/// so a failure is ignored.
fn prune_superseded(
    backend: &Backend,
    review_ids: &[i64],
    roles: &HashMap<i64, String>,
    folds: &HashMap<i64, i32>,
) {
    let keep = review_ids
        .iter()
        .map(
            |id| pb::prune_rwkv_review_retrievability_cache_rows_request::Key {
                revlog_id: *id,
                sample_role: roles.get(id).map_or(FINAL_FIT, String::as_str).into(),
                fold_index: folds.get(id).copied().unwrap_or(-1),
            },
        )
        .collect();
    let _ = backend.with_col(|col| {
        SchedulerService::prune_rwkv_review_retrievability_cache_rows(
            col,
            pb::PruneRwkvReviewRetrievabilityCacheRowsRequest {
                source: RECOMPUTE_SOURCE.into(),
                keep,
                superseded_sources: vec![SUPERSEDED_SOURCE.into()],
            },
        )
    });
}

/// `_rwkv_calibration_fold_role_maps`: the FSRS validation folds when the
/// FSRS cache has them, else the last 30% of answers as one test fold.
fn fold_role_maps(
    backend: &Backend,
    history: &pb::RwkvHistoricalReviewInputsResponse,
) -> (HashMap<i64, String>, HashMap<i64, i32>) {
    let review_ids: Vec<i64> = history.reviews.iter().map(|r| r.review_id).collect();
    let last_review_id = history
        .metadata
        .as_ref()
        .and_then(|m| m.identity.as_ref())
        .map_or(0, |i| i.last_review_id);
    let fsrs_folds = active_fsrs_validation_folds(backend, last_review_id);
    fold_role_maps_for(&review_ids, fsrs_folds.as_ref())
}

pub(super) fn fold_role_maps_for(
    review_ids: &[i64],
    fsrs_folds: Option<&HashMap<i64, i32>>,
) -> (HashMap<i64, String>, HashMap<i64, i32>) {
    if review_ids.len() < 2 {
        return Default::default();
    }
    if let Some(fsrs_folds) = fsrs_folds.filter(|f| !f.is_empty()) {
        let roles = review_ids
            .iter()
            .map(|id| {
                let role = if fsrs_folds.contains_key(id) {
                    TEST_FOLD
                } else {
                    FINAL_FIT
                };
                (*id, role.to_string())
            })
            .collect();
        let folds = review_ids
            .iter()
            .map(|id| (*id, fsrs_folds.get(id).copied().unwrap_or(-1)))
            .collect();
        return (roles, folds);
    }
    // Python's int() truncates, like `as`.
    let train_end = ((review_ids.len() as f64 * TRAIN_FRACTION) as usize)
        .max(1)
        .min(review_ids.len() - 1);
    let mut roles = HashMap::new();
    let mut folds = HashMap::new();
    for (index, id) in review_ids.iter().enumerate() {
        let train = index < train_end;
        roles.insert(*id, if train { FINAL_FIT } else { TEST_FOLD }.to_string());
        folds.insert(*id, if train { -1 } else { 0 });
    }
    (roles, folds)
}

/// `_active_fsrs_validation_fold_indices`; None when the cache can't be
/// read.
fn active_fsrs_validation_folds(
    backend: &Backend,
    last_review_id: i64,
) -> Option<HashMap<i64, i32>> {
    let sql = format!(
        "select cache.revlog_id, cache.fold_index from {FSRS_TABLE} cache \
         join (select revlog_id, max(updated_at) as updated_at from {FSRS_TABLE} \
               where revlog_id <= ? \
                 and sample_role in ('final_fit', 'validation_fold', 'post_optimization') \
               group by revlog_id) latest \
           on latest.revlog_id = cache.revlog_id and latest.updated_at = cache.updated_at \
         where cache.sample_role = 'validation_fold' \
         order by cache.revlog_id"
    );
    let rows = db_query::<(i64, i64)>(backend, &sql, vec![last_review_id.into()]).ok()?;
    Some(
        rows.into_iter()
            .filter(|(id, fold)| *id > 0 && *fold >= 0)
            .map(|(id, fold)| (id, fold as i32))
            .collect(),
    )
}

/// `_rwkv_calibration_test_folds_match_fsrs`.
fn test_folds_match_fsrs(backend: &Backend, last_review_id: i64) -> bool {
    let Some(fsrs_folds) =
        active_fsrs_validation_folds(backend, last_review_id).filter(|f| !f.is_empty())
    else {
        return true;
    };
    let sql = format!(
        "select cache.revlog_id, cache.fold_index from {RWKV_TABLE} cache \
         join (select revlog_id, max(updated_at) as updated_at from {RWKV_TABLE} \
               where revlog_id <= ? \
                 and (sample_role in ({RWKV_CALIBRATION_ROLES}) \
                      or (sample_role = 'final_fit' and source in ({RWKV_SUPPRESSOR_SOURCES}))) \
               group by revlog_id) latest \
           on latest.revlog_id = cache.revlog_id and latest.updated_at = cache.updated_at \
         where cache.sample_role = 'test_fold' \
         order by cache.revlog_id"
    );
    let Ok(rows) = db_query::<(i64, i64)>(backend, &sql, vec![last_review_id.into()]) else {
        return false;
    };
    if rows.iter().any(|(id, fold)| *id <= 0 || *fold < 0) {
        return false;
    }
    let active: HashMap<i64, i64> = rows.into_iter().collect();
    !active.is_empty()
        && active
            .iter()
            .all(|(id, fold)| fsrs_folds.get(id).map(|f| i64::from(*f)) == Some(*fold))
}

/// `_rwkv_review_retrievability_cache_complete`.
fn cache_complete(backend: &Backend, last_review_id: i64, review_count: u64) -> bool {
    if review_count == 0 {
        return true;
    }
    let sql = format!(
        "select count(distinct r.id) from revlog r \
         join {RWKV_TABLE} cache on cache.revlog_id = r.id \
         where {} and r.id <= ? and cache.prediction between 0 and 1",
        historical_answer_condition("r")
    );
    db_query::<(i64,)>(backend, &sql, vec![last_review_id.into()])
        .ok()
        .and_then(|rows| rows.first().map(|(count,)| *count))
        .is_some_and(|count| count >= 0 && count as u64 >= review_count)
}

// MARK: - Reading the caches for a search

/// The add-on's `revlog.id > lower_limit and cid in (...)` restriction.
struct TargetClause {
    card_ids: String,
    lower_limit: f64,
}

impl TargetClause {
    fn sql(&self, column: &str) -> String {
        format!(
            "{column} in (select id from revlog where cid in ({}) and id > ?)",
            self.card_ids
        )
    }

    fn args(&self) -> Vec<serde_json::Value> {
        vec![self.lower_limit.into()]
    }
}

fn target_clause(card_ids: &[i64], rollover: i64, day_range: u32) -> TargetClause {
    TargetClause {
        card_ids: card_ids
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(","),
        lower_limit: revlog_lower_limit(now_millis() / 1000, rollover, day_range),
    }
}

/// `_revlog_lower_limit`: in milliseconds, from Python's float division.
pub(super) fn revlog_lower_limit(now_secs: i64, rollover: i64, day_range: u32) -> f64 {
    if day_range == 0 {
        return 0.0;
    }
    let today = (now_secs - rollover * 60 * 60) as f64 / DAY_SECONDS as f64;
    (today - f64::from(day_range)) * DAY_SECONDS as f64 * 1000.0
}

/// `_read_fsrs_calibration_retrievability_cache` (valid probabilities, by
/// revlog id; later rows win, as in the add-on's map).
fn read_fsrs(backend: &Backend, target: &TargetClause) -> Vec<(i64, f64)> {
    let sql = format!(
        "select cache.revlog_id, cache.prediction from {FSRS_TABLE} cache \
         join (select revlog_id, max(updated_at) as updated_at from {FSRS_TABLE} cache \
               where {} and sample_role in ({FSRS_ROLES_WITH_SUPPRESSORS}) \
               group by revlog_id) latest \
           on latest.revlog_id = cache.revlog_id and latest.updated_at = cache.updated_at \
         where cache.sample_role in ({FSRS_CALIBRATION_ROLES}) \
         order by cache.revlog_id",
        target.sql("cache.revlog_id")
    );
    last_valid(db_query::<(i64, f64)>(backend, &sql, target.args()).unwrap_or_default())
}

/// `_read_rwkv_calibration_retrievability_cache`.
fn read_rwkv(
    backend: &Backend,
    target: &TargetClause,
    sample_ids: &HashSet<i64>,
) -> Vec<(i64, f64)> {
    let sql = format!(
        "select cache.revlog_id, cache.prediction from {RWKV_TABLE} cache \
         join (select revlog_id, max(updated_at) as updated_at from {RWKV_TABLE} cache \
               where {} and (cache.sample_role in ({RWKV_CALIBRATION_ROLES}) \
                     or (cache.sample_role = 'final_fit' \
                         and cache.source in ({RWKV_SUPPRESSOR_SOURCES}))) \
               group by revlog_id) latest \
           on latest.revlog_id = cache.revlog_id and latest.updated_at = cache.updated_at \
         where cache.sample_role in ({RWKV_CALIBRATION_ROLES}) \
         order by cache.revlog_id",
        target.sql("cache.revlog_id")
    );
    // The add-on asks for the samples' ids only.
    let rows = db_query::<(i64, f64)>(backend, &sql, target.args()).unwrap_or_default();
    last_valid(
        rows.into_iter()
            .filter(|(id, _)| sample_ids.contains(id))
            .collect(),
    )
}

/// `_valid_probability`, keeping the last row per revlog id in row order.
fn last_valid(rows: Vec<(i64, f64)>) -> Vec<(i64, f64)> {
    let mut out: Vec<(i64, f64)> = Vec::with_capacity(rows.len());
    for (id, prediction) in rows {
        if !(0.0..=1.0).contains(&prediction) {
            continue;
        }
        match out.last_mut() {
            Some(last) if last.0 == id => last.1 = prediction,
            _ => out.push((id, prediction)),
        }
    }
    out
}

// MARK: - Calibration samples (`getMemorisedDays`)

#[derive(Clone, Copy, Debug)]
pub(super) struct RevlogRow {
    pub id: i64,
    pub cid: i64,
    pub ease: i64,
    pub kind: i64,
    pub factor: i64,
}

/// `CalibrationSample`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Sample {
    pub revlog_id: i64,
    pub card_id: i64,
    pub actual: u8,
}

/// The reviews `getMemorisedDays` adds to `calibration_samples`: rated,
/// non-cram reviews of a card with an earlier rated review at least a
/// (rollover-adjusted, local) day before, after the card's last reset,
/// and not dropped by `applyOutlierFilter`. `revlogs` are ordered by id.
/// Every searched card has an FSRS preset (`fsrsPresetData`), so the
/// add-on's `card_fsrs_source` never skips one.
pub(super) fn calibration_samples(
    revlogs: &[RevlogRow],
    rollover: i64,
    minutes_west: &mut impl FnMut(i64) -> i32,
) -> Vec<Sample> {
    let excluded = outlier_filter(revlogs);
    // `calculateRevlogStats`' `last_forget`.
    let mut last_forget: HashMap<i64, i64> = HashMap::new();
    for revlog in revlogs {
        if revlog.factor == 0 && revlog.kind == 4 {
            last_forget.insert(revlog.cid, revlog.id);
        }
    }
    let rollover_ms = rollover * 60 * 60 * 1000;
    // `card.last_review` of the add-on's ts-fsrs cards, as local day
    // numbers. A forget keeps it.
    let mut last_review_day: HashMap<i64, i64> = HashMap::new();
    let mut samples = vec![];
    for revlog in revlogs {
        if revlog.ease == 0 {
            continue;
        }
        // Cram.
        if revlog.kind == 3 && revlog.factor == 0 {
            continue;
        }
        let day = local_review_day(revlog.id, rollover_ms, minutes_west);
        if let Some(previous) = last_review_day.get(&revlog.cid) {
            let elapsed = day - previous;
            if elapsed >= 1
                && last_forget.get(&revlog.cid).copied().unwrap_or(0) < revlog.id
                && !excluded.contains(&revlog.id)
            {
                samples.push(Sample {
                    revlog_id: revlog.id,
                    card_id: revlog.cid,
                    actual: u8::from(revlog.ease > 1),
                });
            }
        }
        last_review_day.insert(revlog.cid, day);
    }
    samples
}

/// The day `dateDiffInDays` sees for a review: the UTC date of
/// `new Date(ms - rollover_ms).setHours(0, 0, 0, 0)`, i.e. of local
/// midnight on the review's (rollover-adjusted) local date.
pub(super) fn local_review_day(
    ms: i64,
    rollover_ms: i64,
    minutes_west: &mut impl FnMut(i64) -> i32,
) -> i64 {
    let shifted = ms - rollover_ms;
    let local = shifted - i64::from(minutes_west(shifted)) * 60_000;
    let local_midnight = local.div_euclid(DAY_MS) * DAY_MS;
    // A local time's UTC instant uses the offset in force then.
    let guess = local_midnight + i64::from(minutes_west(shifted)) * 60_000;
    let midnight = local_midnight + i64::from(minutes_west(guess)) * 60_000;
    midnight.div_euclid(DAY_MS)
}

/// The device's offset, cached per quarter hour (offsets change on quarter
/// hours at the finest).
pub(super) fn cached_minutes_west() -> impl FnMut(i64) -> i32 {
    let mut cache: HashMap<i64, i32> = HashMap::new();
    move |ms| {
        let bucket = ms.div_euclid(15 * 60_000);
        *cache.entry(bucket).or_insert_with(|| {
            anki::scheduler::timing::local_minutes_west_for_stamp(TimestampSecs(bucket * 15 * 60))
                .unwrap_or(0)
        })
    }
}

/// `applyOutlierFilter`: drops every review of cards whose first interval
/// (first rating, days between the second and third reviews) is rare.
pub(super) fn outlier_filter(revlogs: &[RevlogRow]) -> HashSet<i64> {
    // Each card's first three reviews (any kind), in id order.
    let mut firsts: HashMap<i64, Vec<&RevlogRow>> = HashMap::new();
    for revlog in revlogs {
        let reviews = firsts.entry(revlog.cid).or_default();
        if reviews.len() < 3 {
            reviews.push(revlog);
        }
    }
    // (first rating, delta_t) per card with at least three reviews;
    // `dateDiffInDays` on the raw ids compares UTC dates.
    let pairs: HashMap<i64, (i64, i64)> = firsts
        .iter()
        .filter(|(_, reviews)| reviews.len() == 3)
        .map(|(cid, reviews)| {
            let delta_t = reviews[2].id.div_euclid(DAY_MS) - reviews[1].id.div_euclid(DAY_MS);
            (*cid, (reviews[0].ease, delta_t))
        })
        .collect();
    let mut groups: HashMap<i64, HashMap<i64, usize>> = HashMap::new();
    for (rating, delta_t) in pairs.values() {
        *groups
            .entry(*rating)
            .or_default()
            .entry(*delta_t)
            .or_default() += 1;
    }
    let mut removed: HashMap<i64, HashSet<i64>> = HashMap::new();
    for (rating, delta_ts) in &groups {
        if *rating == 0 {
            continue;
        }
        let mut sub_groups: Vec<(i64, usize)> =
            delta_ts.iter().map(|(dt, count)| (*dt, *count)).collect();
        // By size, then delta_t.
        sub_groups.sort_by_key(|(dt, count)| (*count, *dt));
        let total: usize = sub_groups.iter().map(|(_, count)| count).sum();
        let threshold = 20.max(total / 20);
        let mut has_been_removed = 0;
        let removed_pairs = removed.entry(*rating).or_default();
        for (delta_t, count) in sub_groups {
            if has_been_removed + count < threshold {
                has_been_removed += count;
                removed_pairs.insert(delta_t);
                continue;
            }
            let keep = count >= 6 && delta_t <= if *rating != 4 { 100 } else { 365 };
            if !keep {
                removed_pairs.insert(delta_t);
            }
        }
    }
    let mut excluded: HashSet<i64> = revlogs
        .iter()
        .filter(|revlog| {
            pairs.get(&revlog.cid).is_some_and(|(rating, delta_t)| {
                removed
                    .get(rating)
                    .is_some_and(|removed| removed.contains(delta_t))
            })
        })
        .map(|revlog| revlog.id)
        .collect();
    // Remove non contiguous revlogs.
    let mut ignored_cards = HashSet::new();
    for revlog in revlogs {
        if ignored_cards.contains(&revlog.cid) {
            excluded.insert(revlog.id);
        }
        if excluded.contains(&revlog.id) {
            ignored_cards.insert(revlog.cid);
        }
    }
    excluded
}
