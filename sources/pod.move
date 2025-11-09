module beelievers_kickstarter::pod;

use std::ascii;
use std::string::{Self, String};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};
use sui::url::{Self, Url};

// --- Constants ---
const PRECISION: u64 = 1000; // For permille calculations

// Pod Statuses
const STATUS_INACTIVE: u8 = 0;
const STATUS_SUBSCRIPTION: u8 = 1;
const STATUS_FAILED: u8 = 2;
const STATUS_VESTING: u8 = 3;

// --- Error Codes ---
const E_INVALID_PARAMS: u64 = 0;
const E_POD_NOT_SUBSCRIPTION: u64 = 1;
const E_POD_NOT_VESTING: u64 = 2;
const E_POD_NOT_FAILED: u64 = 3;
const E_NOT_ADMIN: u64 = 5;
const E_INVESTMENT_NOT_FOUND: u64 = 6;
const E_ALREADY_EXITED: u64 = 8;
const E_MAX_GOAL_REACHED: u64 = 9;
const E_INVALID_TOKEN_SUPPLY: u64 = 11;
const E_NOTHING_TO_CLAIM: u64 = 12;

// --- Structs ---

/// Capability for updating platform-wide settings.
public struct PlatformAdminCap has key, store { id: UID }

/// Shared object containing all platform parameters.
public struct GlobalSettings has key {
    id: UID,
    max_immediate_unlock_pm: u64,
    min_vesting_duration: u64,
    min_subscription_duration: u64,
    pod_exit_fee: u64,
    pod_exit_small_fee: u64,
    small_fee_duration: u64,
    subscription_cancel_fee: u64,
}

/// Capability for the project team to manage their pod.
public struct PodAdminCap has key, store {
    id: UID,
    pod_id: ID,
}

/// Represents an individual's investment in a pod.
public struct InvestorAllocation has copy, drop, store {
    invested: u64,
    allocation: u64,
    claimed_tokens: u64,
}

/// The main struct representing a funding campaign.
public struct Pod<phantom C, phantom T> has key {
    id: UID,
    name: String,
    description: String,
    forum_url: Url,
    token_vault: Balance<T>,
    funds_vault: Balance<C>,
    total_raised: u64,
    total_allocated: u64, // TODO: keep track to allow funders to claim back unallocated tokens, and add function to claim the unallocated tokens after subscription end
    investments: Table<address, InvestorAllocation>,
    founder_claimed_funds: u64,
    vesting_start: u64,
    // Pod Parameters
    token_price: u64,
    price_multiplier: u64,
    min_goal: u64,
    max_goal: u64,
    subscription_start: u64,
    subscription_end: u64,
    vesting_duration: u64,
    immediate_unlock_pm: u64,
    // Copied Fee Settings
    pod_exit_fee: u64,
    pod_exit_small_fee: u64,
    small_fee_duration: u64,
}

// --- Events ---
public struct EventPodCreated has copy, drop { pod_id: ID, founder: address }
public struct EventInvestmentMade has copy, drop {
    pod_id: ID,
    investor: address,
    total_investment: u64,
}
public struct EventPodMaxGoal has copy, drop { pod_id: ID }
public struct EventPodFailed has copy, drop { pod_id: ID }
public struct EventSubscriptionCancelled has copy, drop {
    pod_id: ID,
    investor: address,
    refunded: u64,
    invested: u64,
    allocation: u64,
}
public struct EventSettingsUpdated has copy, drop {}

// --- Module Initialization ---
fun init(ctx: &mut TxContext) {
    let settings = GlobalSettings {
        id: object::new(ctx),
        max_immediate_unlock_pm: 50, // 5.0%
        min_vesting_duration: 1000 * 60 * 60 * 24 * 30 * 18, // 18 months
        min_subscription_duration: 1000 * 60 * 60 * 24 * 14, // 14 days
        pod_exit_fee: 50, // 5.0%
        pod_exit_small_fee: 8, // 0.8%
        small_fee_duration: 1000 * 60 * 60 * 24 * 14, // 14 days
        subscription_cancel_fee: 1, // 0.1%
    };
    transfer::share_object(settings);

    let admin_cap = PlatformAdminCap { id: object::new(ctx) };
    transfer::public_transfer(admin_cap, tx_context::sender(ctx));
}

// --- Platform Admin Functions ---
public entry fun update_settings(
    _cap: &PlatformAdminCap,
    settings: &mut GlobalSettings,
    max_immediate_unlock_pm: Option<u64>,
    min_vesting_duration: Option<u64>,
    min_subscription_duration: Option<u64>,
    pod_exit_fee: Option<u64>,
    pod_exit_small_fee: Option<u64>,
    small_fee_duration: Option<u64>,
    subscription_cancel_fee: Option<u64>,
    _ctx: &mut TxContext,
) {
    if (option::is_some(&max_immediate_unlock_pm)) {
        settings.max_immediate_unlock_pm = option::destroy_some(max_immediate_unlock_pm);
    };
    if (option::is_some(&min_vesting_duration)) {
        settings.min_vesting_duration = option::destroy_some(min_vesting_duration);
    };
    if (option::is_some(&min_subscription_duration)) {
        settings.min_subscription_duration = option::destroy_some(min_subscription_duration);
    };
    if (option::is_some(&pod_exit_fee)) {
        settings.pod_exit_fee = option::destroy_some(pod_exit_fee);
    };
    if (option::is_some(&pod_exit_small_fee)) {
        settings.pod_exit_small_fee = option::destroy_some(pod_exit_small_fee);
    };
    if (option::is_some(&small_fee_duration)) {
        settings.small_fee_duration = option::destroy_some(small_fee_duration);
    };
    if (option::is_some(&subscription_cancel_fee)) {
        settings.subscription_cancel_fee = option::destroy_some(subscription_cancel_fee);
    };
    event::emit(EventSettingsUpdated {});
}

// --- Pod Creation and Management ---
public entry fun create_pod<C, T>(
    settings: &GlobalSettings,
    name: String,
    description: String,
    forum_url: ascii::String,
    token_price: u64,
    price_multiplier: u64,
    min_goal: u64,
    max_goal: u64,
    // TODO: add subscription_start
    subscription_duration: u64,
    vesting_duration: u64,
    immediate_unlock_pm: u64,
    tokens: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let params_valid = (
        min_goal > 0 &&
            max_goal >= min_goal &&
            subscription_duration >= settings.min_subscription_duration &&
            vesting_duration >= settings.min_vesting_duration &&
            immediate_unlock_pm <= settings.max_immediate_unlock_pm,
    );
    assert!(params_valid, E_INVALID_PARAMS);

    let subscription_end = clock.timestamp_ms() + subscription_duration;
    let required_tokens = (max_goal * price_multiplier) / token_price;
    let supplied_amount = tokens.value();
    assert!(supplied_amount == required_tokens, E_INVALID_TOKEN_SUPPLY);

    let pod = Pod<C, T> {
        id: object::new(ctx),
        name,
        description,
        forum_url: url::new_unsafe(forum_url),
        token_vault: tokens.into_balance(),
        funds_vault: balance::zero<C>(),
        investments: table::new(ctx),
        token_price,
        price_multiplier,
        min_goal,
        max_goal,
        subscription_start: 0, // TODO: use subscription_start argument
        subscription_end,
        vesting_duration,
        immediate_unlock_pm,
        pod_exit_fee: settings.pod_exit_fee,
        pod_exit_small_fee: settings.pod_exit_small_fee,
        small_fee_duration: settings.small_fee_duration,
        total_raised: 0,
        total_allocated: 0,
        vesting_start: 0,
        founder_claimed_funds: 0,
    };

    let pod_id = object::id(&pod);
    let cap = PodAdminCap { id: object::new(ctx), pod_id };

    event::emit(EventPodCreated { pod_id, founder: tx_context::sender(ctx) });

    transfer::share_object(pod);
    transfer::public_transfer(cap, tx_context::sender(ctx));
}

// --- Public View Functions ---
public fun pod_status<C, T>(pod: &Pod<C, T>, clock: &Clock): u8 {
    let now = clock.timestamp_ms();
    if (now >= pod.subscription_end) {
        if (pod.total_raised < pod.min_goal) STATUS_FAILED else STATUS_VESTING
    } else if (now < pod.subscription_start) {
        STATUS_INACTIVE
    } else {
        STATUS_SUBSCRIPTION
    }
}

// --- Investor Functions ---
public fun invest<C, T>(
    pod: &mut Pod<C, T>,
    mut investment: Coin<C>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(pod_status(pod, clock) == STATUS_SUBSCRIPTION, E_POD_NOT_SUBSCRIPTION);
    assert!(pod.total_raised < pod.max_goal, E_MAX_GOAL_REACHED);

    let investor = tx_context::sender(ctx);
    let investment_amount = investment.value();
    let new_total_raised = pod.total_raised + investment_amount;

    let (actual_investment, excess_coin) = if (new_total_raised > pod.max_goal) {
        let excess = new_total_raised - pod.max_goal;
        let actual = investment_amount - excess;
        (actual, investment.split(excess, ctx))
    } else {
        (investment_amount, coin::zero(ctx))
    };

    let additional_tokens = (actual_investment * pod.price_multiplier) / pod.token_price;
    pod.total_raised = pod.total_raised + actual_investment;
    balance::join(&mut pod.funds_vault, investment.into_balance());

    let total_investment = if (table::contains(&pod.investments, investor)) {
        let allocation = table::borrow_mut(&mut pod.investments, investor);
        allocation.invested = allocation.invested + actual_investment;
        allocation.allocation = allocation.allocation + additional_tokens;
        allocation.invested
    } else {
        let allocation = InvestorAllocation {
            invested: actual_investment,
            allocation: additional_tokens,
            claimed_tokens: 0,
        };
        table::add(&mut pod.investments, investor, allocation);
        actual_investment
    };

    event::emit(EventInvestmentMade { pod_id: object::id(pod), investor, total_investment });

    if (pod.total_raised >= pod.max_goal) {
        // This triggers vesting start
        pod.subscription_end = clock::timestamp_ms(clock);
        event::emit(EventPodMaxGoal { pod_id: object::id(pod) });
    };

    excess_coin
}

// NOTE: probably we should protect from looping cancellation.
/// Cancels an investor's subscription. Reduces the investment to the fee amount.
public fun cancel_subscription<C, T>(
    pod: &mut Pod<C, T>,
    settings: &GlobalSettings,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(pod_status(pod, clock) == STATUS_SUBSCRIPTION, E_POD_NOT_SUBSCRIPTION);

    let investor = tx_context::sender(ctx);
    assert!(table::contains(&pod.investments, investor), E_INVESTMENT_NOT_FOUND);
    let pod_id = object::id(pod);
    let i = table::borrow_mut(&mut pod.investments, investor);
    let orig_investment = i.invested;

    // Reduce allocation.
    // TODO: use u128
    i.invested = (orig_investment * settings.subscription_cancel_fee) / PRECISION;
    i.allocation = (i.allocation * i.invested) / orig_investment;

    let refunded = orig_investment - i.invested;
    pod.total_raised = pod.total_raised - refunded;

    event::emit(EventSubscriptionCancelled {
        pod_id,
        investor,
        refunded,
        invested: i.invested,
        allocation: i.allocation,
    });
    coin::from_balance(balance::split(&mut pod.funds_vault, refunded), ctx)
}

public fun investor_claim_tokens<C, T>(
    pod: &mut Pod<C, T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(pod_status(pod, clock) == STATUS_VESTING, E_POD_NOT_VESTING);
    let investor = tx_context::sender(ctx);
    let time_elapsed = pod.elapsed_vesting_time(clock);
    let allocation = table::borrow_mut(&mut pod.investments, investor);
    let total_vested = calculate_vested_tokens(
        time_elapsed,
        pod.vesting_duration,
        pod.immediate_unlock_pm,
        allocation.allocation,
    );
    let to_claim = total_vested - allocation.claimed_tokens;
    assert!(to_claim > 0, E_NOTHING_TO_CLAIM);

    allocation.claimed_tokens = allocation.claimed_tokens + to_claim;
    coin::from_balance(balance::split(&mut pod.token_vault, to_claim), ctx)
}

public fun exit_investment<C, T>(
    pod: &mut Pod<C, T>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<C>, Coin<T>) {
    assert!(pod_status(pod, clock) == STATUS_VESTING, E_POD_NOT_VESTING);
    let investor = tx_context::sender(ctx);
    let allocation = table::remove(&mut pod.investments, investor);
    assert!(allocation.claimed_tokens < allocation.allocation, E_ALREADY_EXITED);

    let time_elapsed = pod.elapsed_vesting_time(clock);
    let total_vested = calculate_vested_tokens(
        time_elapsed,
        pod.vesting_duration,
        pod.immediate_unlock_pm,
        allocation.allocation,
    );
    let vested_portion = (total_vested * PRECISION) / allocation.allocation;
    let unvested_portion = PRECISION - vested_portion;

    let fee_percentage = if (clock.timestamp_ms() < pod.vesting_start + pod.small_fee_duration) {
        pod.pod_exit_small_fee
    } else {
        pod.pod_exit_fee
    };

    let unvested_investment = (allocation.invested * unvested_portion) / PRECISION;
    let fee_amount = (unvested_investment * fee_percentage) / PRECISION;
    let refund_amount = unvested_investment - fee_amount;

    let refund_coin = if (refund_amount > 0) {
        coin::from_balance(balance::split(&mut pod.funds_vault, refund_amount), ctx)
    } else {
        coin::zero(ctx)
    };

    let vested_tokens_to_investor = total_vested - allocation.claimed_tokens;
    let vested_coin = if (vested_tokens_to_investor > 0) {
        coin::from_balance(balance::split(&mut pod.token_vault, vested_tokens_to_investor), ctx)
    } else {
        coin::zero(ctx)
    };

    let unvested_tokens = allocation.allocation - total_vested;
    if (unvested_tokens > 0) {
        pod.total_allocated = pod.total_allocated - unvested_tokens;
    };

    (refund_coin, vested_coin)
}

public fun failed_pod_refund<C, T>(
    pod: &mut Pod<C, T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(pod_status(pod, clock) == STATUS_FAILED, E_POD_NOT_FAILED);
    let investor = tx_context::sender(ctx);
    let allocation = table::remove(&mut pod.investments, investor);

    coin::from_balance(balance::split(&mut pod.funds_vault, allocation.invested), ctx)
}

// --- Founder Functions ---
public fun founder_claim_funds<C, T>(
    pod: &mut Pod<C, T>,
    cap: &PodAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(cap.pod_id == object::id(pod), E_NOT_ADMIN);
    assert!(pod_status(pod, clock) == STATUS_VESTING, E_POD_NOT_VESTING);

    let total_claimable = calculate_founder_claimable(pod, clock);
    let to_claim = total_claimable - pod.founder_claimed_funds;
    assert!(to_claim > 0, E_NOTHING_TO_CLAIM);

    pod.founder_claimed_funds = pod.founder_claimed_funds + to_claim;
    coin::from_balance(balance::split(&mut pod.funds_vault, to_claim), ctx)
}

public fun failed_pod_withdraw<C, T>(
    pod: &mut Pod<C, T>,
    cap: &PodAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(cap.pod_id == object::id(pod), E_NOT_ADMIN);
    assert!(pod_status(pod, clock) == STATUS_FAILED, E_POD_NOT_FAILED);

    coin::from_balance(balance::withdraw_all(&mut pod.token_vault), ctx)
}

// --- Public (non-entry) View Functions ---

public fun calculate_founder_claimable<C, T>(pod: &Pod<C, T>, clock: &Clock): u64 {
    let time_elapsed = pod.elapsed_vesting_time(clock);
    if (time_elapsed == 0) return 0;

    let immediate_unlock = (pod.total_raised * pod.immediate_unlock_pm) / PRECISION;
    let vested_funds = if (time_elapsed >= pod.vesting_duration) {
        pod.total_raised - immediate_unlock
    } else {
        (time_elapsed * (pod.total_raised - immediate_unlock)) / pod.vesting_duration
    };
    immediate_unlock + vested_funds
}

public fun calculate_vested_tokens(
    time_elapsed: u64,
    vesting_duration: u64,
    immediate_unlock_pm: u64,
    allocation: u64,
): u64 {
    if (time_elapsed == 0) return 0;

    let immediate_unlock = (allocation * immediate_unlock_pm) / PRECISION;
    let vested_tokens = if (time_elapsed >= vesting_duration) {
        allocation - immediate_unlock
    } else {
        (time_elapsed * (allocation - immediate_unlock)) / vesting_duration
    };
    immediate_unlock + vested_tokens
}

// --- Private Helper Functions ---

public fun elapsed_vesting_time<C, T>(pod: &Pod<C, T>, clock: &Clock): u64 {
    assert!(pod_status(pod, clock) == STATUS_VESTING, E_POD_NOT_VESTING);
    let now = clock.timestamp_ms();
    return now - pod.subscription_end
}
