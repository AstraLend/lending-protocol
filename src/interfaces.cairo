// Starknet imports
use starknet::ContractAddress;

// Internal imports
use lending_protocol::pool::Pool::{UserBorrowInfo, PoolInfo};

#[starknet::interface]
pub trait IMarket<TContractState> {
    fn get_price_usd(self: @TContractState, token: ContractAddress) -> u256;

    fn get_pools(
        self: @TContractState, token: ContractAddress, collateral_token: ContractAddress
    ) -> ContractAddress;

    fn deploy_new_pool(
        ref self: TContractState, token: ContractAddress, collateral_token: ContractAddress
    );

    fn supply(
        ref self: TContractState,
        token: ContractAddress,
        collateral: ContractAddress,
        supply_amount: u256
    );

    fn withdraw(
        ref self: TContractState,
        token: ContractAddress,
        collateral: ContractAddress,
        lp_amount_withdraw: u256
    );

    fn borrow(
        ref self: TContractState,
        borrow_token: ContractAddress,
        borrow_amount: u256,
        collateral_token: ContractAddress,
        collateral_amount: u256
    );

    fn repay(
        ref self: TContractState,
        repay_token: ContractAddress,
        collateral_token: ContractAddress,
        borrow_id: u256
    );

    fn liquidate(
        ref self: TContractState,
        repay_token: ContractAddress,
        collateral_token: ContractAddress,
        borrower: ContractAddress,
        borrow_id: u256
    );
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn get_token_name(self: @TContractState) -> ByteArray;

    fn get_collateral_token_name(self: @TContractState) -> ByteArray;

    fn get_token_symbol(self: @TContractState) -> ByteArray;

    fn get_collateral_token_symbol(self: @TContractState) -> ByteArray;

    fn get_total_supply(self: @TContractState) -> u256;

    fn get_total_borrow(self: @TContractState) -> u256;

    fn get_lp_token_address(self: @TContractState) -> ContractAddress;

    fn get_user_to_lp_owned(self: @TContractState, user: ContractAddress) -> u256;

    fn get_user_borrow_quantity(self: @TContractState, user: ContractAddress) -> u256;

    fn get_user_borrow_info(
        self: @TContractState, user: ContractAddress, borrow_id: u256
    ) -> UserBorrowInfo;

    fn get_active_borrower_num(self: @TContractState) -> u256;

    fn get_active_borrower_index(self: @TContractState, borrower: ContractAddress) -> u256;

    fn get_active_borrower(self: @TContractState, index: u256) -> ContractAddress;

    fn get_expect_interest_amount_per_year(self: @TContractState) -> u256;

    fn get_actual_interest_amount(self: @TContractState) -> u256;

    fn get_pool_info(self: @TContractState) -> PoolInfo;

    fn calculate_utilization_rate(self: @TContractState) -> u256;

    fn calculate_borrow_apr(self: @TContractState) -> u256;

    fn calculate_supply_apy(self: @TContractState) -> u256;

    fn add_user_lp_owned(ref self: TContractState, user: ContractAddress, amount: u256);

    fn subtract_user_lp_owned(ref self: TContractState, user: ContractAddress, amount: u256);

    fn add_total_supply(ref self: TContractState, amount: u256);

    fn subtract_total_supply(ref self: TContractState, amount: u256);

    fn add_total_borrow(ref self: TContractState, amount: u256);

    fn subtract_total_borrow(ref self: TContractState, amount: u256);

    fn add_user_borrow_info(
        ref self: TContractState, user: ContractAddress, _user_borrow_info: UserBorrowInfo
    );

    fn remove_borrow_info(ref self: TContractState, user: ContractAddress, borrow_id: u256);

    fn add_expect_interest_amount_per_year(ref self: TContractState, amount: u256);

    fn add_actual_interest_amount(ref self: TContractState, amount: u256);

    fn approve_transfer(ref self: TContractState, token: ContractAddress, amount: u256);
}

#[starknet::interface]
pub trait ILPToken<TContractState> {
    fn total_supply(self: @TContractState) -> u256;

    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;

    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;

    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;

    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;

    fn name(self: @TContractState) -> ByteArray;

    fn symbol(self: @TContractState) -> ByteArray;

    fn decimals(self: @TContractState) -> u8;

    fn totalSupply(self: @TContractState) -> u256;

    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;

    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);

    fn burn(ref self: TContractState, account: ContractAddress, amount: u256);
}
