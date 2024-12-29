#[starknet::contract]
mod Token {
    // Starknet imports
    use starknet::{ContractAddress, get_caller_address};

    // Library imports
    use openzeppelin::token::erc20::ERC20Component;

    // Internal imports
    use lending_protocol::message::Error;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        owner: ContractAddress
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event
    }

    #[constructor]
    // Constructor is a function that's called once and only when deploying contract
    fn constructor(
        ref self: ContractState, name: ByteArray, symbol: ByteArray, _owner: ContractAddress
    ) {
        self.erc20.initializer(name, symbol);
        self.owner.write(_owner);
    }

    #[external(v0)]
    fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
        let caller = get_caller_address();
        assert(caller == self.owner.read(), Error::NOT_OWNER);

        self.erc20._mint(recipient, amount);
    }

    #[external(v0)]
    fn burn(ref self: ContractState, account: ContractAddress, amount: u256) {
        let caller = get_caller_address();
        assert(caller == self.owner.read(), Error::NOT_OWNER);

        self.erc20._burn(account, amount);
    }
}
