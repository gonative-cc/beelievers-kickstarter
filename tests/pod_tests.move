#[allow(unused_let_mut)]
module beelievers_kickstarter::pod_tests;

use beelievers_kickstarter::pod::{Self, GlobalSettings, PlatformAdminCap};
use std::ascii;
use sui::clock;
use sui::coin::mint_for_testing;
use sui::sui::SUI;
use sui::test_scenario::{Self, next_tx, ctx};

const DAY: u64 = 1000 * 60 * 60 * 24;
const HOUR: u64 = 1000 * 60 * 60;
const MINUTE: u64 = 1000 * 60;

// Helper functions for assertions
fun assert_u64_eq(a: u64, b: u64) {
    assert!(a == b, 0);
}

fun assert_u8_eq(a: u8, b: u8) {
    assert!(a == b, 0);
}

// ================================
// Platform Initialization Tests
// ================================

#[test]
fun test_platform_initialization() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    // Initialize module
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    // Verify GlobalSettings was created with correct defaults
    let settings = scenario.take_shared<GlobalSettings>();
    let (
        max_immediate_unlock_pm,
        min_vesting_duration,
        min_subscription_duration,
        pod_exit_fee_pm,
        pod_exit_small_fee_pm,
        small_fee_duration,
        cancel_subscription_keep,
    ) = pod::get_global_settings_pm(&settings);

    assert_u64_eq(max_immediate_unlock_pm, 80); // 8.0%
    assert_u64_eq(min_vesting_duration, DAY * 30 * 3); // 3 months
    assert_u64_eq(min_subscription_duration, DAY * 7); // 7 days
    assert_u64_eq(pod_exit_fee_pm, 80); // 8.0%
    assert_u64_eq(pod_exit_small_fee_pm, 8); // 0.8%
    assert_u64_eq(small_fee_duration, DAY * 14); // 14 days
    assert_u64_eq(cancel_subscription_keep, 1); // 0.1%
    test_scenario::return_shared(settings);

    // Verify PlatformAdminCap was created
    let admin_cap = scenario.take_from_sender<PlatformAdminCap>();
    test_scenario::return_to_sender(&scenario, admin_cap);

    test_scenario::end(scenario);
}

// ================================
// Settings Update Tests
// ================================

#[test]
fun test_update_all_settings() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    // Initialize
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let mut settings = scenario.take_shared<GlobalSettings>();
    let cap = scenario.take_from_sender<PlatformAdminCap>();

    // Update all settings
    pod::update_settings(
        &cap,
        &mut settings,
        option::some(100), // 10%
        option::some(DAY * 60), // 2 months
        option::some(DAY * 14), // 14 days
        option::some(90), // 9%
        option::some(10), // 1%
        option::some(DAY * 30), // 30 days
        option::some(2), // 0.2%
        ctx(&mut scenario),
    );

    // Verify updates
    let (
        max_immediate_unlock_pm,
        min_vesting_duration,
        min_subscription_duration,
        pod_exit_fee_pm,
        pod_exit_small_fee_pm,
        small_fee_duration,
        cancel_subscription_keep,
    ) = pod::get_global_settings_pm(&settings);

    assert_u64_eq(max_immediate_unlock_pm, 100);
    assert_u64_eq(min_vesting_duration, DAY * 60);
    assert_u64_eq(min_subscription_duration, DAY * 14);
    assert_u64_eq(pod_exit_fee_pm, 90);
    assert_u64_eq(pod_exit_small_fee_pm, 10);
    assert_u64_eq(small_fee_duration, DAY * 30);
    assert_u64_eq(cancel_subscription_keep, 2);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(settings);
    test_scenario::end(scenario);
}

#[test]
fun test_update_individual_settings() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let mut settings = scenario.take_shared<GlobalSettings>();
    let cap = scenario.take_from_sender<PlatformAdminCap>();

    // Update only one setting
    pod::update_settings(
        &cap,
        &mut settings,
        option::some(120),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        ctx(&mut scenario),
    );

    // Verify only max_immediate_unlock changed
    let (max_immediate_unlock_pm, _, _, pod_exit_fee_pm, _, _, _) = pod::get_global_settings_pm(
        &settings,
    );

    assert_u64_eq(max_immediate_unlock_pm, 120);
    assert_u64_eq(pod_exit_fee_pm, 80); // unchanged

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(settings);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_update_settings_zero_vesting_duration() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let mut settings = scenario.take_shared<GlobalSettings>();
    let cap = scenario.take_from_sender<PlatformAdminCap>();

    // Try to set vesting duration to 0 (should fail)
    pod::update_settings(
        &cap,
        &mut settings,
        option::none(),
        option::some(0),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        ctx(&mut scenario),
    );

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(settings);
    test_scenario::end(scenario);
}

// ================================
// Pod Creation Tests
// ================================

#[test]
fun test_create_pod_success() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    // Initialize
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    // Calculate required tokens
    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;

    // Mint tokens for the pod
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    let subscription_start = clock.timestamp_ms() + HOUR;
    let vesting_duration = DAY * 365;
    let immediate_unlock_pm = 80;

    // Create pod
    pod::create_pod<SUI, SUI>(
        &settings,
        b"My Project".to_string(),
        b"Great project".to_string(),
        ascii::string(b"https://forum.example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        subscription_start,
        DAY * 7,
        vesting_duration,
        immediate_unlock_pm,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Start new transaction to access created pod
    next_tx(&mut scenario, owner);

    // Verify pod exists and has correct parameters
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();

    let (
        pod_token_price,
        pod_price_multiplier,
        pod_min_goal,
        pod_max_goal,
        _,
        _,
        pod_vesting_duration,
        pod_immediate_unlock_pm,
        _,
    ) = pod::get_pod_params(&pod);

    assert_u64_eq(pod_token_price, token_price);
    assert_u64_eq(pod_price_multiplier, price_multiplier);
    assert_u64_eq(pod_min_goal, 500_000);
    assert_u64_eq(pod_max_goal, max_goal);
    assert_u64_eq(pod_vesting_duration, vesting_duration);
    assert_u64_eq(pod_immediate_unlock_pm, 80);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_create_pod_invalid_min_goal() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    // Try to create with min_goal = 0 (should fail)
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        0,
        max_goal,
        clock.timestamp_ms() + HOUR,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_create_pod_max_less_than_min() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    // max_goal < min_goal (should fail)
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        1_000_000,
        500_000,
        clock.timestamp_ms() + HOUR,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_create_pod_subscription_duration_too_short() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    // subscription_duration < min_subscription_duration (should fail)
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        clock.timestamp_ms() + HOUR,
        DAY * 3,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_create_pod_vesting_duration_too_short() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    // vesting_duration < min_vesting_duration (should fail)
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        clock.timestamp_ms() + HOUR,
        DAY * 7,
        DAY * 30,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_PARAMS)]
fun test_create_pod_immediate_unlock_too_high() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    // immediate_unlock_pm > max_immediate_unlock_pm (should fail)
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        clock.timestamp_ms() + HOUR,
        DAY * 7,
        DAY * 365,
        100, // 10% > 8% max (should fail)
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVALID_TOKEN_SUPPLY)]
fun test_create_pod_wrong_token_supply() {
    let owner = @0x1;
    let mut scenario = test_scenario::begin(owner);
    let ctx = ctx(&mut scenario);

    pod::init_for_tests(ctx);
    next_tx(&mut scenario, owner);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let _required_tokens = 100_000;

    // Provide less tokens (should fail)
    let tokens = mint_for_testing(90_000, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + HOUR,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ================================
// Investment Tests
// ================================

#[test]
fun test_successful_investment() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup: founder creates pod
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    let subscription_start = clock.timestamp_ms() + MINUTE;
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        subscription_start,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward to subscription period
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // Investor makes investment makes investment
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(100_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));

    // Verify no excess returned
    assert_u64_eq(excess.value(), 0);
    transfer::public_transfer(excess, @0x0);

    // Verify investment was recorded
    assert_u64_eq(pod::pod_total_allocated(&pod), (100_000 * price_multiplier) / token_price);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_POD_NOT_SUBSCRIPTION)]
fun test_invest_before_subscription() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    let subscription_start = clock.timestamp_ms() + HOUR;
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        subscription_start,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Try to invest before subscription starts (should fail)
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(100_000, ctx(&mut scenario));
    let _excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(_excess, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_max_goal_reached_early() {
    let founder = @0x1;
    let investor1 = @0x2;
    let investor2 = @0x3;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // First investment gets us close to max
    next_tx(&mut scenario, investor1);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment1 = mint_for_testing(900_000, ctx(&mut scenario));
    let excess1 = pod::invest<SUI, SUI>(&mut pod, investment1, &clock, ctx(&mut scenario));
    assert_u64_eq(excess1.value(), 0);
    transfer::public_transfer(excess1, @0x0);
    test_scenario::return_shared(pod);

    // Second investment exceeds max, excess returned
    next_tx(&mut scenario, investor2);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment2 = mint_for_testing(200_000, ctx(&mut scenario));
    let excess2 = pod::invest<SUI, SUI>(&mut pod, investment2, &clock, ctx(&mut scenario));

    // Should have 100_000 excess
    assert_u64_eq(excess2.value(), 100_000);
    let (_, _, _, _, _, pod_subscription_end, _, _, pod_total_raised) = pod::get_pod_params(&pod);
    assert_u64_eq(pod_total_raised, max_goal);
    assert_u64_eq(pod_subscription_end, clock.timestamp_ms());
    transfer::public_transfer(excess2, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_POD_NOT_SUBSCRIPTION)]
fun test_invest_after_max_goal() {
    let founder = @0x1;
    let investor1 = @0x2;
    let investor2 = @0x3;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // First investment reaches max
    next_tx(&mut scenario, investor1);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment1 = mint_for_testing(1_000_000, ctx(&mut scenario));
    let excess1 = pod::invest<SUI, SUI>(&mut pod, investment1, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess1, @0x0);
    test_scenario::return_shared(pod);

    // Second investment should fail
    next_tx(&mut scenario, investor2);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment2 = mint_for_testing(100_000, ctx(&mut scenario));
    let _excess = pod::invest<SUI, SUI>(&mut pod, investment2, &clock, ctx(&mut scenario));
    transfer::public_transfer(_excess, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_multiple_investments_same_investor() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let required_tokens = (1_000_000 * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        1_000_000,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // First investment
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment1 = mint_for_testing(100_000, ctx(&mut scenario));
    let excess1 = pod::invest<SUI, SUI>(&mut pod, investment1, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess1, @0x0);
    test_scenario::return_shared(pod);

    // Second investment from same investor
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment2 = mint_for_testing(50_000, ctx(&mut scenario));
    let excess2 = pod::invest<SUI, SUI>(&mut pod, investment2, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess2, @0x0);

    // Total should be combined
    let (_, _, _, _, _, _, _, _, pod_total_raised) = pod::get_pod_params(&pod);
    assert_u64_eq(pod_total_raised, 150_000);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_cancel_subscription() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let required_tokens = (1_000_000 * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        1_000_000,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // Investor invests
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(100_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);

    // Cancel subscription
    let refund = pod::cancel_subscription<SUI, SUI>(
        &mut pod,
        &settings,
        &clock,
        ctx(&mut scenario),
    );

    // Should get most of investment back (keep 0.1%)
    let kept = 100_000 / 1000;
    let expected_refund = 100_000 - kept;
    assert_u64_eq(refund.value(), expected_refund);
    transfer::public_transfer(refund, @0x0);

    // Total raised should be reduced
    let (_, _, _, _, _, _, _, _, pod_total_raised) = pod::get_pod_params(&pod);
    assert_u64_eq(pod_total_raised, kept);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pod::E_INVESTMENT_CANCELLED)]
fun test_cancel_subscription_only_once() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let required_tokens = (1_000_000 * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        1_000_000,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward
    next_tx(&mut scenario, founder);
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // Investor invests and cancels
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(100_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    let refund = pod::cancel_subscription<SUI, SUI>(
        &mut pod,
        &settings,
        &clock,
        ctx(&mut scenario),
    );
    transfer::public_transfer(refund, @0x0);
    test_scenario::return_shared(pod);

    // Try to cancel again (should fail)
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let _refund2 = pod::cancel_subscription<SUI, SUI>(
        &mut pod,
        &settings,
        &clock,
        ctx(&mut scenario),
    );
    transfer::public_transfer(_refund2, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ================================
// Vesting and Claiming Tests
// ================================

#[test]
fun test_calculate_vested_tokens() {
    let total_allocation = 1_000_000;
    let immediate_unlock_pm = 80; // 8%
    let vesting_duration = DAY * 365; // 1 year

    // At time 0, only immediate unlock is available
    let vested = pod::calculate_vested_tokens(
        0,
        vesting_duration,
        immediate_unlock_pm,
        total_allocation,
    );
    let immediate_unlock = pod::ratio_ext_pm(total_allocation, immediate_unlock_pm);
    assert_u64_eq(vested, immediate_unlock);

    // After 6 months (half vesting), should have 50% of remaining + immediate
    let half_vested = pod::calculate_vested_tokens(
        DAY * 182,
        vesting_duration,
        immediate_unlock_pm,
        total_allocation,
    );
    let expected =
        immediate_unlock + pod::ratio_ext(DAY * 182, total_allocation - immediate_unlock, vesting_duration);
    assert_u64_eq(half_vested, expected);

    // After full vesting period
    let fully_vested = pod::calculate_vested_tokens(
        DAY * 365,
        vesting_duration,
        immediate_unlock_pm,
        total_allocation,
    );
    // After full vesting, all tokens (including immediate unlock) are vested
    assert_u64_eq(fully_vested, total_allocation);
}

#[test]
fun test_investor_claim_tokens() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup: create pod and complete subscription
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    let subscription_start = clock.timestamp_ms() + MINUTE;
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        subscription_start,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward to just before subscription ends, then invest
    clock::increment_for_testing(&mut clock, DAY * 7);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(1_000_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward to vesting start, then claim
    clock::increment_for_testing(&mut clock, MINUTE);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();

    // Verify pod is now in vesting
    assert_u8_eq(pod::pod_status(&pod, &clock), 3);

    // Investor claims tokens
    let claimed_tokens = pod::investor_claim_tokens<SUI, SUI>(&mut pod, &clock, ctx(&mut scenario));
    // Investment: 1_000_000, Token allocation: 1_000_000 * 10 / 100 = 100_000 tokens
    // Immediate unlock (8%): 100_000 * 80 / 1000 = 8_000 tokens
    let immediate_unlock = 8_000;
    assert_u64_eq(claimed_tokens.value(), immediate_unlock);
    transfer::public_transfer(claimed_tokens, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_founder_claim_funds() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward to just before subscription ends, then invest
    clock::increment_for_testing(&mut clock, DAY * 7);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(1_000_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward past subscription end, then claim (time elapsed > 0)
    clock::increment_for_testing(&mut clock, MINUTE);
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();
    let claimed_funds = pod::founder_claim_funds<SUI, SUI>(
        &mut pod,
        &cap,
        &clock,
        ctx(&mut scenario),
    );

    // Should receive more than immediate unlock due to 1 minute of vesting
    // Investment: 1_000_000, immediate unlock: 80_000
    // With 1 minute elapsed in 365-day vesting: ~80,001
    let expected = 80_000;
    assert!(claimed_funds.value() >= expected, 0);
    transfer::public_transfer(claimed_funds, @0x0);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_withdraw_unallocated_tokens() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward and invest
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(500_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward to vesting
    clock::increment_for_testing(&mut clock, DAY * 7);

    // Founder withdraws unallocated tokens
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();

    let unallocated = pod::pod_token_vault_value(&pod) - pod::pod_total_allocated(&pod);
    let withdrawn = pod::withdraw_unallocated_tokens<SUI, SUI>(
        &mut pod,
        &cap,
        &clock,
        ctx(&mut scenario),
    );
    assert_u64_eq(withdrawn.value(), unallocated);
    transfer::public_transfer(withdrawn, @0x0);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ================================
// Exit Mechanism Tests
// ================================

#[test]
fun test_exit_during_small_fee_period() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup and complete subscription
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward and invest
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(1_000_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward to vesting (small fee period starts)
    clock::increment_for_testing(&mut clock, DAY * 7);

    // Investor exits during small fee period
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let (refund, vested_tokens) = pod::exit_investment<SUI, SUI>(
        &mut pod,
        &clock,
        ctx(&mut scenario),
    );

    // Should get refund with small fee applied
    assert!(refund.value() > 0);
    transfer::public_transfer(refund, @0x0);
    transfer::public_transfer(vested_tokens, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_exit_after_small_fee_period() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup and complete subscription
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward and invest
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(1_000_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward past small fee period (14 days after vesting)
    clock::increment_for_testing(&mut clock, DAY * 7 + DAY * 15);

    // Investor exits after small fee period
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let (refund, vested_tokens) = pod::exit_investment<SUI, SUI>(
        &mut pod,
        &clock,
        ctx(&mut scenario),
    );

    // Should get refund with standard 8% fee
    assert!(refund.value() > 0);
    transfer::public_transfer(refund, @0x0);
    transfer::public_transfer(vested_tokens, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ================================
// Failed Pod Tests
// ================================

#[test]
fun test_failed_pod_refund() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup: create pod with high min goal
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        800_000, // High min goal
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward and invest less than min
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(500_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward past subscription end
    clock::increment_for_testing(&mut clock, DAY * 7 + HOUR);

    // Verify pod failed
    // Note: pod is in a new transaction, already returned

    // Investor gets full refund
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let refund = pod::failed_pod_refund<SUI, SUI>(&mut pod, &clock, ctx(&mut scenario));
    assert_u64_eq(refund.value(), 500_000);
    transfer::public_transfer(refund, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_failed_pod_withdraw_tokens() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup: create pod
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        price_multiplier,
        800_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Fast forward and investor invests less than min
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(500_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // Fast forward to failure
    clock::increment_for_testing(&mut clock, DAY * 7 + HOUR);

    // Founder withdraws all tokens
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();
    let withdrawn = pod::failed_pod_withdraw<SUI, SUI>(&mut pod, &cap, &clock, ctx(&mut scenario));
    assert_u64_eq(withdrawn.value(), required_tokens);
    transfer::public_transfer(withdrawn, @0x0);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ================================
// Edge Cases and Boundary Tests
// ================================

#[test]
#[expected_failure(abort_code = pod::E_ZERO_INVESTMENT)]
fun test_zero_investment() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // Try to invest 0 (should fail)
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(0, ctx(&mut scenario));
    let _excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(_excess, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_pod_status_transitions() {
    let founder = @0x1;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // Setup
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let required_tokens = (1_000_000 * 10) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    let subscription_start = clock.timestamp_ms() + HOUR;
    pod::create_pod<SUI, SUI>(
        &settings,
        b"Test".to_string(),
        b"Test".to_string(),
        ascii::string(b"https://example.com"),
        token_price,
        10,
        500_000,
        1_000_000,
        subscription_start,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // Start new transaction to access created pod
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();

    // Before subscription starts
    assert_u8_eq(pod::pod_status(&pod, &clock), 0);
    test_scenario::return_shared(pod);

    // During subscription
    clock::increment_for_testing(&mut clock, HOUR * 2);
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    assert_u8_eq(pod::pod_status(&pod, &clock), 1);
    test_scenario::return_shared(pod);

    // After subscription ends, min goal not reached
    clock::increment_for_testing(&mut clock, DAY * 7);
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    assert_u8_eq(pod::pod_status(&pod, &clock), 2);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_ratio_ext_precision() {
    // Test that ratio_ext handles large numbers correctly
    let result1 = pod::ratio_ext(1_000_000, 1_000_000, 3);
    // 1_000_000 * 1_000_000 / 3 = 333_333_333_333.33... -> 333_333_333_333
    assert_u64_eq(result1, 333_333_333_333);

    let result2 = pod::ratio_ext_pm(1_000_000, 80);
    // 1_000_000 * 80 / 1000 = 80_000
    assert_u64_eq(result2, 80_000);
}

// ================================
// Integration Tests
// ================================

#[test]
fun test_full_pod_lifecycle_success() {
    let founder = @0x1;
    let investor1 = @0x2;
    let investor2 = @0x3;
    let investor3 = @0x4;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // 1. Initialize platform
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    // 2. Founder creates pod
    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 1_000_000;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Project X".to_string(),
        b"Revolutionary project".to_string(),
        ascii::string(b"https://forum.example.com"),
        token_price,
        price_multiplier,
        500_000,
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // 3. Fast forward to subscription
    clock::increment_for_testing(&mut clock, MINUTE * 2);

    // 4. Multiple investors subscribe
    next_tx(&mut scenario, investor1);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let inv1_investment = mint_for_testing(300_000, ctx(&mut scenario));
    let excess1 = pod::invest<SUI, SUI>(&mut pod, inv1_investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess1, @0x0);
    test_scenario::return_shared(pod);

    next_tx(&mut scenario, investor2);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let inv2_investment = mint_for_testing(250_000, ctx(&mut scenario));
    let excess2 = pod::invest<SUI, SUI>(&mut pod, inv2_investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess2, @0x0);
    test_scenario::return_shared(pod);

    next_tx(&mut scenario, investor3);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let inv3_investment = mint_for_testing(500_000, ctx(&mut scenario));
    let excess3 = pod::invest<SUI, SUI>(&mut pod, inv3_investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess3, @0x0);
    test_scenario::return_shared(pod);

    // 5. Fast forward to vesting
    clock::increment_for_testing(&mut clock, DAY * 7);

    // 6. Investors claim immediate unlock
    next_tx(&mut scenario, investor1);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let claimed1 = pod::investor_claim_tokens<SUI, SUI>(&mut pod, &clock, ctx(&mut scenario));
    assert!(claimed1.value() > 0);
    transfer::public_transfer(claimed1, @0x0);
    test_scenario::return_shared(pod);

    next_tx(&mut scenario, investor2);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let claimed2 = pod::investor_claim_tokens<SUI, SUI>(&mut pod, &clock, ctx(&mut scenario));
    assert!(claimed2.value() > 0);
    transfer::public_transfer(claimed2, @0x0);
    test_scenario::return_shared(pod);

    // 7. Founder claims funds
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();
    let founder_claimed = pod::founder_claim_funds<SUI, SUI>(
        &mut pod,
        &cap,
        &clock,
        ctx(&mut scenario),
    );
    assert!(founder_claimed.value() > 0);
    transfer::public_transfer(founder_claimed, @0x0);
    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);

    // 8. Halfway through vesting, investor 1 exits
    clock::increment_for_testing(&mut clock, DAY * 182);

    next_tx(&mut scenario, investor1);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let (refund, vested_tokens) = pod::exit_investment<SUI, SUI>(
        &mut pod,
        &clock,
        ctx(&mut scenario),
    );
    assert!(refund.value() > 0);
    assert!(vested_tokens.value() > 0);
    transfer::public_transfer(refund, @0x0);
    transfer::public_transfer(vested_tokens, @0x0);

    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_full_pod_lifecycle_failure() {
    let founder = @0x1;
    let investor = @0x2;

    let mut scenario = test_scenario::begin(founder);
    let ctx = ctx(&mut scenario);

    // 1. Initialize and create pod with high min goal
    pod::init_for_tests(ctx);
    next_tx(&mut scenario, founder);

    let settings = scenario.take_shared<GlobalSettings>();
    let mut clock = sui::clock::create_for_testing(ctx(&mut scenario));

    let token_price = 100;
    let price_multiplier = 10;
    let max_goal = 2_000_000; // High max goal
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let tokens = mint_for_testing(required_tokens, ctx(&mut scenario));

    pod::create_pod<SUI, SUI>(
        &settings,
        b"Project Y".to_string(),
        b"Risky project".to_string(),
        ascii::string(b"https://forum.example.com"),
        token_price,
        price_multiplier,
        1_500_000, // Very high min goal
        max_goal,
        clock.timestamp_ms() + MINUTE,
        DAY * 7,
        DAY * 365,
        80,
        tokens,
        &clock,
        ctx(&mut scenario),
    );

    // 2. Fast forward and invest (but not enough to reach min)
    clock::increment_for_testing(&mut clock, MINUTE * 2);
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let investment = mint_for_testing(500_000, ctx(&mut scenario));
    let excess = pod::invest<SUI, SUI>(&mut pod, investment, &clock, ctx(&mut scenario));
    transfer::public_transfer(excess, @0x0);
    test_scenario::return_shared(pod);

    // 3. One investor cancels subscription
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let refund = pod::cancel_subscription<SUI, SUI>(
        &mut pod,
        &settings,
        &clock,
        ctx(&mut scenario),
    );
    assert!(refund.value() > 0);
    transfer::public_transfer(refund, @0x0);
    test_scenario::return_shared(pod);

    // 4. Fast forward past subscription end
    clock::increment_for_testing(&mut clock, DAY * 7);

    // 5. Verify pod failed
    // Note: pod is in a new transaction, already returned

    // 6. Investors get refunds
    next_tx(&mut scenario, investor);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let final_refund = pod::failed_pod_refund<SUI, SUI>(&mut pod, &clock, ctx(&mut scenario));
    // After cancel, kept 0.1% of 500_000 = 500, which is fully refunded on failure
    assert_u64_eq(final_refund.value(), 500);
    transfer::public_transfer(final_refund, @0x0);
    test_scenario::return_shared(pod);

    // 7. Founders withdraw tokens
    next_tx(&mut scenario, founder);
    let mut pod = scenario.take_shared<pod::Pod<SUI, SUI>>();
    let cap = scenario.take_from_sender<pod::PodAdminCap>();
    let withdrawn_tokens = pod::failed_pod_withdraw<SUI, SUI>(
        &mut pod,
        &cap,
        &clock,
        ctx(&mut scenario),
    );
    assert_u64_eq(withdrawn_tokens.value(), required_tokens);
    transfer::public_transfer(withdrawn_tokens, @0x0);

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pod);
    test_scenario::return_shared(settings);
    sui::clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
