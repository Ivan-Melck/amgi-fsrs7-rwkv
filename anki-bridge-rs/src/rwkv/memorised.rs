//! The stats screen's RWKV "Memorised" history: the fork's
//! `start_rwkv_memorised_history` / `_compute_rwkv_memorised_history`
//! (qt/aqt/rwkv_scheduler.py) and the Search Stats Extended add-on's cache of
//! its result (`_persist_rwkv_memorised_result` and the checkpoint tables in
//! its `__init__.py`).
//!
//! A private runtime replays the whole review history day by day and
//! predicts every reviewed card's retrievability at the end of each day; the
//! chart sums the predictions of the searched cards. Per-card daily
//! predictions are kept as UInt16 (`round(p * 65535)`), so a finished history
//! is shown for any search without recomputing, and a cancelled or preempted
//! one resumes from its checkpoint.
//!
//! The desktop runs the build on a thread and the add-on polls it; here the
//! caller's thread runs it (`history`), while `progress` and `cancel`
//! answer from any thread. It doesn't touch the engine, so the reviewer, deck
//! list and card info never wait for it; like the desktop it yields while
//! the engine replays history (`REPLAYING`), and resumes afterwards.
//!
//! The add-on keeps the cache in collection tables; here it is two files in
//! the RWKV cache directory, as the bridge never writes extra tables into the
//! collection.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::collections::HashSet;
use std::fs;
use std::fs::File;
use std::io;
use std::io::BufReader;
use std::io::BufWriter;
use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use super::*;

/// `_RWKV_MEMORISED_CHECKPOINT_INTERVAL_SECONDS`.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(30);
/// `_rwkv_memorised_history_identity`'s "version".
const IDENTITY_VERSION: u32 = 3;
const MAGIC: &[u8] = b"AMGIMEMORISED1\n";
const DIR_NAME: &str = "memorised";
const CACHE_FILE: &str = "history.bin";
const CHECKPOINT_FILE: &str = "checkpoint.bin";

/// Slows each day down, so tests can cancel a build midway.
#[cfg(test)]
pub(super) static TEST_DAY_DELAY_MS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct HistoryRequest {
    /// The stats search; its cards are the ones the series sum.
    pub search: String,
    pub model_path: String,
    pub precision: Option<String>,
    pub cache_dir: Option<String>,
}

/// `rwkv_memorised_history_progress()` / `_aggregate_rwkv_memorised_cache`.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Progress {
    pub phase: &'static str,
    pub current: u64,
    pub total: u64,
    pub first_day: Option<i64>,
    pub completed_through_day: Option<i64>,
    pub retrievability_by_day: Vec<f64>,
    pub note_retrievability_by_day: Vec<f64>,
    pub card_count_by_day: Vec<u32>,
    pub done: bool,
    pub error: Option<String>,
}

/// `RwkvMemorisedCardSeries`.
#[derive(Clone, Debug, PartialEq)]
pub struct CardSeries {
    pub card_id: i64,
    pub note_id: Option<i64>,
    pub start_day: i64,
    pub values: Vec<u16>,
}

/// `RwkvMemorisedHistoryResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryResult {
    pub identity: String,
    pub first_day: i64,
    pub last_day: i64,
    pub cards: Vec<CardSeries>,
    pub completed_through_day: Option<i64>,
    pub total: u64,
    pub complete: bool,
}

/// `RwkvMemorisedHistoryJob`.
struct Job {
    cancel: AtomicBool,
    display: HashSet<i64>,
    request_identity: String,
    state: Mutex<JobState>,
}

#[derive(Default)]
struct JobState {
    phase: &'static str,
    current: u64,
    total: u64,
    first_day: Option<i64>,
    completed_through_day: Option<i64>,
    retrievability: Vec<f64>,
    note_retrievability: Vec<f64>,
    card_count: Vec<u32>,
    result: Option<HistoryResult>,
    checkpoint: Option<HistoryResult>,
    done: bool,
    error: Option<String>,
    /// What the finished `history` call returned, for callers that joined it.
    outcome: Option<Progress>,
}

impl Job {
    fn state(&self) -> std::sync::MutexGuard<'_, JobState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    fn progress(&self) -> Progress {
        let state = self.state();
        Progress {
            phase: state.phase,
            current: state.current,
            total: state.total,
            first_day: state.first_day,
            completed_through_day: state.completed_through_day,
            retrievability_by_day: state.retrievability.clone(),
            note_retrievability_by_day: state.note_retrievability.clone(),
            card_count_by_day: state.card_count.clone(),
            done: state.done,
            error: state.error.clone(),
        }
    }
}

fn current_job() -> &'static Mutex<Option<Arc<Job>>> {
    static JOB: OnceLock<Mutex<Option<Arc<Job>>>> = OnceLock::new();
    JOB.get_or_init(Default::default)
}

fn lock_job() -> std::sync::MutexGuard<'static, Option<Arc<Job>>> {
    current_job().lock().unwrap_or_else(|e| e.into_inner())
}

/// `rwkv_memorised_history_progress`.
pub(super) fn progress() -> Progress {
    let job = lock_job().clone();
    match job {
        Some(job) => job.progress(),
        None => Progress {
            phase: "idle",
            ..Default::default()
        },
    }
}

/// `cancel_rwkv_memorised_history`.
pub(super) fn cancel() {
    let job = lock_job().clone();
    if let Some(job) = job {
        if !job.state().done {
            job.cancel.store(true, Ordering::SeqCst);
        }
    }
}

/// What a build needs besides the collection.
struct Context {
    model_path: PathBuf,
    precision: StatePrecision,
    precision_name: String,
    model_key: String,
    collection: String,
    dir: Option<PathBuf>,
}

/// The add-on's `startRwkvMemorisedHistory` endpoint followed by its polling
/// until the build finishes: the cached history when it is current, else a
/// (resumed) build, saved when it completes and checkpointed when cancelled.
pub(super) fn history(backend: &Backend, req: HistoryRequest) -> Result<Progress> {
    let display: HashSet<i64> = super::fsrs_memorised::search_card_ids(backend, &req.search)?
        .into_iter()
        .filter(|id| *id > 0)
        .collect();
    let context = context(backend, &req)?;
    let request_identity = request_identity(backend, &context)?;
    let dir = context.dir.clone();

    if let Some(cache) = dir.as_deref().and_then(|d| read(&d.join(CACHE_FILE)).ok()) {
        if cache.identity == request_identity {
            return Ok(aggregate_cache(&cache, &display));
        }
    }

    // `start_rwkv_memorised_history`: join the same build, or cancel another
    // (which saves its checkpoint) before starting ours.
    let job = loop {
        let mut slot = lock_job();
        match slot.clone() {
            Some(active) if !active.state().done => {
                if active.display == display && active.request_identity == request_identity {
                    drop(slot);
                    return Ok(join(&active));
                }
                active.cancel.store(true, Ordering::SeqCst);
                drop(slot);
                while !active.state().done {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            _ => {
                let job = Arc::new(Job {
                    cancel: AtomicBool::new(false),
                    display: display.clone(),
                    request_identity: request_identity.clone(),
                    state: Mutex::new(JobState {
                        phase: "loading",
                        ..Default::default()
                    }),
                });
                *slot = Some(job.clone());
                break job;
            }
        }
    };

    // The add-on's resume: a checkpoint of this identity, else the last
    // complete history, whose unchanged prefix can be reused.
    let mut resume = dir.as_deref().and_then(|d| {
        let checkpoint = read(&d.join(CHECKPOINT_FILE)).ok()?;
        if checkpoint.identity != request_identity {
            delete_checkpoint(d);
            return None;
        }
        Some(checkpoint)
    });
    if resume.is_none() {
        resume = dir
            .as_deref()
            .and_then(|d| read(&d.join(CACHE_FILE)).ok())
            .map(complete_cache_result);
    }
    if let Some(resume) = resume {
        let mut state = job.state();
        state.phase = "resuming";
        if !resume.complete {
            let (retrievability, note_retrievability, card_count, _) =
                aggregate_series(&resume, &display);
            state.retrievability = retrievability;
            state.note_retrievability = note_retrievability;
            state.card_count = card_count;
            state.current = resume.cards.iter().map(|c| c.values.len() as u64).sum();
            state.total = resume.total;
            state.first_day = Some(resume.first_day);
            state.completed_through_day = resume.completed_through_day;
        }
        state.checkpoint = Some(resume);
    }

    run(backend, &context, &job);

    let progress = job.progress();
    let result = job.state().result.clone();
    let outcome = match (progress.phase, result) {
        ("complete", Some(result)) => {
            if let Some(dir) = &dir {
                // `_persist_rwkv_memorised_result`: best effort, like a
                // cache; the chart still gets this build's numbers.
                let _ = write(&dir.join(CACHE_FILE), &result);
                delete_checkpoint(dir);
            }
            aggregate_cache(&result, &job.display)
        }
        ("cancelled", Some(result)) if !result.complete => {
            if let Some(dir) = &dir {
                let _ = persist_checkpoint(dir, &result);
            }
            progress
        }
        _ => progress,
    };
    job.state().outcome = Some(outcome.clone());
    Ok(outcome)
}

/// Waits for a build another call started, and returns what it returned.
fn join(job: &Job) -> Progress {
    loop {
        if let Some(outcome) = job.state().outcome.clone() {
            return outcome;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn context(backend: &Backend, req: &HistoryRequest) -> Result<Context> {
    // `state_precision_for_profile`: unknown values fall back to int8.
    let precision_name = req
        .precision
        .clone()
        .filter(|p| StatePrecision::parse(p).is_ok())
        .unwrap_or_else(|| "int8".into());
    let precision = StatePrecision::parse(&precision_name).map_err(|e| Error(e.to_string()))?;
    let model_path = PathBuf::from(&req.model_path);
    if !model_path.exists() {
        return Err(Error("RWKV model is unavailable".into()));
    }
    Ok(Context {
        model_key: model_key(&model_path)?,
        model_path,
        precision,
        precision_name,
        collection: collection_path(backend)?,
        dir: req
            .cache_dir
            .as_ref()
            .map(|dir| PathBuf::from(dir).join(DIR_NAME)),
    })
}

/// `_rwkv_model_cache_key`: the weights' digest, remembered per file
/// version.
fn model_key(path: &Path) -> Result<String> {
    /// Path, length and modification time of the hashed file, and its digest.
    type Key = (PathBuf, u64, Option<SystemTime>, String);
    static KEY: Mutex<Option<Key>> = Mutex::new(None);
    let meta = fs::metadata(path)?;
    let (len, modified) = (meta.len(), meta.modified().ok());
    let mut key = KEY.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((p, l, m, digest)) = key.as_ref() {
        if p == path && *l == len && *m == modified {
            return Ok(digest.clone());
        }
    }
    let digest = hex_sha256(&fs::read(path)?);
    *key = Some((path.to_path_buf(), len, modified, digest.clone()));
    Ok(digest)
}

/// `rwkv_memorised_history_identity`, from the history fingerprint.
fn request_identity(backend: &Backend, context: &Context) -> Result<String> {
    let params = history_params(backend, &context.precision_name)?;
    let history = Identity::from_fingerprint(&fingerprint(backend, &params, None)?);
    let day = backend
        .with_col(SchedulerService::sched_timing_today)?
        .days_elapsed;
    Ok(identity_string(
        context,
        &params.replay_key,
        &history,
        i64::from(day),
    ))
}

/// `_rwkv_memorised_history_identity`: what the daily predictions depend
/// on. The replay key covers the state precision and the replay settings.
fn identity_string(context: &Context, replay_key: &str, history: &Identity, day: i64) -> String {
    serde_json::json!({
        "version": IDENTITY_VERSION,
        "collection": context.collection,
        "model": context.model_key,
        "replayKey": replay_key,
        "lastReviewId": history.last_review_id,
        "reviewCount": history.review_count,
        "historyHash": history.history_hash,
        "dayOffset": day,
    })
    .to_string()
}

/// Why a build stopped early.
enum Stop {
    /// `_RwkvMemorisedPreempted`: the engine is replaying history.
    Preempted,
    Cancelled,
    Failed(Error),
}

impl From<Error> for Stop {
    fn from(err: Error) -> Self {
        Stop::Failed(err)
    }
}

impl From<anki::error::AnkiError> for Stop {
    fn from(err: anki::error::AnkiError) -> Self {
        Stop::Failed(err.into())
    }
}

impl From<io::Error> for Stop {
    fn from(err: io::Error) -> Self {
        Stop::Failed(err.into())
    }
}

/// `_run_rwkv_memorised_history_job`.
fn run(backend: &Backend, context: &Context, job: &Job) {
    loop {
        match compute(backend, context, job) {
            Ok(()) | Err(Stop::Cancelled) => break,
            Err(Stop::Preempted) => {
                let checkpoint = {
                    let mut state = job.state();
                    state.phase = "waiting";
                    state.checkpoint.clone()
                };
                if let (Some(dir), Some(checkpoint)) = (&context.dir, checkpoint) {
                    let _ = persist_checkpoint(dir, &checkpoint);
                }
                // The private runtime is gone; wait for the replay to end.
                while REPLAYING.load(Ordering::SeqCst) && !job.cancelled() {
                    std::thread::sleep(Duration::from_millis(100));
                }
                let mut state = job.state();
                if job.cancelled() {
                    state.phase = "cancelled";
                    state.result = state.checkpoint.clone();
                    break;
                }
                state.phase = "resuming";
            }
            Err(Stop::Failed(err)) => {
                let mut state = job.state();
                state.phase = "failed";
                state.error = Some(err.0);
                break;
            }
        }
    }
    job.state().done = true;
}

/// The build state `_initial_rwkv_memorised_computation_state` returns.
#[derive(Default)]
struct Build {
    review_index: usize,
    active_inputs: BTreeMap<i64, ReviewInput>,
    start_day_by_card: HashMap<i64, i64>,
    values_by_card: BTreeMap<i64, Vec<u16>>,
    retrievability: Vec<f64>,
    note_retrievability: Vec<f64>,
    card_count: Vec<u32>,
    current: u64,
    loop_first_day: i64,
    resumed: bool,
}

/// `_compute_rwkv_memorised_history`.
fn compute(backend: &Backend, context: &Context, job: &Job) -> Result<(), Stop> {
    let last_day = i64::from(
        backend
            .with_col(SchedulerService::sched_timing_today)?
            .days_elapsed,
    );
    let params = history_params(backend, &context.precision_name)?;
    // A complete cache is reusable only while its history is a prefix of
    // the current one; check that under the same lock as the inputs.
    let cached_history = job
        .state()
        .checkpoint
        .as_ref()
        .filter(|c| c.complete)
        .and_then(|c| history_of_identity(&c.identity));
    let (response, cached_is_prefix) = backend.with_col(|col| {
        let response =
            SchedulerService::rwkv_historical_review_inputs(col, history_request(&params))?;
        let cached_is_prefix = match &cached_history {
            Some(cached) => {
                let mut request = params.request.clone();
                request.expected_identity = Some(cached.into());
                let fp = SchedulerService::rwkv_historical_review_fingerprint(col, request)?;
                fp.history_is_valid || fp.history_prefix_is_valid
            }
            None => false,
        };
        Ok((response, cached_is_prefix))
    })?;
    let history = response
        .metadata
        .as_ref()
        .and_then(|m| m.identity.as_ref())
        .map(Identity::from)
        .ok_or_else(|| Error("history response has no identity".into()))?;
    let review_ids: Vec<i64> = response.reviews.iter().map(|r| r.review_id).collect();
    let reviews: Vec<ReviewInput> = response.reviews.iter().map(history_review_input).collect();
    drop(response);
    let identity = identity_string(context, &params.replay_key, &history, last_day);

    if reviews.is_empty() {
        let mut state = job.state();
        state.phase = "complete";
        state.current = 0;
        state.total = 0;
        state.completed_through_day = Some(last_day);
        state.result = Some(HistoryResult {
            identity,
            first_day: last_day,
            last_day,
            cards: vec![],
            completed_through_day: Some(last_day),
            total: 0,
            complete: true,
        });
        return Ok(());
    }

    let mut first_day_by_card: HashMap<i64, i64> = HashMap::new();
    let mut note_id_by_card: HashMap<i64, Option<i64>> = HashMap::new();
    for review in &reviews {
        let day = review.day_offset.unwrap_or_default();
        first_day_by_card.entry(review.card_id).or_insert(day);
        note_id_by_card.insert(review.card_id, review.note_id);
    }
    let first_day = first_day_by_card
        .values()
        .copied()
        .min()
        .unwrap_or(last_day);
    let total: u64 = first_day_by_card
        .values()
        .map(|day| (last_day - day + 1).max(0) as u64)
        .sum();

    let mut selected_note_counts: HashMap<i64, u32> = HashMap::new();
    for card_id in &job.display {
        if let Some(Some(note_id)) = note_id_by_card.get(card_id) {
            *selected_note_counts.entry(*note_id).or_default() += 1;
        }
    }

    if REPLAYING.load(Ordering::SeqCst) {
        return Err(Stop::Preempted);
    }

    let mut runtime = RwkvInference::load_with_precision(
        context.model_path.clone(),
        TARGET_RETENTION,
        MAX_INTERVAL_DAYS,
        context.precision,
    )?;
    let shape = Shape {
        identity: &identity,
        first_day,
        last_day,
        total,
    };
    let mut build = initial_build(
        job,
        &shape,
        &reviews,
        &review_ids,
        cached_is_prefix,
        &history,
        &mut runtime,
    )?;

    {
        let mut state = job.state();
        state.phase = "computing";
        state.current = build.current;
        state.total = total;
        state.first_day = Some(first_day);
        state.completed_through_day = build.resumed.then_some(build.loop_first_day - 1);
        state.retrievability = build.retrievability.clone();
        state.note_retrievability = build.note_retrievability.clone();
        state.card_count = build.card_count.clone();
    }
    let mut last_checkpoint_at = Instant::now();

    for day in build.loop_first_day..=last_day {
        let completed_day = job.state().completed_through_day;
        if job.cancelled() {
            // `_finish_cancelled_rwkv_memorised_job`.
            let checkpoint = completed_day.map(|completed| {
                result_from_values(&shape, completed, &note_id_by_card, &build, false)
            });
            let mut state = job.state();
            state.phase = "cancelled";
            state.checkpoint = checkpoint.clone();
            state.result = checkpoint;
            return Err(Stop::Cancelled);
        }
        if REPLAYING.load(Ordering::SeqCst) {
            if let Some(completed) = completed_day {
                let checkpoint =
                    result_from_values(&shape, completed, &note_id_by_card, &build, false);
                job.state().checkpoint = Some(checkpoint);
            }
            return Err(Stop::Preempted);
        }

        #[cfg(test)]
        std::thread::sleep(Duration::from_millis(
            TEST_DAY_DELAY_MS.load(Ordering::SeqCst),
        ));
        let day_start = build.review_index;
        while build.review_index < reviews.len()
            && reviews[build.review_index].day_offset == Some(day)
        {
            build.review_index += 1;
        }
        let day_reviews = &reviews[day_start..build.review_index];
        for chunk in day_reviews.chunks(WARM_UP_CHUNK) {
            runtime.warm_up_reviews(chunk.to_vec(), false)?;
        }
        for review in day_reviews {
            build.active_inputs.insert(review.card_id, review.clone());
            build.start_day_by_card.entry(review.card_id).or_insert(day);
            build.values_by_card.entry(review.card_id).or_default();
        }

        let predictions = predict_day(&mut runtime, &build.active_inputs, day)?;

        let mut selected_sum = 0.0f64;
        let mut selected_note_sum = 0.0f64;
        let mut selected_count = 0u32;
        for ((card_id, values), raw) in build.values_by_card.iter_mut().zip(&predictions) {
            let prediction = f64::from(*raw).clamp(0.0, 1.0);
            // Python's round() rounds halves to even.
            values.push((prediction * 65_535.0).round_ties_even() as u16);
            if job.display.contains(card_id) {
                selected_sum += prediction;
                selected_count += 1;
                let note_count = note_id_by_card
                    .get(card_id)
                    .copied()
                    .flatten()
                    .and_then(|note_id| selected_note_counts.get(&note_id).copied())
                    .unwrap_or(0);
                if note_count > 0 {
                    selected_note_sum += prediction / f64::from(note_count);
                }
            }
        }
        build.retrievability.push(selected_sum);
        build.note_retrievability.push(selected_note_sum);
        build.card_count.push(selected_count);
        build.current += predictions.len() as u64;
        {
            let mut state = job.state();
            state.current = build.current;
            state.completed_through_day = Some(day);
            state.retrievability = build.retrievability.clone();
            state.note_retrievability = build.note_retrievability.clone();
            state.card_count = build.card_count.clone();
        }

        if last_checkpoint_at.elapsed() >= CHECKPOINT_INTERVAL {
            let checkpoint = result_from_values(&shape, day, &note_id_by_card, &build, false);
            if let Some(dir) = &context.dir {
                let _ = persist_checkpoint(dir, &checkpoint);
            }
            job.state().checkpoint = Some(checkpoint);
            last_checkpoint_at = Instant::now();
        }
    }

    let result = result_from_values(&shape, last_day, &note_id_by_card, &build, true);
    let mut state = job.state();
    state.phase = "complete";
    state.current = total;
    state.completed_through_day = Some(last_day);
    state.result = Some(result);
    state.checkpoint = None;
    Ok(())
}

/// `_predict_rwkv_memorised_day`: each card's last review input queried at
/// the end of `day`, in card id order.
fn predict_day(
    runtime: &mut RwkvInference,
    active_inputs: &BTreeMap<i64, ReviewInput>,
    day: i64,
) -> Result<Vec<f32>> {
    let queries: Vec<ReviewInput> = active_inputs
        .values()
        .map(|previous| memorised_query(previous, day))
        .collect();
    let mut predictions = Vec::with_capacity(queries.len());
    for chunk in queries.chunks(PREDICT_CHUNK) {
        predictions.extend(runtime.predict_retrievability_many_from_warm_up(chunk.to_vec())?);
    }
    if predictions.len() != queries.len() {
        return Err(Error("RWKV prediction count mismatch".into()));
    }
    Ok(predictions)
}

/// `_packed_review_input_row(review_input, query_day=day)`.
fn memorised_query(previous: &ReviewInput, day: i64) -> ReviewInput {
    let elapsed_days = (day - previous.day_offset.unwrap_or(day)).max(0);
    ReviewInput {
        is_query: true,
        ease: None,
        duration_millis: None,
        day_offset: Some(day),
        current_elapsed_days: Some(elapsed_days),
        current_elapsed_seconds: Some(elapsed_days * 86_400),
        ..previous.clone()
    }
}

/// The fixed facts of one build.
struct Shape<'a> {
    identity: &'a str,
    first_day: i64,
    last_day: i64,
    total: u64,
}

/// `_initial_rwkv_memorised_computation_state`.
fn initial_build(
    job: &Job,
    shape: &Shape<'_>,
    reviews: &[ReviewInput],
    review_ids: &[i64],
    cached_is_prefix: bool,
    history: &Identity,
    runtime: &mut RwkvInference,
) -> Result<Build> {
    let mut resume = job.state().checkpoint.clone();
    if resume.as_ref().is_some_and(|r| r.complete) {
        resume = resume.and_then(|completed| {
            completed_prefix_checkpoint(
                completed,
                shape,
                reviews,
                review_ids,
                cached_is_prefix,
                history,
            )
        });
    }
    let Some(resume) = resume else {
        return Ok(fresh_build(job, shape));
    };
    let Some(mut build) = restore_checkpoint(&resume, shape, reviews, runtime)? else {
        return Ok(fresh_build(job, shape));
    };
    let (retrievability, note_retrievability, card_count, _) =
        aggregate_series(&resume, &job.display);
    build.retrievability = retrievability;
    build.note_retrievability = note_retrievability;
    build.card_count = card_count;
    build.current = build.values_by_card.values().map(|v| v.len() as u64).sum();
    build.loop_first_day = resume.completed_through_day.unwrap_or(shape.first_day - 1) + 1;
    build.resumed = true;
    Ok(build)
}

/// Starts from the first day; drops a stale or invalid checkpoint.
fn fresh_build(job: &Job, shape: &Shape<'_>) -> Build {
    job.state().checkpoint = None;
    Build {
        loop_first_day: shape.first_day,
        ..Default::default()
    }
}

/// The history fields of an identity string.
fn history_of_identity(identity: &str) -> Option<Identity> {
    let value: serde_json::Value = serde_json::from_str(identity).ok()?;
    Some(Identity {
        last_review_id: value.get("lastReviewId")?.as_i64()?,
        review_count: value.get("reviewCount")?.as_u64()?,
        history_hash: value.get("historyHash")?.as_str()?.to_string(),
    })
}

/// `_rwkv_memorised_completed_prefix_checkpoint`: reuse the days of a
/// complete history before the first day with new reviews. The desktop
/// rehashes the reviews to see the cached history is an unchanged prefix;
/// the history fingerprint (`cached_is_prefix`) answers the same question.
fn completed_prefix_checkpoint(
    completed: HistoryResult,
    shape: &Shape<'_>,
    reviews: &[ReviewInput],
    review_ids: &[i64],
    cached_is_prefix: bool,
    history: &Identity,
) -> Option<HistoryResult> {
    if !completed.complete
        || completed.completed_through_day != Some(completed.last_day)
        || completed.first_day != shape.first_day
        || completed.last_day > shape.last_day
        || reviews.len() != review_ids.len()
        || !cached_is_prefix
    {
        return None;
    }
    let strip = |identity: &str| -> Option<(serde_json::Value, Identity, i64)> {
        let mut value: serde_json::Value = serde_json::from_str(identity).ok()?;
        let history = history_of_identity(identity)?;
        let object = value.as_object_mut()?;
        let day = object.remove("dayOffset")?.as_i64()?;
        for key in ["lastReviewId", "reviewCount", "historyHash"] {
            object.remove(key);
        }
        Some((value, history, day))
    };
    let (cached_rest, cached, cached_day) = strip(&completed.identity)?;
    let (current_rest, _, current_day) = strip(shape.identity)?;
    if cached_rest != current_rest
        || cached_day != completed.last_day
        || current_day != shape.last_day
        || cached_day > current_day
        || cached.last_review_id > history.last_review_id
        || cached.review_count > history.review_count
    {
        return None;
    }

    let new_review_days: Vec<i64> = review_ids
        .iter()
        .zip(reviews)
        .filter(|(id, _)| **id > cached.last_review_id)
        .filter_map(|(_, review)| review.day_offset)
        .collect();
    if history.last_review_id > cached.last_review_id && new_review_days.is_empty() {
        return None;
    }
    let affected_day = new_review_days
        .iter()
        .copied()
        .min()
        .unwrap_or(completed.last_day + 1);
    let reusable_through_day = completed.last_day.min(affected_day - 1);
    if reusable_through_day < shape.first_day || reusable_through_day >= shape.last_day {
        return None;
    }

    let mut cards = vec![];
    for card in completed.cards {
        if card.start_day > reusable_through_day {
            continue;
        }
        let count = (reusable_through_day - card.start_day + 1) as usize;
        if card.values.len() < count {
            return None;
        }
        cards.push(CardSeries {
            values: card.values[..count].to_vec(),
            ..card
        });
    }
    Some(HistoryResult {
        identity: shape.identity.to_string(),
        first_day: shape.first_day,
        last_day: shape.last_day,
        cards,
        completed_through_day: Some(reusable_through_day),
        total: shape.total,
        complete: false,
    })
}

/// `_restore_rwkv_memorised_checkpoint`: the runtime warmed up through the
/// checkpoint's last day, and the build state to continue from.
fn restore_checkpoint(
    checkpoint: &HistoryResult,
    shape: &Shape<'_>,
    reviews: &[ReviewInput],
    runtime: &mut RwkvInference,
) -> Result<Option<Build>> {
    let Some(completed_day) = checkpoint.completed_through_day else {
        return Ok(None);
    };
    if checkpoint.complete
        || checkpoint.identity != shape.identity
        || checkpoint.first_day != shape.first_day
        || checkpoint.last_day != shape.last_day
        || !(shape.first_day <= completed_day && completed_day < shape.last_day)
    {
        return Ok(None);
    }

    let mut build = Build::default();
    while build.review_index < reviews.len()
        && reviews[build.review_index]
            .day_offset
            .is_some_and(|day| day <= completed_day)
    {
        let review = &reviews[build.review_index];
        build.active_inputs.insert(review.card_id, review.clone());
        build
            .start_day_by_card
            .entry(review.card_id)
            .or_insert(review.day_offset.unwrap_or_default());
        build.review_index += 1;
    }
    build.values_by_card = checkpoint
        .cards
        .iter()
        .map(|card| (card.card_id, card.values.clone()))
        .collect();
    if build.values_by_card.len() != checkpoint.cards.len()
        || !build.values_by_card.keys().eq(build.active_inputs.keys())
    {
        return Ok(None);
    }
    for card in &checkpoint.cards {
        let expected_start = build.start_day_by_card[&card.card_id];
        if card.start_day != expected_start
            || card.values.len() as i64 != completed_day - expected_start + 1
        {
            return Ok(None);
        }
    }
    for chunk in reviews[..build.review_index].chunks(WARM_UP_CHUNK) {
        runtime.warm_up_reviews(chunk.to_vec(), false)?;
    }
    Ok(Some(build))
}

/// `_rwkv_memorised_result_from_values`.
fn result_from_values(
    shape: &Shape<'_>,
    completed_through_day: i64,
    note_id_by_card: &HashMap<i64, Option<i64>>,
    build: &Build,
    complete: bool,
) -> HistoryResult {
    HistoryResult {
        identity: shape.identity.to_string(),
        first_day: shape.first_day,
        last_day: shape.last_day,
        cards: build
            .values_by_card
            .iter()
            .map(|(card_id, values)| CardSeries {
                card_id: *card_id,
                note_id: note_id_by_card.get(card_id).copied().flatten(),
                start_day: build.start_day_by_card[card_id],
                values: values.clone(),
            })
            .collect(),
        completed_through_day: Some(completed_through_day),
        total: shape.total,
        complete,
    }
}

/// `_rwkv_memorised_aggregate_series`: the searched cards' daily sums from
/// `first_day` through the last completed day, and how many predictions
/// they summed.
pub fn aggregate_series(
    result: &HistoryResult,
    display: &HashSet<i64>,
) -> (Vec<f64>, Vec<f64>, Vec<u32>, u64) {
    let Some(completed_day) = result.completed_through_day else {
        return (vec![], vec![], vec![], 0);
    };
    let length = (completed_day - result.first_day + 1).max(0) as usize;
    let mut retrievability = vec![0.0; length];
    let mut note_retrievability = vec![0.0; length];
    let mut card_count = vec![0u32; length];
    let mut note_counts: HashMap<i64, u32> = HashMap::new();
    for card in &result.cards {
        if let (true, Some(note_id)) = (display.contains(&card.card_id), card.note_id) {
            *note_counts.entry(note_id).or_default() += 1;
        }
    }
    let mut summed = 0u64;
    for card in result.cards.iter().filter(|c| display.contains(&c.card_id)) {
        let offset = card.start_day - result.first_day;
        let note_count = card
            .note_id
            .and_then(|note_id| note_counts.get(&note_id).copied())
            .unwrap_or(0);
        for (index, encoded) in card.values.iter().enumerate() {
            let Ok(day_index) = usize::try_from(offset + index as i64) else {
                continue;
            };
            if day_index >= length {
                continue;
            }
            let prediction = f64::from(*encoded) / 65_535.0;
            retrievability[day_index] += prediction;
            card_count[day_index] += 1;
            if note_count > 0 {
                note_retrievability[day_index] += prediction / f64::from(note_count);
            }
            summed += 1;
        }
    }
    (retrievability, note_retrievability, card_count, summed)
}

/// `_aggregate_rwkv_memorised_cache`: a finished history, for the search.
pub fn aggregate_cache(result: &HistoryResult, display: &HashSet<i64>) -> Progress {
    let (retrievability, note_retrievability, card_count, summed) = aggregate_series(
        &HistoryResult {
            completed_through_day: Some(result.last_day),
            ..result.clone()
        },
        display,
    );
    Progress {
        phase: "complete",
        current: summed,
        total: summed,
        first_day: Some(result.first_day),
        completed_through_day: Some(result.last_day),
        retrievability_by_day: retrievability,
        note_retrievability_by_day: note_retrievability,
        card_count_by_day: card_count,
        done: true,
        error: None,
    }
}

/// `_load_rwkv_memorised_cache`: the cache as a complete result.
fn complete_cache_result(cache: HistoryResult) -> HistoryResult {
    HistoryResult {
        completed_through_day: Some(cache.last_day),
        total: cache.cards.iter().map(|c| c.values.len() as u64).sum(),
        complete: true,
        ..cache
    }
}

// MARK: - files

/// The `search_stats_rwkv_memorised_*` metadata columns.
#[derive(Serialize, Deserialize)]
struct Header {
    identity: String,
    first_day: i64,
    last_day: i64,
    completed_day: Option<i64>,
    total: u64,
    complete: bool,
}

fn read_u32(reader: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0u8; 4];
    reader.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_i64(reader: &mut impl Read) -> io::Result<i64> {
    let mut bytes = [0u8; 8];
    reader.read_exact(&mut bytes)?;
    Ok(i64::from_le_bytes(bytes))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

fn read_header(reader: &mut impl Read) -> io::Result<Header> {
    let mut magic = [0u8; MAGIC.len()];
    reader.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(invalid("not a memorised history"));
    }
    let len = read_u32(reader)? as usize;
    let mut json = vec![0u8; len];
    reader.read_exact(&mut json)?;
    serde_json::from_slice(&json).map_err(|e| invalid(&e.to_string()))
}

/// Layout: magic, u32 header length, JSON header, u64 card count, then per
/// card: i64 card id, i64 note id (`i64::MIN` for none), i64 start day,
/// u32 value count and the little-endian UInt16 values.
pub fn read(path: &Path) -> io::Result<HistoryResult> {
    let mut reader = BufReader::new(File::open(path)?);
    let header = read_header(&mut reader)?;
    let mut count = [0u8; 8];
    reader.read_exact(&mut count)?;
    let count = u64::from_le_bytes(count) as usize;
    let mut cards = Vec::with_capacity(count.min(1 << 20));
    for _ in 0..count {
        let card_id = read_i64(&mut reader)?;
        let note_id = read_i64(&mut reader)?;
        let start_day = read_i64(&mut reader)?;
        let len = read_u32(&mut reader)? as usize;
        let mut bytes = vec![0u8; len * 2];
        reader.read_exact(&mut bytes)?;
        cards.push(CardSeries {
            card_id,
            note_id: (note_id != i64::MIN).then_some(note_id),
            start_day,
            values: bytes
                .chunks_exact(2)
                .map(|b| u16::from_le_bytes([b[0], b[1]]))
                .collect(),
        });
    }
    Ok(HistoryResult {
        identity: header.identity,
        first_day: header.first_day,
        last_day: header.last_day,
        cards,
        completed_through_day: header.completed_day,
        total: header.total,
        complete: header.complete,
    })
}

/// Written to a temporary file and renamed, so a crash never leaves a torn
/// history behind.
pub fn write(path: &Path, result: &HistoryResult) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut out = BufWriter::with_capacity(1 << 20, File::create(&tmp)?);
        out.write_all(MAGIC)?;
        let json = serde_json::to_vec(&Header {
            identity: result.identity.clone(),
            first_day: result.first_day,
            last_day: result.last_day,
            completed_day: result.completed_through_day,
            total: result.total,
            complete: result.complete,
        })
        .map_err(|e| invalid(&e.to_string()))?;
        out.write_all(&(json.len() as u32).to_le_bytes())?;
        out.write_all(&json)?;
        out.write_all(&(result.cards.len() as u64).to_le_bytes())?;
        for card in &result.cards {
            out.write_all(&card.card_id.to_le_bytes())?;
            out.write_all(&card.note_id.unwrap_or(i64::MIN).to_le_bytes())?;
            out.write_all(&card.start_day.to_le_bytes())?;
            out.write_all(&(card.values.len() as u32).to_le_bytes())?;
            for value in &card.values {
                out.write_all(&value.to_le_bytes())?;
            }
        }
        out.flush()?;
        out.get_ref().sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// `_delete_rwkv_memorised_checkpoint`.
fn delete_checkpoint(dir: &Path) {
    let _ = fs::remove_file(dir.join(CHECKPOINT_FILE));
    *last_checkpoint_key() = None;
}

fn last_checkpoint_key() -> std::sync::MutexGuard<'static, Option<(String, i64)>> {
    static KEY: Mutex<Option<(String, i64)>> = Mutex::new(None);
    KEY.lock().unwrap_or_else(|e| e.into_inner())
}

/// `_persist_rwkv_memorised_checkpoint`: only a newer partial history of
/// the same identity replaces the saved one.
fn persist_checkpoint(dir: &Path, result: &HistoryResult) -> io::Result<()> {
    let Some(completed) = result.completed_through_day.filter(|_| !result.complete) else {
        return Ok(());
    };
    let key = (result.identity.clone(), completed);
    if last_checkpoint_key().as_ref() == Some(&key) {
        return Ok(());
    }
    let path = dir.join(CHECKPOINT_FILE);
    if let Ok(file) = File::open(&path) {
        if let Ok(saved) = read_header(&mut BufReader::new(file)) {
            if saved.identity == result.identity
                && saved.completed_day.is_some_and(|day| day >= completed)
            {
                return Ok(());
            }
        }
    }
    write(&path, result)?;
    *last_checkpoint_key() = Some(key);
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod test {
    use super::*;

    fn card(card_id: i64, note_id: Option<i64>, start_day: i64, values: &[u16]) -> CardSeries {
        CardSeries {
            card_id,
            note_id,
            start_day,
            values: values.to_vec(),
        }
    }

    fn result(cards: Vec<CardSeries>, completed: Option<i64>) -> HistoryResult {
        HistoryResult {
            identity: "{}".into(),
            first_day: 10,
            last_day: 14,
            cards,
            completed_through_day: completed,
            total: 0,
            complete: false,
        }
    }

    #[test]
    fn aggregation_sums_the_searched_cards_and_splits_notes() {
        let history = result(
            vec![
                card(1, Some(100), 10, &[65_535, 32_768, 0]),
                card(2, Some(100), 11, &[65_535, 65_535]),
                card(3, Some(200), 10, &[65_535, 65_535, 65_535]),
                card(4, None, 12, &[13_107]),
            ],
            Some(12),
        );
        let display: HashSet<i64> = [1, 2, 4].into();
        let (r, n, c, summed) = aggregate_series(&history, &display);
        let half = 32_768.0 / 65_535.0;
        assert_eq!(r, vec![1.0, half + 1.0, 1.0 + 0.2]);
        // Cards 1 and 2 share note 100; card 4 has no note.
        assert_eq!(n, vec![0.5, (half + 1.0) / 2.0, 0.5]);
        assert_eq!(c, vec![1, 2, 3]);
        assert_eq!(summed, 6);

        // A finished history covers through its last day.
        let progress = aggregate_cache(&history, &display);
        assert_eq!(progress.phase, "complete");
        assert!(progress.done);
        assert_eq!(progress.first_day, Some(10));
        assert_eq!(progress.completed_through_day, Some(14));
        assert_eq!(progress.retrievability_by_day.len(), 5);
        assert_eq!(progress.current, 6);
        assert_eq!(progress.total, 6);

        assert_eq!(
            aggregate_series(&result(vec![], None), &display),
            (vec![], vec![], vec![], 0)
        );
    }

    #[test]
    fn histories_round_trip_through_files() {
        let dir = std::env::temp_dir().join(format!(
            "amgi-memorised-{}-{}",
            std::process::id(),
            now_millis()
        ));
        let mut history = result(
            vec![
                card(1, Some(100), 10, &[1, 2, 65_535]),
                card(2, None, 12, &[]),
            ],
            Some(12),
        );
        history.total = 9;
        let path = dir.join(CACHE_FILE);
        write(&path, &history).unwrap();
        assert_eq!(read(&path).unwrap(), history);

        // Checkpoints only move forward for the same identity.
        persist_checkpoint(&dir, &history).unwrap();
        let older = HistoryResult {
            completed_through_day: Some(11),
            ..history.clone()
        };
        *last_checkpoint_key() = None;
        persist_checkpoint(&dir, &older).unwrap();
        assert_eq!(
            read(&dir.join(CHECKPOINT_FILE))
                .unwrap()
                .completed_through_day,
            Some(12)
        );
        // A complete result is never a checkpoint.
        *last_checkpoint_key() = None;
        let complete = HistoryResult {
            identity: "other".into(),
            complete: true,
            ..history.clone()
        };
        persist_checkpoint(&dir, &complete).unwrap();
        assert_eq!(read(&dir.join(CHECKPOINT_FILE)).unwrap().identity, "{}");
        delete_checkpoint(&dir);
        assert!(read(&dir.join(CHECKPOINT_FILE)).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn memorised_queries_ask_for_the_end_of_the_day() {
        let previous = ReviewInput {
            card_id: 1,
            note_id: Some(2),
            deck_id: Some(3),
            preset_id: Some(4),
            is_query: false,
            ease: Some(3),
            duration_millis: Some(5000),
            card_type: Some(2),
            day_offset: Some(10),
            current_elapsed_days: Some(4),
            current_elapsed_seconds: Some(4 * 86_400 + 7),
            target_retentions: [None; 4],
            enforce_grade_order: true,
        };
        let query = memorised_query(&previous, 13);
        assert!(query.is_query);
        assert_eq!(query.ease, None);
        assert_eq!(query.duration_millis, None);
        assert_eq!(query.day_offset, Some(13));
        assert_eq!(query.current_elapsed_days, Some(3));
        assert_eq!(query.current_elapsed_seconds, Some(3 * 86_400));
        assert_eq!(query.card_type, Some(2));
        assert_eq!(query.preset_id, Some(4));
        assert_eq!(memorised_query(&previous, 9).current_elapsed_days, Some(0));
    }
}
