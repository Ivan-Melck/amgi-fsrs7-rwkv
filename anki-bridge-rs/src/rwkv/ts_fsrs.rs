//! The parts of ts-fsrs 5.3.2 (the build the Search Stats Extended add-on
//! vendors, ts-fsrs-a32fb5e15e2a4117ddb18bc9776969ef282a5e83) that its
//! `getMemorisedDays` uses: parameter migration and clipping, the forgetting
//! curve and `next_state`, in f64 with ts-fsrs' 8-decimal rounding, so the
//! stats screen's FSRS series equal the desktop's to the last digit.
//!
//! FSRS-7 here is ts-fsrs' single-trace model (stability and difficulty
//! only; the curve's fast trace is the stability and its difficulty 5), not
//! the fsrs crate's dual-trace one the fork schedules with.

/// `S_MIN`, `S_MAX`, `INIT_S_MAX`.
const S_MIN: f64 = 1e-4;
const S_MAX: f64 = 36_500.0;
const INIT_S_MAX: f64 = 100.0;
/// `FSRS5_DEFAULT_DECAY`.
const FSRS5_DEFAULT_DECAY: f64 = 0.5;
/// `W17_W18_Ceiling`.
const W17_W18_CEILING: f64 = 2.0;
/// `FSRS7_PARAM_LEN`, `LEGACY_FSRS7_PREVIEW_PARAM_LEN`.
const FSRS7_PARAM_LEN: usize = 34;
const LEGACY_FSRS7_PARAM_LEN: usize = 35;

/// `Math.round`: halves round up.
pub fn js_round(x: f64) -> f64 {
    let floor = x.floor();
    if x - floor >= 0.5 {
        floor + 1.0
    } else {
        floor
    }
}

/// `roundTo(num, decimals)`.
pub fn round_to(num: f64, decimals: i32) -> f64 {
    let factor = 10f64.powi(decimals);
    js_round(num * factor) / factor
}

/// `Math.exp`: V8's `base::ieee754::exp` (fdlibm's `e_exp.c`), which is not
/// always the platform libm's nearest double. The add-on sums some
/// unrounded `Math.exp` results, where an ulp shows.
pub fn js_exp(x: f64) -> f64 {
    // fdlibm's constants, by their bit patterns.
    const HALF: [f64; 2] = [0.5, -0.5];
    const O_THRESHOLD: f64 = f64::from_bits(0x4086_2E42_FEFA_39EF);
    const U_THRESHOLD: f64 = f64::from_bits(0xC087_4910_D52D_3051);
    const LN2_HI: f64 = f64::from_bits(0x3FE6_2E42_FEE0_0000);
    const LN2_LO: f64 = f64::from_bits(0x3DEA_39EF_3579_3C76);
    const INV_LN2: f64 = f64::from_bits(0x3FF7_1547_652B_82FE);
    const P1: f64 = f64::from_bits(0x3FC5_5555_5555_553E);
    const P2: f64 = f64::from_bits(0xBF66_C16C_16BE_BD93);
    const P3: f64 = f64::from_bits(0x3F11_566A_AF25_DE2C);
    const P4: f64 = f64::from_bits(0xBEBB_BD41_C5D2_6BF1);
    const P5: f64 = f64::from_bits(0x3E66_3769_72BE_A4D0);
    const E: f64 = std::f64::consts::E;
    const HUGE: f64 = 1.0e+300;
    const TWO_M1000: f64 = f64::from_bits(0x0170_0000_0000_0000);
    const TWO_1023: f64 = f64::from_bits(0x7FE0_0000_0000_0000);

    let high = (x.to_bits() >> 32) as u32;
    let sign = (high >> 31) as usize;
    let high = high & 0x7fff_ffff;
    let mut x = x;
    let (mut hi, mut lo, mut k) = (0.0, 0.0, 0i32);
    // Non-finite and out-of-range arguments.
    if high >= 0x4086_2E42 {
        if high >= 0x7ff0_0000 {
            if x.is_nan() {
                return x + x;
            }
            return if sign == 0 { x } else { 0.0 };
        }
        if x > O_THRESHOLD {
            return HUGE * HUGE;
        }
        if x < U_THRESHOLD {
            return TWO_M1000 * TWO_M1000;
        }
    }
    // Argument reduction.
    if high > 0x3fd6_2e42 {
        if high < 0x3FF0_A2B2 {
            if x == 1.0 {
                return E;
            }
            hi = x - [LN2_HI, -LN2_HI][sign];
            lo = [LN2_LO, -LN2_LO][sign];
            k = 1 - sign as i32 - sign as i32;
        } else {
            k = (INV_LN2 * x + HALF[sign]) as i32;
            let t = f64::from(k);
            hi = x - t * LN2_HI;
            lo = t * LN2_LO;
        }
        x = hi - lo;
    } else if high < 0x3e30_0000 {
        if HUGE + x > 1.0 {
            return 1.0 + x;
        }
    } else {
        k = 0;
    }
    let t = x * x;
    let two_pk = if k >= -1021 {
        f64::from_bits(u64::from((0x3ff0_0000 + (k << 20)) as u32) << 32)
    } else {
        f64::from_bits(u64::from((0x3ff0_0000 + ((k + 1000) << 20)) as u32) << 32)
    };
    let c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
    if k == 0 {
        return 1.0 - ((x * c) / (c - 2.0) - x);
    }
    let y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
    if k >= -1021 {
        if k == 1024 {
            return y * 2.0 * TWO_1023;
        }
        y * two_pk
    } else {
        y * two_pk * TWO_M1000
    }
}

/// `Math.max` / `Math.min`, which propagate NaN.
fn js_max(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.max(b)
    }
}

fn js_min(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.min(b)
    }
}

/// `clamp`.
fn clamp(value: f64, min: f64, max: f64) -> f64 {
    js_min(js_max(value, min), max)
}

/// `(+value.toFixed(8))` for the migration's values. `toFixed` picks the
/// integer `n` nearest to `value * 1e8` on the exact binary value, the larger
/// `n` (in magnitude) on a tie; `format!("{:.8}")` would round that tie to
/// even.
fn to_fixed_8(value: f64) -> f64 {
    // `toFixed` falls back to `ToString` from 1e21.
    if !value.is_finite() || value.abs() >= 1e21 {
        return value;
    }
    let bits = value.abs().to_bits();
    let biased = (bits >> 52) as i32;
    let fraction = bits & ((1 << 52) - 1);
    // |value| = mantissa * 2^exponent, exactly.
    let (mantissa, exponent) = if biased == 0 {
        (fraction, -1074)
    } else {
        (fraction | 1 << 52, biased - 1075)
    };
    // Below 1e21, `scaled` < 2^80 and a left shift is at most 17.
    let scaled = u128::from(mantissa) * 100_000_000;
    let n = if exponent >= 0 {
        scaled << exponent
    } else {
        let shift = exponent.unsigned_abs();
        if shift >= 128 {
            0
        } else {
            let floor = scaled >> shift;
            let rest = scaled - (floor << shift);
            if rest >= 1 << (shift - 1) {
                floor + 1
            } else {
                floor
            }
        }
    };
    let sign = if value < 0.0 { "-" } else { "" };
    // The unary `+`: the nearest double to n * 10^-8.
    format!("{sign}{n}e-8").parse().unwrap_or(value)
}

/// `CLAMP_PARAMETERS(w17_w18_ceiling, enable_short_term = true)`.
fn clamp_parameters(w17_w18_ceiling: f64) -> [(f64, f64); 21] {
    [
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (1.0, 10.0),
        (1e-3, 4.0),
        (1e-3, 4.0),
        (1e-3, 0.75),
        (0.0, 4.5),
        (0.0, 0.8),
        (1e-3, 3.5),
        (1e-3, 5.0),
        (1e-3, 0.25),
        (1e-3, 0.9),
        (0.0, 4.0),
        (0.0, 1.0),
        (1.0, 6.0),
        (0.0, w17_w18_ceiling),
        (0.0, w17_w18_ceiling),
        (0.01, 0.8),
        (0.1, 0.8),
    ]
}

/// `clipFsrs7Parameters`.
fn clip_fsrs7(parameters: &[f64]) -> Vec<f64> {
    let mut w = parameters.to_vec();
    let fixed: [(usize, f64, f64); 30] = [
        (4, 1.0, 10.0),
        (5, 1e-3, 4.0),
        (6, 0.1, 4.0),
        (7, 0.0, 4.0),
        (8, 0.0, 1.2),
        (9, 0.3, 3.0),
        (10, 0.01, 1.5),
        (11, 0.1, 1.0),
        (12, 0.0, 3.5),
        (13, 0.0, 1.0),
        (14, 1.0, 7.0),
        (15, 0.0, 4.0),
        (16, 0.0, 2.0),
        (17, 0.5, 6.0),
        (18, 1e-3, 1.5),
        (19, 1e-3, 1.0),
        (20, 0.0, 5.0),
        (21, 0.0, 1.0),
        (22, 1.0, 7.0),
        (23, 0.01, 0.25),
        (24, 0.01, 0.95),
        (25, 0.2, 0.85),
        (26, f64::NAN, 0.99),
        (27, 0.01, 1.0),
        (28, 0.1, 1.0),
        (29, 0.0, 0.9),
        (30, 0.1, 1.1),
        (31, 0.0, 1.0),
        (32, 0.0, 0.6),
        (33, 0.0, 0.6),
    ];
    w[0] = clamp(w[0], 1e-4, 50.0);
    w[1] = clamp(w[1], w[0], 100.0);
    w[2] = clamp(w[2], w[1], 100.0);
    w[3] = clamp(w[3], w[2], 100.0);
    for (i, min, max) in fixed {
        // w[26] = clamp(w[26], w[25], 0.99)
        let min = if i == 26 { w[25] } else { min };
        w[i] = clamp(w[i], min, max);
    }
    w
}

/// `clipLegacyFsrs7PreviewParameters`.
fn clip_legacy_fsrs7(parameters: &[f64]) -> Vec<f64> {
    let mut w = parameters.to_vec();
    w[0] = clamp(w[0], 1e-3, 50.0);
    w[1] = clamp(w[1], w[0], 100.0);
    w[2] = clamp(w[2], w[1], 100.0);
    w[3] = clamp(w[3], w[2], 100.0);
    let fixed: [(usize, f64, f64); 31] = [
        (4, 1.0, 10.0),
        (5, 1e-3, 4.0),
        (6, 0.1, 4.0),
        (7, 0.0, 4.0),
        (8, 0.0, 1.2),
        (9, 0.3, 3.0),
        (10, 0.01, 1.5),
        (11, 1e-3, 0.9),
        (12, 0.1, 1.0),
        (13, 0.0, 3.5),
        (14, 0.0, 1.0),
        (15, 1.0, 7.0),
        (16, 0.0, 4.0),
        (17, 0.0, 2.0),
        (18, 0.5, 6.0),
        (19, 1e-3, 1.5),
        (20, 1e-3, 2.0),
        (21, 1e-3, 1.0),
        (22, 0.0, 5.0),
        (23, 0.0, 1.0),
        (24, 1.0, 7.0),
        (25, 2.5, 15.0),
        (26, 0.0, 1.0),
        (27, 0.01, 0.25),
        (28, f64::NAN, 0.95),
        (29, 0.5, 0.85),
        (30, f64::NAN, 0.99),
        (31, 0.01, 1.0),
        (32, 0.1, 1.0),
        (33, 0.0, 0.9),
        (34, 0.1, 1.1),
    ];
    for (i, min, max) in fixed {
        // w[28] >= w[27], w[30] >= w[29].
        let min = match i {
            28 => w[27],
            30 => w[29],
            _ => min,
        };
        w[i] = clamp(w[i], min, max);
    }
    w
}

/// `clipParameters(parameters, 1, true)`.
fn clip_parameters(parameters: &[f64]) -> Vec<f64> {
    match parameters.len() {
        FSRS7_PARAM_LEN => clip_fsrs7(parameters),
        LEGACY_FSRS7_PARAM_LEN => clip_legacy_fsrs7(parameters),
        len => {
            // One relearning step keeps the default ceiling.
            let bounds = clamp_parameters(W17_W18_CEILING);
            bounds[..len.min(bounds.len())]
                .iter()
                .enumerate()
                .map(|(i, (min, max))| {
                    // `parameters[index] || 0`
                    let value = parameters.get(i).copied().unwrap_or(0.0);
                    let value = if value == 0.0 || value.is_nan() {
                        0.0
                    } else {
                        value
                    };
                    clamp(value, *min, *max)
                })
                .collect()
        }
    }
}

/// `migrateParameters(parameters, 1, true)`: one relearning step
/// (`default_relearning_steps`), short-term scheduling on.
fn migrate_parameters(parameters: &[f64]) -> Option<Vec<f64>> {
    Some(match parameters.len() {
        34 | 35 | 21 => clip_parameters(parameters),
        19 => {
            let mut w = clip_parameters(parameters);
            w.extend([0.0, FSRS5_DEFAULT_DECAY]);
            w
        }
        17 => {
            let mut w = clip_parameters(parameters);
            w[4] = to_fixed_8(w[5] * 2.0 + w[4]);
            w[5] = to_fixed_8((w[5] * 3.0 + 1.0).ln() / 3.0);
            w[6] = to_fixed_8(w[6] + 0.5);
            w.extend([0.0, 0.0, 0.0, FSRS5_DEFAULT_DECAY]);
            w
        }
        // ts-fsrs falls back to its defaults; `checkParameters` rejects
        // these lengths first.
        _ => return None,
    })
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Version {
    Six,
    Seven,
    LegacySeven,
}

/// `FSRSState`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct State {
    pub stability: f64,
    pub difficulty: f64,
}

/// `fsrs(generatorParameters({ w, enable_fuzz: false, enable_short_term:
/// true }))`, as `getFsrs` builds it.
#[derive(Clone, Debug)]
pub struct TsFsrs {
    w: Vec<f64>,
    version: Version,
}

impl TsFsrs {
    /// `paramsForTsFsrs`, `checkParameters`, then `generatorParameters`
    /// twice: once by `getFsrs`, once more by the `FSRS` constructor, which
    /// migrates the already migrated weights again (FSRS-4.5/5's padded
    /// w[19] = 0 is clipped to 0.01 then).
    pub fn new(params: &[f32]) -> Result<Self, String> {
        // `paramsForTsFsrs` pads final FSRS-7 weights only for a ts-fsrs
        // whose `default_w_fsrs7` has 35; this build's has 34.
        let params: Vec<f64> = params.iter().map(|w| f64::from(*w)).collect();
        if params.iter().any(|w| w.is_infinite()) {
            return Err(format!("Non-finite or NaN value in parameters {params:?}"));
        }
        if ![17, 19, 21, 34, 35].contains(&params.len()) {
            return Err(format!(
                "Invalid parameter length: {}. Must be 17, 19, 21, 34 or legacy 35 for FSRSv4, 5, 6 and 7 respectively.",
                params.len()
            ));
        }
        let w = migrate_parameters(&params)
            .and_then(|w| migrate_parameters(&w))
            .ok_or("invalid parameters")?;
        let version = match w.len() {
            LEGACY_FSRS7_PARAM_LEN => Version::LegacySeven,
            FSRS7_PARAM_LEN => Version::Seven,
            _ => Version::Six,
        };
        Ok(Self { w, version })
    }

    #[cfg(test)]
    pub fn weights(&self) -> &[f64] {
        &self.w
    }

    fn is_fsrs7(&self) -> bool {
        self.version != Version::Six
    }

    /// `forgetting_curve(w, elapsed_days, stability)`.
    pub fn forgetting_curve(&self, elapsed_days: f64, stability: f64) -> f64 {
        let w = &self.w;
        match self.version {
            Version::LegacySeven => {
                let s = js_max(stability, S_MIN);
                let t_over_s = js_max(0.0, elapsed_days) / s;
                let decay1 = -w[27];
                let decay2 = -w[28];
                let factor1 = w[29].powf(1.0 / decay1) - 1.0;
                let factor2 = w[30].powf(1.0 / decay2) - 1.0;
                let r1 = (1.0 + factor1 * t_over_s).powf(decay1);
                let r2 = (1.0 + factor2 * t_over_s).powf(decay2);
                let weight1 = w[31] * s.powf(-w[33]);
                let weight2 = w[32] * s.powf(w[34]);
                round_to((weight1 * r1 + weight2 * r2) / (weight1 + weight2), 8)
            }
            Version::Seven => {
                let s = js_max(stability, S_MIN);
                let t = js_max(0.0, elapsed_days);
                let s_fast = s;
                let difficulty = 5.0;
                let decay1 = -clamp(w[23] * s_fast.powf(w[33] - 0.3), 0.01, 0.95);
                let factor1 = js_min(w[25].ln() / decay1, 60.0).exp() - 1.0;
                let r1 = (1.0 + factor1 * (t / s_fast)).powf(decay1);
                let decay2 = -clamp(w[24], 0.01, 0.95);
                let factor2 = w[26].powf(1.0 / decay2) - 1.0;
                let d_timescale = ((difficulty - 5.0) * (w[32] - 0.3)).exp();
                let r2 = (1.0 + factor2 * d_timescale * (t / s)).powf(decay2);
                let weight1 = w[27] * s_fast.powf(-w[29]);
                let weight2 = w[28] * s.powf(w[30]) * ((difficulty - 5.0) * (w[31] - 0.5)).exp();
                let retention = (weight1 * r1 + weight2 * r2) / (weight1 + weight2);
                round_to(retention * (1.0 - 2e-5) + 1e-5, 8)
            }
            Version::Six => {
                // `computeDecayFactor`
                let decay = -w[20];
                let factor = round_to((decay.powi(-1) * 0.9f64.ln()).exp() - 1.0, 8);
                round_to((1.0 + factor * elapsed_days / stability).powf(decay), 8)
            }
        }
    }

    /// `init_stability`.
    fn init_stability(&self, g: u32) -> f64 {
        let floor = if self.is_fsrs7() { S_MIN } else { 0.1 };
        js_max(self.w[g as usize - 1], floor)
    }

    /// `init_difficulty`.
    fn init_difficulty(&self, g: u32) -> f64 {
        let w = &self.w;
        round_to(w[4] - ((f64::from(g) - 1.0) * w[5]).exp() + 1.0, 8)
    }

    /// `linear_damping`.
    fn linear_damping(delta_d: f64, old_d: f64) -> f64 {
        round_to(delta_d * (10.0 - old_d) / 9.0, 8)
    }

    /// `next_difficulty`.
    fn next_difficulty(&self, d: f64, g: u32) -> f64 {
        let delta_d = -self.w[6] * (f64::from(g) - 3.0);
        let next_d = d + Self::linear_damping(delta_d, d);
        // `mean_reversion`
        let init = self.init_difficulty(4);
        clamp(
            round_to(self.w[7] * init + (1.0 - self.w[7]) * next_d, 8),
            1.0,
            10.0,
        )
    }

    /// `fsrs7_next_difficulty` and `legacyFsrs7PreviewNextDifficulty`
    /// (without the retrievability factor).
    fn fsrs7_next_difficulty(&self, d: f64, g: u32, r: Option<f64>) -> f64 {
        let mut delta_d = -self.w[6] * (f64::from(g) - 3.0);
        if let (1, Some(r)) = (g, r) {
            delta_d *= r + 0.1;
        }
        let next_d = d + Self::linear_damping(delta_d, d);
        // `fsrs7_mean_reversion`
        let init = self.init_difficulty(4);
        clamp(round_to(0.01 * init + 0.99 * next_d, 8), 1.0, 10.0)
    }

    /// `fsrs7_stability_for_set`.
    fn fsrs7_stability_for_set(&self, d: f64, s: f64, r: f64, g: u32, start: usize) -> f64 {
        let w = &self.w;
        let hard_penalty = if g == 2 { w[start + 6] } else { 1.0 };
        let easy_bonus = if g == 4 { w[start + 7] } else { 1.0 };
        let new_s_fail =
            w[start + 3] * ((s + 1.0).powf(w[start + 4]) - 1.0) * ((1.0 - r) * w[start + 5]).exp();
        let pls = js_min(s, new_s_fail);
        let sinc = (w[start] - 1.5).exp()
            * (11.0 - d)
            * s.powf(-w[start + 1])
            * (((1.0 - r) * w[start + 2]).exp() - 1.0)
            * hard_penalty
            * easy_bonus
            + 1.0;
        let new_s_success = js_max(pls, s * sinc);
        if g > 1 {
            new_s_success
        } else {
            pls
        }
    }

    /// `legacyFsrs7PreviewStabilityForSet`.
    fn legacy_stability_for_set(&self, d: f64, s: f64, r: f64, g: u32, start: usize) -> f64 {
        let w = &self.w;
        let hard_penalty = if g == 2 { w[start + 7] } else { 1.0 };
        let easy_bonus = if g == 4 { w[start + 8] } else { 1.0 };
        let new_s_fail = w[start + 3]
            * d.powf(-w[start + 4])
            * ((s + 1.0).powf(w[start + 5]) - 1.0)
            * ((1.0 - r) * w[start + 6]).exp();
        let pls = js_min(s, new_s_fail);
        let sinc = (w[start] - 1.5).exp()
            * (11.0 - d)
            * s.powf(-w[start + 1])
            * (((1.0 - r) * w[start + 2]).exp() - 1.0)
            * hard_penalty
            * easy_bonus
            + 1.0;
        let new_s_success = js_max(pls, s * sinc);
        if g > 1 {
            new_s_success
        } else {
            pls
        }
    }

    /// `next_recall_stability`.
    fn next_recall_stability(&self, d: f64, s: f64, r: f64, g: u32) -> f64 {
        let w = &self.w;
        let hard_penalty = if g == 2 { w[15] } else { 1.0 };
        let easy_bound = if g == 4 { w[16] } else { 1.0 };
        round_to(
            clamp(
                s * (1.0
                    + w[8].exp()
                        * (11.0 - d)
                        * s.powf(-w[9])
                        * (((1.0 - r) * w[10]).exp() - 1.0)
                        * hard_penalty
                        * easy_bound),
                S_MIN,
                36_500.0,
            ),
            8,
        )
    }

    /// `next_forget_stability`.
    fn next_forget_stability(&self, d: f64, s: f64, r: f64) -> f64 {
        let w = &self.w;
        round_to(
            clamp(
                w[11] * d.powf(-w[12]) * ((s + 1.0).powf(w[13]) - 1.0) * ((1.0 - r) * w[14]).exp(),
                S_MIN,
                36_500.0,
            ),
            8,
        )
    }

    /// `next_short_term_stability`.
    fn next_short_term_stability(&self, s: f64, g: u32) -> f64 {
        let w = &self.w;
        let sinc = s.powf(-w[19]) * (w[17] * (f64::from(g) - 3.0 + w[18])).exp();
        let masked = if g >= 2 { js_max(sinc, 1.0) } else { sinc };
        round_to(clamp(s * masked, S_MIN, 36_500.0), 8)
    }

    /// `next_state(memory_state, t, g)`, with short-term scheduling on.
    pub fn next_state(&self, state: Option<State>, t: f64, g: u32) -> Result<State, String> {
        let State {
            difficulty: d,
            stability: s,
        } = state.unwrap_or(State {
            difficulty: 0.0,
            stability: 0.0,
        });
        if t < 0.0 {
            return Err(format!("Invalid delta_t \"{t}\""));
        }
        if g > 4 {
            return Err(format!("Invalid grade \"{g}\""));
        }
        if d == 0.0 && s == 0.0 {
            return Ok(State {
                difficulty: clamp(self.init_difficulty(g), 1.0, 10.0),
                stability: self.init_stability(g),
            });
        }
        if g == 0 {
            return Ok(State {
                difficulty: d,
                stability: s,
            });
        }
        if d < 1.0 || s < S_MIN {
            return Err(format!(
                "Invalid memory state {{ difficulty: {d}, stability: {s} }}"
            ));
        }
        let r = self.forgetting_curve(t, s);
        let (new_s, new_d) = match self.version {
            Version::LegacySeven => {
                let long_term = self.legacy_stability_for_set(d, s, r, g, 7);
                let short_term = self.legacy_stability_for_set(d, s, r, g, 16);
                let coefficient = 1.0 - self.w[26] * (-self.w[25] * t).exp();
                (
                    coefficient * long_term + (1.0 - coefficient) * short_term,
                    self.fsrs7_next_difficulty(d, g, None),
                )
            }
            Version::Seven => (
                self.fsrs7_stability_for_set(d, s, r, g, 7),
                self.fsrs7_next_difficulty(d, g, Some(r)),
            ),
            Version::Six => {
                let new_s = if t == 0.0 {
                    self.next_short_term_stability(s, g)
                } else if g == 1 {
                    let s_after_fail = self.next_forget_stability(d, s, r);
                    let next_s_min = s / (self.w[17] * self.w[18]).exp();
                    clamp(round_to(next_s_min, 8), S_MIN, s_after_fail)
                } else {
                    self.next_recall_stability(d, s, r, g)
                };
                (new_s, self.next_difficulty(d, g))
            }
        };
        Ok(State {
            difficulty: clamp(round_to(new_d, 8), 1.0, 10.0),
            stability: clamp(round_to(new_s, 8), S_MIN, S_MAX),
        })
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod test {
    use super::*;

    /// The add-on's test weights (test/memorised.test.ts), ts-fsrs'
    /// `default_w`, and the add-on's FSRS-7 and legacy preview weights.
    const W5: [f32; 19] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ];
    const W6: [f32; 21] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ];
    const W7: [f32; 34] = [
        0.1104, 2.2395, 3.9221, 11.7841, 6.1686, 0.6457, 3.6807, 1.9795, 0.0, 1.3826, 0.7024,
        0.5999, 0.8146, 0.6398, 1.0, 1.3207, 0.6707, 3.8668, 0.4416, 0.0934, 1.8631, 0.6162,
        1.0869, 0.1567, 0.0801, 0.2421, 0.9464, 0.1433, 0.7145, 0.0, 0.5667, 0.3734, 0.5333,
        0.3048,
    ];
    const WL: [f32; 35] = [
        0.041, 2.4175, 4.1283, 11.9709, 5.6385, 0.4468, 3.262, 2.3054, 0.1688, 1.3325, 0.3524,
        0.0049, 0.7503, 0.0896, 0.6625, 1.3, 0.882, 0.3072, 3.5875, 0.303, 0.0107, 0.2279, 2.6413,
        0.5594, 1.3, 2.5, 1.0, 0.0723, 0.1634, 0.5, 0.9555, 0.2245, 0.6232, 0.1362, 0.3862,
    ];

    /// (elapsed days, grade); the first review starts the card.
    const REVIEWS: [(f64, u32); 8] = [
        (0.0, 3),
        (0.0, 3),
        (1.0, 1),
        (0.0, 3),
        (3.0, 3),
        (9.0, 2),
        (21.0, 4),
        (60.0, 1),
    ];

    /// Expected (stability, difficulty) after each review and the curve of
    /// the last state at 0, 1, 10 and 100 days: the vendored ts-fsrs'
    /// `next_state` / `forgetting_curve`, transcribed line by line and run
    /// in f64.
    fn check(params: &[f32], states: [(f64, f64); 8], curve: [f64; 4]) {
        let fsrs = TsFsrs::new(params).unwrap();
        let mut state = None;
        for ((t, g), (stability, difficulty)) in REVIEWS.iter().zip(states) {
            let next = fsrs.next_state(state, *t, *g).unwrap();
            assert_eq!(
                next,
                State {
                    stability,
                    difficulty
                },
                "after ({t}, {g})"
            );
            state = Some(next);
        }
        let last = state.unwrap().stability;
        for (t, r) in [0.0, 1.0, 10.0, 100.0].into_iter().zip(curve) {
            assert_eq!(fsrs.forgetting_curve(t, last), r, "R at {t}");
        }
    }

    #[test]
    fn fsrs45_matches_ts_fsrs() {
        check(
            &W5[..17],
            [
                (3.1730000972747803, 7.37138915),
                (3.1730001, 7.3681186),
                (0.8875127, 8.5061534),
                (0.88857242, 8.49766293),
                (4.0003546, 8.48921152),
                (5.98710223, 8.8083685),
                (50.97037886, 8.54011802),
                (4.41426221, 9.16453524),
            ],
            [1.0, 0.97444476, 0.80808604, 0.39797187],
        );
    }

    #[test]
    fn fsrs5_matches_ts_fsrs() {
        check(
            &W5,
            [
                (3.1730000972747803, 5.28243444),
                (4.41557708, 5.27296795),
                (1.11078176, 6.79056769),
                (1.56208455, 6.77416379),
                (7.10656759, 6.75783534),
                (10.53681026, 7.26525722),
                (91.69177974, 6.80495344),
                (5.18362348, 7.82061273),
            ],
            [1.0, 0.97811418, 0.82973489, 0.42542899],
        );
    }

    #[test]
    fn fsrs6_matches_ts_fsrs() {
        check(
            &W6,
            [
                (2.30649995803833, 2.11810389),
                (2.30649996, 2.11121415),
                (0.57141346, 7.39223789),
                (0.62291714, 7.38007402),
                (3.8990788, 7.36792231),
                (10.16356911, 8.2379325),
                (41.07795263, 7.63436005),
                (2.70518616, 9.20765854),
            ],
            [1.0, 0.95343362, 0.78968692, 0.57246794],
        );
    }

    #[test]
    fn fsrs7_matches_ts_fsrs() {
        check(
            &W7,
            [
                (3.922100067138672, 3.53072422),
                (3.92275431, 3.49771699),
                (1.19644461, 8.85900115),
                (1.19650182, 8.77271115),
                (2.58123194, 8.68728405),
                (4.37842688, 9.13419973),
                (8.22564415, 8.69461511),
                (2.29615982, 9.5681722),
            ],
            [0.99999, 0.89427367, 0.79885788, 0.67110718],
        );
    }

    #[test]
    fn legacy_fsrs7_preview_matches_ts_fsrs() {
        check(
            &WL,
            [
                (4.128300189971924, 4.19458833),
                (4.12830019, 4.18082174),
                (0.79275041, 8.343268),
                (0.79275041, 8.28801461),
                (2.71927663, 8.23331375),
                (5.38917192, 8.81308227),
                (12.34545547, 8.3272409),
                (2.12201133, 9.47258665),
            ],
            [1.0, 0.8893494, 0.7793487, 0.58464993],
        );
    }

    #[test]
    fn migration_pads_and_clips_like_the_fsrs_constructor() {
        // 19 weights get w19 = 0, then the constructor's second migration
        // clips it to 0.01.
        let w = TsFsrs::new(&W5).unwrap();
        assert_eq!(w.weights().len(), 21);
        assert_eq!(w.weights()[19..], [0.01, 0.5]);
        let w = TsFsrs::new(&W5[..17]).unwrap();
        assert_eq!(w.weights()[17..], [0.0, 0.0, 0.01, 0.5]);
        assert_eq!(TsFsrs::new(&W7).unwrap().weights().len(), 34);
        assert!(TsFsrs::new(&W5[..18]).is_err());
        assert!(TsFsrs::new(&[f32::INFINITY; 21]).is_err());
    }

    /// `toFixed(8)` rounds an exact binary tie up where `{:.8}` rounds it to
    /// even: w[6] = 1.001953125 migrates to 1.501953125, ts-fsrs' 1.50195313.
    #[test]
    fn fsrs45_migration_rounds_ties_like_to_fixed() {
        let mut w = W5;
        w[6] = 1.0 + 1.0 / 512.0;
        let fsrs = TsFsrs::new(&w[..17]).unwrap();
        assert_eq!(fsrs.weights()[6], 1.50195313);
        // ts-fsrs' `next_state` after (0, 3), (3, 1) with these weights; the
        // tie rounded to even (1.50195312) gives a difficulty of 8.24142732.
        let state = fsrs.next_state(None, 0.0, 3).unwrap();
        let state = fsrs.next_state(Some(state), 3.0, 1).unwrap();
        assert_eq!(
            state,
            State {
                stability: 1.017571,
                difficulty: 8.24142733
            }
        );
    }

    #[test]
    fn to_fixed_8_follows_javascript() {
        // Expected: node's `+x.toFixed(8)`.
        for (x, expected) in [
            (1.501953125, 1.50195313),
            (-1.501953125, -1.50195313),
            (0.001953125, 0.00195313),
            (1.0009765625, 1.00097656),
            (7.1949, 7.1949),
            (0.123456785, 0.12345678),
            (2.0, 2.0),
            (5e-324, 0.0),
            (1e21, 1e21),
        ] {
            assert_eq!(to_fixed_8(x).to_bits(), f64::to_bits(expected), "{x}");
        }
        assert_eq!(to_fixed_8(-1e-10).to_bits(), (-0.0f64).to_bits());
        assert!(to_fixed_8(f64::NAN).is_nan());
    }

    #[test]
    fn exp_follows_v8() {
        // Expected: node's `Math.exp`; the first four are an ulp off the
        // correctly rounded result.
        for (x, expected) in [
            (-0.20831489086058508, 0.8119513204026529),
            (-1.6770674730066657, 0.18692132492043112),
            (-0.8788072869891621, 0.4152779238020333),
            (-0.07720867624744941, 0.9256966625441874),
            (1.0, std::f64::consts::E),
            (0.0, 1.0),
            (-800.0, 0.0),
            (f64::NEG_INFINITY, 0.0),
            (f64::INFINITY, f64::INFINITY),
        ] {
            assert_eq!(js_exp(x).to_bits(), f64::to_bits(expected), "{x}");
        }
        assert!(js_exp(f64::NAN).is_nan());
    }

    #[test]
    fn grade_zero_and_invalid_states() {
        let fsrs = TsFsrs::new(&W6).unwrap();
        let state = State {
            stability: 3.0,
            difficulty: 5.0,
        };
        assert_eq!(fsrs.next_state(Some(state), 2.0, 0).unwrap(), state);
        assert!(fsrs.next_state(Some(state), -1.0, 3).is_err());
        let bad = State {
            stability: 3.0,
            difficulty: 0.5,
        };
        assert!(fsrs.next_state(Some(bad), 1.0, 3).is_err());
    }

    #[test]
    fn rounding_follows_javascript() {
        assert_eq!(js_round(2.5), 3.0);
        assert_eq!(js_round(-2.5), -2.0);
        assert_eq!(round_to(0.123456785, 8), 0.12345679);
        assert_eq!(round_to(1.0, 8), 1.0);
    }
}
