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

        move_to<State>(admin, State {
            nextMintId: startMintId,
            endMintId,
            nft_collection: simple_map::create<u32, u64>(),
            mint_events: account::new_event_handle<MintEvent>(&resource_signer),
            send_events: account::new_event_handle<SendEvent>(&resource_signer),
            recv_events: account::new_event_handle<RecvEvent>(&resource_signer),
            cap: signer_cap
        });

        let cap = endpoint::register_ua<OnftUA>(admin);
        lzapp::init(admin, cap);
        remote::init(admin);

        move_to(&resource_signer, MerklyCap { cap });
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
        // send to lzendpoint
        let admin_address = account::create_resource_address(&@merkly, MERKLY_SEED);
        
        let fee_in_coin = coin::withdraw<AptosCoin>(sender, fee);
        let sender_address = signer::address_of(sender);

        let cap = borrow_global<MerklyCap>(@merkly);
        let state = borrow_global_mut<State>(@merkly);

        let adminer = account::create_signer_with_capability(&state.cap);

        let dst_address = remote::get(@merkly, dstChainId);
        let payload = encode_send_payload(dst_receiver, tokenId);
        let (_, refund) = lzapp::send<OnftUA>(dstChainId, dst_address, payload, fee_in_coin, vector::empty<u8>(), vector::empty<u8>(), &cap.cap);
        // send nft here
        let creation_number = simple_map::borrow(&state.nft_collection, &tokenId);
        let token_obj = object::address_to_object<aptos_token::AptosToken>(object::create_guid_object_address(admin_address, *creation_number));
        object::transfer(&adminer, token_obj, sender_address);
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
    public entry fun lz_receive(
        src_chain_id: u64, 
        src_address: vector<u8>, 
        payload: vector<u8>
    ) acquires State, MerklyCap {
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
            let token_obj = object::address_to_object<aptos_token::AptosToken>(object::create_guid_object_address(admin_address, *creation_number));
            object::transfer(&adminer, token_obj, (receiver_address));
        } else {
            mint_nft((receiver_address), string::utf8(b"Merkly"), string::utf8(b"Merkly ONFT"));
        }

        
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
        let uri = std::string_utils::format1(&b"https://api.merkly.com/api/merk/#{}", tokenId);

        let creation_number = account::get_guid_next_creation_num(admin_address);

        aptos_token::mint(
          &adminer,
          string::utf8(b"MERK"),
          string::utf8(b"MERK"),
          string::utf8(b"MERK"),
          uri,
          vector::empty<String>(),
          vector::empty<String>(),
          vector::empty<vector<u8>>()
        );

        state.nextMintId = tokenId + 1;

        let token_obj = object::address_to_object<aptos_token::AptosToken>(object::create_guid_object_address(admin_address, creation_number));
        object::transfer(&adminer, token_obj, account);

        (tokenId, creation_number, uri)
    }

    // encode send payload : receiver_address(32) + tokenId(32)
    fun encode_send_payload(
        dst_receiver: vector<u8>,
        tokenId: u32
    ): vector<u8> {
        assert_length(&dst_receiver, 32);

        let payload = vector::empty<u8>();
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u16(&mut payload, (((tokenId >> 16) & 0xFFFF) as u64));
        serde::serialize_u16(&mut payload, ((tokenId) as u64));

        payload
    }

    // decode received payload : receiver_address(32) + tokenId(32)
    fun decode_receive_payload(payload: &vector<u8>): (address, u32) {
        assert_length(payload, 64);

        let receiver_address = to_address(vector_slice(payload, 0, 32));
        let tokenId1 = serde::deserialize_u16(&vector_slice(payload, 33, 48));
        let tokenId2 = serde::deserialize_u16(&vector_slice(payload, 49, 64));

        (receiver_address, ((tokenId2 << 16 | tokenId1) as u32))
    }


    #[test]
    fun test_init() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin, 100, 1000);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.nft_collection) == 0, 0);
        assert!(event::counter(&state.mint_events) == 0, 4);
        assert!(event::counter(&state.send_events) == 0, 5);
        assert!(event::counter(&state.recv_events) == 0, 6);

        let resource_account_address = account::create_resource_address(&@admin, MERKLY_SEED);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 10);
    }

    #[test]
    fun test_mint() acquires State{
        use aptos_token_objects::token::{Self};
        use std::signer;
        use aptos_token_objects::aptos_token;
        use std::option;
        use aptos_token_objects::royalty;

        let admin = account::create_account_for_test(@admin);
        init(&admin, 100, 1000);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Merkly Collection");
        let nft_name = string::utf8(b"Merkly ONFT");

        let (tokenId, creation_number, uri) = mint_nft(signer::address_of(&account), collection_name, nft_name);

        let state = borrow_global_mut<State>(@merkly);

        event::emit_event<MintEvent>(
            &mut state.mint_events,
            MintEvent{
                owner: signer::address_of(&account),
                token_id: tokenId,
                uri: uri,
                creation_number: creation_number,
                timestamp: timestamp::now_seconds()
        });

        let uri = std::string_utils::format1(&b"https://api.merkly.com/api/merk/#{}", tokenId);

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
        assert!(token::collection_name(token_object) == string::utf8(b"Merkly"), 20);
        assert!(token::description(token_object) == string::utf8(b"Merkly"), 21);
        assert!(token::name(token_object) == string::utf8(b"Merkly"), 22);
        assert!(token::uri(token_object) == uri, 23);

        let maybe_token_royalty = token::royalty(token_object);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);        
    }
}
