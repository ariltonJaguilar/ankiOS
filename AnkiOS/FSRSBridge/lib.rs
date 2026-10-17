use fsrs::{
    check_and_fill_parameters, compute_parameters, evaluate_with_time_series_splits,
    extract_simulator_config, simulate, Card, ComputeParametersInput, FSRSItem,
    FSRSReview, RevlogEntry, RevlogReviewKind,
};
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

#[derive(Deserialize)]
struct Input {
    items: Vec<Item>,
    #[serde(default = "default_true")]
    enable_short_term: bool,
    num_relearning_steps: Option<usize>,
    #[serde(default)]
    health_check: bool,
}

#[derive(Deserialize)]
struct Item {
    card_id: i64,
    reviews: Vec<Review>,
}

#[derive(Deserialize)]
struct Review {
    rating: u32,
    delta_t: u32,
}

fn default_true() -> bool { true }

#[derive(Serialize)]
struct Output {
    parameters: Vec<f32>,
    health: Option<Health>,
}

#[derive(Serialize)]
struct Health {
    log_loss: f32,
    rmse_bins: f32,
}

#[derive(Deserialize)]
struct SimulationInput {
    parameters: Vec<f32>,
    retention: f32,
    day_cutoff: i64,
    deck_size: usize,
    days: usize,
    new_per_day: usize,
    max_reviews_per_day: usize,
    new_cards_ignore_review_limit: bool,
    max_interval: f32,
    learning_step_count: usize,
    relearning_step_count: usize,
    cards: Vec<SimulationCard>,
    revlogs: Vec<SimulationRevlog>,
}

#[derive(Deserialize)]
struct SimulationCard {
    id: i64,
    difficulty: f32,
    stability: f32,
    last_date: Option<f32>,
    due: f32,
    interval: f32,
    lapses: u32,
    desired_retention: f32,
}

#[derive(Deserialize)]
struct SimulationRevlog {
    id: i64,
    cid: i64,
    usn: i32,
    button_chosen: u8,
    interval: i32,
    last_interval: i32,
    ease_factor: u32,
    taken_millis: u32,
    review_kind: u8,
}

#[derive(Serialize)]
struct SimulationOutput {
    days: Vec<SimulationDay>,
}

#[derive(Serialize)]
struct SimulationDay {
    day: usize,
    reviews: usize,
    learned: usize,
    study_seconds: f32,
    memorized: f32,
}

#[no_mangle]
pub unsafe extern "C" fn ankios_fsrs_compute_parameters(input: *const c_char) -> *mut c_char {
    if input.is_null() { return std::ptr::null_mut(); }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let raw = CStr::from_ptr(input).to_str().map_err(|e| e.to_string())?;
        let input: Input = serde_json::from_str(raw).map_err(|e| e.to_string())?;
        let card_ids: Vec<i64> = input.items.iter().map(|item| item.card_id).collect();
        let train_set: Vec<FSRSItem> = input.items.into_iter().map(|item| FSRSItem {
            reviews: item.reviews.into_iter().map(|review| FSRSReview {
                rating: review.rating,
                delta_t: review.delta_t,
            }).collect(),
        }).collect();
        let parameters = compute_parameters(ComputeParametersInput {
            train_set: train_set.clone(),
            card_ids: Some(card_ids.clone()),
            enable_short_term: input.enable_short_term,
            num_relearning_steps: input.num_relearning_steps,
            ..Default::default()
        }).map_err(|e| e.to_string())?;
        let health = if input.health_check {
            evaluate_with_time_series_splits(ComputeParametersInput {
                train_set,
                card_ids: Some(card_ids),
                enable_short_term: input.enable_short_term,
                num_relearning_steps: input.num_relearning_steps,
                ..Default::default()
            }, |_| true).ok().map(|result| Health {
                log_loss: result.log_loss,
                rmse_bins: result.rmse_bins,
            })
        } else {
            None
        };
        serde_json::to_string(&Output { parameters, health }).map_err(|e| e.to_string())
    }));
    let output = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => format!("{{\"error\":{}}}", serde_json::to_string(&error).unwrap_or_else(|_| "\"optimizer error\"".into())),
        Err(_) => "{\"error\":\"optimizer panic\"}".to_string(),
    };
    CString::new(output).map_or(std::ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn ankios_fsrs_free_string(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[no_mangle]
pub unsafe extern "C" fn ankios_fsrs_simulate(input: *const c_char) -> *mut c_char {
    if input.is_null() { return std::ptr::null_mut(); }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let raw = CStr::from_ptr(input).to_str().map_err(|e| e.to_string())?;
        let input: SimulationInput = serde_json::from_str(raw).map_err(|e| e.to_string())?;
        let parameters = check_and_fill_parameters(&input.parameters).map_err(|e| e.to_string())?;
        let shared_parameters = std::sync::Arc::new(parameters.clone());
        let revlogs = input.revlogs.into_iter().map(|entry| RevlogEntry {
            id: entry.id,
            cid: entry.cid,
            usn: entry.usn,
            button_chosen: entry.button_chosen,
            interval: entry.interval,
            last_interval: entry.last_interval,
            ease_factor: entry.ease_factor,
            taken_millis: entry.taken_millis,
            review_kind: match entry.review_kind {
                1 => RevlogReviewKind::Review,
                2 => RevlogReviewKind::Relearning,
                3 => RevlogReviewKind::Filtered,
                4 => RevlogReviewKind::Manual,
                _ => RevlogReviewKind::Learning,
            },
        }).collect();
        let mut config = extract_simulator_config(revlogs, input.day_cutoff, true);
        config.deck_size = input.deck_size;
        config.learn_span = input.days;
        config.learn_limit = input.new_per_day;
        config.review_limit = input.max_reviews_per_day;
        config.new_cards_ignore_review_limit = input.new_cards_ignore_review_limit;
        config.max_ivl = input.max_interval;
        config.learning_step_count = input.learning_step_count;
        config.relearning_step_count = input.relearning_step_count;
        let cards = input.cards.into_iter().map(|card| Card {
            id: card.id,
            difficulty: card.difficulty,
            stability: card.stability,
            last_date: card.last_date.unwrap_or(f32::NEG_INFINITY),
            due: card.due,
            interval: card.interval,
            lapses: card.lapses,
            desired_retention: card.desired_retention,
            parameters: shared_parameters.clone(),
        }).collect();
        let result = simulate(&config, &shared_parameters, input.retention, Some(42), Some(cards))
            .map_err(|e| e.to_string())?;
        let days = (0..config.learn_span).map(|index| SimulationDay {
            day: index + 1,
            reviews: result.review_cnt_per_day.get(index).copied().unwrap_or(0),
            learned: result.learn_cnt_per_day.get(index).copied().unwrap_or(0),
            study_seconds: result.cost_per_day.get(index).copied().unwrap_or(0.0),
            memorized: result.memorized_cnt_per_day.get(index).copied().unwrap_or(0.0),
        }).collect();
        serde_json::to_string(&SimulationOutput { days }).map_err(|e| e.to_string())
    }));
    let output = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => format!("{{\"error\":{}}}", serde_json::to_string(&error).unwrap_or_else(|_| "\"simulation error\"".into())),
        Err(_) => "{\"error\":\"simulation panic\"}".to_string(),
    };
    CString::new(output).map_or(std::ptr::null_mut(), CString::into_raw)
}
