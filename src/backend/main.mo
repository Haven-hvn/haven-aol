import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import VarArray "mo:core/VarArray";
import Text "mo:core/Text";
import Char "mo:core/Char";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Map "mo:core/Map";
import Sha256 "mo:sha2/Sha256";
import Secp256k1 "mo:secp256k1";

// Haven-AOL (Always Online on DFINITY ICP): smart access management with conditional keys
// for web3 — DAOs, DataDAOs, agent swarms, and shared gated resources.
persistent actor {

  // ── EVM RPC canister types (from evm_rpc.did) ──────────────────────

  type RpcServices = {
    #EthMainnet : ?[EthMainnetService];
    #EthSepolia : ?[EthSepoliaService];
    #ArbitrumOne : ?[L2MainnetService];
    #BaseMainnet : ?[L2MainnetService];
    #OptimismMainnet : ?[L2MainnetService];
  };

  type EthMainnetService = {
    #Alchemy; #Ankr; #BlockPi; #Cloudflare; #PublicNode; #Llama;
  };

  type EthSepoliaService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Sepolia;
  };

  type L2MainnetService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Llama;
  };

  type ConsensusStrategy = {
    #Equality;
    #Threshold : { total : ?Nat8; min : Nat8 };
  };

  type RpcConfig = {
    responseSizeEstimate : ?Nat64;
    responseConsensus : ?ConsensusStrategy;
  };

  type TransactionRequest = {
    to : ?Text;
    input : ?Text;
    accessList : ?[{ address : Text; storageKeys : [Text] }];
    blobVersionedHashes : ?[Text];
    blobs : ?[Text];
    chainId : ?Nat;
    from : ?Text;
    gas : ?Nat;
    gasPrice : ?Nat;
    maxFeePerBlobGas : ?Nat;
    maxFeePerGas : ?Nat;
    maxPriorityFeePerGas : ?Nat;
    nonce : ?Nat;
    type_ : ?Text;
    value : ?Nat;
  };

  type BlockTag = {
    #Earliest; #Safe; #Finalized; #Latest; #Number : Nat; #Pending;
  };

  type CallArgs = {
    transaction : TransactionRequest;
    block : ?BlockTag;
  };

  type RejectionCode = {
    #NoError; #CanisterError; #SysTransient;
    #DestinationInvalid; #Unknown; #SysFatal; #CanisterReject;
  };

  type HttpOutcallError = {
    #IcError : { code : RejectionCode; message : Text };
    #InvalidHttpJsonRpcResponse : { status : Nat16; body : Text; parsingError : ?Text };
  };

  type JsonRpcError = { code : Int64; message : Text };

  type ValidationError = {
    #CredentialPathNotAllowed;
    #HostNotAllowed : Text;
    #CredentialHeaderNotAllowed;
    #UrlParseError : Text;
    #Custom : Text;
  };

  type ProviderError = {
    #TooFewCycles : { expected : Nat; received : Nat };
    #MissingRequiredProvider;
    #ProviderNotFound;
    #NoPermission;
    #InvalidRpcConfig : Text;
  };

  type RpcError = {
    #JsonRpcError : JsonRpcError;
    #ProviderError : ProviderError;
    #ValidationError : ValidationError;
    #HttpOutcallError : HttpOutcallError;
  };

  type CallResult = {
    #Ok : Text;
    #Err : RpcError;
  };

  type RpcService = {
    #Provider : Nat64;
    #Custom : { url : Text; headers : ?[{ name : Text; value : Text }] };
    #EthSepolia : EthSepoliaService;
    #EthMainnet : EthMainnetService;
    #ArbitrumOne : L2MainnetService;
    #BaseMainnet : L2MainnetService;
    #OptimismMainnet : L2MainnetService;
  };

  type MultiCallResult = {
    #Consistent : CallResult;
    #Inconsistent : [(RpcService, CallResult)];
  };

  type EvmRpcCanister = actor {
    eth_call : (RpcServices, ?RpcConfig, CallArgs) -> async MultiCallResult;
  };

  // ── VetKD types ────────────────────────────────────────────────────

  type VetKdCurve = { #bls12_381_g2 };

  type VetKdKeyId = {
    curve : VetKdCurve;
    name : Text;
  };

  type VetKdPublicKeyRequest = {
    canister_id : ?Principal;
    context : Blob;
    key_id : VetKdKeyId;
  };

  type VetKdPublicKeyResponse = {
    public_key : Blob;
  };

  type VetKdDeriveKeyRequest = {
    input : Blob;
    context : Blob;
    transport_public_key : Blob;
    key_id : VetKdKeyId;
  };

  type VetKdDeriveKeyResponse = {
    encrypted_key : Blob;
  };

  type VetKdCanister = actor {
    vetkd_public_key : (VetKdPublicKeyRequest) -> async VetKdPublicKeyResponse;
    vetkd_derive_key : (VetKdDeriveKeyRequest) -> async VetKdDeriveKeyResponse;
  };

  // ── Public types ───────────────────────────────────────────────────

  public type Chain = {
    #EthMainnet;
    #EthSepolia;
    #ArbitrumOne;
    #BaseMainnet;
    #OptimismMainnet;
  };

  public type BalanceError = {
    #InvalidAddress : Text;
    #EvmRpcError : Text;
  };

  // ── Constants ──────────────────────────────────────────────────────

  let CYCLE_BUDGET : Nat = 10_000_000_000;
  let APP_NAME : Text = "HavenAOL";
  let EIP712_DOMAIN_TYPEHASH_HEX : Text = "8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866";
  let EIP712_GATE_REQUEST_TYPEHASH_HEX : Text = "88160239aa0076952ec94d7cf6b6b51da1765acd803b051b6d06b3f27623f2c0";
  // VetKD context — protocol v1 identifier (stable across Haven-AOL deployments).
  let VETKD_CONTEXT : Blob = Text.encodeUtf8("accessol_v1");
  let usedNonces = Map.empty<Text, Bool>();

  // ── EVM RPC canister reference ─────────────────────────────────────

  transient let evmRpc : EvmRpcCanister = do {
    let ?id = Runtime.envVar("PUBLIC_CANISTER_ID:evm_rpc")
      else Runtime.trap("PUBLIC_CANISTER_ID:evm_rpc not set");
    actor (id) : EvmRpcCanister;
  };

  // ── VetKD canister reference ───────────────────────────────────────
  // Local dev: management canister "aaaaa-aa" with "test_key_1"
  // Mainnet v1: chain-key testing canister with "insecure_test_key_1"

  transient let vetkdCanister : VetKdCanister = do {
    let id = switch (Runtime.envVar("VETKD_CANISTER_ID")) {
      case (?v) { v };
      case null { "aaaaa-aa" }; // default: management canister (local dev)
    };
    actor (id) : VetKdCanister;
  };

  transient let vetkdKeyName : Text = do {
    switch (Runtime.envVar("VETKD_KEY_NAME")) {
      case (?v) { v };
      case null { "key_1" }; // default: local dev key (auto-provisioned by replica)
    };
  };

  // Memoized VetKD public key (96 bytes, deterministic constant).
  // Populated on first warmup; survives canister upgrades.
  persistent var cachedVetKDPublicKey : ?Blob = null;

  func vetkdKeyId() : VetKdKeyId {
    { curve = #bls12_381_g2; name = vetkdKeyName };
  };

  // ── Chain mapping ──────────────────────────────────────────────────

  func chainToRpcServices(chain : Chain) : RpcServices {
    switch (chain) {
      case (#EthMainnet) { #EthMainnet(null) };
      case (#EthSepolia) { #EthSepolia(null) };
      case (#ArbitrumOne) { #ArbitrumOne(null) };
      case (#BaseMainnet) { #BaseMainnet(null) };
      case (#OptimismMainnet) { #OptimismMainnet(null) };
    };
  };

  func chainToText(chain : Chain) : Text {
    switch (chain) {
      case (#EthMainnet) { "EthMainnet" };
      case (#EthSepolia) { "EthSepolia" };
      case (#ArbitrumOne) { "ArbitrumOne" };
      case (#BaseMainnet) { "BaseMainnet" };
      case (#OptimismMainnet) { "OptimismMainnet" };
    };
  };

  // ── Hex utilities ──────────────────────────────────────────────────

  func isHexChar(c : Char) : Bool {
    (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
  };

  func hexCharToNat(c : Char) : Nat {
    let code = Char.toNat32(c);
    if (c >= '0' and c <= '9') { Nat.fromNat32(code - 48) }
    else if (c >= 'a' and c <= 'f') { Nat.fromNat32(code - 87) }
    else { Nat.fromNat32(code - 55) };
  };

  func stripHexPrefix(hex : Text) : Text {
    let chars = hex.chars();
    switch (chars.next(), chars.next()) {
      case (?'0', ?'x') {
        var rest = "";
        for (c in chars) { rest #= Text.fromChar(c) };
        rest;
      };
      case (?'0', ?'X') {
        var rest = "";
        for (c in chars) { rest #= Text.fromChar(c) };
        rest;
      };
      case _ { hex };
    };
  };

  func hexToNat(hex : Text) : ?Nat {
    let stripped = stripHexPrefix(hex);
    if (stripped.size() == 0) return ?0;
    var result : Nat = 0;
    for (c in stripped.chars()) {
      if (not isHexChar(c)) return null;
      result := result * 16 + hexCharToNat(c);
    };
    ?result;
  };

  func toLowerHex(hex : Text) : Text {
    var out = "";
    for (c in hex.chars()) {
      out #= Text.fromChar(if (c >= 'A' and c <= 'F') {
        Char.fromNat32(Char.toNat32(c) + 32)
      } else { c });
    };
    out;
  };

  func natToHexDigit(n : Nat) : Char {
    if (n < 10) {
      Char.fromNat32(48 + Nat32.fromNat(n))
    } else {
      Char.fromNat32(87 + Nat32.fromNat(n))
    };
  };

  func natToFixedHex(value : Nat, length : Nat) : Text {
    var n = value;
    var out = "";
    var i : Nat = 0;
    while (i < length * 2) {
      let nibble = n % 16;
      out := Text.fromChar(natToHexDigit(nibble)) # out;
      n := n / 16;
      i += 1;
    };
    out;
  };

  func blobToHex(bytes : Blob) : Text {
    var out = "";
    for (b in Blob.toArray(bytes).vals()) {
      let n = Nat8.toNat(b);
      out #= Text.fromChar(natToHexDigit(n / 16));
      out #= Text.fromChar(natToHexDigit(n % 16));
    };
    out;
  };

  func hexToBlob(hex : Text) : ?Blob {
    let stripped = stripHexPrefix(hex);
    if (stripped.size() % 2 != 0) return null;
    let chars = stripped.chars();
    let byteLen = stripped.size() / 2;
    let bytes = VarArray.tabulate<Nat8>(byteLen, func _ = 0);
    var idx : Nat = 0;
    label parse while (true) {
      let hi = chars.next();
      let lo = chars.next();
      switch (hi, lo) {
        case (null, null) { break parse };
        case (?h, ?l) {
          if (not isHexChar(h) or not isHexChar(l)) return null;
          let value = hexCharToNat(h) * 16 + hexCharToNat(l);
          bytes[idx] := Nat8.fromNat(value);
          idx += 1;
        };
        case _ { return null };
      };
    };
    ?Blob.fromArray(VarArray.toArray(bytes));
  };

  // Minimal Keccak-f[1600] for EIP-712 / Ethereum.
  let KECCAKF_ROUNDS : Nat = 24;
  let KECCAKF_RNDC : [Nat64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
  ];
  let KECCAKF_ROTC : [Nat] = [
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
  ];
  let KECCAKF_PILN : [Nat] = [
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
  ];

  func rol64(a : Nat64, s : Nat) : Nat64 {
    if (s == 0) return a;
    Nat64.bitrotLeft(a, Nat64.fromNat(s));
  };

  func keccakF(st : [var Nat64]) {
    var round : Nat = 0;
    while (round < KECCAKF_ROUNDS) {
      let bc = VarArray.tabulate<Nat64>(5, func _ = 0);
      var i : Nat = 0;
      while (i < 5) {
        bc[i] := st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
        i += 1;
      };
      i := 0;
      while (i < 5) {
        let t = bc[(i + 4) % 5] ^ rol64(bc[(i + 1) % 5], 1);
        var j : Nat = 0;
        while (j < 25) {
          if (j % 5 == i) { st[j] := st[j] ^ t };
          j += 1;
        };
        i += 1;
      };
      var t = st[1];
      i := 0;
      while (i < 24) {
        let j = KECCAKF_PILN[i];
        let temp = st[j];
        st[j] := rol64(t, KECCAKF_ROTC[i]);
        t := temp;
        i += 1;
      };
      var y : Nat = 0;
      while (y < 5) {
        let row = [var st[y * 5], st[y * 5 + 1], st[y * 5 + 2], st[y * 5 + 3], st[y * 5 + 4]];
        i := 0;
        while (i < 5) {
          st[y * 5 + i] := row[i] ^ (Nat64.bitnot(row[(i + 1) % 5]) & row[(i + 2) % 5]);
          i += 1;
        };
        y += 1;
      };
      st[0] := st[0] ^ KECCAKF_RNDC[round];
      round += 1;
    };
  };

  func keccak256(data : Blob) : Blob {
    let rate : Nat = 136; // 1088-bit rate for keccak-256
    let st = VarArray.tabulate<Nat64>(25, func _ = 0);
    let bytes = Blob.toArray(data);
    var offset : Nat = 0;
    while (offset + rate <= bytes.size()) {
      var i : Nat = 0;
      while (i < rate) {
        let lane = i / 8;
        let shift = (i % 8) * 8;
        st[lane] := st[lane] ^ Nat64.bitshiftLeft(Nat64.fromNat(Nat8.toNat(bytes[offset + i])), Nat64.fromNat(shift));
        i += 1;
      };
      keccakF(st);
      offset += rate;
    };
    let rem = bytes.size() - offset;
    var i : Nat = 0;
    while (i < rem) {
      let lane = i / 8;
      let shift = (i % 8) * 8;
      st[lane] := st[lane] ^ Nat64.bitshiftLeft(Nat64.fromNat(Nat8.toNat(bytes[offset + i])), Nat64.fromNat(shift));
      i += 1;
    };
    // Keccak padding: 0x01 ... 0x80
    let padLane = rem / 8;
    let padShift = (rem % 8) * 8;
    st[padLane] := st[padLane] ^ Nat64.bitshiftLeft(1, Nat64.fromNat(padShift));
    let last = rate - 1;
    let lastLane = last / 8;
    let lastShift = (last % 8) * 8;
    st[lastLane] := st[lastLane] ^ Nat64.bitshiftLeft(0x80, Nat64.fromNat(lastShift));
    keccakF(st);
    let out = VarArray.tabulate<Nat8>(32, func _ = 0);
    i := 0;
    while (i < 32) {
      let lane = i / 8;
      let shift = (i % 8) * 8;
      let byte = Nat64.toNat(Nat64.bitand(Nat64.bitshiftRight(st[lane], Nat64.fromNat(shift)), Nat64.fromNat(0xff)));
      out[i] := Nat8.fromNat(byte);
      i += 1;
    };
    Blob.fromArray(VarArray.toArray(out));
  };

  func leftPad32(hexNoPrefix : Text) : Text {
    let lower = toLowerHex(stripHexPrefix(hexNoPrefix));
    if (lower.size() > 64) { return lower };
    var out = "";
    var i : Nat = 0;
    while (i < 64 - lower.size()) {
      out #= "0";
      i += 1;
    };
    out # lower;
  };

  func encodeAddress32(address : Text) : ?Text {
    switch (validateEvmAddress(address)) {
      case (#err(_)) { null };
      case (#ok(h)) { ?leftPad32(h) };
    };
  };

  func encodeUint256(value : Nat) : Text {
    leftPad32(natToFixedHex(value, 32));
  };

  func eip712DomainSeparator(name : Text, chainId : Nat, verifyingContract : Text) : ?Blob {
    let ?contract32 = encodeAddress32(verifyingContract) else return null;
    let nameHash = blobToHex(keccak256(Text.encodeUtf8(name)));
    let domainTypeHashHex = "8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866";
    let packedHex = domainTypeHashHex # nameHash # encodeUint256(chainId) # contract32;
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  func eip712GateStructHash(evmAddress : Text, transportPublicKey : Blob, nonce : Nat) : ?Blob {
    let ?address32 = encodeAddress32(evmAddress) else return null;
    let transportHashHex = blobToHex(keccak256(transportPublicKey));
    let gateTypeHashHex = "88160239aa0076952ec94d7cf6b6b51da1765acd803b051b6d06b3f27623f2c0";
    let packedHex = gateTypeHashHex # address32 # transportHashHex # encodeUint256(nonce);
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  func eip712Digest(domainSeparator : Blob, structHash : Blob) : ?Blob {
    let prefixHex = "1901";
    let payloadHex = prefixHex # blobToHex(domainSeparator) # blobToHex(structHash);
    let ?payload = hexToBlob(payloadHex) else return null;
    ?keccak256(payload);
  };

  func nonceReplayKey(domainSeparator : Blob) : Blob {
    let gateTypeHashHex = "88160239aa0076952ec94d7cf6b6b51da1765acd803b051b6d06b3f27623f2c0";
    let scopeHex = blobToHex(domainSeparator) # gateTypeHashHex;
    let ?scopeBlob = hexToBlob(scopeHex) else Runtime.trap("internal nonce scope hex encoding failure");
    keccak256(scopeBlob);
  };

  // ── Address validation ─────────────────────────────────────────────

  func validateEvmAddress(addr : Text) : Result.Result<Text, Text> {
    if (addr.size() != 42) return #err("address must be 42 characters (0x + 40 hex)");
    let stripped = stripHexPrefix(addr);
    if (stripped.size() != 40) return #err("address must start with 0x");
    for (c in stripped.chars()) {
      if (not isHexChar(c)) return #err("address contains non-hex character");
    };
    #ok(toLowerHex(stripped));
  };

  // ── Derivation input hash ──────────────────────────────────────────
  // Per docs/derivation-spec.md:
  //   preimage = "accessol:" + chain + ":" + tokenAddress + ":" + str(threshold) + ":" + cid
  //   derivation_input = SHA-256(UTF-8(preimage))

  func computeDerivationInput(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    cid : Text,
  ) : Blob {
    let preimage = "accessol:" # chainToText(chain) # ":" # tokenAddress # ":" # Nat.toText(threshold) # ":" # cid;
    Sha256.fromBlob(#sha256, Text.encodeUtf8(preimage));
  };

  // ── VetKD key derivation ───────────────────────────────────────────

  func deriveKey(
    derivationInput : Blob,
    transportPublicKey : Blob,
  ) : async Blob {
    let response = await (with cycles = CYCLE_BUDGET) vetkdCanister.vetkd_derive_key({
      input = derivationInput;
      context = VETKD_CONTEXT;
      transport_public_key = transportPublicKey;
      key_id = vetkdKeyId();
    });
    response.encrypted_key;
  };

  // ── Public endpoints ───────────────────────────────────────────────

  /// Returns the canister's VetKD verification public key.
  /// Now a query call — returns from memoized state (no inter-canister call).
  public query func getVetKDPublicKey() : async Blob {
    switch (cachedVetKDPublicKey) {
      case (?key) { key };
      case null {
        Runtime.trap("VetKD public key not yet cached. Call warmupVetKDPublicKey() first.");
      };
    };
  };

  /// Populate the VetKD public key cache. Call once after deploy or on key rotation.
  public func warmupVetKDPublicKey() : async Blob {
    let response = await vetkdCanister.vetkd_public_key({
      canister_id = null;
      context = VETKD_CONTEXT;
      key_id = vetkdKeyId();
    });
    cachedVetKDPublicKey := ?response.public_key;
    response.public_key;
  };

  // ── Balance check ──────────────────────────────────────────────────

  public func checkBalance(
    chain : Chain,
    tokenAddress : Text,
    evmAddress : Text,
  ) : async Result.Result<Nat, BalanceError> {

    switch (validateEvmAddress(tokenAddress)) {
      case (#err(msg)) { return #err(#InvalidAddress("tokenAddress: " # msg)) };
      case (#ok(_)) {};
    };

    let walletHex = switch (validateEvmAddress(evmAddress)) {
      case (#err(msg)) { return #err(#InvalidAddress("evmAddress: " # msg)) };
      case (#ok(h)) { h };
    };

    let calldata = "0x70a08231000000000000000000000000" # walletHex;

    let rpcConfig : RpcConfig = {
      responseSizeEstimate = null;
      responseConsensus = ?#Threshold({ total = ?3 : ?Nat8; min = 2 : Nat8 });
    };

    let callArgs : CallArgs = {
      transaction = {
        to = ?tokenAddress;
        input = ?calldata;
        accessList = null;
        blobVersionedHashes = null;
        blobs = null;
        chainId = null;
        from = null;
        gas = null;
        gasPrice = null;
        maxFeePerBlobGas = null;
        maxFeePerGas = null;
        maxPriorityFeePerGas = null;
        nonce = null;
        type_ = null;
        value = null;
      };
      block = null;
    };

    let result = await (with cycles = CYCLE_BUDGET) evmRpc.eth_call(
      chainToRpcServices(chain),
      ?rpcConfig,
      callArgs,
    );

    switch (result) {
      case (#Consistent(#Ok(hexBalance))) {
        switch (hexToNat(hexBalance)) {
          case (?balance) { #ok(balance) };
          case null { #err(#EvmRpcError("failed to parse hex balance: " # hexBalance)) };
        };
      };
      case (#Consistent(#Err(rpcError))) {
        #err(#EvmRpcError("RPC error: " # debug_show rpcError));
      };
      case (#Inconsistent(results)) {
        #err(#EvmRpcError("providers returned inconsistent results: " # debug_show results));
      };
    };
  };

  // ── Public types for gate endpoint ───────────────────────────────

  public type GateRequest = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    cid : Text;
    evmAddress : Text;
    transportPublicKey : Blob;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  public type GateError = {
    #InsufficientBalance : { required : Nat; actual : Nat };
    #InvalidAddress : Text;
    #InvalidThreshold;
    #EvmRpcError : Text;
    #VetKDError : Text;
    #InvalidSignature : Text;
    #NonceAlreadyUsed;
  };

  public type GateResult = {
    #ok : { encrypted_key : Blob; verification_key : Blob };
    #err : GateError;
  };

  // ── Input validation ───────────────────────────────────────────────

  func validateAddress(addr : Text, fieldName : Text) : ?GateError {
    if (addr.size() != 42) return ?#InvalidAddress(fieldName # ": address must be 42 characters (0x + 40 hex)");
    let stripped = stripHexPrefix(addr);
    if (stripped.size() != 40) return ?#InvalidAddress(fieldName # ": address must start with 0x");
    for (c in stripped.chars()) {
      if (not isHexChar(c)) return ?#InvalidAddress(fieldName # ": address contains non-hex character");
    };
    null;
  };

  // ── requestDecryptionKey endpoint ──────────────────────────────────

  public func requestDecryptionKey(req : GateRequest) : async GateResult {
    // Input validation
    switch (validateAddress(req.tokenAddress, "tokenAddress")) {
      case (?e) { return #err(e) };
      case null {};
    };
    switch (validateAddress(req.evmAddress, "evmAddress")) {
      case (?e) { return #err(e) };
      case null {};
    };
    switch (validateAddress(req.eip712VerifyingContract, "eip712VerifyingContract")) {
      case (?e) { return #err(e) };
      case null {};
    };
    if (req.threshold == 0) return #err(#InvalidThreshold);
    if (req.cid.size() == 0) return #err(#InvalidAddress("cid must not be empty"));
    if (Blob.toArray(req.transportPublicKey).size() == 0) return #err(#InvalidAddress("transportPublicKey must not be empty"));
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes [r||s||v]"));

    // Step A: Nonce validation (scoped by EIP-712 domain + primary type)
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };
    let nonceScopeKey = nonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    // Step B: EIP-712 hash construction
    let structHash = switch (eip712GateStructHash(req.evmAddress, req.transportPublicKey, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    // Step C: Native signature recovery via secp256k1 package (synchronous — <20ms)
    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };

    // Step D: recovered address must match claimed evmAddress (case-insensitive / lowercase compare)
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // Step E: Balance check (only remaining EVM RPC call)
    let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
    let balance = switch (balanceResult) {
      case (#ok(b)) { b };
      case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
      case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
    };

    // Threshold comparison
    if (balance < req.threshold) {
      return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
    };

    // Step F: VetKD key derivation
    let derivationInput = computeDerivationInput(req.chain, req.tokenAddress, req.threshold, req.cid);
    try {
      let encryptedKey = await deriveKey(derivationInput, req.transportPublicKey);

      // Bundle the verification key — read from memoized state (zero cost).
      // Lazy warmup if not yet cached (first call after deploy).
      let verificationKey = switch (cachedVetKDPublicKey) {
        case (?k) { k };
        case null {
          let resp = await vetkdCanister.vetkd_public_key({
            canister_id = null;
            context = VETKD_CONTEXT;
            key_id = vetkdKeyId();
          });
          cachedVetKDPublicKey := ?resp.public_key;
          resp.public_key;
        };
      };

      #ok({ encrypted_key = encryptedKey; verification_key = verificationKey });
    } catch (e) {
      #err(#VetKDError(Error.message(e)));
    };
  };

  // ── Health check ───────────────────────────────────────────────────

  public query func health() : async Text { "ok" };
};
