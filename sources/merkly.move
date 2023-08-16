module merkly::onft {
    use std::vector;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::coin::Self;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_std::simple_map::{Self, SimpleMap};
    use layerzero_common::serde;    
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use layerzero_common::utils::{vector_slice, assert_length};
    use layerzero::endpoint::{Self, UaCapability};
    use layerzero::lzapp;
    use layerzero::remote;
    use aptos_framework::object::{Self};
    use aptos_token_objects::aptos_token;
    use aptos_std::from_bcs::to_address;


    // Constants
    const PRECEIVE: u8 = 0;
    const PSEND: u8 = 1;
    const COUNTER_PAYLOAD: vector<u8> = vector<u8>[1, 2, 3, 4];
    /// 
    /// Seed
    /// 
    const MERKLY_SEED: vector<u8> = b"MERKLY";

    //
    // Errors
    //
    const ERROR_SIGNER_NOT_ADMIN: u64 = 0;
    const ERROR_STATE_NOT_INITIALIZED: u64 = 1;
    const ERROR_TOO_MANY_NFTS: u64 = 2;


    //
    // Events
    //
    struct MintEvent has store, drop {
        owner: address,
        token_id: u32,
        uri: String,
        creation_number: u64,
        timestamp: u64
    }

    struct SendEvent has store, drop {
        sender: address,
        dst_chain_id: u64,
        dst_address: vector<u8>,
        receiver: vector<u8>,
        token_id: u32,
        timestamp: u64
    }

    struct RecvEvent has store, drop {
        src_chain_id: u64,
        src_address: vector<u8>,
        receiver: address,
        token_id: u32,
        timestamp: u64
    }

    //
    // Data structures
    //

    struct OnftUA {}

    struct MerklyCap has key {
        cap: UaCapability<OnftUA>,
    }

    struct State has key {
        nextMintId: u32,
        endMintId: u32,
        nft_collection: SimpleMap<u32, u64>, // SimpleMap<ONFT Token id, Aptos NFT Creation Number>
        mint_events: EventHandle<MintEvent>,
        send_events: EventHandle<SendEvent>,
        recv_events: EventHandle<RecvEvent>,
        cap: SignerCapability
    }

    //
    // Assert functions
    //
    inline fun assert_signer_is_admin(admin: &signer) {
        // Assert that address of the parameter is the same as admin in Move.toml
        assert!(signer::address_of(admin) == @merkly, ERROR_SIGNER_NOT_ADMIN);
    }

    inline fun assert_state_initialized() {
        // Assert that State resource exists at the admin address
        assert!(exists<State>(@merkly), ERROR_STATE_NOT_INITIALIZED);
    }

    inline fun assert_too_many_nfts(nextMintId: u32, endMintId: u32) {
        assert!(nextMintId <= endMintId, ERROR_TOO_MANY_NFTS);
    }

    //
    // Entry functions
    //

    // init function
    public entry fun init(
        admin: &signer, 
        startMintId: u32,
        endMintId: u32,
    ) {
        assert_signer_is_admin(admin);

        let (resource_signer, signer_cap) = account::create_resource_account(admin, MERKLY_SEED);

        let cap = endpoint::register_ua<OnftUA>(admin);
        lzapp::init(admin, cap);
        remote::init(admin);

        move_to(admin, MerklyCap { cap });

        let adminer = account::create_signer_with_capability(&signer_cap);

        move_to<State>(admin, State {
            nextMintId: startMintId,
            endMintId,
            nft_collection: simple_map::create<u32, u64>(),
            mint_events: account::new_event_handle<MintEvent>(&resource_signer),
            send_events: account::new_event_handle<SendEvent>(&resource_signer),
            recv_events: account::new_event_handle<RecvEvent>(&resource_signer),
            cap: signer_cap
        });

        let uri = string::utf8(b"https://api.merkly.com/merk-onft.jpg");
        aptos_token::create_collection(
            &adminer,
            string::utf8(b"Merkly NFT Collection"),
            100000, // max_supply
            string::utf8(b"Merkly NFT Collection"),
            uri,
            false,  // mutable_description
            false,  // mutable_royalty
            false,  // mutable_uri
            false,  // mutable_token_description
            false,  // mutable_token_name
            false,  // mutable_token_properties
            false,  // mutable_token_uri
            false,  // tokens_burnable_by_creator
            true,  // tokens_freezable_by_creator
            1,  // royalty_numerator
            10,  // royalty_denominator
        );
    }

    // mint nft
    public entry fun mint(
        minter: &signer,
        collection_name: String,
        nft_name: String,
    ) acquires State {

        let (tokenId, creation_number, uri) = mint_nft(signer::address_of(minter), collection_name, nft_name);

        let state = borrow_global_mut<State>(@merkly);

        event::emit_event<MintEvent>(
            &mut state.mint_events,
            MintEvent{
                owner: signer::address_of(minter),
                token_id: tokenId,
                uri: uri,
                creation_number: creation_number,
                timestamp: timestamp::now_seconds()
        });
    }

    // send nft
    public entry fun send(
        sender: &signer,          // ONFT owner
        dstChainId: u64,        // dst Chain ID
        // dst_address: vector<u8>, // dst UA address
        dst_receiver: vector<u8>,  // ONFT receiver
        fee: u64,               // fee to send
        tokenId: u32            // ONFT token ID to send
    ) acquires State, MerklyCap {

        let admin_address = account::create_resource_address(&@merkly, MERKLY_SEED);
        // send to lzendpoint
        let fee_in_coin = coin::withdraw<AptosCoin>(sender, fee);
        let sender_address = signer::address_of(sender);
        
        let state = borrow_global_mut<State>(@merkly);
        let cap = borrow_global<MerklyCap>(@merkly);

        let _adminer = account::create_signer_with_capability(&state.cap);
        let dst_address = remote::get(@merkly, dstChainId);
        let payload = encode_send_payload(dst_receiver, tokenId);
        let (_, refund) = lzapp::send<OnftUA>(dstChainId, dst_address, payload, fee_in_coin, vector::empty<u8>(), vector::empty<u8>(), &cap.cap);
        // send nft here
        let creation_number = simple_map::borrow(&state.nft_collection, &tokenId);
        let token_address = object::create_guid_object_address(admin_address, *creation_number);
        let token_obj = object::address_to_object<aptos_token::AptosToken>(token_address);
        assert!(object::owner(token_obj) == sender_address, 199999);

        // object::transfer(sender, token_obj, admin_address);
        object::transfer_raw(sender, token_address, admin_address);
        // aptos_token::freeze_transfer(&adminer,token_obj );
        // deposit refunds
        coin::deposit(sender_address, refund);

        event::emit_event<SendEvent>(
            &mut state.send_events,
            SendEvent{
                sender: signer::address_of(sender),
                dst_chain_id: dstChainId,
                dst_address: dst_address,
                receiver: dst_receiver,
                token_id: tokenId,
                timestamp: timestamp::now_seconds()           
        });
    }

    // receive nft 
    public entry fun lz_receive(chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires State, MerklyCap {
        lz_receive_internal(chain_id, src_address, payload);
    }

    fun lz_receive_internal(
        src_chain_id: u64, 
        src_address: vector<u8>, 
        payload: vector<u8>
    ) : (u32) acquires State, MerklyCap {
        let admin_address = account::create_resource_address(&@merkly, MERKLY_SEED);

        remote::assert_remote(@merkly, src_chain_id, src_address);
        let cap = borrow_global<MerklyCap>(@merkly);
        endpoint::lz_receive<OnftUA>(src_chain_id, src_address, payload, &cap.cap);

        // get receiver address and tokenId from payload
        let (receiver_address, tokenId) = decode_receive_payload(&payload);

        // if tokenId exists send to receiver or if not mint tokenId
        let state = borrow_global_mut<State>(@merkly);
        let adminer = account::create_signer_with_capability(&state.cap);

        event::emit_event<RecvEvent>(
            &mut state.recv_events,
            RecvEvent {
                src_chain_id,
                src_address,
                receiver: receiver_address,
                token_id: tokenId,
                timestamp: timestamp::now_seconds()                
        });

        if (simple_map::contains_key(&state.nft_collection, &tokenId)) {
            let creation_number = simple_map::borrow(&state.nft_collection, &tokenId);
            let token_address = object::create_guid_object_address(admin_address, *creation_number);
            let _token_obj = object::address_to_object<aptos_token::AptosToken>(token_address);
            // object::transfer(&adminer, token_obj, (receiver_address));
            object::transfer_raw(&adminer, token_address, (receiver_address));
        } else {
            mint_nft((receiver_address), string::utf8(b"Merkly"), string::utf8(b"Merkly ONFT"));
        };

        (tokenId)
    }
    
    public fun quote_fee(dst_chain_id: u64, pay_in_zro: bool, adapter_params: vector<u8>, msglib_params: vector<u8>): (u64, u64) {
        endpoint::quote_fee(@merkly, dst_chain_id, 64, pay_in_zro, adapter_params, msglib_params)
    }

    //
    // internal functions
    //

    // mint nft 
    fun mint_nft(
        account: address,
        _collection_name: String,
        _nft_name: String,
    ) : (u32, u64, String) acquires State  {
        assert_state_initialized();

        let admin_address = account::create_resource_address(&@merkly, MERKLY_SEED);

        let state = borrow_global_mut<State>(@merkly);

        let adminer = account::create_signer_with_capability(&state.cap);

        assert_too_many_nfts(state.nextMintId, state.endMintId);

        let _collection = state.nft_collection;

        let tokenId = state.nextMintId;

        // let uri = std::string_utils::format1(&b"https://api.merkly.com/api/merk/#{}", tokenId);
        let uri = string::utf8(b"https://api.merkly.com/merk-onft.jpg");

        let creation_number = account::get_guid_next_creation_num(admin_address);

        aptos_token::mint(
          &adminer,
          string::utf8(b"Merkly NFT Collection"),
          string::utf8(b"MERKLY"),
          std::string_utils::format2(&b"MERKLY #{} #{}", tokenId, creation_number),
          uri,
          vector::empty<String>(),
          vector::empty<String>(),
          vector::empty<vector<u8>>()
        );

        state.nextMintId = tokenId + 1;

        let token_obj = object::address_to_object<aptos_token::AptosToken>(object::create_guid_object_address(admin_address, creation_number));
        
        object::transfer(&adminer, token_obj, account);

        simple_map::add(&mut state.nft_collection, tokenId, creation_number);

        (tokenId, creation_number, uri)
    }

    // encode send payload : receiver_address(32) + tokenId(4)
    fun encode_send_payload(
        dst_receiver: vector<u8>,
        tokenId: u32
    ): vector<u8> {
        // assert_length(&dst_receiver, 32);

        let payload = vector::empty<u8>();
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u16(&mut payload, (((tokenId >> 16) & 0xFFFF) as u64));
        serde::serialize_u16(&mut payload, ((tokenId) as u64));

        // assert_length(&payload, 36);

        payload
    }

    // decode received payload : receiver_address(32) + tokenId(4)
    fun decode_receive_payload(payload: &vector<u8>): (address, u32) {
        assert_length(payload, 36);

        let receiver_address = to_address(vector_slice(payload, 0, 32));
        let tokenId1 = serde::deserialize_u16(&vector_slice(payload, 32, 34));
        let tokenId2 = serde::deserialize_u16(&vector_slice(payload, 34, 36));

        (receiver_address, ((tokenId2 | tokenId1 << 16) as u32))
    }

    #[test_only]
    public fun initialize(account: &signer) {
       init(account, 1000, 20000);
    }

    #[test_only]
    use aptos_framework::coin::{MintCapability, BurnCapability};

    #[test_only]
    struct AptosCoinCap has key {
        mint_cap: MintCapability<AptosCoin>,
        burn_cap: BurnCapability<AptosCoin>,
    }

    #[test_only]
    fun setup(aptos: &signer, core_resources: &signer, addresses: vector<address>) {
        use aptos_framework::aptos_coin;
        use aptos_framework::aptos_account;

        // init the aptos_coin and give merkly_root the mint ability.
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);

        aptos_account::create_account(signer::address_of(core_resources));
        let coins = coin::mint<AptosCoin>(
            18446744073709551615,
            &mint_cap,
        );
        coin::deposit<AptosCoin>(signer::address_of(core_resources), coins);

        let i = 0;
        while (i < vector::length(&addresses)) {
            aptos_account::transfer(core_resources, *vector::borrow(&addresses, i), 100000000000);
            i = i + 1;
        };

        // gracefully shutdown
        move_to(core_resources, AptosCoinCap {
            mint_cap,
            burn_cap
        });
    }

    // sender: admin account
    // chain_id: trusted remote chain id
    // remote_addr: trusted contract address
    public entry fun set_trust_remote(sender: &signer, chain_id: u64, remote_addr: vector<u8>) {
        assert_signer_is_admin(sender);
        // let state = borrow_global_mut<State>(@merkly);
        // let resource = account::create_signer_with_capability(&state.cap);
        remote::set(sender, chain_id, remote_addr);
    }

     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, merkly_root = @merkly, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth)]
    fun test_send_recv(
        aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, merkly_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer
    ) acquires State, MerklyCap {
        use std::bcs;
        use std::signer;
        use layerzero::test_helpers;
        use layerzero_common::packet;
        use layerzero_common::serde;
        use aptos_token_objects::token::{Self};
        use std::option;
        use aptos_token_objects::royalty;

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        
        let layerzero_addr = signer::address_of(layerzero_root);
        let oracle_addr = signer::address_of(oracle_root);
        let relayer_addr = signer::address_of(relayer_root);
        let executor_addr = signer::address_of(executor_root);
        let merkly_addr = signer::address_of(merkly_root);
        
        setup(aptos, core_resources, vector<address>[layerzero_addr, oracle_addr, relayer_addr, executor_addr, merkly_addr]);

        // prepare the endpoint
        let src_chain_id: u64 = 20030;
        let dst_chain_id: u64 = 20030;

        test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, src_chain_id, dst_chain_id);       

        // init test
        init(merkly_root, 1000, 2000);

        let state = borrow_global<State>(@merkly);
        assert!(simple_map::length(&state.nft_collection) == 0, 0);
        assert!(event::counter(&state.mint_events) == 0, 4);
        assert!(event::counter(&state.send_events) == 0, 5);
        assert!(event::counter(&state.recv_events) == 0, 6);

        let resource_account_address = account::create_resource_address(&@admin, MERKLY_SEED);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 10);


        // mint test
        let account = merkly_root; //account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Merkly Collection");
        let nft_name = string::utf8(b"Merkly ONFT");

        let (tokenId, creation_number, uri) = mint_nft(signer::address_of(merkly_root), collection_name, nft_name);

        let state = borrow_global_mut<State>(@merkly);

        event::emit_event<MintEvent>(
            &mut state.mint_events,
            MintEvent{
                owner: signer::address_of(account),
                token_id: tokenId,
                uri: uri,
                creation_number: creation_number,
                timestamp: timestamp::now_seconds()
        });

        // let uri = std::string_utils::format1(&b"https://api.merkly.com/api/merk/#{}", tokenId);\
        let uri = string::utf8(b"https://api.merkly.com/merk-onft.jpg");

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.nft_collection) == 1, 0);
        assert!(simple_map::contains_key(&state.nft_collection, &tokenId), 1);
        assert!(event::counter(&state.mint_events) == 1, 3);

        let _creation_number = simple_map::borrow(&state.nft_collection, &tokenId);

        let resource_account_address = account::create_resource_address(&@merkly, MERKLY_SEED);
        let token_address = object::create_guid_object_address(resource_account_address, *_creation_number);
        let token_object = object::address_to_object<aptos_token::AptosToken>(token_address);
        assert!(!aptos_token::are_properties_mutable(token_object), 13);
        assert!(!aptos_token::is_burnable(token_object), 14);
        assert!(aptos_token::is_freezable_by_creator(token_object), 15);
        assert!(!aptos_token::is_mutable_description(token_object), 16);
        assert!(!aptos_token::is_mutable_name(token_object), 17);
        assert!(!aptos_token::is_mutable_uri(token_object), 18);
        assert!(token::creator(token_object) == resource_account_address, 19);
        assert!(token::collection_name(token_object) == string::utf8(b"Merkly NFT Collection"), 20);
        assert!(token::description(token_object) == string::utf8(b"MERKLY"), 21);
        assert!(token::name(token_object) == std::string_utils::format2(&b"MERKLY #{} #{}", tokenId, creation_number), 22);
        assert!(token::uri(token_object) == uri, 23);

        let maybe_token_royalty = token::royalty(token_object);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27); 


        // send & recv test
        let src_address = @merkly;
        let src_address_bytes = bcs::to_bytes(&src_address);

        let dst_address = @merkly;
        let dst_address_bytes = bcs::to_bytes(&dst_address);

        remote::set(merkly_root, dst_chain_id, dst_address_bytes);
        // let addr = merkly_addr; //loopback
        // assert!(get_count(addr) == 0, 0);

        let confirmations_bytes = vector::empty();
        serde::serialize_u64(&mut confirmations_bytes, 20);
        lzapp::set_config<OnftUA>(merkly_root, 1, 0, dst_chain_id, 3, confirmations_bytes);
        let config = layerzero::uln_config::get_uln_config(@merkly, dst_chain_id);
        assert!(layerzero::uln_config::oracle(&config) == oracle_addr, 0);
        assert!(layerzero::uln_config::relayer(&config) == relayer_addr, 0);
        assert!(layerzero::uln_config::inbound_confirmations(&config) == 15, 0);
        assert!(layerzero::uln_config::outbound_confiramtions(&config) == 20, 0);

        // counter send - receive flow
        let (fee, _) = quote_fee(dst_chain_id, false, vector::empty<u8>(), vector::empty<u8>());
        // assert!(fee == 10 + 100 + 1 * 4 + 1, 0); // oracle fee + relayer fee + treasury fee

        send(
            merkly_root,
            dst_chain_id,
            bcs::to_bytes(&@0xCAFE),
            fee,
            tokenId
        );
        assert!(tokenId == 1000, 199999);
        // oracle and relayer submission
        let confirmation: u64 = 77;
        let payload = encode_send_payload(bcs::to_bytes(&@0xCAFE), tokenId);
        let nonce = 1;
        let emitted_packet = packet::new_packet(src_chain_id, src_address_bytes, dst_chain_id, dst_address_bytes, nonce, payload);

        test_helpers::deliver_packet<OnftUA>(oracle_root, relayer_root, emitted_packet, confirmation);

        // receive from remote
        let p = lz_receive_internal(dst_chain_id, dst_address_bytes, payload);
        assert!(p == tokenId, 1000);
    }

    // #[test]
    // fun test_mint() acquires State{
    //     use aptos_token_objects::token::{Self};
    //     use std::signer;
    //     use aptos_token_objects::aptos_token;
    //     use std::option;
    //     use aptos_token_objects::royalty;

    //     let admin = account::create_account_for_test(@admin);
    //     init(&admin, 100, 1000);

    //     let account = account::create_account_for_test(@0xCAFE);
    //     let collection_name = string::utf8(b"Merkly Collection");
    //     let nft_name = string::utf8(b"Merkly ONFT");

    //     let (tokenId, creation_number, uri) = mint_nft(signer::address_of(&account), collection_name, nft_name);

    //     let state = borrow_global_mut<State>(@merkly);

    //     event::emit_event<MintEvent>(
    //         &mut state.mint_events,
    //         MintEvent{
    //             owner: signer::address_of(&account),
    //             token_id: tokenId,
    //             uri: uri,
    //             creation_number: creation_number,
    //             timestamp: timestamp::now_seconds()
    //     });

    //     let uri = std::string_utils::format1(&b"https://api.merkly.com/api/merk/#{}", tokenId);

    //     let state = borrow_global<State>(@admin);
    //     assert!(simple_map::length(&state.nft_collection) == 1, 0);
    //     assert!(simple_map::contains_key(&state.nft_collection, &tokenId), 1);
    //     assert!(event::counter(&state.mint_events) == 1, 3);

    //     let _creation_number = simple_map::borrow(&state.nft_collection, &tokenId);

    //     let resource_account_address = account::create_resource_address(&@merkly, MERKLY_SEED);
    //     let token_address = object::create_guid_object_address(resource_account_address, *_creation_number);
    //     let token_object = object::address_to_object<aptos_token::AptosToken>(token_address);
    //     assert!(!aptos_token::are_properties_mutable(token_object), 13);
    //     assert!(!aptos_token::is_burnable(token_object), 14);
    //     assert!(aptos_token::is_freezable_by_creator(token_object), 15);
    //     assert!(!aptos_token::is_mutable_description(token_object), 16);
    //     assert!(!aptos_token::is_mutable_name(token_object), 17);
    //     assert!(!aptos_token::is_mutable_uri(token_object), 18);
    //     assert!(token::creator(token_object) == resource_account_address, 19);
    //     assert!(token::collection_name(token_object) == string::utf8(b"Merkly"), 20);
    //     assert!(token::description(token_object) == string::utf8(b"Merkly"), 21);
    //     assert!(token::name(token_object) == string::utf8(b"Merkly"), 22);
    //     assert!(token::uri(token_object) == uri, 23);

    //     let maybe_token_royalty = token::royalty(token_object);
    //     assert!(option::is_some(&maybe_token_royalty), 24);

    //     let token_royalty = option::extract(&mut maybe_token_royalty);
    //     assert!(royalty::denominator(&token_royalty) == 10, 25);
    //     assert!(royalty::numerator(&token_royalty) == 1, 26);
    //     assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);        
    // }
}
