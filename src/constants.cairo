use alexandria_math::fast_power::fast_power;

const DECIMALS: u8 = 2;
const MIN_HF_WITH_DECIMALS: u16 = 120;
const UPPER_LIQUIDATE_HF_WITH_DECIMALS: u16 = 100;
const BORROW_LIMIT: u8 = 90; // 90%
const OPTIMAL_UTILIZATION_RATE: u8 = 65; // 65%
const BASE_INTEREST_RATE: u8 = 3; // 3 %
const RSLOPE_1: u8 = 25; // 25%
const RSLOPE_2: u8 = 80; // 80%
const YEAR_TIMESTAMPS: u32 = 31536000;
const THRESHOLD_LIQUIDATION: u8 = 80; // 80%

fn ten_pow_decimals() -> u128 {
    fast_power(10, DECIMALS.into())
}
