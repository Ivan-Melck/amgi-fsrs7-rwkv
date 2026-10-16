# RWKV: deliberate differences from the desktop

The RWKV code in `anki-bridge-rs/src/rwkv/` ports the desktop fork's
`qt/aqt/rwkv_scheduler.py` and aims to match it exactly. This file records the
places where it deliberately does not, and why, so nobody "fixes" them back.

## Synced reviews are always replayed

*Decided 2026-10-16.*

**Desktop:** after a sync, synced reviews older than 8 days are not replayed
(`ignoredReviewIds` in the state cache, cutoff
`_RWKV_STATE_CACHE_CHECKPOINT_MAX_AGE_MILLIS`). The desktop keeps its previous
state, warns that it left those reviews out, and suggests running Rebuild RWKV
State.

**iOS:** `history_params` in `mod.rs` never sets `ignored_review_ids`, so a sync
that brings in older reviews leads to a full replay. The result is what the
desktop's Rebuild RWKV State produces.

**Why:** skipping saves a replay, but it costs too much accuracy for what it
saves. Measured on a real 27,335-review, 4,193-review-card collection by
replaying the history in full and again with the skipped reviews left out:

| Reviews skipped | Cards reviewed in that period: mean / p90 R gap | Other cards: mean R gap | Due status differs (R above or below 90%) |
|---|---|---|---|
| 7 days | 8.9 / 20 points | 1.6 points | 6% of review cards |
| 14 days | 9.7 / 25 points | 2.2 points | 9% |
| 30 days | 12.9 / 31 points | 5.1 points | 16% |

Cards that weren't reviewed in that period also shift, because RWKV keeps state
shared across cards. A full replay of that history took a few seconds on a
desktop CPU.

**Consequence:** a device that studies for more than 8 days without syncing
leaves the two apps disagreeing until the desktop rebuilds. iOS is the exact
one.
