//! The deck options' "Compare RWKV with FSRS" workload: `simulate_rwkv_workload`
//! from the fork's qt/aqt/rwkv_scheduler.py, run by the runtime's
//! `simulate_workload_from_warm_up` on the resident state, as the desktop's
//! embedded runtime path does.

use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU32;
use std::sync::atomic::Ordering;

use anki::rwkv::RwkvWorkloadReviewModel;
use anki::rwkv::RwkvWorkloadSimulationConfig;
use anki::rwkv::RwkvWorkloadSimulationInput;
use anki::services::SchedulerService;
use anki_proto::deck_config::deck_config::config::ReviewCardOrder;
use anki_proto::scheduler as pb;
use serde::Deserialize;
use serde::Serialize;

use super::*;

/// `_RWKV_WORKLOAD_MIN_DR` / `_RWKV_WORKLOAD_MAX_DR`.
const MIN_DR: u32 = 30;
const MAX_DR: u32 = 99;
/// `_RWKV_SIMULATOR_*`.
const BUCKET_COUNT: usize = 20;
const PRIOR_WEIGHT: f64 = 4.0;
const DEFAULT_GRADE_SECONDS: f64 = 8.0;
const MAX_TAKEN_MILLIS: i64 = 600_000;
/// `_RWKV_REVIEW_RETRIEVABILITY_CACHE_TABLE`: historical predictions the
/// desktop records; absent here unless the collection came with it.
const RETRIEVABILITY_CACHE_TABLE: &str = "search_stats_rwkv_review_retrievability";

/// Set to stop a running simulation; read without the engine lock.
pub static CANCEL: AtomicBool = AtomicBool::new(false);
static PROGRESS_CURRENT: AtomicU32 = AtomicU32::new(0);
static PROGRESS_TOTAL: AtomicU32 = AtomicU32::new(0);

/// The `SimulateFsrsReviewRequest` fields the RWKV workload reads.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct WorkloadRequest {
    pub search: String,
    pub days_to_simulate: u32,
    pub review_limit: u32,
    pub new_limit: u32,
    pub new_cards_ignore_review_limit: bool,
    pub max_interval: u32,
    pub review_order: i32,
    pub suspend_after_lapse_count: Option<u32>,
    /// `rwkv_workload_sample_limit`; 0 simulates every card.
    pub sample_limit: u32,
    pub target_step: u32,
    pub state_update_interval: u32,
}

#[derive(Serialize, Default, Debug, PartialEq)]
pub struct WorkloadResponse {
    pub reviewless_end_memorized: f32,
    pub reviewless_end_weighted_memorized: f32,
    pub points: Vec<WorkloadPoint>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct WorkloadPoint {
    pub dr: u32,
    pub memorized: f32,
    pub weighted_memorized: f32,
    pub cost: f32,
    pub review_count: u32,
}

#[derive(Serialize)]
pub struct WorkloadProgress {
    pub current: u32,
    pub total: u32,
}

pub fn progress() -> WorkloadProgress {
    WorkloadProgress {
        current: PROGRESS_CURRENT.load(Ordering::SeqCst),
        total: PROGRESS_TOTAL.load(Ordering::SeqCst),
    }
}

impl Engine {
    /// `simulate_rwkv_workload`.
    pub(super) fn simulate_workload(
        &mut self,
        backend: &Backend,
        req: WorkloadRequest,
    ) -> Result<WorkloadResponse> {
        CANCEL.store(false, Ordering::SeqCst);
        PROGRESS_CURRENT.store(0, Ordering::SeqCst);
        PROGRESS_TOTAL.store(0, Ordering::SeqCst);
        // The desktop loads its saved state when it isn't warmed up.
        if !self.current(backend)? {
            self.ensure_ready(backend)?;
        }

        let rows = backend.with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_search(
                col,
                pb::RwkvReviewInputRowsForSearchRequest {
                    search: req.search.clone(),
                    include_suspended_review: false,
                    include_disabled_decks: false,
                    include_new_cards: req.new_limit > 0,
                },
            )
        })?;
        let all_inputs = simulation_inputs(&rows.rows);
        let inputs = sample_inputs(all_inputs.clone(), req.sample_limit as usize);
        let input_scale = if inputs.is_empty() {
            1.0
        } else {
            all_inputs.len() as f64 / inputs.len() as f64
        };
        if inputs.is_empty() {
            return Ok(WorkloadResponse::default());
        }

        let review_model = review_model(&review_model_rows(backend));
        let review_limit = req.review_limit;
        let new_limit = req.new_limit;
        let config = RwkvWorkloadSimulationConfig {
            min_dr: MIN_DR,
            max_dr: MAX_DR,
            target_dr_step: req.target_step.max(1),
            days_to_simulate: req.days_to_simulate,
            review_limit: sampled_limit(review_limit, input_scale),
            new_limit: sampled_limit(new_limit, input_scale),
            new_cards_ignore_review_limit: req.new_cards_ignore_review_limit,
            max_interval: req.max_interval.max(1),
            review_order: ReviewCardOrder::try_from(req.review_order)
                .unwrap_or(ReviewCardOrder::Day),
            suspend_after_lapses: req.suspend_after_lapse_count,
            state_update_interval: req.state_update_interval.max(1),
            review_model,
        };
        let review_count_cap = review_count_cap(
            review_limit,
            if req.new_cards_ignore_review_limit {
                new_limit
            } else {
                0
            },
            req.days_to_simulate,
        );

        // Like a replay, the deck list and card info answer without waiting.
        let _busy = ReplayGuard::start();
        let mut report = |current: u32, total: u32| -> std::io::Result<()> {
            if CANCEL.load(Ordering::SeqCst) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "cancelled",
                ));
            }
            PROGRESS_CURRENT.store(current, Ordering::SeqCst);
            PROGRESS_TOTAL.store(total, Ordering::SeqCst);
            Ok(())
        };
        let output =
            self.model_mut()?
                .simulate_workload_from_warm_up(inputs, config, &mut report)?;

        let mut response = WorkloadResponse {
            reviewless_end_memorized: output.reviewless_end_memorized,
            reviewless_end_weighted_memorized: output.reviewless_end_weighted_memorized,
            points: output
                .points
                .into_iter()
                .map(|(dr, point)| WorkloadPoint {
                    dr,
                    memorized: point.memorized,
                    weighted_memorized: point.weighted_memorized,
                    cost: point.cost,
                    review_count: point.review_count,
                })
                .collect(),
        };
        scale_response(&mut response, input_scale, review_count_cap);
        Ok(response)
    }
}

/// `_rwkv_simulation_inputs`: new cards, and review cards with an elapsed
/// time.
fn simulation_inputs(
    rows: &[pb::rwkv_review_input_rows_for_cards_response::Row],
) -> Vec<RwkvWorkloadSimulationInput> {
    const NEW: i64 = 0;
    const REVIEW: i64 = 2;
    rows.iter()
        .filter_map(|row| {
            let input = query_input_from_row(row);
            match input.card_type {
                Some(NEW) => {}
                Some(REVIEW) if input.current_elapsed_days.is_some() => {}
                _ => return None,
            }
            Some(RwkvWorkloadSimulationInput {
                review_input: input,
                interval_days: Some(row.interval_days.into()),
                ease_factor: Some(row.ease_factor.into()),
                reps: Some(row.reps.into()),
                lapses: Some(row.lapses.into()),
            })
        })
        .collect()
}

/// `_sample_rwkv_simulation_inputs`: evenly spaced by card id.
fn sample_inputs(
    mut inputs: Vec<RwkvWorkloadSimulationInput>,
    limit: usize,
) -> Vec<RwkvWorkloadSimulationInput> {
    if limit == 0 || inputs.len() <= limit {
        return inputs;
    }
    inputs.sort_by_key(|input| input.review_input.card_id);
    let total = inputs.len();
    if limit == 1 {
        return vec![inputs.swap_remove(total / 2)];
    }
    (0..limit)
        // Python's round() rounds halves to even.
        .map(|index| {
            let at = (index as f64 * (total - 1) as f64 / (limit - 1) as f64).round_ties_even();
            inputs[at as usize].clone()
        })
        .collect()
}

/// `_rwkv_sampled_review_limit`.
fn sampled_limit(limit: u32, input_scale: f64) -> u32 {
    if limit == 0 {
        return 0;
    }
    if input_scale <= 1.0 {
        return limit;
    }
    ((limit as f64 / input_scale).round_ties_even() as u32).max(1)
}

/// `_rwkv_workload_review_count_cap`.
fn review_count_cap(review_limit: u32, additional_new_limit: u32, days: u32) -> u32 {
    ((review_limit as u64 + additional_new_limit as u64) * days as u64).min(u32::MAX as u64) as u32
}

/// `_scale_rwkv_workload_response` then
/// `_enforce_monotonic_rwkv_workload_review_counts`.
fn scale_response(response: &mut WorkloadResponse, scale: f64, review_count_cap: u32) {
    if scale != 1.0 {
        response.reviewless_end_memorized *= scale as f32;
        response.reviewless_end_weighted_memorized *= scale as f32;
        for point in &mut response.points {
            point.memorized *= scale as f32;
            point.weighted_memorized *= scale as f32;
            point.cost *= scale as f32;
        }
    }
    for point in &mut response.points {
        let count = (point.review_count as f64 * scale)
            .round_ties_even()
            .max(0.0);
        point.review_count = (count.min(u32::MAX as f64) as u32).min(review_count_cap);
    }
    response.points.sort_by_key(|point| point.dr);
    let mut running = 0;
    for point in &mut response.points {
        running = running.max(point.review_count);
        point.review_count = running;
    }
}

/// `_rwkv_simulator_review_model_rows`: (prediction, ease, time) of the
/// reviews the desktop recorded predictions for; empty when it didn't.
fn review_model_rows(backend: &Backend) -> Vec<(f64, i64, i64)> {
    let sql = format!(
        "select cache.prediction, r.ease, r.time from {RETRIEVABILITY_CACHE_TABLE} cache \
         join revlog r on r.id = cache.revlog_id \
         where cache.prediction between 0 and 1 and {}",
        historical_answer_condition("r")
    );
    db_query::<(f64, i64, i64)>(backend, &sql, vec![]).unwrap_or_default()
}

/// `_rwkv_simulator_review_model`: answer-grade probabilities per
/// retrievability bucket and seconds per grade, in Python's doubles.
pub(super) fn review_model(rows: &[(f64, i64, i64)]) -> RwkvWorkloadReviewModel {
    let mut bucket_counts: std::collections::BTreeMap<u32, [f64; 4]> = Default::default();
    let mut seconds_sum = [0.0f64; 4];
    let mut seconds_count = [0u32; 4];
    for &(retrievability, ease, taken_millis) in rows {
        // `_valid_probability`; NaN and infinities fall outside the range.
        if !(1..=4).contains(&ease) || !(0.0..=1.0).contains(&retrievability) {
            continue;
        }
        let grade = (ease - 1) as usize;
        bucket_counts.entry(bucket(retrievability)).or_default()[grade] += 1.0;
        if 0 < taken_millis && taken_millis < MAX_TAKEN_MILLIS {
            seconds_sum[grade] += taken_millis as f64 / 1000.0;
            seconds_count[grade] += 1;
        }
    }
    let bucket_probabilities = bucket_counts
        .into_iter()
        .filter_map(|(bucket, counts)| {
            let center = (bucket as f64 + 0.5) / BUCKET_COUNT as f64;
            let fallback = fallback_grade_probabilities(center);
            let smoothed: [f64; 4] =
                std::array::from_fn(|i| counts[i] + fallback[i] * PRIOR_WEIGHT);
            let total: f64 = smoothed.iter().sum();
            (total > 0.0).then(|| (bucket, smoothed.map(|value| (value / total) as f32)))
        })
        .collect();
    let grade_seconds = std::array::from_fn(|i| {
        if seconds_count[i] > 0 {
            (seconds_sum[i] / seconds_count[i] as f64) as f32
        } else {
            DEFAULT_GRADE_SECONDS as f32
        }
    });
    RwkvWorkloadReviewModel {
        grade_seconds,
        bucket_probabilities,
    }
}

/// `_rwkv_simulator_bucket`.
fn bucket(retrievability: f64) -> u32 {
    if !retrievability.is_finite() {
        return BUCKET_COUNT as u32 - 1;
    }
    ((retrievability * BUCKET_COUNT as f64) as i64).clamp(0, BUCKET_COUNT as i64 - 1) as u32
}

/// `_fallback_rwkv_grade_probabilities`.
pub(super) fn fallback_grade_probabilities(retrievability: f64) -> [f64; 4] {
    let r = if retrievability.is_finite() {
        retrievability.clamp(0.0, 1.0)
    } else {
        0.9
    };
    let again = (1.0 - r).clamp(0.02, 0.85);
    let success = 1.0 - again;
    let mut hard_share = ((0.95 - r) / 0.45).clamp(0.10, 0.45);
    let mut easy_share = ((r - 0.75) / 0.25).clamp(0.05, 0.35);
    if hard_share + easy_share > 0.90 {
        let scale = 0.90 / (hard_share + easy_share);
        hard_share *= scale;
        easy_share *= scale;
    }
    let hard = success * hard_share;
    let easy = success * easy_share;
    let good = (success - hard - easy).max(0.0);
    let total = again + hard + good + easy;
    [again / total, hard / total, good / total, easy / total]
}
