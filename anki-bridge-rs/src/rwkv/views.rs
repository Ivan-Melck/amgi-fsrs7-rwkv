//! RWKV scores outside the review screen: deck-list counts, stats and browser
//! searches, filtered decks, card info, and the RWKV-Curve reschedule. Ports
//! of the desktop functions named on each method.

use std::collections::HashMap;
use std::collections::HashSet;

use anki::backend::Backend;
use anki::rwkv::ReviewInput;
use anki::rwkv::ReviewPredictionOutput;
use anki::rwkv::ReviewPredictionRequest;
use anki::services::DecksService;
use anki::services::SchedulerService;
use anki::services::SearchService;
use anki_proto::decks::DeckTreeNode;
use anki_proto::scheduler as pb;
use serde::Deserialize;
use serde::Serialize;

use super::inputs::*;
use super::*;

/// `_RWKV_REVIEW_RESCHEDULE_BATCH_SIZE`: full predictions per batch.
const FULL_PREDICTION_CHUNK: usize = 128;
/// `_RWKV_AFTER_REVIEW_HORIZONS`.
const AFTER_REVIEW_HORIZONS: [(&str, i64); 2] =
    [("RWKV : R After Review", 0), ("RWKV : R After 10min", 600)];
const RATING_LABELS: [&str; 4] = ["Again", "Hard", "Good", "Easy"];

// MARK: - Requests and responses

#[derive(Serialize)]
pub(super) struct DeckCountsResponse {
    /// RWKV-Instant scopes whose counts now include RWKV eligibility.
    pub scopes: u32,
    /// The model isn't ready yet; counts are the due-date counts for now.
    pub deferred: bool,
}

#[derive(Deserialize)]
pub(super) struct SearchScoresRequest {
    pub search: String,
    /// Wait for (and if needed, rebuild) the model state first. Graphs don't
    /// wait; searches whose matches depend on RWKV scores do.
    #[serde(default)]
    pub wait: bool,
}

#[derive(Deserialize)]
pub(super) struct FilteredDeckRequest {
    pub deck_id: i64,
}

#[derive(Serialize)]
pub(super) struct SearchScoresResponse {
    /// "ready", "pending" (model still loading), "unavailable" (no RWKV
    /// preset or no model), or "skipped" (nothing in the request needs RWKV).
    pub status: &'static str,
    pub scored: u32,
}

#[derive(Deserialize)]
pub(super) struct CardInfoRequest {
    pub card_id: i64,
}

#[derive(Serialize)]
pub(super) struct CardInfoRow {
    pub label: String,
    pub value: String,
}

#[derive(Serialize)]
pub(super) struct CardInfoResponse {
    pub rows: Vec<CardInfoRow>,
}

#[derive(Deserialize)]
pub(super) struct RescheduleRequest {
    /// The deck (and its subdecks) to reschedule; none for the whole collection.
    #[serde(default)]
    pub deck_id: Option<i64>,
}

#[derive(Deserialize)]
pub(super) struct SearchNoteIdsRequest {
    pub search: String,
}

#[derive(Serialize)]
pub(super) struct SearchNoteIdsResponse {
    pub ids: Vec<i64>,
}

#[derive(Serialize)]
pub(super) struct RebuildFilteredDeckResponse {
    pub count: u32,
}

#[derive(Serialize)]
pub(super) struct RescheduleResponse {
    /// False when the model state couldn't be prepared.
    pub built: bool,
    pub predicted: u32,
    pub updated: u32,
}

/// Which RWKV values a search's matches depend on
/// (`_search_uses_rwkv_*` and `search_uses_rwkv_retrievability`).
#[derive(Default, Clone, Copy, PartialEq, Eq, Debug)]
pub(super) struct SearchNeeds {
    pub instant_r: bool,
    pub curve_r: bool,
    pub instant_due: bool,
    pub curve_due: bool,
}

impl SearchNeeds {
    pub fn of(search: &str) -> Self {
        Self {
            instant_r: find_prop(search, "prop:rwkv:r"),
            curve_r: find_prop(search, "prop:rwkv-curve:r"),
            instant_due: find_flag(search, "is:rwkv:due"),
            curve_due: find_flag(search, "is:rwkv-curve:due"),
        }
    }

    fn any(self) -> bool {
        self.instant_r || self.curve_r || self.instant_due || self.curve_due
    }
}

/// `(?<![A-Za-z0-9_])<prop>(?=[<>=!])`, case-insensitively.
fn find_prop(search: &str, prop: &str) -> bool {
    occurrences(search, prop).any(|(start, end)| {
        let before_ok = search[..start]
            .chars()
            .next_back()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
        let after_ok = search[end..].starts_with(['<', '>', '=', '!']);
        before_ok && after_ok
    })
}

/// `(?<![A-Za-z0-9_:-])-?<flag>(?![A-Za-z0-9_:-])`, case-insensitively.
fn find_flag(search: &str, flag: &str) -> bool {
    let word = |c: char| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '-');
    occurrences(search, flag).any(|(start, end)| {
        let mut prefix = &search[..start];
        if let Some(stripped) = prefix.strip_suffix('-') {
            prefix = stripped;
        }
        let before_ok = prefix.chars().next_back().is_none_or(|c| !word(c));
        let after_ok = search[end..].chars().next().is_none_or(|c| !word(c));
        before_ok && after_ok
    })
}

fn occurrences<'a>(
    haystack: &'a str,
    needle: &'a str,
) -> impl Iterator<Item = (usize, usize)> + 'a {
    let lower = haystack.to_ascii_lowercase();
    let needle = needle.to_ascii_lowercase();
    let mut out = vec![];
    let mut from = 0;
    while let Some(pos) = lower[from..].find(&needle) {
        let start = from + pos;
        out.push((start, start + needle.len()));
        from = start + 1;
    }
    out.into_iter()
}

impl Engine {
    /// Full predictions (`predict_many`) for query inputs, in reschedule-size
    /// batches.
    pub(super) fn predict_full(
        &mut self,
        inputs: &[ReviewInput],
    ) -> Result<Vec<ReviewPredictionOutput>> {
        let model = self.model_mut()?;
        let mut out = Vec::with_capacity(inputs.len());
        for chunk in inputs.chunks(FULL_PREDICTION_CHUNK) {
            let requests = chunk
                .iter()
                .map(|input| ReviewPredictionRequest {
                    state: model.warm_up_state(input),
                    input: input.clone(),
                })
                .collect();
            out.extend(model.predict_many(requests)?);
        }
        Ok(out)
    }

    // MARK: deck-list counts

    /// `deck_browser_rwkv_count_scope_ids` and
    /// `prepare_deck_browser_rwkv_counts_incrementally`: RWKV-Instant decks'
    /// counts include the cards RWKV would admit today.
    pub(super) fn deck_counts(&mut self, backend: &Backend) -> Result<DeckCountsResponse> {
        clear_deck_counts(backend)?;
        if !self.current(backend)? {
            return Ok(DeckCountsResponse {
                scopes: 0,
                deferred: self.model.is_some(),
            });
        }
        let tree = backend.with_col(|col| {
            DecksService::deck_tree(col, anki_proto::decks::DeckTreeRequest { now: 0 })
        })?;
        let mut scopes = vec![];
        let current = backend
            .with_col(DecksService::get_current_deck)
            .ok()
            .map(|deck| deck.id);
        for child in &tree.children {
            collect_instant_scopes(backend, child, &mut scopes)?;
        }
        // The current deck's scope first, as the desktop does.
        scopes.sort_by_key(|(_, node_ids)| !current.is_some_and(|id| node_ids.contains(&id)));

        let count = scopes.len() as u32;
        for (scope, _) in scopes {
            self.score_deck_counts_scope(backend, scope)?;
        }
        Ok(DeckCountsResponse {
            scopes: count,
            deferred: false,
        })
    }

    /// `_set_rwkv_deck_count_scores`: the scope's scores, and each subdeck's
    /// share with its own intervening-review counts.
    fn score_deck_counts_scope(&mut self, backend: &Backend, scope: i64) -> Result<()> {
        let Some(config) = deck_config_for_deck(backend, scope)? else {
            return Ok(());
        };
        let rows = backend.with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_deck_review_queue(
                col,
                pb::RwkvReviewInputRowsForDeckReviewQueueRequest {
                    deck_id: scope,
                    include_disabled_decks: false,
                    include_new_cards: new_gather_uses_retrievability(&config),
                },
            )
        })?;
        let inputs: Vec<ReviewInput> = rows.rows.iter().map(query_input_from_row).collect();
        let scores = self.predict_many(&inputs)?;
        let scored: Vec<(i64, f32, Option<f32>)> = inputs
            .iter()
            .zip(&scores)
            .map(|(input, r)| (input.card_id, *r, input_target_retention(input)))
            .collect();

        let request =
            |deck_id: i64, intervening: &HashMap<i64, u32>, scores: &[(i64, f32, Option<f32>)]| {
                pb::RwkvReviewQueueScoresRequest {
                    deck_id,
                    scores: scores
                        .iter()
                        .map(|(card_id, retrievability, target)| {
                            pb::rwkv_review_queue_scores_request::Score {
                                card_id: *card_id,
                                retrievability: *retrievability,
                                intervening_reviews: intervening.get(card_id).copied(),
                                target_retention: *target,
                            }
                        })
                        .collect(),
                }
            };
        let mut requests = vec![request(
            scope,
            &self.intervening_reviews(backend, scope, &config)?,
            &scored,
        )];

        let child_ids: Vec<i64> = deck_and_children(backend, scope)?
            .into_iter()
            .filter(|id| *id != scope)
            .collect();
        if !child_ids.is_empty() {
            let card_decks: HashMap<i64, i64> = if scored.is_empty() {
                HashMap::new()
            } else {
                let ids: Vec<String> = scored.iter().map(|(id, _, _)| id.to_string()).collect();
                db_query::<(i64, i64)>(
                    backend,
                    &format!("select id, did from cards where id in ({})", ids.join(",")),
                    vec![],
                )?
                .into_iter()
                .collect()
            };
            for child in child_ids {
                let subtree: HashSet<i64> =
                    deck_and_children(backend, child)?.into_iter().collect();
                let child_scores: Vec<_> = scored
                    .iter()
                    .filter(|(card_id, _, _)| {
                        card_decks
                            .get(card_id)
                            .is_some_and(|did| subtree.contains(did))
                    })
                    .copied()
                    .collect();
                let intervening = match deck_config_for_deck(backend, child)? {
                    Some(child_config) => {
                        self.intervening_reviews(backend, child, &child_config)?
                    }
                    None => HashMap::new(),
                };
                requests.push(request(child, &intervening, &child_scores));
            }
        }
        for request in requests {
            backend.with_col(|col| SchedulerService::set_rwkv_deck_count_scores(col, request))?;
        }
        Ok(())
    }

    // MARK: stats, browser and filtered-deck scores

    /// `prepare_stats_retrievability_scores` +
    /// `_rwkv_stats_graph_scores_for_search`: scores keyed by `search`, read
    /// by the graphs and by searches using `prop:rwkv*:r` / `is:rwkv*:due`.
    pub(super) fn search_scores(
        &mut self,
        backend: &Backend,
        req: SearchScoresRequest,
    ) -> Result<SearchScoresResponse> {
        self.search_scores_with(backend, &req.search, SearchNeeds::of(&req.search), req.wait)
    }

    fn search_scores_with(
        &mut self,
        backend: &Backend,
        search: &str,
        needs: SearchNeeds,
        wait: bool,
    ) -> Result<SearchScoresResponse> {
        let active = all_deck_configs(backend)?.iter().any(rwkv_active);
        let ready = active
            && self.model.is_some()
            && (self.current(backend)? || ((wait || needs.any()) && self.ready(backend)));
        if !ready {
            set_stats_scores(backend, search, vec![])?;
            let status = if active && self.model.is_some() {
                "pending"
            } else {
                "unavailable"
            };
            return Ok(SearchScoresResponse { status, scored: 0 });
        }

        let rows = backend.with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_search(
                col,
                pb::RwkvReviewInputRowsForSearchRequest {
                    search: search.to_string(),
                    include_suspended_review: true,
                    include_disabled_decks: false,
                    include_new_cards: false,
                },
            )
        })?;
        let inputs: Vec<ReviewInput> = rows.rows.iter().map(query_input_from_row).collect();

        let mut entries: HashMap<i64, pb::rwkv_stats_graph_scores_request::Score> = HashMap::new();
        if needs.curve_due || needs.curve_r {
            // `_rwkv_curve_enabled_input_build`: full predictions for cards
            // whose deck uses RWKV-Curve.
            let mut curve_by_deck: HashMap<i64, bool> = HashMap::new();
            let mut curve_inputs = vec![];
            let mut curve_rows = vec![];
            for (input, row) in inputs.iter().zip(&rows.rows) {
                let deck_id = input.deck_id.unwrap_or_default();
                let enabled = match curve_by_deck.get(&deck_id) {
                    Some(enabled) => *enabled,
                    None => {
                        let enabled = deck_config_for_deck(backend, deck_id)?
                            .as_ref()
                            .is_some_and(curve_enabled);
                        curve_by_deck.insert(deck_id, enabled);
                        enabled
                    }
                };
                if enabled {
                    curve_inputs.push(input.clone());
                    curve_rows.push(row);
                }
            }
            let predictions = self.predict_full(&curve_inputs)?;
            for ((input, row), prediction) in curve_inputs.iter().zip(curve_rows).zip(predictions) {
                if !valid_probability(prediction.retrievability) {
                    continue;
                }
                let curve_due = row.card_type == 2
                    && row.card_queue == 2
                    && matches!(
                        (input.current_elapsed_days, prediction.current_interval),
                        (Some(elapsed), Some(interval)) if elapsed >= i64::from(interval)
                    );
                entries.insert(
                    input.card_id,
                    pb::rwkv_stats_graph_scores_request::Score {
                        card_id: input.card_id,
                        retrievability: prediction.retrievability,
                        curve_due: curve_due.then_some(true),
                        curve_retrievability: prediction
                            .curve_retrievability
                            .filter(|r| valid_probability(*r)),
                        ..Default::default()
                    },
                );
            }
        }

        let remaining: Vec<ReviewInput> = inputs
            .iter()
            .filter(|i| !entries.contains_key(&i.card_id))
            .cloned()
            .collect();
        for (input, retrievability) in remaining.iter().zip(self.predict_many(&remaining)?) {
            entries.insert(
                input.card_id,
                pb::rwkv_stats_graph_scores_request::Score {
                    card_id: input.card_id,
                    retrievability,
                    ..Default::default()
                },
            );
        }

        if needs.instant_due || needs.curve_due {
            for input in &inputs {
                if let (Some(entry), Some(target)) = (
                    entries.get_mut(&input.card_id),
                    input_target_retention(input),
                ) {
                    entry.target_retention = Some(target);
                }
            }
        }
        if needs.instant_due {
            // `_rwkv_filtered_deck_intervening_reviews_by_card_id`.
            let mut cards_by_deck: HashMap<i64, HashSet<i64>> = HashMap::new();
            for input in &inputs {
                if let Some(deck_id) = input.deck_id {
                    cards_by_deck
                        .entry(deck_id)
                        .or_default()
                        .insert(input.card_id);
                }
            }
            for (deck_id, card_ids) in cards_by_deck {
                let Some(config) = deck_config_for_deck(backend, deck_id)? else {
                    continue;
                };
                for (card_id, n) in self.intervening_reviews(backend, deck_id, &config)? {
                    if card_ids.contains(&card_id) {
                        if let Some(entry) = entries.get_mut(&card_id) {
                            entry.intervening_reviews = Some(n);
                        }
                    }
                }
            }
        }

        let scored = entries.len() as u32;
        set_stats_scores(backend, search, entries.into_values().collect())?;
        Ok(SearchScoresResponse {
            status: "ready",
            scored,
        })
    }

    /// `prepare_filtered_deck_retrievability_scores`: before building a
    /// filtered deck whose terms order or filter by RWKV.
    pub(super) fn filtered_deck_scores(
        &mut self,
        backend: &Backend,
        req: FilteredDeckRequest,
    ) -> Result<SearchScoresResponse> {
        use anki_proto::decks::deck::filtered::search_term::Order;
        let deck = backend.with_col(|col| {
            DecksService::get_deck(col, anki_proto::decks::DeckId { did: req.deck_id })
        })?;
        let Some(anki_proto::decks::deck::Kind::Filtered(filtered)) = deck.kind else {
            return Ok(SearchScoresResponse {
                status: "skipped",
                scored: 0,
            });
        };
        let terms: Vec<_> = filtered
            .search_terms
            .iter()
            .take(2)
            .filter(|t| t.limit > 0)
            .collect();
        let mut needs = SearchNeeds::default();
        let mut orders_by_r = false;
        for term in &terms {
            let term_needs = SearchNeeds::of(&term.search);
            needs.instant_due |= term_needs.instant_due;
            needs.curve_due |= term_needs.curve_due;
            needs.curve_r |= term_needs.curve_r;
            needs.instant_r |= term_needs.instant_r;
            orders_by_r |= matches!(
                term.order(),
                Order::RetrievabilityAscending | Order::RetrievabilityDescending
            );
        }
        if !(orders_by_r || needs.any()) {
            return Ok(SearchScoresResponse {
                status: "skipped",
                scored: 0,
            });
        }
        use anki_proto::search::search_node;
        let search = backend
            .with_col(|col| {
                SearchService::build_search_string(
                    col,
                    anki_proto::search::SearchNode {
                        filter: Some(search_node::Filter::Group(search_node::Group {
                            nodes: terms
                                .iter()
                                .map(|t| anki_proto::search::SearchNode {
                                    filter: Some(search_node::Filter::ParsableText(
                                        t.search.clone(),
                                    )),
                                })
                                .collect(),
                            joiner: search_node::group::Joiner::Or as i32,
                        })),
                    },
                )
            })?
            .val;
        // `warm_up_if_needed=True`, and the instant-R flag is a search flag
        // there, not a prepared value.
        needs.instant_r = false;
        self.search_scores_with(backend, &search, needs, true)
    }

    /// Note search whose matches depend on RWKV scores
    /// (`prepare_browser_retrievability_scores` + the search): scoring and
    /// searching under the engine lock, so a graph scoring another search
    /// in between can't replace the scores the search reads.
    pub(super) fn search_note_ids(
        &mut self,
        backend: &Backend,
        req: SearchNoteIdsRequest,
    ) -> Result<SearchNoteIdsResponse> {
        let needs = SearchNeeds::of(&req.search);
        if needs.any() {
            self.search_scores_with(backend, &req.search, needs, true)?;
        }
        let found = backend.with_col(|col| {
            SearchService::search_notes(
                col,
                anki_proto::search::SearchRequest {
                    search: req.search.clone(),
                    order: None,
                },
            )
        })?;
        Ok(SearchNoteIdsResponse { ids: found.ids })
    }

    /// `_prepare_filtered_deck_retrievability_scores` + the rebuild, under
    /// the engine lock. Like the desktop, the rebuild fails rather than build
    /// without the RWKV scores its terms need.
    pub(super) fn rebuild_filtered_deck(
        &mut self,
        backend: &Backend,
        req: FilteredDeckRequest,
    ) -> Result<RebuildFilteredDeckResponse> {
        let scores = self.filtered_deck_scores(
            backend,
            FilteredDeckRequest {
                deck_id: req.deck_id,
            },
        )?;
        if scores.status == "pending" {
            return Err(Error(
                "RWKV scores for this filtered deck aren't ready yet; try again shortly.".into(),
            ));
        }
        let changes = backend.with_col(|col| {
            SchedulerService::rebuild_filtered_deck(
                col,
                anki_proto::decks::DeckId { did: req.deck_id },
            )
        })?;
        Ok(RebuildFilteredDeckResponse {
            count: changes.count,
        })
    }

    // MARK: card info

    /// `rwkv_card_info_rows`: rows the desktop appends to Card Info, and the
    /// card-info score the backend's own Card Info retrievability uses.
    pub(super) fn card_info(
        &mut self,
        backend: &Backend,
        req: CardInfoRequest,
    ) -> Result<CardInfoResponse> {
        let clear = |backend: &Backend| -> Result<()> {
            Ok(backend.with_col(|col| {
                SchedulerService::set_rwkv_card_info_score(
                    col,
                    pb::RwkvCardInfoScoreRequest {
                        card_id: req.card_id,
                        ..Default::default()
                    },
                )
            })?)
        };
        let card = get_card(backend, req.card_id)?;
        let config = deck_config_for_deck(backend, current_deck_id(&card))?.filter(rwkv_active);
        let Some(config) = config else {
            clear(backend)?;
            return Ok(CardInfoResponse { rows: vec![] });
        };
        let fallback = if card.memory_state.is_some() {
            "FSRS"
        } else {
            "SM2"
        };
        let curve = curve_enabled(&config);

        let states = backend
            .with_col(|col| {
                SchedulerService::get_scheduling_states(
                    col,
                    anki_proto::cards::CardId { cid: card.id },
                )
            })
            .ok();
        let prediction = match (&states, self.current(backend)?) {
            (Some(states), true) => {
                let context = LiveContext::load(backend, &card, &config, &self.synthetic)?;
                let input = context.query_input(&card, &config, states);
                let prediction = self.predict_full(std::slice::from_ref(&input))?.pop();
                prediction.map(|p| (input, p))
            }
            _ => None,
        };

        let mut rows = vec![];
        let row = |label: &str, value: String| CardInfoRow {
            label: label.to_string(),
            value,
        };
        let Some((input, prediction)) =
            prediction.filter(|(_, p)| valid_probability(p.retrievability))
        else {
            clear(backend)?;
            rows.push(row("RWKV computed R", "Unavailable".into()));
            rows.push(row(
                "Retrievability source",
                format!("{fallback} (RWKV unavailable)"),
            ));
            if curve {
                rows.push(row("RWKV Curve Next S90", format_next_s90(&[None; 4])));
                rows.push(row(
                    "FSRS Next S90",
                    format_next_s90(&fsrs_next_s90(states.as_ref())),
                ));
            }
            for (label, _) in AFTER_REVIEW_HORIZONS {
                rows.push(row(label, unavailable_after_review()));
            }
            return Ok(CardInfoResponse { rows });
        };

        backend.with_col(|col| {
            SchedulerService::set_rwkv_card_info_score(
                col,
                pb::RwkvCardInfoScoreRequest {
                    card_id: card.id,
                    retrievability: Some(prediction.retrievability),
                    curve_retrievability: prediction.curve_retrievability,
                },
            )
        })?;

        rows.push(row(
            "RWKV computed R",
            format_percent(Some(prediction.retrievability)),
        ));
        let probabilities = rescale_button_probabilities(
            prediction.button_probabilities,
            prediction.retrievability,
        );
        rows.push(row(
            "RWKV : Answer Button Probability",
            RATING_LABELS
                .iter()
                .zip(probabilities)
                .map(|(label, p)| format!("{label}:{}", format_percent(Some(p))))
                .collect::<Vec<_>>()
                .join(" "),
        ));
        rows.push(row("Retrievability source", "RWKV".into()));
        if curve {
            rows.push(row(
                "RWKV Curve Next S90",
                format_next_s90(&prediction.s90s),
            ));
            rows.push(row(
                "FSRS Next S90",
                format_next_s90(&fsrs_next_s90(states.as_ref())),
            ));
        }
        rows.extend(
            self.after_review_rows(&input)?
                .into_iter()
                .map(|(label, value)| row(label, value)),
        );
        Ok(CardInfoResponse { rows })
    }

    /// `rwkv_card_info_after_review_rows`: R right after each possible
    /// answer, and 10 minutes later.
    fn after_review_rows(&mut self, query: &ReviewInput) -> Result<Vec<(&'static str, String)>> {
        let answers: Vec<ReviewInput> = (1..=4)
            .map(|ease| ReviewInput {
                is_query: false,
                ease: Some(ease),
                duration_millis: None,
                ..query.clone()
            })
            .collect();
        let horizons: Vec<ReviewInput> = AFTER_REVIEW_HORIZONS
            .iter()
            .map(|(_, seconds)| ReviewInput {
                current_elapsed_days: Some(0),
                current_elapsed_seconds: Some(*seconds),
                ..query.clone()
            })
            .collect();
        let batches = self
            .model_mut()?
            .predict_retrievability_many_after_reviews_from_warm_up(answers, horizons)
            .ok()
            .filter(|b| b.len() == 4);
        Ok(AFTER_REVIEW_HORIZONS
            .iter()
            .enumerate()
            .map(|(horizon, (label, _))| {
                let value = match &batches {
                    Some(batches) => RATING_LABELS
                        .iter()
                        .zip(batches)
                        .map(|(rating, scores)| {
                            format!("{rating}:{}", format_percent(scores.get(horizon).copied()))
                        })
                        .collect::<Vec<_>>()
                        .join(" "),
                    None => unavailable_after_review(),
                };
                (*label, value)
            })
            .collect())
    }

    // MARK: Curve reschedule

    /// `reschedule_rwkv_review_cards`: write RWKV-Curve's current interval
    /// and S90 to review cards in RWKV-Curve decks.
    pub(super) fn reschedule(
        &mut self,
        backend: &Backend,
        req: RescheduleRequest,
    ) -> Result<RescheduleResponse> {
        if self.model.is_none() || self.ensure_ready(backend).is_err() {
            return Ok(RescheduleResponse {
                built: false,
                predicted: 0,
                updated: 0,
            });
        }
        let rows = match req.deck_id {
            Some(deck_id) => backend.with_col(|col| {
                SchedulerService::rwkv_review_input_rows_for_deck_review_queue(
                    col,
                    pb::RwkvReviewInputRowsForDeckReviewQueueRequest {
                        deck_id,
                        include_disabled_decks: false,
                        include_new_cards: false,
                    },
                )
            })?,
            None => {
                let card_ids: Vec<i64> = db_query::<(i64,)>(
                    backend,
                    "select id from cards where type = 2 and queue = 2",
                    vec![],
                )?
                .into_iter()
                .map(|(id,)| id)
                .collect();
                backend.with_col(|col| {
                    SchedulerService::rwkv_review_input_rows_for_cards(
                        col,
                        pb::RwkvReviewInputRowsForCardsRequest {
                            card_ids,
                            ..Default::default()
                        },
                    )
                })?
            }
        };
        let mut curve_by_deck: HashMap<i64, bool> = HashMap::new();
        let mut inputs = vec![];
        for input in rows.rows.iter().map(query_input_from_row) {
            let deck_id = input.deck_id.unwrap_or_default();
            let enabled = match curve_by_deck.get(&deck_id) {
                Some(enabled) => *enabled,
                None => {
                    let enabled = deck_config_for_deck(backend, deck_id)?
                        .as_ref()
                        .is_some_and(curve_enabled);
                    curve_by_deck.insert(deck_id, enabled);
                    enabled
                }
            };
            if enabled {
                inputs.push(input);
            }
        }
        let predictions = self.predict_full(&inputs)?;
        let items: Vec<pb::rwkv_review_reschedule_request::Item> = inputs
            .iter()
            .zip(predictions)
            .filter(|(_, p)| validate_prediction(p))
            .filter_map(|(input, p)| {
                Some(pb::rwkv_review_reschedule_request::Item {
                    card_id: input.card_id,
                    interval_days: p.current_interval?,
                    elapsed_days: u32::try_from(input.current_elapsed_days?).ok()?,
                    s90: p.current_s90?,
                    target_retention: input_target_retention(input),
                })
            })
            .collect();
        let predicted = items.len() as u32;
        for item in &items {
            clear_card_info_score(backend, item.card_id)?;
        }
        if items.is_empty() {
            return Ok(RescheduleResponse {
                built: true,
                predicted,
                updated: 0,
            });
        }
        let changes = backend.with_col(|col| {
            SchedulerService::apply_rwkv_review_reschedule(
                col,
                pb::RwkvReviewRescheduleRequest { items },
            )
        })?;
        Ok(RescheduleResponse {
            built: true,
            predicted,
            updated: changes.count,
        })
    }
}

/// `deck_browser_rwkv_count_scope_ids`: the topmost decks using
/// RWKV-Instant; each with the ids of its subtree.
fn collect_instant_scopes(
    backend: &Backend,
    node: &DeckTreeNode,
    out: &mut Vec<(i64, HashSet<i64>)>,
) -> Result<()> {
    if deck_config_for_deck(backend, node.deck_id)?
        .as_ref()
        .is_some_and(instant_enabled)
    {
        let mut ids = HashSet::new();
        subtree_ids(node, &mut ids);
        out.push((node.deck_id, ids));
        return Ok(());
    }
    for child in &node.children {
        collect_instant_scopes(backend, child, out)?;
    }
    Ok(())
}

fn subtree_ids(node: &DeckTreeNode, out: &mut HashSet<i64>) {
    out.insert(node.deck_id);
    for child in &node.children {
        subtree_ids(child, out);
    }
}

fn deck_and_children(backend: &Backend, deck_id: i64) -> Result<Vec<i64>> {
    Ok(backend
        .with_col(|col| {
            DecksService::get_deck_and_child_names(col, anki_proto::decks::DeckId { did: deck_id })
        })?
        .entries
        .into_iter()
        .map(|e| e.id)
        .collect())
}

fn clear_deck_counts(backend: &Backend) -> Result<()> {
    Ok(backend.with_col(SchedulerService::clear_rwkv_deck_count_scores)?)
}

pub(super) fn clear_deck_counts_without_engine(backend: &Backend) -> Result<DeckCountsResponse> {
    clear_deck_counts(backend)?;
    Ok(DeckCountsResponse {
        scopes: 0,
        deferred: true,
    })
}

pub(super) fn pending_search_scores(
    backend: &Backend,
    search: &str,
) -> Result<SearchScoresResponse> {
    set_stats_scores(backend, search, vec![])?;
    Ok(SearchScoresResponse {
        status: "pending",
        scored: 0,
    })
}

fn set_stats_scores(
    backend: &Backend,
    search: &str,
    scores: Vec<pb::rwkv_stats_graph_scores_request::Score>,
) -> Result<()> {
    Ok(backend.with_col(|col| {
        SchedulerService::set_rwkv_stats_graph_scores(
            col,
            pb::RwkvStatsGraphScoresRequest {
                search: search.to_string(),
                scores,
            },
        )
    })?)
}

/// `_validate_prediction` as a filter.
fn validate_prediction(p: &ReviewPredictionOutput) -> bool {
    valid_probability(p.retrievability)
        && p.curve_retrievability.is_none_or(valid_probability)
        && p.button_probabilities.iter().all(|p| valid_probability(*p))
        && p.current_s90.is_none_or(|s| s.is_finite() && s > 0.0)
        && p.intervals
            .iter()
            .chain(&p.s90s)
            .flatten()
            .all(|v| v.is_finite() && *v > 0.0)
}

/// `_format_retrievability`.
pub(super) fn format_percent(value: Option<f32>) -> String {
    match value {
        Some(value) => format!("{:.0}%", f64::from(value) * 100.0),
        None => "Unavailable".into(),
    }
}

/// `_rwkv_button_probabilities_with_retrievability`: Again is 1 - R, the
/// passing buttons share R in the model's proportions.
pub(super) fn rescale_button_probabilities(p: [f32; 4], retrievability: f32) -> [f32; 4] {
    if !valid_probability(retrievability) {
        return p;
    }
    let successful = p[1] + p[2] + p[3];
    if successful <= 0.0 {
        return p;
    }
    let scale = retrievability / successful;
    [
        1.0 - retrievability,
        p[1] * scale,
        p[2] * scale,
        p[3] * scale,
    ]
}

/// `_format_next_s90_values`.
pub(super) fn format_next_s90(values: &[Option<f32>; 4]) -> String {
    RATING_LABELS
        .iter()
        .zip(values)
        .map(|(label, value)| {
            let text = match value {
                Some(v) if v.is_finite() && *v > 0.0 => {
                    let s = format!("{v:.2}");
                    let s = s.trim_end_matches('0').trim_end_matches('.');
                    format!("{s}d")
                }
                _ => "Unavailable".into(),
            };
            format!("{label}:{text}")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// `_s90_for_scheduling_state` per button.
fn fsrs_next_s90(states: Option<&pb::SchedulingStates>) -> [Option<f32>; 4] {
    let Some(states) = states else {
        return [None; 4];
    };
    [&states.again, &states.hard, &states.good, &states.easy]
        .map(|s| s.as_ref().and_then(s90_for_state))
}

fn s90_for_state(state: &pb::SchedulingState) -> Option<f32> {
    use pb::scheduling_state::filtered::Kind as F;
    use pb::scheduling_state::Kind;
    match state.kind.as_ref()? {
        Kind::Normal(normal) => s90_for_normal(normal),
        Kind::Filtered(filtered) => match filtered.kind.as_ref()? {
            F::Rescheduling(r) => r.original_state.as_ref().and_then(s90_for_normal),
            F::Preview(_) => None,
        },
    }
}

fn s90_for_normal(normal: &pb::scheduling_state::Normal) -> Option<f32> {
    use pb::scheduling_state::normal::Kind as N;
    let stability = |m: &Option<anki_proto::cards::FsrsMemoryState>| {
        m.as_ref()
            .map(|m| m.stability)
            .filter(|s| s.is_finite() && *s > 0.0)
    };
    match normal.kind.as_ref()? {
        N::Learning(l) => stability(&l.memory_state),
        N::Review(r) => stability(&r.memory_state),
        N::Relearning(r) => r
            .learning
            .as_ref()
            .and_then(|l| stability(&l.memory_state))
            .or_else(|| r.review.as_ref().and_then(|r| stability(&r.memory_state))),
        N::New(_) => None,
    }
}

/// Card info while the model state is being built (`_prepare_reviewer_backend_for_card_info`).
pub(super) fn loading_card_info() -> CardInfoResponse {
    CardInfoResponse {
        rows: vec![
            CardInfoRow {
                label: "RWKV computed R".into(),
                value: "Unavailable".into(),
            },
            CardInfoRow {
                label: "Retrievability source".into(),
                value: "RWKV state is loading".into(),
            },
        ],
    }
}

fn unavailable_after_review() -> String {
    "Again:Unavailable Hard:Unavailable Good:Unavailable Easy:Unavailable".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_patterns_match_the_desktop_regexes() {
        assert!(SearchNeeds::of("prop:rwkv:r<0.9").instant_r);
        assert!(SearchNeeds::of("deck:x PROP:RWKV:R>=0.5").instant_r);
        assert!(!SearchNeeds::of("xprop:rwkv:r<0.9").instant_r);
        assert!(!SearchNeeds::of("prop:rwkv:rx").instant_r);
        assert!(SearchNeeds::of("prop:rwkv-curve:r!=0").curve_r);
        assert!(!SearchNeeds::of("prop:rwkv-curve:r!=0").instant_r);
        assert!(SearchNeeds::of("is:rwkv:due").instant_due);
        assert!(SearchNeeds::of("deck:a -is:rwkv:due").instant_due);
        assert!(!SearchNeeds::of("is:rwkv:dueX").instant_due);
        assert!(!SearchNeeds::of("x:is:rwkv:due").instant_due);
        assert!(SearchNeeds::of("(is:rwkv-curve:due)").curve_due);
        assert!(!SearchNeeds::of("is:rwkv-curve:due").instant_due);
        assert!(!SearchNeeds::of("deck:current").any());
    }

    #[test]
    fn card_info_formatting_matches_python() {
        assert_eq!(format_percent(Some(0.876)), "88%");
        assert_eq!(format_percent(None), "Unavailable");
        assert_eq!(
            format_next_s90(&[Some(1.5), Some(10.0), Some(12.345), None]),
            "Again:1.5d Hard:10d Good:12.35d Easy:Unavailable"
        );
        let p = rescale_button_probabilities([0.1, 0.2, 0.5, 0.2], 0.8);
        assert!((p[0] - 0.2).abs() < 1e-6);
        assert!((p[1] + p[2] + p[3] - 0.8).abs() < 1e-6);
        assert!((p[2] / p[1] - 2.5).abs() < 1e-5);
    }
}
