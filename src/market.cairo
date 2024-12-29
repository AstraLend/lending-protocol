#[starknet::contract]
mod Market {
    // Starknet imports
    use core::traits::Into;
    use starknet::{
        ContractAddress, ClassHash, deploy_syscall, get_caller_address, get_contract_address,
        get_block_timestamp
    };
    use poseidon::poseidon_hash_span;

    // Library imports
    use alexandria_math::fast_power::fast_power;
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
        IERC20MetadataDispatcherTrait
    };
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{DataType, PragmaPricesResponse};

    // Local imports
    use lending_protocol::{
        constants::{
            MIN_HF_WITH_DECIMALS, UPPER_LIQUIDATE_HF_WITH_DECIMALS, BORROW_LIMIT,
            THRESHOLD_LIQUIDATION, OPTIMAL_UTILIZATION_RATE, BASE_INTEREST_RATE, RSLOPE_1, RSLOPE_2,
            YEAR_TIMESTAMPS, ten_pow_decimals
        },
        interfaces::{
            IMarket, IPoolDispatcher, IPoolDispatcherTrait, ILPTokenDispatcher,
            ILPTokenDispatcherTrait
        },
        pool::Pool::{UserBorrowInfo}, message::Error
    };

    #[derive(Drop, Serde)]
    struct PoolDeployData {
        _token: ContractAddress,
        _collateral_token: ContractAddress,
        lp_token_class_hash: ClassHash,
        _market_address: ContractAddress
    }

    #[storage]
    struct Storage {
        owner: ContractAddress, // Owner
        pools: LegacyMap<
            (ContractAddress, ContractAddress), ContractAddress
        >, // Mapping: (Token, Collateral token) => Pool address
        pool_class_hash: ClassHash,
        lp_token_class_hash: ClassHash,
        pragma_contract: ContractAddress // This is Pragma Oracle Contract that will be called later to get the price of assets
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        _owner: ContractAddress,
        _pool_class_hash: ClassHash,
        _lp_token_class_hash: ClassHash,
        _pragma_contract: ContractAddress,
    ) {
        self.owner.write(_owner);
        self.pool_class_hash.write(_pool_class_hash);
        self.lp_token_class_hash.write(_lp_token_class_hash);
        self.pragma_contract.write(_pragma_contract);
    }

    #[abi(embed_v0)]
    impl MarketImpl of IMarket<ContractState> {
        fn get_price_usd(self: @ContractState, token: ContractAddress) -> u256 {
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };
            let token_symbol = IERC20MetadataDispatcher { contract_address: token }.symbol();
            let token_usd_ticker = token_symbol + "/USD";
            let token_usd_ticker_felt252 = token_usd_ticker.pending_word;

            let token_usd_price_output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(token_usd_ticker_felt252));

            token_usd_price_output.price.into()
        }

        fn get_pools(
            self: @ContractState, token: ContractAddress, collateral_token: ContractAddress
        ) -> ContractAddress {
            let pool_address = self.pools.read((token, collateral_token));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);
            pool_address
        }

        fn deploy_new_pool(
            ref self: ContractState, token: ContractAddress, collateral_token: ContractAddress,
        ) {
            // Check owner
            let caller = get_caller_address();
            assert(caller == self.owner.read(), Error::NOT_OWNER);

            let mut hash_data: Array<felt252> = array![];
            let mut calldata: Array<felt252> = array![];
            let mut deploy_data = PoolDeployData {
                _token: token,
                _collateral_token: collateral_token,
                lp_token_class_hash: self.lp_token_class_hash.read(),
                _market_address: get_contract_address()
            };
            Serde::serialize(@deploy_data, ref hash_data);
            let salt = poseidon_hash_span(hash_data.span());
            Serde::serialize(@deploy_data, ref calldata);
            let deploy_from_zero: bool = false;

            let (_pool_address, _) = deploy_syscall(
                self.pool_class_hash.read(), salt, calldata.span(), deploy_from_zero
            )
                .unwrap();

            self.pools.write((token, collateral_token), _pool_address);
        }

        fn supply(
            ref self: ContractState,
            token: ContractAddress,
            collateral: ContractAddress,
            supply_amount: u256,
        ) {
            // Get tx info
            let caller = get_caller_address();
            let market_contract = get_contract_address();

            // Verify inputs
            assert(token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(supply_amount > 0, Error::INVALID_AMOUNT);

            // Get pool address
            let pool_address = self.pools.read((token, collateral));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);

            // Check that user has enough balance
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            assert(
                token_dispatcher.balance_of(caller) >= supply_amount,
                Error::NOT_ENOUGH_BALANCE_TO_SUPPLY
            );

            // Check that user has enough allowance
            assert(
                token_dispatcher.allowance(caller, market_contract) >= supply_amount,
                Error::NOT_ENOUGH_ALLOWANCE
            );

            // Take token from user
            token_dispatcher.transfer_from(caller, pool_address, supply_amount);

            // Mint LP Token to user
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let lp_token_address = pool_dispatcher.get_lp_token_address(); // Get LP Token address
            let pool_total_supply = pool_dispatcher.get_total_supply();
            let lp_token_dispatcher = ILPTokenDispatcher { contract_address: lp_token_address };

            // Calculate LP Token mint
            let mut lp_token_mint = 0;
            if (pool_total_supply == 0) { // If this is the first supply
                lp_token_mint = supply_amount;
            } else { // Normal case
                lp_token_mint = supply_amount
                    * lp_token_dispatcher.total_supply()
                    / pool_total_supply;
            }
            lp_token_dispatcher.mint(caller, lp_token_mint);

            // Update user's LP Token owned
            pool_dispatcher.add_user_lp_owned(caller, lp_token_mint);

            // Update pool token's total supply
            pool_dispatcher.add_total_supply(supply_amount);
        }

        fn withdraw(
            ref self: ContractState,
            token: ContractAddress,
            collateral: ContractAddress,
            lp_amount_withdraw: u256
        ) {
            // Get caller
            let caller = get_caller_address();

            // Verify inputs
            assert(token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(lp_amount_withdraw > 0, Error::INVALID_AMOUNT);

            // Get pool address
            let pool_address = self.pools.read((token, collateral));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);

            // Verify LP Token amount
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let lp_amount_avail = pool_dispatcher.get_user_to_lp_owned(caller);
            assert(lp_amount_withdraw <= lp_amount_avail, Error::INVALID_AMOUNT);

            // Check that user has enough lp amount balance
            let lp_token_address = pool_dispatcher.get_lp_token_address();
            let lp_token_dispatcher = ILPTokenDispatcher { contract_address: lp_token_address };
            assert(
                lp_token_dispatcher.balance_of(caller) >= lp_amount_withdraw,
                Error::NOT_ENOUGH_LP_TOKEN_AMOUNT
            );

            // Transfer token to user
            let token_withdraw_amount = lp_amount_withdraw
                * (pool_dispatcher.get_total_supply())
                / lp_token_dispatcher.total_supply();

            pool_dispatcher.approve_transfer(token, token_withdraw_amount); // Approve

            IERC20Dispatcher { contract_address: token }
                .transfer_from(pool_address, caller, token_withdraw_amount);

            // Burn LP Token from user
            lp_token_dispatcher.burn(caller, lp_amount_withdraw);

            // Update user's LP Token owned
            pool_dispatcher.subtract_user_lp_owned(caller, lp_amount_withdraw);

            // Update pool token's total supply
            pool_dispatcher.subtract_total_supply(token_withdraw_amount);
        }

        fn borrow(
            ref self: ContractState,
            borrow_token: ContractAddress,
            borrow_amount: u256,
            collateral_token: ContractAddress,
            collateral_amount: u256
        ) {
            // Get tx info
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Verify inputs
            assert(borrow_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(borrow_amount > 0 && collateral_amount > 0, Error::INVALID_AMOUNT);

            // Check the user has enough collateral amount balance
            let collateral_token_dispatcher = IERC20Dispatcher {
                contract_address: collateral_token
            };
            assert(
                collateral_token_dispatcher.balance_of(caller) >= collateral_amount,
                Error::NOT_ENOUGH_COLLATERAL_BALANCE
            );

            // Check the user has enough collateral amount allowance
            assert(
                collateral_token_dispatcher.allowance(caller, market_contract) >= collateral_amount,
                Error::NOT_ENOUGH_ALLOWANCE
            );

            // Get pool address
            let pool_address = self.pools.read((borrow_token, collateral_token));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);

            // Check the pool's supply balance
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let pool_total_supply = pool_dispatcher.get_total_supply();
            let pool_total_borrow = pool_dispatcher.get_total_borrow();
            let available_supply = pool_total_supply - pool_total_borrow;
            assert(
                pool_total_supply > 0 && borrow_amount <= available_supply, Error::NOT_ENOUGH_SUPPLY
            );

            // Check the pool's current UR, must <= 90(%)
            let current_ur = pool_dispatcher.calculate_utilization_rate();
            assert(
                (current_ur / ten_pow_decimals().into()) < BORROW_LIMIT.into(),
                Error::EXCEEDS_BORROW_LIMIT
            );

            // Calculate Health Factor (HF)
            // HF = collateral_amount value / borrow_amount value
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };
            let borrow_token_symbol = IERC20MetadataDispatcher { contract_address: borrow_token }
                .symbol();
            let collateral_token_symbol = IERC20MetadataDispatcher {
                contract_address: collateral_token
            }
                .symbol();
            let borrow_token_usd_ticker = borrow_token_symbol + "/USD";
            let collateral_token_usd_ticker = collateral_token_symbol + "/USD";
            let borrow_token_usd_ticker_felt252 = borrow_token_usd_ticker.pending_word;
            let collateral_token_usd_ticker_felt252 = collateral_token_usd_ticker.pending_word;

            let borrow_token_usd_price_output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(borrow_token_usd_ticker_felt252));
            let collateral_token_usd_price_output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(collateral_token_usd_ticker_felt252));
            let borrow_token_usd_price = borrow_token_usd_price_output.price;
            let collateral_token_usd_price = collateral_token_usd_price_output.price;

            let hf = collateral_token_usd_price.into()
                * collateral_amount
                * THRESHOLD_LIQUIDATION.into()
                / (borrow_token_usd_price.into()
                    * borrow_amount); // According the Pragma Oracle docs, the tokens our protocol intended to use will all have the same 8 decimals

            // Verify the loan's HF
            assert(hf >= MIN_HF_WITH_DECIMALS.into(), Error::UNSECURED_LOAN);

            // Calculate UR after loan, must <= 90(%)
            let new_ur = (pool_total_borrow + borrow_amount)
                * ten_pow_decimals().into()
                * ten_pow_decimals().into()
                / pool_total_supply;
            assert(
                (new_ur / ten_pow_decimals().into()) <= BORROW_LIMIT.into(),
                Error::EXCEEDS_BORROW_LIMIT
            );

            // Calculate borrow APR
            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (new_ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * new_ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((new_ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            // Add expect interest amount per year
            pool_dispatcher
                .add_expect_interest_amount_per_year(
                    (borrow_amount * borrow_apr)
                        / (ten_pow_decimals().into() * ten_pow_decimals().into())
                );

            // Update user borrow info
            let user_borrow_info = UserBorrowInfo {
                borrow_amount, collateral_amount, hf, borrow_apr, borrow_start_time: cur_timestamp
            };
            pool_dispatcher.add_user_borrow_info(caller, user_borrow_info); // Update info

            // Transfer collateral token from user
            collateral_token_dispatcher.transfer_from(caller, pool_address, collateral_amount);

            // Update pool token's total borrow
            pool_dispatcher.add_total_borrow(borrow_amount);

            // Transfer token to user
            pool_dispatcher.approve_transfer(borrow_token, borrow_amount); // Approve
            IERC20Dispatcher { contract_address: borrow_token }
                .transfer_from(pool_address, caller, borrow_amount);
        }

        fn repay(
            ref self: ContractState,
            repay_token: ContractAddress,
            collateral_token: ContractAddress,
            borrow_id: u256
        ) {
            // Get tx info
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Verify inputs
            assert(repay_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);

            // Get pool address
            let pool_address = self.pools.read((repay_token, collateral_token));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);

            // Check user borrow quantity
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let user_borrow_quantity = pool_dispatcher.get_user_borrow_quantity(caller);
            assert(user_borrow_quantity > 0, Error::HAVENT_BORROW_YET);
            assert(borrow_id < user_borrow_quantity, Error::INVALID_BORROW_ID);

            // Calculate interest amount
            let user_borrow_info = pool_dispatcher.get_user_borrow_info(caller, borrow_id);
            let user_borrow_amount = user_borrow_info.borrow_amount;
            let interest_amount = user_borrow_amount
                * user_borrow_info.borrow_apr
                * (cur_timestamp - user_borrow_info.borrow_start_time).into()
                / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());

            // Check user has enough token balance
            let repay_token_dispatcher = IERC20Dispatcher { contract_address: repay_token };
            let total_repay_amount = user_borrow_amount + interest_amount;
            assert(
                repay_token_dispatcher.balance_of(caller) >= total_repay_amount,
                Error::NOT_ENOUGH_BALANCE_TO_REPAY
            );

            // Check user has enough token allowance
            assert(
                repay_token_dispatcher.allowance(caller, market_contract) >= total_repay_amount,
                Error::NOT_ENOUGH_ALLOWANCE
            );

            // Repay
            repay_token_dispatcher.transfer_from(caller, pool_address, total_repay_amount);

            // Update pool total supply
            pool_dispatcher.add_total_supply(interest_amount);

            // Update actual interest amount
            pool_dispatcher.add_actual_interest_amount(interest_amount);

            // Transfer collateral token to user
            pool_dispatcher
                .approve_transfer(collateral_token, user_borrow_info.collateral_amount); // Approve
            IERC20Dispatcher { contract_address: collateral_token }
                .transfer_from(pool_address, caller, user_borrow_info.collateral_amount);

            // Remove user borrow info
            pool_dispatcher.remove_borrow_info(caller, borrow_id);

            // Update pool token's total borrow
            pool_dispatcher.subtract_total_borrow(user_borrow_amount);
        }

        fn liquidate(
            ref self: ContractState,
            repay_token: ContractAddress,
            collateral_token: ContractAddress,
            borrower: ContractAddress,
            borrow_id: u256
        ) {
            // Get tx info
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Verify inputs
            assert(repay_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(borrower.is_non_zero(), Error::INVALID_BORROWER_ADDRESS);

            // Get pool address
            let pool_address = self.pools.read((repay_token, collateral_token));
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXISTS);

            // Check borrower borrow quantity
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let borrower_borrow_quantity = pool_dispatcher.get_user_borrow_quantity(borrower);
            assert(borrower_borrow_quantity > 0, Error::HAVENT_BORROW_YET);
            assert(borrow_id < borrower_borrow_quantity, Error::INVALID_BORROW_ID);

            // Get loan info
            let loan_info = pool_dispatcher.get_user_borrow_info(borrower, borrow_id);
            let borrow_amount = loan_info.borrow_amount;
            let collateral_amount = loan_info.collateral_amount;

            // Check HF < 1
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_contract.read()
            };
            let repay_token_symbol = IERC20MetadataDispatcher { contract_address: repay_token }
                .symbol();
            let collateral_token_symbol = IERC20MetadataDispatcher {
                contract_address: collateral_token
            }
                .symbol();
            let repay_token_usd_ticker = repay_token_symbol + "/USD";
            let collateral_token_usd_ticker = collateral_token_symbol + "/USD";
            let repay_token_usd_ticker_felt252 = repay_token_usd_ticker.pending_word;
            let collateral_token_usd_ticker_felt252 = collateral_token_usd_ticker.pending_word;

            let repay_token_usd_price_output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(repay_token_usd_ticker_felt252));
            let collateral_token_usd_price_output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(collateral_token_usd_ticker_felt252));
            let repay_token_usd_price = repay_token_usd_price_output.price;
            let collateral_token_usd_price = collateral_token_usd_price_output.price;

            // Calculate interest amount
            let interest_amount = borrow_amount
                * loan_info.borrow_apr
                * (cur_timestamp - loan_info.borrow_start_time).into()
                / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());

            let hf = collateral_token_usd_price.into()
                * collateral_amount
                * THRESHOLD_LIQUIDATION.into()
                / (repay_token_usd_price.into() * (borrow_amount + interest_amount));

            assert(hf <= UPPER_LIQUIDATE_HF_WITH_DECIMALS.into(), Error::LIQUIDATE_NOT_ALLOWED);

            // Check caller has enough token balance
            let liquidate_token_dispatcher = IERC20Dispatcher { contract_address: repay_token };
            let total_repay_amount = borrow_amount + interest_amount;
            assert(
                liquidate_token_dispatcher.balance_of(caller) >= total_repay_amount,
                Error::NOT_ENOUGH_BALANCE_TO_REPAY
            );

            // Check caller has enough token allowance
            assert(
                liquidate_token_dispatcher.allowance(caller, market_contract) >= total_repay_amount,
                Error::NOT_ENOUGH_ALLOWANCE
            );

            // Liquidate
            liquidate_token_dispatcher.transfer_from(caller, pool_address, total_repay_amount);

            // Update pool total supply
            pool_dispatcher.add_total_supply(interest_amount);

            // Update actual interest amount
            pool_dispatcher.add_actual_interest_amount(interest_amount);

            // Transfer collateral token to caller
            pool_dispatcher
                .approve_transfer(collateral_token, loan_info.collateral_amount); // Approve
            IERC20Dispatcher { contract_address: collateral_token }
                .transfer_from(pool_address, caller, loan_info.collateral_amount);

            // Remove user borrow info
            pool_dispatcher.remove_borrow_info(borrower, borrow_id);
        }
    }
}
