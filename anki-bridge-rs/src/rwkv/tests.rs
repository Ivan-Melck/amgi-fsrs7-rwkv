//! End-to-end checks of the RWKV orchestration against a real collection.
//!
//! The central invariant: after answering cards live through this bridge, the
//! resident state must predict exactly what a fresh replay of the resulting
//! revlog predicts. The replay uses the backend's canonical history builder
//! (the same one the desktop uses), so any drift in how live answers are
//! encoded (state kinds, elapsed time, day offsets, durations, presets) shows
//! up here.
//!
//! Needs the model weights: `RWKV_MODEL=/path/to/RWKV_trained_on_5000_10000.bin`,
//! or `anki-upstream` checked out next to this crate. Skipped otherwise.

#![allow(clippy::unwrap_used)]

use std::path::PathBuf;

use anki::backend::init_backend;
use anki::backend::Backend;
use anki::services::BackendCollectionService;
use anki::services::CollectionService;
use anki::services::DeckConfigService;
use anki::services::DecksService;
use anki::services::NotesService;
use anki::services::NotetypesService;
use anki::services::SchedulerService;
use anki::services::SearchService;
use anki_proto::scheduler as pb;
use data_encoding::BASE64;
use prost::Message;

use super::*;

const DAY_MS: i64 = 86_400_000;

fn model_path() -> Option<String> {
    let path = std::env::var("RWKV_MODEL")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../anki-upstream/qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin")
        });
    path.exists().then(|| path.to_string_lossy().into_owned())
}

struct Fixture {
    backend: Backend,
    _dir: tempfile_dir::Dir,
    card_ids: Vec<i64>,
    model: String,
}

mod tempfile_dir {
    pub struct Dir(pub std::path::PathBuf);
    impl Dir {
        pub fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "amgi-rwkv-{name}-{}-{}",
                std::process::id(),
                super::now_millis()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn sql(backend: &Backend, sql: &str, args: Vec<serde_json::Value>) -> Vec<Vec<serde_json::Value>> {
    db_query(backend, sql, args).unwrap()
}

/// A collection 60 days old with `cards` Basic review cards, each with a month
/// of learning and review history, all due today, plus `new_cards` unstudied
/// cards, in a deck whose preset uses RWKV-Instant with RWKV-Curve as its
/// due-date calculator. Some review cards were already answered earlier today,
/// so their next answer goes through the same-day state machine.
fn fixture(name: &str, cards: usize) -> Option<Fixture> {
    fixture_with_new(name, cards, 0)
}

fn fixture_with_new(name: &str, cards: usize, new_cards: usize) -> Option<Fixture> {
    let model = model_path()?;
    let dir = tempfile_dir::Dir::new(name);
    let backend =
        init_backend(&anki_proto::backend::BackendInit::default().encode_to_vec()).unwrap();
    backend
        .open_collection(anki_proto::collection::OpenCollectionRequest {
            collection_path: dir.0.join("collection.anki2").to_string_lossy().into(),
            media_folder_path: dir.0.join("media").to_string_lossy().into(),
            media_db_path: dir.0.join("media.db").to_string_lossy().into(),
        })
        .unwrap();

    let now = now_millis();
    sql(
        &backend,
        "update col set crt = crt - ?",
        vec![serde_json::json!(60 * 86_400)],
    );

    let mut card_ids = vec![];
    backend
        .with_col(|col| {
            let basic = NotetypesService::get_notetype_id_by_name(
                col,
                anki_proto::generic::String {
                    val: "Basic".into(),
                },
            )?;
            for i in 0..cards + new_cards {
                let mut note = NotesService::new_note(col, basic)?;
                note.fields = vec![format!("front {i}"), format!("back {i}")];
                let _ = NotesService::add_note(
                    col,
                    anki_proto::notes::AddNoteRequest {
                        note: Some(note),
                        deck_id: 1,
                    },
                )?;
            }
            Ok(())
        })
        .unwrap();
    let ids = sql(&backend, "select id from cards order by id", vec![]);
    for (i, row) in ids.iter().take(cards).enumerate() {
        let old = row[0].as_i64().unwrap();
        // Created 40 days ago, a second apart.
        let new = now - 40 * DAY_MS + i as i64 * 1000;
        sql(
            &backend,
            "update cards set id = ? where id = ?",
            vec![new.into(), old.into()],
        );
        card_ids.push(new);
    }

    // History: two learning steps 30 days ago, then reviews; some lapses.
    for (i, cid) in card_ids.iter().enumerate() {
        let base = now - 30 * DAY_MS + i as i64 * 7_000;
        let mut rows: Vec<(i64, i64, i64, i64)> = vec![
            (base, 3, 0, 1),                               // learn
            (base + 600_000, 3, 0, 1),                     // learn (graduate)
            (base + DAY_MS, 3, 1, 3),                      // review
            (base + 6 * DAY_MS, 1 + (i as i64 % 4), 1, 8), // review, ease varies
        ];
        if i % 4 == 0 {
            // A lapse relearned the same day.
            rows.push((base + 6 * DAY_MS + 900_000, 3, 2, 1));
        }
        rows.push((base + 15 * DAY_MS, 3, 1, 10));
        // Earlier today: a Review lapse, a Relearning step, or a Learning
        // step; the next Review answer becomes Relearning or Filtered.
        match i % 5 {
            1 => rows.push((now - 7_200_000 + i as i64, 1, 1, 10)),
            2 => rows.push((now - 7_200_000 + i as i64, 3, 2, 1)),
            3 => rows.push((now - 7_200_000 + i as i64, 3, 0, 1)),
            _ => {}
        }
        for (id, ease, kind, ivl) in rows {
            sql(
                &backend,
                "insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, -1, ?, ?, 0, 2500, 8000, ?)",
                vec![id.into(), (*cid).into(), ease.into(), ivl.into(), kind.into()],
            );
        }
        let timing = backend
            .with_col(SchedulerService::sched_timing_today)
            .unwrap();
        sql(
            &backend,
            "update cards set type = 2, queue = 2, ivl = 10, due = ?, factor = 2500, reps = 5 where id = ?",
            vec![(i64::from(timing.days_elapsed) - 5).into(), (*cid).into()],
        );
    }

    // RWKV-Instant, with RWKV-Curve as the due-date calculator, FSRS on.
    backend
        .with_col(|col| {
            let mut config = DeckConfigService::get_deck_config(
                col,
                anki_proto::deck_config::DeckConfigId { dcid: 1 },
            )?;
            let inner = config.config.as_mut().unwrap();
            inner.rwkv_review_enabled = true;
            inner.rwkv_review_instant_order_enabled = true;
            inner.rwkv_review_min_intervening_reviews = 2;
            inner.rwkv_review_min_elapsed_secs = 0;
            inner.reviews_per_day = 1000;
            inner.new_per_day = 100;
            let _ = DeckConfigService::update_deck_configs(
                col,
                anki_proto::deck_config::UpdateDeckConfigsRequest {
                    target_deck_id: 1,
                    configs: vec![config],
                    fsrs: true,
                    // Same-day reviews, so cards answered today stay eligible.
                    fsrs_short_term_with_steps_enabled: true,
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .unwrap();

    Some(Fixture {
        backend,
        _dir: dir,
        card_ids,
        model,
    })
}

fn prepare(
    engine: &mut Engine,
    fx: &Fixture,
    cache_dir: Option<&std::path::Path>,
) -> PrepareResponse {
    engine
        .prepare(
            &fx.backend,
            PrepareRequest {
                model_path: fx.model.clone(),
                cache_dir: cache_dir.map(|d| d.to_string_lossy().into_owned()),
                precision: None,
            },
        )
        .unwrap()
}

/// Query inputs for every card, fixed once so two engines see identical inputs.
fn all_queries(fx: &Fixture) -> Vec<ReviewInput> {
    let rows = fx
        .backend
        .with_col(|col| {
            SchedulerService::rwkv_review_input_rows_for_cards(
                col,
                pb::RwkvReviewInputRowsForCardsRequest {
                    card_ids: fx.card_ids.clone(),
                    include_disabled_decks: true,
                    include_suspended_review: true,
                    include_new_cards: true,
                },
            )
        })
        .unwrap();
    assert!(!rows.rows.is_empty());
    rows.rows.iter().map(query_input_from_row).collect()
}

fn assert_same_predictions(a: &[f32], b: &[f32]) {
    assert_eq!(a.len(), b.len());
    let worst = a
        .iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs())
        .fold(0.0f32, f32::max);
    assert!(worst <= 1e-6, "predictions differ by up to {worst}");
}

/// Shows and answers the next queued card the way the app does; returns its id.
fn answer_next(engine: &mut Engine, fx: &Fixture, rating: u8) -> Option<i64> {
    let queued = fx
        .backend
        .with_col(|col| {
            SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )
        })
        .unwrap();
    let queued = queued.cards.into_iter().next()?;
    let card_id = queued.card.as_ref()?.id;
    let shown = engine
        .scheduling_states(
            &fx.backend,
            SchedulingStatesRequest {
                card_id,
                states: BASE64.encode(&queued.states?.encode_to_vec()),
            },
        )
        .unwrap();
    let states =
        pb::SchedulingStates::decode(BASE64.decode(shown.states.as_bytes()).unwrap().as_slice())
            .unwrap();
    let new_state = match rating {
        1 => states.again,
        2 => states.hard,
        3 => states.good,
        _ => states.easy,
    }
    .unwrap();
    engine
        .answer_card(
            &fx.backend,
            AnswerCardRequest {
                card_id,
                rating,
                milliseconds_taken: 5_000 + u32::from(rating) * 1_000,
                current_state: BASE64.encode(&states.current.unwrap().encode_to_vec()),
                new_state: BASE64.encode(&new_state.encode_to_vec()),
            },
        )
        .unwrap();
    Some(card_id)
}

#[test]
fn live_answers_match_a_fresh_canonical_replay() {
    let Some(fx) = fixture_with_new("parity", 15, 4) else {
        return;
    };
    let mut live = Engine::default();
    let prepared = prepare(&mut live, &fx, None);
    assert!(prepared.active && prepared.ready);
    assert_eq!(prepared.source, "replayed");
    // Cards whose latest learning start is today's seeded Learning step keep
    // only that review (`_benchmark_retained_historical_review_starts`).
    // Per card i: 5 rows, +1 lapse when i % 4 == 0, +1 same-day row when
    // i % 5 is 1 or 2; i % 5 == 3 keeps 1. Summed over i in 0..15: 72.
    assert_eq!(prepared.replayed_reviews, 72);

    let scored = live
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();
    assert!(scored.instant);
    assert!(scored.scored > 0);

    // Mixed grades until the queue runs dry, so lapses and learning steps
    // come back through learn-ahead.
    let mut answered = vec![];
    for rating in [3, 1, 3, 4, 2, 1, 3, 3, 1, 4, 3, 2].iter().cycle().take(60) {
        match answer_next(&mut live, &fx, *rating) {
            Some(card_id) => answered.push(card_id),
            None => break,
        }
    }
    assert_eq!(live.own_review_ids.len(), answered.len());

    // Every dataset state was exercised by a live answer.
    let kinds: Vec<i64> = sql(
        &fx.backend,
        "select distinct type from revlog where id > ? order by type",
        vec![(now_millis() - 600_000).into()],
    )
    .iter()
    .map(|r| r[0].as_i64().unwrap())
    .collect();
    assert_eq!(
        kinds,
        vec![0, 1, 2, 3],
        "live answers covered revlog kinds {kinds:?}"
    );
    let learn_starts = sql(
        &fx.backend,
        "select count() from revlog r where r.id > ? and r.type = 0 and not exists \
         (select 1 from revlog p where p.cid = r.cid and p.id < r.id)",
        vec![(now_millis() - 600_000).into()],
    )[0][0]
        .as_i64()
        .unwrap();
    assert!(learn_starts > 0, "no learn starts answered");

    let queries = all_queries(&fx);
    let live_predictions = live.predict_many(&queries).unwrap();

    let mut fresh = Engine::default();
    let replayed = prepare(&mut fresh, &fx, None);
    assert_eq!(replayed.source, "replayed");
    assert_eq!(
        replayed.replayed_reviews,
        prepared.replayed_reviews + answered.len() as u64
    );
    let fresh_predictions = fresh.predict_many(&queries).unwrap();
    assert_same_predictions(&live_predictions, &fresh_predictions);

    // The live engine's identity bookkeeping agrees with the collection.
    live.trusted = false;
    let revalidated = live.ensure_ready(&fx.backend).unwrap();
    assert_eq!(revalidated.0, "revalidated");
}

#[test]
fn curve_states_and_answer_metadata_reach_the_collection() {
    let Some(fx) = fixture("curve", 6) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();

    let queued = fx
        .backend
        .with_col(|col| {
            SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )
        })
        .unwrap()
        .cards
        .remove(0);
    let card_id = queued.card.unwrap().id;
    let original = queued.states.unwrap();
    let shown = engine
        .scheduling_states(
            &fx.backend,
            SchedulingStatesRequest {
                card_id,
                states: BASE64.encode(&original.encode_to_vec()),
            },
        )
        .unwrap();
    assert!(shown.curve);
    let r = shown.retrievability.unwrap();
    assert!((0.0..=1.0).contains(&r));
    let prediction = engine.session.prediction.unwrap();
    assert!(prediction.interval_override_used);
    let good_s90 = prediction.s90s[2].unwrap();

    let states =
        pb::SchedulingStates::decode(BASE64.decode(shown.states.as_bytes()).unwrap().as_slice())
            .unwrap();
    assert_ne!(
        states.good, original.good,
        "Curve should replace FSRS's Good state"
    );
    engine
        .answer_card(
            &fx.backend,
            AnswerCardRequest {
                card_id,
                rating: 3,
                milliseconds_taken: 4_000,
                current_state: BASE64.encode(&states.current.clone().unwrap().encode_to_vec()),
                new_state: BASE64.encode(&states.good.clone().unwrap().encode_to_vec()),
            },
        )
        .unwrap();

    // The revlog carries RWKV's review kind; the card RWKV's S90.
    let row = &sql(
        &fx.backend,
        "select type, ease from revlog where cid = ? order by id desc limit 1",
        vec![card_id.into()],
    )[0];
    assert_eq!(
        row[0].as_i64(),
        Some(1),
        "review answered on a new day is a Review"
    );
    let card = get_card(&fx.backend, card_id).unwrap();
    let stability = card.memory_state.unwrap().stability;
    assert!(
        (stability - good_s90).abs() < 1e-3,
        "stability {stability} vs S90 {good_s90}"
    );
}

#[test]
fn undo_restores_the_state_before_the_answer() {
    let Some(fx) = fixture("undo", 6) else { return };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();
    let queries = all_queries(&fx);
    let before = engine.predict_many(&queries).unwrap();

    answer_next(&mut engine, &fx, 3).unwrap();
    let after = engine.predict_many(&queries).unwrap();
    assert!(before.iter().zip(&after).any(|(a, b)| a != b));

    let _ = fx.backend.with_col(CollectionService::undo).unwrap();
    assert!(engine.undo_answer(&fx.backend).unwrap().restored);
    assert_same_predictions(&before, &engine.predict_many(&queries).unwrap());
    engine.trusted = false;
    assert_eq!(engine.ensure_ready(&fx.backend).unwrap().0, "revalidated");
}

#[test]
fn persisted_state_restores_and_catches_up() {
    let Some(fx) = fixture("persist", 8) else {
        return;
    };
    let cache = tempfile_dir::Dir::new("persist-cache");
    let mut engine = Engine::default();
    assert_eq!(prepare(&mut engine, &fx, Some(&cache.0)).source, "replayed");
    engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();

    // Untouched collection: restored as is.
    let mut restored = Engine::default();
    assert_eq!(
        prepare(&mut restored, &fx, Some(&cache.0)).source,
        "restored"
    );
    let queries = all_queries(&fx);
    assert_same_predictions(
        &engine.predict_many(&queries).unwrap(),
        &restored.predict_many(&queries).unwrap(),
    );

    // Answers after the save: restored, then only the newer reviews replayed.
    for rating in [3, 1, 3] {
        answer_next(&mut engine, &fx, rating);
    }
    let mut caught_up = Engine::default();
    let prepared = prepare(&mut caught_up, &fx, Some(&cache.0));
    assert_eq!(prepared.source, "restored+suffix");
    assert_eq!(prepared.replayed_reviews, 3);
    let queries = all_queries(&fx);
    assert_same_predictions(
        &engine.predict_many(&queries).unwrap(),
        &caught_up.predict_many(&queries).unwrap(),
    );

    // Saving after live answers records the new identity.
    assert!(engine.save(&fx.backend).unwrap().saved);
    let mut reopened = Engine::default();
    assert_eq!(
        prepare(&mut reopened, &fx, Some(&cache.0)).source,
        "restored"
    );
}

#[test]
fn inactive_collection_is_left_alone() {
    let Some(fx) = fixture("inactive", 2) else {
        return;
    };
    fx.backend
        .with_col(|col| {
            let mut config = DeckConfigService::get_deck_config(
                col,
                anki_proto::deck_config::DeckConfigId { dcid: 1 },
            )?;
            let inner = config.config.as_mut().unwrap();
            inner.rwkv_review_enabled = false;
            inner.rwkv_review_instant_order_enabled = false;
            let _ = DeckConfigService::update_deck_configs(
                col,
                anki_proto::deck_config::UpdateDeckConfigsRequest {
                    target_deck_id: 1,
                    configs: vec![config],
                    fsrs: true,
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .unwrap();
    let mut engine = Engine::default();
    let prepared = prepare(&mut engine, &fx, None);
    assert!(!prepared.active);
    let scored = engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();
    assert!(!scored.instant);
}

fn rwkv_score(fx: &Fixture, card_id: i64) -> Option<f32> {
    fx.backend
        .with_col(|col| {
            SchedulerService::get_rwkv_retrievability_score(
                col,
                anki_proto::cards::CardId { cid: card_id },
            )
        })
        .unwrap()
        .retrievability
}

#[test]
fn deck_counts_install_scores_for_instant_scopes() {
    let Some(fx) = fixture("counts", 6) else {
        return;
    };
    let mut engine = Engine::default();
    // Not prepared yet: deferred, nothing installed.
    let counts = engine.deck_counts(&fx.backend).unwrap();
    assert_eq!(counts.scopes, 0);
    prepare(&mut engine, &fx, None);
    assert_eq!(rwkv_score(&fx, fx.card_ids[0]), None);

    let counts = engine.deck_counts(&fx.backend).unwrap();
    assert_eq!((counts.scopes, counts.deferred), (1, false));
    let r = rwkv_score(&fx, fx.card_ids[0]).expect("deck count score installed");
    assert!((0.0..=1.0).contains(&r));
    // The deck tree with counts builds with the scores in place.
    let _ = fx
        .backend
        .with_col(|col| {
            DecksService::deck_tree(
                col,
                anki_proto::decks::DeckTreeRequest {
                    now: now_millis() / 1000,
                },
            )
        })
        .unwrap();
}

#[test]
fn search_scores_feed_graphs_and_rwkv_searches() {
    let Some(fx) = fixture("search", 6) else {
        return;
    };
    let mut engine = Engine::default();
    let pending = engine
        .search_scores(
            &fx.backend,
            views::SearchScoresRequest {
                search: "deck:current".into(),
                wait: false,
            },
        )
        .unwrap();
    // No model loaded yet.
    assert_eq!(pending.status, "unavailable");
    prepare(&mut engine, &fx, None);

    let ready = engine
        .search_scores(
            &fx.backend,
            views::SearchScoresRequest {
                search: "deck:current".into(),
                wait: false,
            },
        )
        .unwrap();
    assert_eq!((ready.status, ready.scored), ("ready", 6));
    let graphs = fx
        .backend
        .with_col(|col| {
            anki::services::StatsService::graphs(
                col,
                anki_proto::stats::GraphsRequest {
                    search: "deck:current".into(),
                    days: 30,
                },
            )
        })
        .unwrap();
    assert!(graphs.retrievability.is_some());

    // A browser search on RWKV retrievability matches once scores exist.
    let search = "prop:rwkv:r<=1";
    let scores = engine
        .search_scores(
            &fx.backend,
            views::SearchScoresRequest {
                search: search.into(),
                wait: true,
            },
        )
        .unwrap();
    assert_eq!(scores.status, "ready");
    let found = fx
        .backend
        .with_col(|col| {
            SearchService::search_cards(
                col,
                anki_proto::search::SearchRequest {
                    search: search.into(),
                    order: None,
                },
            )
        })
        .unwrap();
    assert_eq!(found.ids.len(), 6);

    // Curve due searches get full predictions.
    let curve = engine
        .search_scores(
            &fx.backend,
            views::SearchScoresRequest {
                search: "is:rwkv-curve:due".into(),
                wait: true,
            },
        )
        .unwrap();
    assert_eq!(curve.status, "ready");
}

#[test]
fn filtered_deck_ordered_by_retrievability_gets_scores() {
    let Some(fx) = fixture("filtered", 4) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let deck_id = fx
        .backend
        .with_col(|col| {
            let mut deck = DecksService::get_or_create_filtered_deck(
                col,
                anki_proto::decks::DeckId { did: 0 },
            )?;
            let config = deck.config.as_mut().unwrap();
            config.search_terms[0].search = "deck:Default".into();
            config.search_terms[0].set_order(
                anki_proto::decks::deck::filtered::search_term::Order::RetrievabilityAscending,
            );
            deck.name = "RWKV filtered".into();
            Ok(DecksService::add_or_update_filtered_deck(col, deck)?.id)
        })
        .unwrap();
    let scores = engine
        .filtered_deck_scores(&fx.backend, views::FilteredDeckRequest { deck_id })
        .unwrap();
    assert_eq!(scores.status, "ready");
    let skipped = engine
        .filtered_deck_scores(&fx.backend, views::FilteredDeckRequest { deck_id: 1 })
        .unwrap();
    assert_eq!(skipped.status, "skipped");
}

#[test]
fn card_info_rows_match_the_desktop_labels() {
    let Some(fx) = fixture("cardinfo", 3) else {
        return;
    };
    let mut engine = Engine::default();
    let unavailable = engine
        .card_info(
            &fx.backend,
            views::CardInfoRequest {
                card_id: fx.card_ids[0],
            },
        )
        .unwrap();
    assert_eq!(unavailable.rows[0].value, "Unavailable");

    prepare(&mut engine, &fx, None);
    let info = engine
        .card_info(
            &fx.backend,
            views::CardInfoRequest {
                card_id: fx.card_ids[0],
            },
        )
        .unwrap();
    let labels: Vec<&str> = info.rows.iter().map(|r| r.label.as_str()).collect();
    assert_eq!(
        labels,
        [
            "RWKV computed R",
            "RWKV : Answer Button Probability",
            "Retrievability source",
            "RWKV Curve Next S90",
            "FSRS Next S90",
            "RWKV : R After Review",
            "RWKV : R After 10min",
        ]
    );
    assert!(info.rows[0].value.ends_with('%'));
    assert_eq!(info.rows[2].value, "RWKV");
    assert!(
        !info.rows[5].value.contains("Unavailable"),
        "{}",
        info.rows[5].value
    );
    assert!(rwkv_score(&fx, fx.card_ids[0]).is_some());
}

#[test]
fn curve_reschedule_writes_intervals_and_s90() {
    let Some(fx) = fixture("reschedule", 5) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let before = sql(
        &fx.backend,
        "select ivl, due from cards order by id",
        vec![],
    );
    let result = engine
        .reschedule(&fx.backend, views::RescheduleRequest { deck_id: Some(1) })
        .unwrap();
    assert!(result.built);
    assert_eq!(result.predicted, 5);
    assert_eq!(result.updated, 5);
    let after = sql(
        &fx.backend,
        "select ivl, due from cards order by id",
        vec![],
    );
    assert_ne!(before, after);
    let card = get_card(&fx.backend, fx.card_ids[0]).unwrap();
    assert!(card.memory_state.unwrap().stability > 0.0);

    // Whole collection; no history changed, so the state stays trusted.
    let all = engine
        .reschedule(&fx.backend, views::RescheduleRequest { deck_id: None })
        .unwrap();
    assert_eq!(all.predicted, 5);
    engine.trusted = false;
    assert_eq!(engine.ensure_ready(&fx.backend).unwrap().0, "revalidated");
}

/// Moves the cards at `indices` into a "Default::Plain" subdeck whose preset
/// uses plain FSRS-7 (no RWKV).
fn add_plain_subdeck(fx: &Fixture, indices: &[usize]) -> i64 {
    let deck_id = fx
        .backend
        .with_col(|col| {
            let mut deck = DecksService::new_deck(col)?;
            deck.name = "Default::Plain".into();
            let deck_id = DecksService::add_deck(col, deck)?.id;
            let mut config = DeckConfigService::get_deck_config(
                col,
                anki_proto::deck_config::DeckConfigId { dcid: 1 },
            )?;
            config.id = 0;
            config.name = "Plain FSRS".into();
            let inner = config.config.as_mut().unwrap();
            inner.rwkv_review_enabled = false;
            inner.rwkv_review_instant_order_enabled = false;
            let _ = DeckConfigService::update_deck_configs(
                col,
                anki_proto::deck_config::UpdateDeckConfigsRequest {
                    target_deck_id: deck_id,
                    configs: vec![config],
                    fsrs: true,
                    fsrs_short_term_with_steps_enabled: true,
                    ..Default::default()
                },
            )?;
            Ok(deck_id)
        })
        .unwrap();
    for i in indices {
        sql(
            &fx.backend,
            "update cards set did = ? where id = ?",
            vec![deck_id.into(), fx.card_ids[*i].into()],
        );
    }
    deck_id
}

#[test]
fn answers_on_plain_presets_also_advance_the_model() {
    let Some(fx) = fixture("mixed", 10) else {
        return;
    };
    let plain = add_plain_subdeck(&fx, &[0, 2, 4, 6, 8]);
    let mut live = Engine::default();
    assert_eq!(prepare(&mut live, &fx, None).source, "replayed");
    live.score_deck_request(
        &fx.backend,
        ScoreDeckRequest {
            deck_id: 1,
            new_session: true,
        },
    )
    .unwrap();

    let mut answered = vec![];
    for rating in [3, 1, 3, 4, 2, 3, 1, 3].iter().cycle().take(40) {
        match answer_next(&mut live, &fx, *rating) {
            Some(card_id) => answered.push(card_id),
            None => break,
        }
    }
    let plain_answers = sql(
        &fx.backend,
        "select count() from revlog r join cards c on c.id = r.cid where c.did = ? and r.id > ?",
        vec![plain.into(), (now_millis() - 600_000).into()],
    )[0][0]
        .as_i64()
        .unwrap();
    assert!(plain_answers > 0, "no answers landed on the plain preset");
    assert!(
        live.current(&fx.backend).unwrap(),
        "live state should still be current"
    );

    let queries = all_queries(&fx);
    let mut fresh = Engine::default();
    prepare(&mut fresh, &fx, None);
    assert_same_predictions(
        &live.predict_many(&queries).unwrap(),
        &fresh.predict_many(&queries).unwrap(),
    );
}

#[test]
fn reviewer_bookkeeping_survives_a_new_session() {
    let Some(fx) = fixture("sessions", 15) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();
    // Stop while a synthesised state is held: a later plain answer of the
    // same card drops it again, and the queue order (so whether that
    // happens within the loop) varies from run to run.
    for rating in [3, 1, 3, 4, 2, 1, 3, 3, 1, 4, 3, 2].iter().cycle().take(60) {
        if answer_next(&mut engine, &fx, *rating).is_none() || !engine.synthetic.is_empty() {
            break;
        }
    }
    let synthetic = engine.synthetic.len();
    let answered = engine.answered_ids.len();
    assert!(
        synthetic > 0,
        "the fixture's same-day cards should synthesise states"
    );
    engine
        .score_deck_request(
            &fx.backend,
            ScoreDeckRequest {
                deck_id: 1,
                new_session: true,
            },
        )
        .unwrap();
    assert_eq!(engine.synthetic.len(), synthetic);
    assert_eq!(engine.answered_ids.len(), answered);
}

#[test]
fn a_learning_restart_after_history_rebuilds_the_state() {
    let Some(fx) = fixture("restart", 1) else {
        return;
    };
    let mut live = Engine::default();
    prepare(&mut live, &fx, None);
    // Back to new without a reset entry: the next answer starts a new
    // learning history, which the canonical history keeps from there on.
    sql(
        &fx.backend,
        "update cards set type = 0, queue = 0, due = 0 where id = ?",
        vec![fx.card_ids[0].into()],
    );
    let _ = fx.backend.with_col(|col| {
        let mut config = DeckConfigService::get_deck_config(
            col,
            anki_proto::deck_config::DeckConfigId { dcid: 1 },
        )?;
        config.config.as_mut().unwrap().new_per_day = 10;
        DeckConfigService::update_deck_configs(
            col,
            anki_proto::deck_config::UpdateDeckConfigsRequest {
                target_deck_id: 1,
                configs: vec![config],
                fsrs: true,
                fsrs_short_term_with_steps_enabled: true,
                ..Default::default()
            },
        )
    });
    assert_eq!(answer_next(&mut live, &fx, 3), Some(fx.card_ids[0]));
    assert!(
        live.base.is_none(),
        "a restart must drop the resident state"
    );
    assert_eq!(live.ensure_ready(&fx.backend).unwrap().0, "replayed");

    let queries = all_queries(&fx);
    let mut fresh = Engine::default();
    prepare(&mut fresh, &fx, None);
    assert_same_predictions(
        &live.predict_many(&queries).unwrap(),
        &fresh.predict_many(&queries).unwrap(),
    );
}

#[test]
fn changes_made_elsewhere_are_noticed_and_caught_up() {
    let Some(fx) = fixture("elsewhere", 6) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    assert!(engine.current(&fx.backend).unwrap());

    // Another client (or the browser) answers a card behind the engine's back.
    let queued = fx
        .backend
        .with_col(|col| {
            SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )
        })
        .unwrap()
        .cards
        .remove(0);
    let states = queued.states.unwrap();
    let _ = fx
        .backend
        .with_col(|col| {
            SchedulerService::answer_card(
                col,
                pb::CardAnswer {
                    card_id: queued.card.unwrap().id,
                    current_state: states.current,
                    new_state: states.good,
                    rating: 2,
                    answered_at_millis: now_millis(),
                    milliseconds_taken: 3000,
                    ..Default::default()
                },
            )
        })
        .unwrap();
    assert!(
        !engine.current(&fx.backend).unwrap(),
        "the outside answer must be noticed"
    );
    let counts = engine.deck_counts(&fx.backend).unwrap();
    assert!(counts.deferred);
    assert_eq!(engine.ensure_ready(&fx.backend).unwrap(), ("suffix", 1));

    let queries = all_queries(&fx);
    let mut fresh = Engine::default();
    prepare(&mut fresh, &fx, None);
    assert_same_predictions(
        &engine.predict_many(&queries).unwrap(),
        &fresh.predict_many(&queries).unwrap(),
    );
}

#[test]
fn answering_clears_the_card_info_score() {
    let Some(fx) = fixture("infoclear", 4) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let head = fx
        .backend
        .with_col(|col| {
            SchedulerService::get_queued_cards(
                col,
                pb::GetQueuedCardsRequest {
                    fetch_limit: 1,
                    ..Default::default()
                },
            )
        })
        .unwrap()
        .cards[0]
        .card
        .as_ref()
        .unwrap()
        .id;
    engine
        .card_info(&fx.backend, views::CardInfoRequest { card_id: head })
        .unwrap();
    assert!(rwkv_score(&fx, head).is_some());
    assert_eq!(answer_next(&mut engine, &fx, 3), Some(head));
    assert_eq!(rwkv_score(&fx, head), None);
}

#[test]
fn undo_still_works_after_a_save() {
    let Some(fx) = fixture("undosave", 6) else {
        return;
    };
    let cache = tempfile_dir::Dir::new("undosave-cache");
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, Some(&cache.0));
    let queries = all_queries(&fx);
    let before = engine.predict_many(&queries).unwrap();
    answer_next(&mut engine, &fx, 3).unwrap();
    assert!(engine.save(&fx.backend).unwrap().saved);

    let _ = fx.backend.with_col(CollectionService::undo).unwrap();
    assert!(engine.undo_answer(&fx.backend).unwrap().restored);
    assert!(
        engine.current(&fx.backend).unwrap(),
        "undo should revalidate, not replay"
    );
    assert_same_predictions(&before, &engine.predict_many(&queries).unwrap());
}

#[test]
fn another_collection_on_the_same_backend_is_not_trusted() {
    let Some(fx) = fixture("switch", 3) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    assert!(engine.current(&fx.backend).unwrap());

    let other = tempfile_dir::Dir::new("switch-other");
    fx.backend
        .close_collection(anki_proto::collection::CloseCollectionRequest::default())
        .unwrap();
    fx.backend
        .open_collection(anki_proto::collection::OpenCollectionRequest {
            collection_path: other.0.join("collection.anki2").to_string_lossy().into(),
            media_folder_path: other.0.join("media").to_string_lossy().into(),
            media_db_path: other.0.join("media.db").to_string_lossy().into(),
        })
        .unwrap();
    assert!(!engine.current(&fx.backend).unwrap());
    assert!(engine.base.is_none() && engine.answered_ids.is_empty());
}

#[test]
fn candidates_follow_the_review_order() {
    use anki_proto::deck_config::deck_config::config::ReviewCardOrder;
    let scores: HashMap<i64, (f32, Option<f32>)> = [
        (1, (0.9, Some(0.9))),
        (2, (0.5, Some(0.5))),
        (3, (0.7, None)),
        (4, (0.5, Some(0.95))),
    ]
    .into();
    let order =
        |o: ReviewCardOrder, limit, current| candidate_card_ids(&scores, o as i32, limit, current);
    // Lowest retrievability first, ties by card id.
    assert_eq!(order(ReviewCardOrder::Day, 3, None), vec![2, 4, 3]);
    assert_eq!(
        order(ReviewCardOrder::RetrievabilityDescending, 2, None),
        vec![1, 3]
    );
    // Retrievability over target; a missing target counts as 1.
    assert_eq!(
        order(ReviewCardOrder::RelativeOverdueness, 4, None),
        vec![4, 3, 1, 2]
    );
    // The current card is appended once.
    assert_eq!(order(ReviewCardOrder::Day, 1, Some(9)), vec![2, 9]);
    assert_eq!(order(ReviewCardOrder::Day, 1, Some(2)), vec![2]);
}

fn set_candidate_refresh(fx: &Fixture, enabled: bool) {
    edit_config(fx, |config| {
        config.rwkv_review_candidate_refresh_enabled = enabled
    });
}

fn edit_config(fx: &Fixture, edit: impl FnOnce(&mut anki_proto::deck_config::deck_config::Config)) {
    fx.backend
        .with_col(|col| {
            let mut config = DeckConfigService::get_deck_config(
                col,
                anki_proto::deck_config::DeckConfigId { dcid: 1 },
            )?;
            edit(config.config.as_mut().unwrap());
            let _ = DeckConfigService::update_deck_configs(
                col,
                anki_proto::deck_config::UpdateDeckConfigsRequest {
                    target_deck_id: 1,
                    configs: vec![config],
                    fsrs: true,
                    fsrs_short_term_with_steps_enabled: true,
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .unwrap();
}

#[test]
fn candidate_refresh_reuses_scores_only_while_they_are_current() {
    let Some(fx) = fixture("candidates", 8) else {
        return;
    };
    set_candidate_refresh(&fx, true);
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let request = ScoreDeckRequest {
        deck_id: 1,
        new_session: true,
    };
    engine.score_deck_request(&fx.backend, request).unwrap();
    let config = deck_config_for_deck(&fx.backend, 1).unwrap().unwrap();
    let candidates = |engine: &Engine| {
        engine
            .refresh_candidates(&fx.backend, 1, &config, None)
            .unwrap()
    };
    assert!(candidates(&engine).is_some());

    // Our own answers keep the scores current.
    answer_next(&mut engine, &fx, 3).unwrap();
    answer_next(&mut engine, &fx, 1).unwrap();
    assert!(
        candidates(&engine).is_some(),
        "own answers made the scores stale"
    );

    // A candidate refresh (every card fits in one batch here) agrees with
    // scoring the whole deck.
    engine.score_deck(&fx.backend, 1, None).unwrap();
    let partial = engine.installed_scores.as_ref().unwrap().scores.clone();
    engine.installed_scores = None;
    engine.score_deck(&fx.backend, 1, None).unwrap();
    let full = engine.installed_scores.as_ref().unwrap().scores.clone();
    for (card_id, (r, target)) in &full {
        let (pr, ptarget) = partial[card_id];
        assert!(
            (pr - r).abs() <= 1e-6 && ptarget == *target,
            "card {card_id}"
        );
    }
    // As on the desktop, the per-card rows also keep the card relearning
    // after Again, which the deck's review-queue rows leave out.
    for card_id in partial.keys().filter(|id| !full.contains_key(id)) {
        let queue = sql(
            &fx.backend,
            "select queue from cards where id = ?",
            vec![(*card_id).into()],
        );
        assert_eq!(queue[0][0].as_i64(), Some(1), "card {card_id}");
    }

    // Anything else that changes the collection means a full rescore.
    let _ = fx
        .backend
        .with_col(|col| {
            SchedulerService::bury_or_suspend_cards(
                col,
                pb::BuryOrSuspendCardsRequest {
                    card_ids: vec![fx.card_ids[0]],
                    note_ids: vec![],
                    mode: pb::bury_or_suspend_cards_request::Mode::Suspend as i32,
                },
            )
        })
        .unwrap();
    assert!(candidates(&engine).is_none(), "stale scores were reused");
    engine.score_deck(&fx.backend, 1, None).unwrap();
    assert!(candidates(&engine).is_some());
    assert!(!engine
        .installed_scores
        .as_ref()
        .unwrap()
        .scores
        .contains_key(&fx.card_ids[0]));
}

#[test]
fn candidate_refresh_drops_new_cards_like_the_desktop() {
    let Some(fx) = fixture_with_new("candidates-new", 4, 3) else {
        return;
    };
    edit_config(&fx, |config| {
        config.rwkv_review_candidate_refresh_enabled = true;
        config.set_new_card_gather_priority(
            anki_proto::deck_config::deck_config::config::NewCardGatherPriority::DescendingRetrievability,
        );
    });
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let new_cards: Vec<i64> = sql(&fx.backend, "select id from cards where type = 0", vec![])
        .iter()
        .map(|r| r[0].as_i64().unwrap())
        .collect();
    assert_eq!(new_cards.len(), 3);
    let scored = |engine: &Engine| engine.installed_scores.as_ref().unwrap().scores.clone();

    // A full scoring includes the new cards the gather order ranks...
    engine.score_deck(&fx.backend, 1, None).unwrap();
    assert!(new_cards.iter().all(|id| scored(&engine).contains_key(id)));
    // ...but the per-card rows of a candidate refresh leave them out, so
    // they drop out of the map.
    engine.score_deck(&fx.backend, 1, None).unwrap();
    let after = scored(&engine);
    assert!(new_cards.iter().all(|id| !after.contains_key(id)));
    assert_eq!(after.len(), 4);
}

#[test]
fn rebuilding_replays_the_whole_history_and_saves_it() {
    let Some(fx) = fixture("rebuild", 6) else {
        return;
    };
    let cache = tempfile_dir::Dir::new("rebuild-cache");
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, Some(&cache.0));
    answer_next(&mut engine, &fx, 3).unwrap();
    let queries = all_queries(&fx);
    let live = engine.predict_many(&queries).unwrap();

    let request = PrepareRequest {
        model_path: fx.model.clone(),
        cache_dir: Some(cache.0.to_string_lossy().into_owned()),
        precision: None,
    };
    let rebuilt = engine.rebuild_state(&fx.backend, request).unwrap();
    assert_eq!(rebuilt.source, "replayed");
    assert!(rebuilt.ready);
    assert_same_predictions(&live, &engine.predict_many(&queries).unwrap());
    // Back to normal: the next prepare keeps the resident state.
    assert_eq!(prepare(&mut engine, &fx, Some(&cache.0)).source, "resident");
    // And the rebuilt state was saved.
    let mut restored = Engine::default();
    assert_eq!(
        prepare(&mut restored, &fx, Some(&cache.0)).source,
        "restored"
    );
}

#[test]
fn fallback_grade_probabilities_match_the_desktop() {
    // `_fallback_rwkv_grade_probabilities(0.9)` and `(0.3)` on the desktop.
    let high = workload::fallback_grade_probabilities(0.9);
    let expected_high = [
        0.09999999999999998,
        0.09999999999999987,
        0.48500000000000015,
        0.315,
    ];
    let low = workload::fallback_grade_probabilities(0.3);
    let expected_low = [0.7, 0.13500000000000004, 0.15, 0.015000000000000003];
    for (got, want) in high
        .iter()
        .chain(&low)
        .zip(expected_high.iter().chain(&expected_low))
    {
        assert!((got - want).abs() < 1e-12, "{got} != {want}");
    }
}

#[test]
fn review_model_smooths_grades_per_bucket() {
    // Two Good answers at r = 0.92 (bucket 18) taking 4s and 6s, one Again
    // with an implausible time.
    let (model, _) =
        workload::review_model(&[(0.92, 3, 4_000), (0.93, 3, 6_000), (0.5, 1, 700_000)]);
    assert_eq!(model.grade_seconds, [8.0, 8.0, 5.0, 8.0]);
    let buckets: Vec<u32> = model.bucket_probabilities.iter().map(|(b, _)| *b).collect();
    assert_eq!(buckets, vec![10, 18]);
    let (_, p) = model.bucket_probabilities[1];
    let prior = workload::fallback_grade_probabilities(18.5 / 20.0);
    let total = 2.0 + 4.0;
    let expected = [
        prior[0] * 4.0 / total,
        prior[1] * 4.0 / total,
        (2.0 + prior[2] * 4.0) / total,
        prior[3] * 4.0 / total,
    ];
    for (got, want) in p.iter().zip(expected) {
        assert!((f64::from(*got) - want).abs() < 1e-6);
    }
}

#[test]
fn review_time_fields_match_the_desktop() {
    // Expected values from `_rwkv_simulator_review_model` /
    // `_rwkv_simulator_review_time_fields` run in Python on the same rows.
    // Again: positive slope, so the top buckets fall back to the grade mean;
    // Hard: R 1e-7 apart, so the mean; Good: a regression; Easy: one timed sample;
    // then untimed and invalid rows.
    let rows = [
        (0.9, 1, 1000),
        (0.1, 1, 30000),
        (0.62, 2, 7500),
        (0.6200001, 2, 12500),
        (0.97, 3, 4200),
        (0.88, 3, 5100),
        (0.75, 3, 6900),
        (0.51, 3, 9300),
        (1.0, 3, 3000),
        (0.0, 3, 15000),
        (0.99, 4, 2500),
        (0.95, 4, 0),
        (0.95, 4, 600000),
        (0.5, 0, 5000),
        (0.5, 5, 5000),
        (1.5, 3, 5000),
        (-0.1, 3, 5000),
        (0.4, 1, -3),
    ];
    let (model, fields) = workload::review_model(&rows);
    assert_eq!(model.grade_seconds, [15.5, 10.0, 7.25, 2.5]);
    assert_eq!(fields.r_bucket_count, 20);
    assert_eq!(fields.s_bucket_count, 1);
    assert_eq!(
        fields.seconds[0],
        vec![
            15.5,
            0.09374999999999822,
            1.90625,
            3.7187500000000018,
            5.53125,
            7.34375,
            9.156249999999998,
            10.96875,
            12.781250000000002,
            14.593750000000004,
            16.40625,
            18.218750000000004,
            20.03125,
            21.84375,
            23.656250000000004,
            25.46875,
            27.281250000000004,
            29.09375,
            30.90625,
            32.71875
        ]
    );
    assert_eq!(fields.seconds[1], vec![10.0; 20]);
    assert_eq!(
        fields.seconds[2],
        vec![
            3.9117189121860076,
            4.487284616981523,
            5.06285032177704,
            5.638416026572555,
            6.2139817313680705,
            6.789547436163588,
            7.365113140959103,
            7.9406788457546185,
            8.516244550550136,
            9.091810255345653,
            9.667375960141168,
            10.242941664936684,
            10.818507369732199,
            11.394073074527714,
            11.969638779323232,
            12.545204484118747,
            13.120770188914262,
            13.696335893709778,
            14.271901598505295,
            14.84746730330081
        ]
    );
    assert_eq!(fields.seconds[3], vec![2.5; 20]);
    assert_eq!(
        fields.sample_counts,
        vec![3, 1, 1, 0, 1, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1]
    );
    assert_eq!(
        fields.coeffs,
        [
            [-2.625, 36.25, 0.0, 0.0, 0.0],
            [10.0, 0.0, 0.0, 0.0, 0.0],
            [3.6239360597882495, 11.511314095910318, 0.0, 0.0, 0.0],
            [2.5, 0.0, 0.0, 0.0, 0.0]
        ]
    );
    let weights = [
        0.21428571428571427,
        0.14285714285714285,
        0.42857142857142855,
        0.21428571428571427,
    ];
    assert_eq!(fields.grade_weights, weights);
    assert_eq!(fields.transition_probs, weights.repeat(4));
    assert_eq!(fields.transition_counts, vec![0; 16]);
    assert_eq!(
        fields.success_grade_probs,
        vec![
            0.057142857142857155,
            0.5999999999999999,
            0.3428571428571429,
            0.1,
            0.55,
            0.35,
            0.13333333333333325,
            0.5866666666666667,
            0.27999999999999997,
            0.2777777777777778,
            0.42222222222222244,
            0.2999999999999998,
            0.311111111111111,
            0.6088888888888889,
            0.08000000000000007,
            0.45,
            0.5,
            0.049999999999999996,
            0.45,
            0.5,
            0.05,
            0.6333333333333333,
            0.3333333333333333,
            0.03333333333333333,
            0.45,
            0.5,
            0.05,
            0.36,
            0.6,
            0.04,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05000000000000001,
            0.45,
            0.5,
            0.049999999999999996,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45000000000000007,
            0.4999999999999999,
            0.049999999999999996,
            0.45000000000000007,
            0.4999999999999999,
            0.049999999999999996,
            0.36000000000000004,
            0.5999999999999999,
            0.039999999999999994
        ]
    );
    assert_eq!(
        fields.success_grade_counts,
        vec![3, 0, 1, 0, 1, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    );

    // Without samples: the default seconds and fallback shares.
    let (_, empty) = workload::review_model(&[]);
    assert_eq!(empty.seconds, std::array::from_fn(|_| vec![8.0; 20]));
    assert_eq!(empty.sample_counts, vec![0; 20]);
    assert_eq!(empty.coeffs, [[8.0, 0.0, 0.0, 0.0, 0.0]; 4]);
    assert_eq!(empty.grade_weights, [0.25; 4]);
    assert_eq!(
        empty.success_grade_probs,
        vec![
            0.10000000000000002,
            0.5499999999999999,
            0.35000000000000003,
            0.1,
            0.55,
            0.35,
            0.16666666666666657,
            0.48333333333333345,
            0.35,
            0.2777777777777778,
            0.42222222222222244,
            0.2999999999999998,
            0.38888888888888873,
            0.5111111111111112,
            0.10000000000000009,
            0.45,
            0.5,
            0.049999999999999996,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05000000000000001,
            0.45,
            0.5,
            0.049999999999999996,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45,
            0.5,
            0.05,
            0.45000000000000007,
            0.4999999999999999,
            0.049999999999999996,
            0.45000000000000007,
            0.4999999999999999,
            0.049999999999999996,
            0.45000000000000007,
            0.4999999999999999,
            0.049999999999999996
        ]
    );
    assert_eq!(empty.success_grade_counts, vec![0; 20]);
}

#[test]
fn py_sum_compensates_like_python() {
    // sum([0.1] * 10) == 1.0 and sum([1e16, 1.0, -1e16]) == 1.0 in Python 3.12+.
    assert_eq!(workload::py_sum([0.1; 10]), 1.0);
    assert_eq!(workload::py_sum([1e16, 1.0, -1e16]), 1.0);
    assert_ne!([0.1f64; 10].iter().sum::<f64>(), 1.0);
}

#[test]
fn rwkv_workload_runs_on_the_resident_state() {
    let Some(fx) = fixture_with_new("workload", 8, 4) else {
        return;
    };
    let mut engine = Engine::default();
    prepare(&mut engine, &fx, None);
    let queries = all_queries(&fx);
    let before = engine.predict_many(&queries).unwrap();
    let request = |sample_limit| workload::WorkloadRequest {
        search: "deck:current".into(),
        days_to_simulate: 30,
        review_limit: 100,
        new_limit: 2,
        max_interval: 36500,
        sample_limit,
        target_step: 10,
        state_update_interval: 1,
        ..Default::default()
    };
    let full = engine.simulate_workload(&fx.backend, request(0)).unwrap();
    // No recorded predictions here, so the desktop's default answer times.
    assert_eq!(full.review_time_r_bucket_count, 20);
    assert_eq!(full.review_time_s_bucket_count, 1);
    assert_eq!(full.review_time_again_seconds, vec![8.0; 20]);
    assert_eq!(full.review_time_easy_coeffs, vec![8.0, 0.0, 0.0, 0.0, 0.0]);
    assert_eq!(full.review_time_grade_weights, vec![0.25; 4]);
    assert_eq!(full.review_time_transition_probs, vec![0.25; 16]);
    assert_eq!(full.review_time_success_grade_probs.len(), 60);
    assert_eq!(full.review_time_success_grade_counts, vec![0; 20]);
    let drs: Vec<u32> = full.points.iter().map(|p| p.dr).collect();
    assert_eq!(drs.first(), Some(&30));
    assert!(drs.windows(2).all(|w| w[0] < w[1]));
    assert!(full
        .points
        .iter()
        .all(|p| p.cost >= 0.0 && p.memorized >= 0.0));
    assert!(full
        .points
        .windows(2)
        .all(|w| w[0].review_count <= w[1].review_count));
    assert!(full.points.iter().any(|p| p.review_count > 0));
    // The resident state is unchanged.
    assert_same_predictions(&before, &engine.predict_many(&queries).unwrap());

    // Sampling scales the result back up to the whole deck.
    let sampled = engine.simulate_workload(&fx.backend, request(6)).unwrap();
    assert_eq!(sampled.points.len(), full.points.len());
}
