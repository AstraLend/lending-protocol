#[starknet::contract]
mod Pool {
    // Starknet imports
    use starknet::{
        ClassHash, ContractAddress, contract_address_const, deploy_syscall, get_caller_address,
        get_contract_address
    };
    use poseidon::poseidon_hash_span;

    // Library imports
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
        IERC20MetadataDispatcherTrait
    };

    // Internal imports
    use lending_protocol::{
        constants::{
            OPTIMAL_UTILIZATION_RATE, BASE_INTEREST_RATE, RSLOPE_1, RSLOPE_2, ten_pow_decimals
        },
        interfaces::IPool, message::Error
    };

    #[derive(Drop, Serde)]
    struct LPTokenDeployData {
        name: ByteArray,
        symbol: ByteArray,
        _market_contract: ContractAddress
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct UserBorrowInfo {
        borrow_amount: u256,
        collateral_amount: u256,
        hf: u256,
        borrow_apr: u256,
        borrow_start_time: u64
    }

    #[derive(Drop, Serde)]
    struct PoolInfo {
        pool: felt252,
        total_borrow: u256,
        total_supply: u256,
        ur: u256,
        borrow_apr: u256,
        supply_apy: u256
    }

    #[storage]
    struct Storage {
        market_address: ContractAddress,
        token: ContractAddress, // STRK
        collateral_token: ContractAddress, // ET
        lp_token_address: ContractAddress, // LP-STRK/ETH
        total_supply: u256,
        total_borrow: u256,
        user_to_lp_owned: LegacyMap<ContractAddress, u256>,
        user_borrow_quantity: LegacyMap<ContractAddress, u256>,
        user_borrow_info: LegacyMap<
            (ContractAddress, u256), UserBorrowInfo
        >, // Mapping: User Address => Borrow ID => User Borrow Info
        active_borrower: LegacyMap<u256, ContractAddress>, // This serves FE purpose
        active_borrower_num: u256,
        active_borrower_index: LegacyMap<ContractAddress, u256>,
        expect_interest_amount_per_year: u256,
        actual_interest_amount: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        _token: ContractAddress,
        _collateral_token: ContractAddress,
        lp_token_class_hash: ClassHash,
        _market_address: ContractAddress
    ) {
        // Let: khai báo biến trong logic
        let token_symbol = IERC20MetadataDispatcher { contract_address: _token }.symbol();
        let collateral_token_symbol = IERC20MetadataDispatcher {
            contract_address: _collateral_token
        }
            .symbol();
        let lp_token_symbol = "LP-" + token_symbol + "/" + collateral_token_symbol;
        let lp_token_name = lp_token_symbol.clone();

        let mut hash_data: Array<felt252> = array![];
        let mut calldata: Array<felt252> = array![];
        let mut deploy_data = LPTokenDeployData {
            name: lp_token_name, symbol: lp_token_symbol, _market_contract: _market_address
        };
        Serde::serialize(@deploy_data, ref hash_data);
        let salt = poseidon_hash_span(hash_data.span());
        Serde::serialize(@deploy_data, ref calldata);
        let deploy_from_zero: bool = false;

        let (_lp_token_address, _) = deploy_syscall(
            lp_token_class_hash, salt, calldata.span(), deploy_from_zero
        )
            .unwrap();
        self.market_address.write(_market_address);
        self.token.write(_token);
        self.collateral_token.write(_collateral_token);
        self.lp_token_address.write(_lp_token_address);
    }

    #[abi(embed_v0)]
    impl PoolImpl of IPool<ContractState> {
        fn get_token_name(self: @ContractState) -> ByteArray {
            IERC20MetadataDispatcher { contract_address: self.token.read() }.name()
        }

        fn get_collateral_token_name(self: @ContractState) -> ByteArray {
            IERC20MetadataDispatcher { contract_address: self.collateral_token.read() }.name()
        }

        fn get_token_symbol(self: @ContractState) -> ByteArray {
            IERC20MetadataDispatcher { contract_address: self.token.read() }.symbol()
        }

        fn get_collateral_token_symbol(self: @ContractState) -> ByteArray {
            IERC20MetadataDispatcher { contract_address: self.collateral_token.read() }.symbol()
        }

        fn get_total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn get_total_borrow(self: @ContractState) -> u256 {
            self.total_borrow.read()
        }

        fn get_lp_token_address(self: @ContractState) -> ContractAddress {
            self.lp_token_address.read()
        }

        fn get_user_to_lp_owned(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_to_lp_owned.read(user)
        }

        fn get_user_borrow_quantity(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_borrow_quantity.read(user)
        }

        fn get_user_borrow_info(
            self: @ContractState, user: ContractAddress, borrow_id: u256
        ) -> UserBorrowInfo {
            let user_borrow_quantity = self.user_borrow_quantity.read(user);
            if (borrow_id >= user_borrow_quantity) {
                panic_with_felt252(Error::INVALID_BORROW_ID);
            }
            self.user_borrow_info.read((user, borrow_id))
        }

        fn get_active_borrower_num(self: @ContractState) -> u256 {
            self.active_borrower_num.read()
        }

        fn get_active_borrower_index(self: @ContractState, borrower: ContractAddress) -> u256 {
            assert(borrower.is_non_zero(), Error::INVALID_ADDRESS);
            let index = self.active_borrower_index.read(borrower);
            if (index == 0) {
                assert(self.active_borrower.read(0) == borrower, Error::BORROWER_NOT_EXISTS);
            }
            index
        }

        fn get_active_borrower(self: @ContractState, index: u256) -> ContractAddress {
            let borrower = self.active_borrower.read(index);
            assert(borrower.is_non_zero(), Error::INVALID_INDEX);
            borrower
        }

        fn get_expect_interest_amount_per_year(self: @ContractState) -> u256 {
            self.expect_interest_amount_per_year.read()
        }

        fn get_actual_interest_amount(self: @ContractState) -> u256 {
            self.actual_interest_amount.read()
        }

        fn get_pool_info(self: @ContractState) -> PoolInfo {
            // Pool
            let token_symbol = self.get_token_symbol();
            let collateral_token_symbol = self.get_collateral_token_symbol();
            let pool: felt252 = (token_symbol + "/" + collateral_token_symbol).pending_word;

            // Total Borrow
            let total_borrow = self.total_borrow.read();

            // Total Supply
            let total_supply = self.total_supply.read();

            // UR
            let mut ur = 0;
            if (total_supply.is_non_zero()) {
                ur = total_borrow
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / total_supply;
            }

            // Borrow APR
            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            // Supply APY
            let mut supply_apy = 0;
            if (total_supply.is_non_zero()) {
                supply_apy = self.expect_interest_amount_per_year.read()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / (total_supply - self.actual_interest_amount.read())
            }

            PoolInfo { pool, total_borrow, total_supply, ur, borrow_apr, supply_apy }
        }

        fn calculate_utilization_rate(self: @ContractState) -> u256 {
            let total_supply = self.get_total_supply();
            if (total_supply.is_zero()) {
                0
            } else {
                self.get_total_borrow()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / total_supply
            }
        }

        fn calculate_borrow_apr(self: @ContractState) -> u256 {
            let ur = self.calculate_utilization_rate();

            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            borrow_apr
        }

        fn calculate_supply_apy(self: @ContractState) -> u256 {
            let total_supply = self.total_supply.read();
            if (total_supply.is_zero()) {
                0
            } else {
                self.expect_interest_amount_per_year.read()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / (self.total_supply.read() - self.actual_interest_amount.read())
            }
        }

        fn add_user_lp_owned(ref self: ContractState, user: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.user_to_lp_owned.write(user, self.user_to_lp_owned.read(user) + amount);
        }

        fn subtract_user_lp_owned(ref self: ContractState, user: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.user_to_lp_owned.write(user, self.user_to_lp_owned.read(user) - amount);
        }

        fn add_total_supply(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.total_supply.write(self.total_supply.read() + amount);
        }

        fn subtract_total_supply(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.total_supply.write(self.total_supply.read() - amount);
        }

        fn add_total_borrow(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.total_borrow.write(self.total_borrow.read() + amount);
        }

        fn subtract_total_borrow(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self.total_borrow.write(self.total_borrow.read() - amount);
        }

        fn add_user_borrow_info(
            ref self: ContractState, user: ContractAddress, _user_borrow_info: UserBorrowInfo
        ) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            // Get borrow id
            let borrow_id = self.user_borrow_quantity.read(user);

            // Add user borrow info
            self.user_borrow_info.write((user, borrow_id), _user_borrow_info);

            // Update user borrow quantity
            self.user_borrow_quantity.write(user, borrow_id + 1);

            // Add to active borrower
            if (borrow_id == 0) {
                let active_borrower_num = self.active_borrower_num.read();
                self.active_borrower.write(active_borrower_num, user);
                self.active_borrower_index.write(user, active_borrower_num);
                self.active_borrower_num.write(active_borrower_num + 1);
            }
        }

        fn remove_borrow_info(ref self: ContractState, user: ContractAddress, borrow_id: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            let default_user_borrow_info = UserBorrowInfo {
                borrow_amount: Default::default(),
                collateral_amount: Default::default(),
                hf: Default::default(),
                borrow_apr: Default::default(),
                borrow_start_time: Default::default()
            };

            // Remove borrow info
            let final_index = self.get_user_borrow_quantity(user) - 1;
            if (borrow_id < final_index) {
                let final_index_borrow_info = self.user_borrow_info.read((user, final_index));

                self.user_borrow_info.write((user, borrow_id), final_index_borrow_info);
            }
            self.user_borrow_info.write((user, final_index), default_user_borrow_info);

            // Update user borrow quantity
            self.user_borrow_quantity.write(user, final_index);

            // Remove from active borrower
            if (final_index == 0) {
                let active_borrower_index = self.active_borrower_index.read(user);
                let active_borrower_final_index = self.active_borrower_num.read() - 1;
                if (active_borrower_index < active_borrower_final_index) {
                    let final_index_borrower = self
                        .active_borrower
                        .read(active_borrower_final_index);

                    self.active_borrower.write(active_borrower_index, final_index_borrower);
                }
                self
                    .active_borrower
                    .write(active_borrower_final_index, contract_address_const::<0>());
                self.active_borrower_index.write(user, 0);
                self.active_borrower_num.write(active_borrower_final_index);
            }
        }

        fn add_expect_interest_amount_per_year(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self
                .expect_interest_amount_per_year
                .write(self.expect_interest_amount_per_year.read() + amount);
        }

        fn subtract_expect_interest_amount_per_year(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            self
                .expect_interest_amount_per_year
                .write(self.expect_interest_amount_per_year.read() - amount);
        }

        fn add_actual_interest_amount(ref self: ContractState, amount: u256) {
            self.actual_interest_amount.write(self.actual_interest_amount.read() + amount);
        }

        fn approve_transfer(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.market_address.read(), Error::NOT_MARKET_CONTRACT);

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.approve(self.market_address.read(), amount);
        }
    }
}
