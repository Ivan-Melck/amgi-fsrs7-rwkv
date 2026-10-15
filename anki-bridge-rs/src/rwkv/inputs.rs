//! Pure RWKV input construction, ported from the desktop orchestration in
//! `anki-upstream/qt/aqt/rwkv_scheduler.py`. Each function names the Python
//! function it mirrors; keep them in step when the desktop changes.

use anki::rwkv::ReviewInput;
use anki_proto::scheduler::rwkv_review_input_rows_for_cards_response::Row;
use anki_proto::scheduler::scheduling_state;
use anki_proto::scheduler::SchedulingState;
use blake2::digest::consts::U8;
use blake2::Blake2b;
use blake2::Digest;

/// `RwkvReviewState`: the dataset state stored in `ReviewInput::card_type`.
pub const LEARN_START: i64 = 0;
pub const LEARNING: i64 = 1;
pub const REVIEW: i64 = 2;
pub const RELEARNING: i64 = 3;
pub const FILTERED: i64 = 4;

/// `_RWKV_DEFAULT_TARGET_RETENTION`.
pub const DEFAULT_TARGET_RETENTION: f32 = 0.9;

const SECONDS_PER_DAY: i64 = 86_400;

/// `_valid_probability`.
pub fn valid_probability(value: f32) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

/// `_stable_preset_id`: deck-config ids stay numeric; add-on preset ids hash
/// to blake2b-8 (big-endian) masked to 63 bits, as the desktop persists them.
pub fn stable_preset_id(preset_id: &str) -> i64 {
    if !preset_id.is_empty() && preset_id.bytes().all(|b| b.is_ascii_digit()) {
        if let Ok(id) = preset_id.parse::<i64>() {
            return id;
        }
    }
    let digest = Blake2b::<U8>::digest(preset_id.as_bytes());
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&digest);
    (u64::from_be_bytes(bytes) & ((1u64 << 63) - 1)) as i64
}

/// `_historical_review_day_offset`.
pub fn historical_review_day_offset(review_id_ms: i64, days_elapsed: i64, next_day_at: i64) -> i64 {
    let review_secs = review_id_ms.div_euclid(1000);
    let days_before_today = (next_day_at - 1 - review_secs)
        .max(0)
        .div_euclid(SECONDS_PER_DAY);
    (days_elapsed - days_before_today).max(0)
}

/// The scheduling state's (kind, normal kind), as `_scheduling_state_kinds`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateKind {
    New,
    Learning,
    Review,
    Relearning,
    Filtered,
    Unknown,
}

pub fn state_kind(state: Option<&SchedulingState>) -> StateKind {
    use scheduling_state::normal::Kind as N;
    use scheduling_state::Kind;
    match state.and_then(|s| s.kind.as_ref()) {
        Some(Kind::Filtered(_)) => StateKind::Filtered,
        Some(Kind::Normal(normal)) => match normal.kind {
            Some(N::New(_)) => StateKind::New,
            Some(N::Learning(_)) => StateKind::Learning,
            Some(N::Review(_)) => StateKind::Review,
            Some(N::Relearning(_)) => StateKind::Relearning,
            None => StateKind::Unknown,
        },
        None => StateKind::Unknown,
    }
}

/// `_rwkv_review_state_for_scheduling_state`.
pub fn review_state_for_kind(kind: StateKind, card_type: i64) -> i64 {
    match kind {
        StateKind::Filtered => FILTERED,
        StateKind::New => LEARN_START,
        StateKind::Learning => LEARNING,
        StateKind::Review => REVIEW,
        StateKind::Relearning => RELEARNING,
        // Anki's persistent card types happen to match dataset states 0-3.
        StateKind::Unknown => card_type,
    }
}

/// `_rwkv_review_state_for_scheduling_state` for backend rows, which carry the
/// kinds as strings.
pub fn review_state_for_kind_strings(
    state_kind: &str,
    normal_state_kind: &str,
    card_type: i64,
) -> i64 {
    if state_kind == "filtered" {
        return FILTERED;
    }
    match normal_state_kind {
        "new" => LEARN_START,
        "learning" => LEARNING,
        "review" => REVIEW,
        "relearning" => RELEARNING,
        _ => card_type,
    }
}

/// `_scheduling_state_elapsed`: (elapsed days, elapsed seconds).
pub fn scheduling_state_elapsed(state: Option<&SchedulingState>) -> (Option<i64>, Option<i64>) {
    use scheduling_state::normal::Kind as N;
    use scheduling_state::Kind;
    let Some(Kind::Normal(normal)) = state.and_then(|s| s.kind.as_ref()) else {
        return (None, None);
    };
    match &normal.kind {
        Some(N::Review(review)) => (Some(review.elapsed_days.into()), None),
        Some(N::Learning(learning)) => (None, Some(learning.elapsed_secs.into())),
        Some(N::Relearning(relearning)) => (
            relearning.review.as_ref().map(|r| r.elapsed_days.into()),
            relearning.learning.as_ref().map(|l| l.elapsed_secs.into()),
        ),
        _ => (None, None),
    }
}

/// The card's latest eligible revlog entry: (id, ease, type).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreviousReview {
    pub id: i64,
    pub ease: i64,
    pub kind: i64,
}

/// A same-day state this bridge synthesised for an answer
/// (`_RwkvSyntheticAnswerState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyntheticAnswer {
    pub review_state: i64,
    pub answered_at_millis: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timing {
    pub days_elapsed: i64,
    pub next_day_at: i64,
}

/// `_rwkv_review_state_for_live_context`: a Review answered again on the
/// scheduler day of its previous answer continues as Relearning or Filtered,
/// matching how the training data labels same-day reviews.
pub fn review_state_for_live_context(
    base_review_state: i64,
    previous: Option<PreviousReview>,
    timing: Timing,
    answered_at_millis: i64,
    synthetic: Option<SyntheticAnswer>,
) -> i64 {
    if base_review_state != REVIEW {
        return base_review_state;
    }
    let Some(previous) = previous else {
        return base_review_state;
    };
    if historical_review_day_offset(previous.id, timing.days_elapsed, timing.next_day_at)
        != historical_review_day_offset(answered_at_millis, timing.days_elapsed, timing.next_day_at)
    {
        return base_review_state;
    }
    match previous.kind {
        1 => {
            if previous.ease == 1 {
                RELEARNING
            } else {
                FILTERED
            }
        }
        2 => {
            if matches!(previous.ease, 1 | 2) {
                RELEARNING
            } else {
                FILTERED
            }
        }
        0 => FILTERED,
        3 => match synthetic {
            Some(synthetic)
                if synthetic.review_state == FILTERED
                    && (synthetic.answered_at_millis - previous.id).abs() <= 1_000 =>
            {
                FILTERED
            }
            _ => base_review_state,
        },
        _ => base_review_state,
    }
}

/// `_rwkv_raw_review_kind`: the revlog type the answer is recorded as.
pub fn raw_review_kind(review_state: i64) -> Option<u32> {
    match review_state {
        LEARN_START | LEARNING => Some(0),
        REVIEW => Some(1),
        RELEARNING => Some(2),
        FILTERED => Some(3),
        _ => None,
    }
}

/// `_stats_graph_elapsed_days_for_review_time` and
/// `_elapsed_seconds_since_review_time`.
pub fn elapsed_since_review_time(
    last_review_secs: Option<i64>,
    next_day_at: i64,
    now_secs: i64,
) -> (Option<i64>, Option<i64>) {
    match last_review_secs {
        Some(last) => (
            Some((next_day_at - last).max(0).div_euclid(SECONDS_PER_DAY)),
            Some((now_secs - last).max(0)),
        ),
        None => (None, None),
    }
}

/// `_rwkv_answer_elapsed`: (day offset, elapsed days, elapsed seconds) at the
/// moment of answering, measured from the card's previous eligible answer.
pub fn answer_elapsed(
    timing: Timing,
    answered_at_millis: i64,
    review_state: i64,
    previous: Option<PreviousReview>,
) -> (i64, i64, i64) {
    let day_offset =
        historical_review_day_offset(answered_at_millis, timing.days_elapsed, timing.next_day_at);
    match previous.filter(|_| review_state != LEARN_START) {
        Some(previous) => {
            let elapsed_seconds = (answered_at_millis - previous.id).div_euclid(1000).max(0);
            let elapsed_days = (day_offset
                - historical_review_day_offset(
                    previous.id,
                    timing.days_elapsed,
                    timing.next_day_at,
                ))
            .max(0);
            (day_offset, elapsed_days, elapsed_seconds)
        }
        None => (day_offset, -1, -1),
    }
}

/// `_rwkv_review_input_from_backend_proto_row`: a queue-scoring query.
pub fn query_input_from_row(row: &Row) -> ReviewInput {
    let target = if valid_probability(row.target_retention) {
        row.target_retention
    } else {
        DEFAULT_TARGET_RETENTION
    };
    ReviewInput {
        card_id: row.card_id,
        note_id: Some(row.note_id),
        deck_id: Some(row.deck_id),
        preset_id: (!row.preset_id.is_empty()).then(|| stable_preset_id(&row.preset_id)),
        is_query: true,
        ease: None,
        duration_millis: None,
        card_type: Some(review_state_for_kind_strings(
            &row.current_state_kind,
            &row.current_normal_state_kind,
            row.card_type.into(),
        )),
        day_offset: Some(row.day_offset.into()),
        current_elapsed_days: row.current_elapsed_days.map(Into::into),
        current_elapsed_seconds: row.current_elapsed_seconds.map(Into::into),
        target_retentions: [Some(target); 4],
        enforce_grade_order: row.enforce_grade_order.unwrap_or(true),
    }
}

/// `_rwkv_review_input_target_retention`: the Good target, if valid.
pub fn input_target_retention(input: &ReviewInput) -> Option<f32> {
    input.target_retentions[2].filter(|t| valid_probability(*t))
}

/// `_session_intervening_reviews_by_card_id` merged with
/// `_revlog_intervening_reviews_by_card_id`, as `_queue_intervening_reviews_by_card_id`.
/// `session_answered_ids` is oldest first; `recent_revlog_card_ids` newest first.
pub fn intervening_reviews(
    min_intervening_reviews: u32,
    session_answered_ids: &[i64],
    recent_revlog_card_ids: &[i64],
) -> std::collections::HashMap<i64, u32> {
    let mut out = std::collections::HashMap::new();
    if min_intervening_reviews == 0 {
        return out;
    }
    let max_items = min_intervening_reviews as usize; // (min - 1) + 1
    let answered = &session_answered_ids[session_answered_ids.len().saturating_sub(max_items)..];
    let mut last_index = std::collections::HashMap::new();
    for (index, card_id) in answered.iter().enumerate() {
        last_index.insert(*card_id, index);
    }
    for (card_id, index) in last_index {
        let reviews = (answered.len() - index - 1) as u32;
        if reviews < min_intervening_reviews {
            out.insert(card_id, reviews);
        }
    }
    let mut seen = std::collections::HashSet::new();
    for (index, card_id) in recent_revlog_card_ids.iter().enumerate() {
        if seen.insert(*card_id) {
            out.insert(*card_id, index as u32);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_preset_id_matches_python() {
        // python3 -c "import hashlib; d=hashlib.blake2b(b'overlay-a',digest_size=8).digest(); print(int.from_bytes(d,'big') & ((1<<63)-1))"
        assert_eq!(stable_preset_id("1"), 1);
        assert_eq!(stable_preset_id("1700000000000"), 1_700_000_000_000);
        assert_eq!(stable_preset_id("overlay-a"), EXPECTED_OVERLAY_A);
    }

    // From Python's hashlib, as computed in the comment above.
    const EXPECTED_OVERLAY_A: i64 = 4_636_347_088_547_118_613;

    #[test]
    fn day_offset_matches_python_floor_semantics() {
        let next_day_at = 1_000_000;
        // A review just before rollover belongs to today.
        assert_eq!(
            historical_review_day_offset((next_day_at - 1) * 1000, 10, next_day_at),
            10
        );
        // One day earlier.
        assert_eq!(
            historical_review_day_offset((next_day_at - 1 - 86_400) * 1000, 10, next_day_at),
            9
        );
        // Clamped at zero.
        assert_eq!(historical_review_day_offset(0, 2, next_day_at), 0);
    }

    fn timing() -> Timing {
        Timing {
            days_elapsed: 100,
            next_day_at: 10_000_000,
        }
    }

    fn today_ms(offset_secs: i64) -> i64 {
        (10_000_000 - 3_600 + offset_secs) * 1000
    }

    #[test]
    fn same_day_state_machine() {
        let prev = |kind, ease| {
            Some(PreviousReview {
                id: today_ms(0),
                ease,
                kind,
            })
        };
        let now = today_ms(60);
        // Not a review: unchanged.
        assert_eq!(
            review_state_for_live_context(LEARNING, prev(1, 1), timing(), now, None),
            LEARNING
        );
        // Review after a same-day Review answer.
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(1, 1), timing(), now, None),
            RELEARNING
        );
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(1, 3), timing(), now, None),
            FILTERED
        );
        // After Relearning.
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(2, 2), timing(), now, None),
            RELEARNING
        );
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(2, 4), timing(), now, None),
            FILTERED
        );
        // After Learning.
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(0, 3), timing(), now, None),
            FILTERED
        );
        // After Filtered only when this bridge synthesised it.
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(3, 3), timing(), now, None),
            REVIEW
        );
        let synthetic = SyntheticAnswer {
            review_state: FILTERED,
            answered_at_millis: today_ms(0) + 500,
        };
        assert_eq!(
            review_state_for_live_context(REVIEW, prev(3, 3), timing(), now, Some(synthetic)),
            FILTERED
        );
        // A previous answer on an earlier day leaves Review alone.
        let yesterday = Some(PreviousReview {
            id: today_ms(-86_400),
            ease: 1,
            kind: 1,
        });
        assert_eq!(
            review_state_for_live_context(REVIEW, yesterday, timing(), now, None),
            REVIEW
        );
    }

    #[test]
    fn answer_elapsed_measures_from_previous_answer() {
        let previous = Some(PreviousReview {
            id: today_ms(-86_400),
            ease: 3,
            kind: 1,
        });
        let answered = today_ms(90);
        assert_eq!(
            answer_elapsed(timing(), answered, REVIEW, previous),
            (100, 1, 86_490)
        );
        // Learn starts never carry elapsed time.
        assert_eq!(
            answer_elapsed(timing(), answered, LEARN_START, previous),
            (100, -1, -1)
        );
        assert_eq!(
            answer_elapsed(timing(), answered, REVIEW, None),
            (100, -1, -1)
        );
    }

    #[test]
    fn intervening_reviews_merge_session_and_revlog() {
        // Session (oldest first): 1, 2, 1, 3. Min 3 → last 3 answers: 2, 1, 3.
        let merged = intervening_reviews(3, &[1, 2, 1, 3], &[]);
        assert_eq!(merged.get(&3), Some(&0));
        assert_eq!(merged.get(&1), Some(&1));
        assert_eq!(merged.get(&2), Some(&2));
        // Revlog positions (newest first) override.
        let merged = intervening_reviews(3, &[1, 2], &[2, 2, 9]);
        assert_eq!(merged.get(&2), Some(&0));
        assert_eq!(merged.get(&9), Some(&2));
        assert_eq!(merged.get(&1), Some(&1));
        assert!(intervening_reviews(0, &[1], &[1]).is_empty());
    }

    #[test]
    fn row_query_uses_row_target_and_kinds() {
        let row = Row {
            card_id: 5,
            note_id: 6,
            deck_id: 7,
            preset_id: "8".into(),
            card_type: 2,
            day_offset: 42,
            current_state_kind: "normal".into(),
            current_normal_state_kind: "review".into(),
            current_elapsed_days: Some(3),
            current_elapsed_seconds: Some(260_000),
            target_retention: 0.85,
            enforce_grade_order: None,
            ..Default::default()
        };
        let input = query_input_from_row(&row);
        assert_eq!(input.preset_id, Some(8));
        assert_eq!(input.card_type, Some(REVIEW));
        assert_eq!(input.target_retentions, [Some(0.85); 4]);
        assert!(input.enforce_grade_order);
        assert!(input.is_query);
    }
}
