//! The stats screen's FSRS "Memorised" series: `getMemorisedDays` from the
//! Search Stats Extended add-on (src/ts/MemorisedBar.ts), which draws the
//! desktop's memorised chart, and the `burden` series of its
//! `calculateRevlogStats` (src/ts/revlogGraphs.ts) for "Cards/Load".
//!
//! The add-on replays the search's review log with ts-fsrs; this replays the
//! same reviews, in the same way, with the `fsrs` crate the fork's rslib
//! schedules with, so FSRS-7 presets use the fork's dual-trace model.
//!
//! Days are the collection's day numbers (`days_elapsed` is today), where
//! the add-on uses local Unix days; the two only differ by a constant.

use std::collections::BTreeMap;
use std::collections::HashMap;

use anki::services::ConfigService;
use anki::services::SchedulerService;
use anki::services::SearchService;
use fsrs::MemoryState;
use fsrs::FSRS;
use serde::Deserialize;
use serde::Serialize;

use super::*;

/// `STABILITY_WEIGHT_FACTOR`.
const STABILITY_WEIGHT_FACTOR: f64 = 8.0 / 365.0;
const SECONDS_PER_DAY: i64 = 86_400;

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct FsrsMemorisedRequest {
    pub search: String,
    /// The stats period in days (`searchLimit`); 0 is the whole history.
    pub days: u32,
}

/// `memorised_stats` fields the chart reads, as dense series from
/// `first_day`, plus `revlogStats.burden` from `burden_first_day`.
#[derive(Serialize, Debug, Default, PartialEq)]
pub struct FsrsMemorisedResponse {
    pub today: i64,
    /// The scheduler's rollover hour, to turn day numbers into dates.
    pub rollover: u32,
    pub first_day: i64,
    pub retrievability: Vec<f64>,
    pub note_retrievability: Vec<f64>,
    pub card_count: Vec<u32>,
    pub stable_retrievability: Vec<f64>,
    pub burden_first_day: i64,
    pub burden: Vec<f64>,
}

/// The `revlogs` endpoint's columns.
#[derive(Deserialize, Clone, Copy, Debug)]
pub struct Revlog {
    pub id: i64,
    pub cid: i64,
    pub ease: i64,
    pub ivl: i64,
    pub factor: i64,
    pub kind: i64,
}

/// The `cardData` columns these series read.
#[derive(Deserialize, Clone, Copy, Debug, Default)]
pub struct CardData {
    pub nid: i64,
    pub ctype: i64,
    pub queue: i64,
    pub ivl: i64,
}

/// Collection day numbers of review timestamps (`dayFromMs`).
#[derive(Clone, Copy)]
pub struct Days {
    pub today: i64,
    pub next_day_at: i64,
}

impl Days {
    pub fn of(&self, millis: i64) -> i64 {
        self.today - (self.next_day_at - 1 - millis.div_euclid(1000)).div_euclid(SECONDS_PER_DAY)
    }
}

/// Day-indexed sums, grown on demand like the add-on's sparse arrays.
#[derive(Default)]
struct DaySums<T> {
    first: i64,
    values: Vec<T>,
}

impl<T: Copy + Default + std::ops::AddAssign> DaySums<T> {
    fn add(&mut self, day: i64, value: T) {
        if self.values.is_empty() {
            self.first = day;
        }
        if day < self.first {
            let grow = (self.first - day) as usize;
            self.values
                .splice(0..0, std::iter::repeat_n(T::default(), grow));
            self.first = day;
        }
        let index = (day - self.first) as usize;
        if index >= self.values.len() {
            self.values.resize(index + 1, T::default());
        }
        self.values[index] += value;
    }

    /// The series from `first` to `last`, zero where nothing was added.
    fn dense(&self, first: i64, last: i64) -> Vec<T> {
        (first..=last)
            .map(|day| {
                usize::try_from(day - self.first)
                    .ok()
                    .and_then(|index| self.values.get(index).copied())
                    .unwrap_or_default()
            })
            .collect()
    }
}

/// The replay state `getMemorisedDays` keeps per card.
struct ReplayCard {
    last_review: Option<i64>,
    /// `card.stability` / `card.difficulty`: none for a new or forgotten card.
    state: Option<MemoryState>,
    /// `last_stability`: the curve the card follows until its next review,
    /// which a forget doesn't reset.
    last: Option<MemoryState>,
}

#[derive(Debug, Default, PartialEq)]
pub struct MemorisedDays {
    pub first_day: i64,
    pub retrievability: Vec<f64>,
    pub note_retrievability: Vec<f64>,
    pub card_count: Vec<u32>,
    pub stable_retrievability: Vec<f64>,
}

/// `getMemorisedDays`' memorised series. `fsrs_for_card` is the card's
/// resolved preset model (`card_fsrs_source`); cards without one are
/// skipped.
pub fn memorised_days<'a>(
    revlogs: &[Revlog],
    cards: &HashMap<i64, CardData>,
    fsrs_for_card: impl Fn(i64) -> Option<&'a FSRS>,
    days: Days,
) -> std::result::Result<MemorisedDays, fsrs::FSRSError> {
    let mut note_counts: HashMap<i64, u32> = HashMap::new();
    for card in cards.values() {
        *note_counts.entry(card.nid).or_default() += 1;
    }
    let mut sums = Sums::default();
    let mut replay: BTreeMap<i64, ReplayCard> = BTreeMap::new();

    for revlog in revlogs {
        let Some(fsrs) = fsrs_for_card(revlog.cid) else {
            continue;
        };
        let grade = revlog.ease;
        let new_card = !replay.contains_key(&revlog.cid);
        let revlog_day = days.of(revlog.id);
        let card = replay.entry(revlog.cid).or_insert(ReplayCard {
            last_review: None,
            state: None,
            last: None,
        });

        // on forget
        if revlog.factor == 0 && revlog.kind == 4 && !new_card {
            card.state = None;
        }
        // set due date or reschedule; cram
        if grade == 0 || (revlog.kind == 3 && revlog.factor == 0) {
            if new_card && card.last_review.is_none() {
                // `fsrsCards` only keeps cards a review touched.
                replay.remove(&revlog.cid);
            }
            continue;
        }
        if let (Some(last), Some(last_review)) = (card.last, card.last_review) {
            let nid = cards.get(&revlog.cid).map(|c| c.nid);
            sums.curve(
                fsrs,
                last,
                days.of(last_review)..revlog_day,
                card.state,
                nid.and_then(|nid| note_counts.get(&nid).copied()),
            );
        }

        let (memory_state, elapsed) = match card.last_review {
            Some(last_review) => (card.state, (revlog_day - days.of(last_review)).max(0)),
            None => (None, 0),
        };
        let next = fsrs.next_states(memory_state, 0.9, elapsed as u32)?;
        let next = match grade {
            1 => next.again,
            2 => next.hard,
            3 => next.good,
            _ => next.easy,
        }
        .memory;
        card.last_review = Some(revlog.id);
        card.state = Some(next);
        card.last = Some(next);
    }

    for (cid, card) in &replay {
        let (Some(fsrs), Some(last), Some(last_review)) =
            (fsrs_for_card(*cid), card.last, card.last_review)
        else {
            continue;
        };
        let nid = cards.get(cid).map(|c| c.nid);
        sums.curve(
            fsrs,
            last,
            days.of(last_review)..days.today + 1,
            card.state,
            nid.and_then(|nid| note_counts.get(&nid).copied()),
        );
    }

    if sums.retrievability.values.is_empty() {
        return Ok(MemorisedDays {
            first_day: days.today + 1,
            ..Default::default()
        });
    }
    let first = sums.retrievability.first;
    let last = first + sums.retrievability.values.len() as i64 - 1;
    Ok(MemorisedDays {
        first_day: first,
        retrievability: sums.retrievability.dense(first, last),
        note_retrievability: sums.note_retrievability.dense(first, last),
        card_count: sums.card_count.dense(first, last),
        stable_retrievability: sums.stable_retrievability.dense(first, last),
    })
}

#[derive(Default)]
struct Sums {
    retrievability: DaySums<f64>,
    note_retrievability: DaySums<f64>,
    card_count: DaySums<u32>,
    stable_retrievability: DaySums<f64>,
}

impl Sums {
    /// `forgetting_curve`: adds a card's retrievability on each day.
    fn curve(
        &mut self,
        fsrs: &FSRS,
        last: MemoryState,
        days: std::ops::Range<i64>,
        current: Option<MemoryState>,
        note_count: Option<u32>,
    ) {
        let from = days.start;
        for day in days {
            let retrievability = f64::from(fsrs.current_retrievability(last, (day - from) as f32));
            self.retrievability.add(day, retrievability);
            self.card_count.add(day, 1);
            // Ignore deleted notes for note count
            if let Some(count) = note_count.filter(|count| *count > 0) {
                self.note_retrievability
                    .add(day, retrievability / f64::from(count));
            }
            // If the cards not been forgotten
            if let Some(current) = current {
                self.stable_retrievability.add(
                    day,
                    retrievability * stability_weight(f64::from(current.stability)),
                );
            }
        }
    }
}

/// `stability_weight`.
fn stability_weight(stability: f64) -> f64 {
    1.0 - (-STABILITY_WEIGHT_FACTOR * stability).exp()
}

/// `calculateRevlogStats`' `intervals` replay and `burden`: per day, the
/// cards in each interval, each weighing 1/interval (1 when learning);
/// suspended cards don't count. Returns the first day and the series up to
/// the last day any card occupies.
pub fn burden(revlogs: &[Revlog], cards: &HashMap<i64, CardData>, days: Days) -> (i64, Vec<f64>) {
    let mut intervals: BTreeMap<i64, BTreeMap<i64, u32>> = BTreeMap::new();
    let mut next_reviews: HashMap<i64, Revlog> = HashMap::new();
    let end = days.today;
    for revlog in revlogs.iter().rev() {
        let day = days.of(revlog.id);
        let Some(card) = cards.get(&revlog.cid) else {
            continue;
        };
        let next_review = next_reviews.get(&revlog.cid).copied();
        // If the card is still learning, use the card data
        let mut ivl = if next_review.is_some() {
            revlog.ivl
        } else if card.ctype != 3 && card.ctype != 1 {
            card.ivl
        } else {
            0
        };
        // Ignore "forgets"
        if (revlog.factor == 0 && revlog.kind == 4) || (next_review.is_none() && card.queue == 0) {
            next_reviews.insert(revlog.cid, *revlog);
            continue;
        }
        ivl = ivl.max(0);
        // If the card is suspended
        if next_review.is_none() && card.queue == -1 {
            ivl = -1;
        }
        let to = next_review.map_or(end + 1, |next| days.of(next.id));
        for interval_day in day..to {
            *intervals
                .entry(interval_day)
                .or_default()
                .entry(ivl)
                .or_default() += 1;
        }
        next_reviews.insert(revlog.cid, *revlog);
    }

    let (Some(first), Some(last)) = (
        intervals.keys().next().copied(),
        intervals.keys().next_back().copied(),
    ) else {
        return (days.today + 1, vec![]);
    };
    let burden = (first..=last)
        .map(|day| {
            intervals.get(&day).map_or(0.0, |counts| {
                counts
                    .iter()
                    // -1 (suspended) and -2 (learn) aren't array elements.
                    .filter(|(ivl, _)| **ivl >= 0)
                    .map(|(ivl, count)| f64::from(*count) / (*ivl).max(1) as f64)
                    .sum()
            })
        })
        .collect();
    (first, burden)
}

/// `_revlog_lower_limit`: reviews after this id are in the stats period.
fn revlog_lower_limit(days: u32, rollover: u32, now_secs: i64) -> f64 {
    if days == 0 {
        return 0.0;
    }
    let today = (now_secs - i64::from(rollover) * 3600) as f64 / SECONDS_PER_DAY as f64;
    (today - f64::from(days)) * SECONDS_PER_DAY as f64 * 1000.0
}

fn id_list(ids: &[i64]) -> String {
    ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
}

/// The search's cards, as the add-on's `cardSearch` endpoint finds them.
pub(super) fn search_card_ids(backend: &Backend, search: &str) -> Result<Vec<i64>> {
    Ok(backend
        .with_col(|col| {
            SearchService::search_cards(
                col,
                anki_proto::search::SearchRequest {
                    search: search.into(),
                    order: None,
                },
            )
        })?
        .ids)
}

/// The aux method: `memorised_stats` (`revlogs`, `cardData`, `fsrsPresetData`
/// and `getMemorisedDays`) plus `revlogStats.burden`, for one search.
pub(super) fn fsrs_memorised(
    backend: &Backend,
    req: FsrsMemorisedRequest,
) -> Result<FsrsMemorisedResponse> {
    let card_ids = search_card_ids(backend, &req.search)?;
    let (timing, rollover) = backend.with_col(|col| {
        let timing = SchedulerService::sched_timing_today(col)?;
        let rollover = ConfigService::get_preferences(col)?
            .scheduling
            .map_or(0, |s| s.rollover);
        Ok((timing, rollover))
    })?;
    let days = Days {
        today: i64::from(timing.days_elapsed),
        next_day_at: timing.next_day_at,
    };
    let empty = FsrsMemorisedResponse {
        today: days.today,
        rollover,
        first_day: days.today + 1,
        burden_first_day: days.today + 1,
        ..Default::default()
    };
    if card_ids.is_empty() {
        return Ok(empty);
    }
    let ids = id_list(&card_ids);
    let cards: HashMap<i64, CardData> = db_query::<(i64, i64, i64, i64, i64)>(
        backend,
        &format!("select id, nid, type, queue, ivl from cards where id in ({ids})"),
        vec![],
    )?
    .into_iter()
    .map(|(id, nid, ctype, queue, ivl)| {
        (
            id,
            CardData {
                nid,
                ctype,
                queue,
                ivl,
            },
        )
    })
    .collect();
    let lower_limit = revlog_lower_limit(req.days, rollover, now_millis() / 1000);
    let revlogs: Vec<Revlog> = db_query::<(i64, i64, i64, i64, i64, i64)>(
        backend,
        &format!(
            "select id, cid, ease, ivl, factor, type from revlog \
             where cid in ({ids}) and id > ? order by id"
        ),
        vec![serde_json::json!(lower_limit)],
    )?
    .into_iter()
    .map(|(id, cid, ease, ivl, factor, kind)| Revlog {
        id,
        cid,
        ease,
        ivl,
        factor,
        kind,
    })
    .collect();

    // `fsrsPresetData`: each reviewed card's resolved preset, one model per
    // distinct parameter set (`getFsrs`).
    let mut reviewed: Vec<i64> = revlogs.iter().map(|r| r.cid).collect();
    reviewed.sort_unstable();
    reviewed.dedup();
    let presets = backend.with_col(|col| {
        reviewed
            .iter()
            .map(|cid| {
                SchedulerService::get_fsrs_preset_for_card(
                    col,
                    anki_proto::cards::CardId { cid: *cid },
                )
                .map(|preset| (*cid, preset))
            })
            .collect::<anki::error::Result<Vec<_>>>()
    })?;
    let mut models: Vec<(Vec<u32>, FSRS)> = vec![];
    let mut model_for_card: HashMap<i64, usize> = HashMap::new();
    for (cid, preset) in presets {
        let signature: Vec<u32> = preset.params.iter().map(|w| w.to_bits()).collect();
        let index = match models.iter().position(|(s, _)| *s == signature) {
            Some(index) => index,
            None => {
                let model = FSRS::new(&preset.params).map_err(|_| {
                    Error(format!(
                        "Resolved FSRS preset {} has unsupported params length {}",
                        preset.id,
                        preset.params.len()
                    ))
                })?;
                models.push((signature, model));
                models.len() - 1
            }
        };
        model_for_card.insert(cid, index);
    }

    let memorised = memorised_days(
        &revlogs,
        &cards,
        |cid| model_for_card.get(&cid).map(|index| &models[*index].1),
        days,
    )
    .map_err(|err| Error(format!("FSRS replay failed: {err:?}")))?;
    let (burden_first_day, burden) = burden(&revlogs, &cards, days);
    Ok(FsrsMemorisedResponse {
        first_day: memorised.first_day,
        retrievability: memorised.retrievability,
        note_retrievability: memorised.note_retrievability,
        card_count: memorised.card_count,
        stable_retrievability: memorised.stable_retrievability,
        burden_first_day,
        burden,
        ..empty
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod test {
    use super::*;

    const DAY_MS: i64 = 86_400_000;

    /// The add-on's FSRS-5 test weights (test/memorised.test.ts).
    const WEIGHTS: [f32; 19] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ];
    const WEIGHTS7: [f32; 34] = [
        0.1104, 2.2395, 3.9221, 11.7841, 6.1686, 0.6457, 3.6807, 1.9795, 0.0, 1.3826, 0.7024,
        0.5999, 0.8146, 0.6398, 1.0, 1.3207, 0.6707, 3.8668, 0.4416, 0.0934, 1.8631, 0.6162,
        1.0869, 0.1567, 0.0801, 0.2421, 0.9464, 0.1433, 0.7145, 0.0, 0.5667, 0.3734, 0.5333,
        0.3048,
    ];

    /// `RevlogBuilder`: one card's reviews; a positive interval waits that
    /// many days before the next review, a negative one that many ms.
    struct Builder {
        cid: i64,
        id: i64,
        ivl: i64,
        kind: i64,
        revlogs: Vec<Revlog>,
    }

    impl Builder {
        fn new(cid: i64) -> Self {
            Self {
                cid,
                id: 1,
                ivl: 0,
                kind: 0,
                revlogs: vec![],
            }
        }

        fn review(&mut self, ivl: i64, ease: i64) -> &mut Self {
            self.id += if self.ivl > 0 {
                self.ivl * DAY_MS
            } else {
                -self.ivl
            };
            self.kind = if ivl > 0 {
                1
            } else if self.kind == 0 || self.kind == 4 {
                0
            } else if ivl == 0 {
                4
            } else {
                2
            };
            self.ivl = ivl;
            self.revlogs.push(Revlog {
                id: self.id,
                cid: self.cid,
                ease,
                ivl,
                factor: if ivl > 0 { 200 } else { 0 },
                kind: self.kind,
            });
            self
        }

        fn last_review_day(&self) -> i64 {
            self.id.div_euclid(DAY_MS)
        }
    }

    /// UTC days from the epoch, as the add-on's tests see them.
    fn days(today: i64) -> Days {
        Days {
            today,
            next_day_at: (today + 1) * SECONDS_PER_DAY,
        }
    }

    fn cards(cids: &[i64]) -> HashMap<i64, CardData> {
        cids.iter()
            .map(|cid| {
                (
                    *cid,
                    CardData {
                        nid: *cid,
                        ctype: 2,
                        queue: 2,
                        ivl: 0,
                    },
                )
            })
            .collect()
    }

    fn run(builder: &Builder, weights: &[f32], today: i64) -> MemorisedDays {
        let fsrs = FSRS::new(weights).unwrap();
        memorised_days(
            &builder.revlogs,
            &cards(&[builder.cid]),
            |_| Some(&fsrs),
            days(today),
        )
        .unwrap()
    }

    fn at(series: &MemorisedDays, day: i64) -> f64 {
        series.retrievability[(day - series.first_day) as usize]
    }

    #[test]
    fn day_timings() {
        let mut card = Builder::new(1);
        card.review(-3000, 3)
            .review(-3000, 3)
            .review(5, 3)
            .review(10, 3)
            .review(20, 3);
        let memorised = run(&card, &WEIGHTS, 40);
        assert_eq!(memorised.first_day, 0);
        assert_eq!(at(&memorised, 0), 1.0);
        assert_eq!(at(&memorised, 5), 1.0);
        assert_eq!(at(&memorised, 15), 1.0);
        assert_ne!(at(&memorised, 16), 0.0);
        assert_eq!(memorised.retrievability.len(), 41);
        assert!(memorised.card_count.iter().all(|count| *count == 1));
        // One card per note: notes equal cards.
        assert_eq!(memorised.note_retrievability, memorised.retrievability);
    }

    /// fsrs-rs's inference test: S = 31.722975 after these reviews.
    #[test]
    fn stability() {
        let fsrs = FSRS::new(&WEIGHTS).unwrap();
        let mut card = Builder::new(1);
        card.review(1, 1).review(3, 3).review(21, 3).review(80, 3);
        let last = card.last_review_day();
        let memorised = run(&card, &WEIGHTS, last + 20);
        let expected = f64::from(fsrs.current_retrievability(
            MemoryState {
                stability: 31.722975,
                difficulty: 5.0,
                stability_fast: 31.722975,
            },
            10.0,
        ));
        assert!((at(&memorised, last + 10) - expected).abs() < 0.005);
    }

    #[test]
    fn stability_on_forget() {
        let fsrs = FSRS::new(&WEIGHTS).unwrap();
        let mut card = Builder::new(1);
        card.review(1, 1)
            .review(3, 3)
            .review(0, 0)
            .review(1, 1)
            .review(3, 3)
            .review(21, 3)
            .review(80, 3);
        let last = card.last_review_day();
        let memorised = run(&card, &WEIGHTS, last + 20);
        let expected = f64::from(fsrs.current_retrievability(
            MemoryState {
                stability: 31.722975,
                difficulty: 5.0,
                stability_fast: 31.722975,
            },
            10.0,
        ));
        assert!((at(&memorised, last + 10) - expected).abs() < 0.005);
    }

    #[test]
    fn fsrs7_params_are_accepted() {
        let mut card = Builder::new(1);
        card.review(-3000, 3).review(-3000, 3).review(5, 3);
        let memorised = run(&card, &WEIGHTS7, 10);
        assert!(!memorised.retrievability.is_empty());
        assert!((at(&memorised, 0) - 0.99999).abs() < 5e-6);
    }

    #[test]
    fn forgotten_cards_keep_their_curve_but_leave_the_stable_series() {
        let mut card = Builder::new(1);
        card.review(1, 3).review(3, 3);
        // A reset ("forget") on day 4, with no review after it.
        card.revlogs.push(Revlog {
            id: card.id + 3 * DAY_MS + 1000,
            cid: 1,
            ease: 0,
            ivl: 0,
            factor: 0,
            kind: 4,
        });
        let today = 10;
        let memorised = run(&card, &WEIGHTS, today);
        let index = |day: i64| (day - memorised.first_day) as usize;
        // The curve continues to today...
        assert!(memorised.retrievability[index(today)] > 0.0);
        // ...but a forgotten card has no stability for the weighted series.
        assert_eq!(memorised.stable_retrievability[index(today)], 0.0);
        assert!(memorised.stable_retrievability[index(0)] > 0.0);
    }

    #[test]
    fn notes_split_retrievability_between_sibling_cards() {
        let fsrs = FSRS::new(&WEIGHTS).unwrap();
        let mut a = Builder::new(1);
        a.review(2, 3);
        let mut b = Builder::new(2);
        b.review(2, 3);
        let mut revlogs = a.revlogs.clone();
        revlogs.extend(b.revlogs.iter().map(|r| Revlog { id: r.id + 1, ..*r }));
        revlogs.sort_by_key(|r| r.id);
        let mut cards = cards(&[1, 2, 3]);
        for card in cards.values_mut() {
            card.nid = 7;
        }
        let memorised = memorised_days(&revlogs, &cards, |_| Some(&fsrs), days(5)).unwrap();
        // Three cards of the note are in the search; two were reviewed.
        for (r, n) in memorised
            .retrievability
            .iter()
            .zip(&memorised.note_retrievability)
        {
            assert!((n - r / 3.0).abs() < 1e-12);
        }
        assert!(memorised.card_count.iter().all(|count| *count == 2));
    }

    #[test]
    fn burden_weighs_each_card_by_its_interval() {
        let day = |d: i64| d * DAY_MS + 1000;
        let revlog = |id, cid, ivl, kind| Revlog {
            id,
            cid,
            ease: 3,
            ivl,
            factor: 2500,
            kind,
        };
        let revlogs = vec![
            revlog(day(0), 1, -600, 0),
            revlog(day(1), 1, 4, 1),
            revlog(day(5), 1, 10, 1),
            revlog(day(2), 2, 2, 1),
        ];
        let mut revlogs = revlogs;
        revlogs.sort_by_key(|r| r.id);
        let mut cards = cards(&[1, 2]);
        cards.get_mut(&1).unwrap().ivl = 10;
        // Card 2 is suspended now.
        cards.get_mut(&2).unwrap().queue = -1;
        cards.get_mut(&2).unwrap().ivl = 2;
        let (first, burden) = burden(&revlogs, &cards, days(7));
        assert_eq!(first, 0);
        let expected = [
            1.0,  // day 0: card 1 learning (interval 0 weighs 1)
            0.25, // day 1: card 1 at 4 days
            0.25, // day 2: card 2 suspended since its last review
            0.25, 0.25, // days 3-4
            0.1, 0.1, 0.1, // days 5-7: card 1 at 10 days
        ];
        assert_eq!(burden.len(), expected.len());
        for (got, want) in burden.iter().zip(expected) {
            assert!((got - want).abs() < 1e-12, "{burden:?}");
        }
    }

    #[test]
    fn lower_limit_is_the_period_before_the_rollover_adjusted_now() {
        assert_eq!(revlog_lower_limit(0, 4, 1_000_000), 0.0);
        let limit = revlog_lower_limit(30, 4, 100 * 86_400);
        assert_eq!(
            limit,
            ((100 * 86_400 - 4 * 3600) - 30 * 86_400) as f64 * 1000.0
        );
    }

    #[test]
    fn days_follow_the_scheduler_day_boundary() {
        let days = Days {
            today: 10,
            next_day_at: 1_000_000,
        };
        assert_eq!(days.of((1_000_000 - 1) * 1000), 10);
        assert_eq!(days.of((1_000_000 - 86_400) * 1000), 10);
        assert_eq!(days.of((1_000_000 - 86_401) * 1000), 9);
        assert_eq!(days.of(1_000_000 * 1000), 11);
    }
}
