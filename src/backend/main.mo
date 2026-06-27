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
import Int "mo:core/Int";
import Time "mo:core/Time";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
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

  // ── IC Management Canister types (for t-Schnorr signing) ───────────

  type SchnorrAlgorithm = { #bip340secp256k1; #ed25519 };

  type SchnorrKeyId = {
    algorithm : SchnorrAlgorithm;
    name : Text;
  };

  type SchnorrPublicKeyRequest = {
    canister_id : ?Principal;
    derivation_path : [Blob];
    key_id : SchnorrKeyId;
  };

  type SchnorrPublicKeyResponse = {
    public_key : Blob;
    chain_code : Blob;
  };

  type SignWithSchnorrRequest = {
    message : Blob;
    derivation_path : [Blob];
    key_id : SchnorrKeyId;
  };

  type SignWithSchnorrResponse = {
    signature : Blob;
  };

  type IcManagementCanister = actor {
    schnorr_public_key : (SchnorrPublicKeyRequest) -> async SchnorrPublicKeyResponse;
    sign_with_schnorr : (SignWithSchnorrRequest) -> async SignWithSchnorrResponse;
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

  // EVM RPC eth_call + VetKD derive_key budget (10B too low for mainnet eth_call → IC0406).
  let CYCLE_BUDGET : Nat = 30_000_000_000;
  // t-Schnorr signing ~26B+ observed on mainnet; keep headroom above public_key call.
  let SCHNORR_CYCLE_BUDGET : Nat = 35_000_000_000;
  let APP_NAME : Text = "HavenAOL";
  let EIP712_DOMAIN_TYPEHASH_HEX : Text = "8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866";
  let EIP712_GATE_REQUEST_TYPEHASH_HEX : Text = "88160239aa0076952ec94d7cf6b6b51da1765acd803b051b6d06b3f27623f2c0";
  // keccak256("AttestRequest(address evmAddress,bytes32 cidHash,uint256 nonce)")
  let EIP712_ATTEST_REQUEST_TYPEHASH_HEX : Text = "7e4a5ca1db93a70b82733f9735aaa5682d44760b336ea437fea3715550a833b0";
  // keccak256("MerkleAttestRequest(address evmAddress,bytes32[] cidHashes,uint256 nonce)")
  let EIP712_MERKLE_ATTEST_REQUEST_TYPEHASH_HEX : Text = "c00ac9ce7cbe8a3db226ac00ce16786b3014a553ce52c01cd84a5fcba347b0da";
  // keccak256("BatchGateRequest(address evmAddress,bytes32 transportKeyHash,bytes32 cidsCommitment,uint256 nonce)")
  let EIP712_BATCH_GATE_REQUEST_TYPEHASH_HEX : Text = "b4633d97ed58755b24090d30395e8a391cb37f4e9c10d3478dc052697cf78394";
  // keccak256("GateRequestV3(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 nonce)")
  // Pinned in tests/fixtures/derivation-v3-vectors.json (`constants.eip712TypehashHex`)
  // and tasking/README.md (Interface Contracts).
  let EIP712_GATE_REQUEST_V3_TYPEHASH_HEX : Text = "bf3ae9382ccda27b087c12bfb5fd82fa7ccc60857623462a4c7fec696bc7d7af";
  // VetKD context — protocol v1 identifier (stable across Haven-AOL deployments).
  let VETKD_CONTEXT : Blob = Text.encodeUtf8("accessol_v1");
  // VetKD context — protocol v3 (corpus + epoch). Distinct from v1 so a
  // single transport key under different protocols cannot be confused.
  let VETKD_CONTEXT_V3 : Blob = Text.encodeUtf8("accessol_v3");
  // 30-day epoch cadence (seconds). Pinned in docs/derivation-spec.md and
  // tests/fixtures/derivation-v3-vectors.json (`constants.epochLengthSeconds`).
  let EPOCH_LENGTH_SECONDS : Nat = 2_592_000;
  // Approval-cache TTL (Sprint 1 · Task 02). Semantic alias for
  // EPOCH_LENGTH_SECONDS — declared as a distinct binding because the
  // two concepts can drift in future protocol revisions (e.g. a future
  // epoch redefinition must not silently lengthen cached approvals).
  let APPROVAL_TTL_SECONDS : Nat = EPOCH_LENGTH_SECONDS;
  let usedNonces = Map.empty<Text, Bool>();
  // ── Approval cache (Protocol v3 only) ──────────────────────────────
  // Key:   text join `chain|tokenAddress_lower|threshold|epoch|evmAddress_lower`
  //        (see `approvalCacheKey`). Both addresses are lowercased so case
  //        variants of the same wallet/token share a row.
  // Value: `verifiedAt` — UNIX seconds at the moment the chain-side
  //        `balanceOf` returned `>= threshold` for this key.
  // Per-entry byte budget (mo:core B-tree Map<Text, Nat>): ~140 bytes
  //   ≈ key string (~95–110 chars × 1 B) + Nat (~8 B) + tree node
  //   overhead (~25–35 B). At the proposal §6.1 steady-state target of
  //   100k DAU × ~3 live keys (current + edge-of-TTL + opportunistic
  //   refresh) this stays under ~45 MB, well inside the 50 MB envelope.
  // Lifecycle: written on a successful EVM verification (threshold != 0
  //   only), read on every v3 endpoint hit, lazily deleted on stale
  //   read, bulk-deleted by the controller-only `evictExpiredApprovals`.
  // v1 endpoints DO NOT touch this map — v1 has per-CID semantics and
  // its callers expect a balance check on every request.
  let approvedHolders = Map.empty<Text, Nat>();


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

  // Memoized VetKD public keys (96 bytes each, deterministic
  // constants for a given (key_id, context) pair). The two caches
  // are independent because v1 and v3 use distinct context blobs
  // ("accessol_v1" vs "accessol_v3") and therefore distinct master
  // public keys. Splitting them keeps the cached-path branch in
  // each endpoint family returning the correct key without any
  // runtime context check. Each is populated on first warmup;
  // both survive canister upgrades.
  var cachedVetKDPublicKey : ?Blob = null;    // v1, accessol_v1
  var cachedVetKDPublicKeyV3 : ?Blob = null;  // v3, accessol_v3

  func vetkdKeyId() : VetKdKeyId {
    { curve = #bls12_381_g2; name = vetkdKeyName };
  };

  // ── IC Management Canister reference (for t-Schnorr) ───────────────

  transient let ic : IcManagementCanister = actor ("aaaaa-aa") : IcManagementCanister;

  transient let schnorrKeyName : Text = do {
    switch (Runtime.envVar("SCHNORR_KEY_NAME")) {
      case (?v) { v };
      case null { "key_1" }; // default: local dev key (auto-provisioned by replica)
    };
  };

  func schnorrKeyId() : SchnorrKeyId {
    { algorithm = #ed25519; name = schnorrKeyName };
  };

  // Memoized t-Schnorr/Ed25519 attestation public key (32 bytes).
  // Populated on first warmup; survives canister upgrades.
  var cachedAttestPublicKey : ?Blob = null;

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

  // EIP-712 struct hash for AttestRequest(address evmAddress, bytes32 cidHash, uint256 nonce)
  func eip712AttestStructHash(evmAddress : Text, cidHash : Text, nonce : Nat) : ?Blob {
    let ?address32 = encodeAddress32(evmAddress) else return null;
    // cidHash is a hex-encoded 32-byte hash (no 0x prefix expected, but strip if present)
    let cidHashHex = leftPad32(stripHexPrefix(cidHash));
    let packedHex = EIP712_ATTEST_REQUEST_TYPEHASH_HEX # address32 # cidHashHex # encodeUint256(nonce);
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  // Nonce replay key scoped to attestation (separate from gate request nonces)
  func attestNonceReplayKey(domainSeparator : Blob) : Blob {
    let scopeHex = blobToHex(domainSeparator) # EIP712_ATTEST_REQUEST_TYPEHASH_HEX;
    let ?scopeBlob = hexToBlob(scopeHex) else Runtime.trap("internal attest nonce scope hex encoding failure");
    keccak256(scopeBlob);
  };

  // Nonce replay key scoped to merkle (batch) attestation (separate from single attest nonces).
  // Distinct from the legacy `:batch_attest:` scope so v1 nonces cannot be replayed against v2.
  func merkleAttestNonceReplayKey(domainSeparator : Blob) : Blob {
    let scopeHex = blobToHex(domainSeparator) # EIP712_MERKLE_ATTEST_REQUEST_TYPEHASH_HEX;
    let ?scopeBlob = hexToBlob(scopeHex) else Runtime.trap("internal merkle attest nonce scope hex encoding failure");
    keccak256(scopeBlob);
  };

  // Nonce replay key scoped to batch gate (separate from gate/attest nonce namespaces)
  func batchGateNonceReplayKey(domainSeparator : Blob) : Blob {
    let scopeHex = blobToHex(domainSeparator) # EIP712_BATCH_GATE_REQUEST_TYPEHASH_HEX;
    let ?scopeBlob = hexToBlob(scopeHex) else Runtime.trap("internal batch gate nonce scope hex encoding failure");
    keccak256(scopeBlob);
  };

  // ── Protocol v3 EIP-712 helpers ────────────────────────────────────
  //
  // Per docs/derivation-spec.md §v3.7, v3 requests are signed against
  //   GateRequestV3(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 nonce)
  // with typehash = EIP712_GATE_REQUEST_V3_TYPEHASH_HEX. Both the single-CID
  // and batch v3 endpoints share this struct hash — the multi-CID nature of
  // the batch endpoint is expressed in the response shape, not the signature
  // (one VetKey unlocks the whole (community, epoch) bucket, so the batch
  // request commits to the same `(epoch, transportPublicKey)` as the single).

  // EIP-712 struct hash for the v3 GateRequest type. bytes-typed
  // transportPublicKey is hashed (per EIP-712 dynamic-bytes rules).
  func eip712GateStructHashV3(
    evmAddress : Text,
    transportPublicKey : Blob,
    epoch : Nat,
    nonce : Nat,
  ) : ?Blob {
    let ?address32 = encodeAddress32(evmAddress) else return null;
    let transportHashHex = blobToHex(keccak256(transportPublicKey));
    let packedHex =
      EIP712_GATE_REQUEST_V3_TYPEHASH_HEX
      # address32
      # transportHashHex
      # encodeUint256(epoch)
      # encodeUint256(nonce);
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  // Nonce replay key scoped to protocol v3 gate requests. Distinct from v1
  // (`nonceReplayKey`) and batch v1 (`batchGateNonceReplayKey`) so the same
  // wire nonce can be used across protocol versions without colliding, and
  // a v1 nonce can never be replayed against v3. Single-CID and batch v3
  // share this scope because they share a typehash.
  func gateV3NonceReplayKey(domainSeparator : Blob) : Blob {
    let scopeHex = blobToHex(domainSeparator) # EIP712_GATE_REQUEST_V3_TYPEHASH_HEX;
    let ?scopeBlob = hexToBlob(scopeHex) else Runtime.trap("internal v3 nonce scope hex encoding failure");
    keccak256(scopeBlob);
  };

  // EIP-712 struct hash for BatchGateRequest(address evmAddress, bytes32 transportKeyHash, bytes32 cidsCommitment, uint256 nonce)
  // cidsCommitment = keccak256(abi.encodePacked(derivationInput₁, derivationInput₂, ...))
  func eip712BatchGateStructHash(evmAddress : Text, transportPublicKey : Blob, cids : [Text], chain : Chain, tokenAddress : Text, threshold : Nat, nonce : Nat) : ?Blob {
    let ?address32 = encodeAddress32(evmAddress) else return null;
    let transportKeyHash = blobToHex(keccak256(transportPublicKey));
    // Build cidsCommitment: concatenate derivation inputs for each CID, then keccak256
    var derivationInputsPacked = "";
    for (cid in cids.vals()) {
      let derivationInput = computeDerivationInput(chain, tokenAddress, threshold, cid);
      derivationInputsPacked #= blobToHex(derivationInput);
    };
    let ?derivationInputsBlob = hexToBlob(derivationInputsPacked) else return null;
    let cidsCommitment = blobToHex(keccak256(derivationInputsBlob));
    let packedHex = EIP712_BATCH_GATE_REQUEST_TYPEHASH_HEX # address32 # transportKeyHash # cidsCommitment # encodeUint256(nonce);
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  // EIP-712 struct hash for MerkleAttestRequest(address evmAddress, bytes32[] cidHashes, uint256 nonce)
  // cidHashes are verified in *submitted* order (sorting happens after verification, before tree
  // build); per EIP-712 array encoding the array hash is keccak256(abi.encodePacked(cidHashes)).
  func eip712MerkleAttestStructHash(evmAddress : Text, cidHashes : [Text], nonce : Nat) : ?Blob {
    let ?address32 = encodeAddress32(evmAddress) else return null;
    var cidHashesPacked = "";
    for (cidHash in cidHashes.vals()) {
      cidHashesPacked #= leftPad32(stripHexPrefix(cidHash));
    };
    let ?cidHashesPackedBlob = hexToBlob(cidHashesPacked) else return null;
    let cidHashesHash = blobToHex(keccak256(cidHashesPackedBlob));
    let packedHex = EIP712_MERKLE_ATTEST_REQUEST_TYPEHASH_HEX # address32 # cidHashesHash # encodeUint256(nonce);
    let ?packedBlob = hexToBlob(packedHex) else return null;
    ?keccak256(packedBlob);
  };

  // ── Attestation encoding (deterministic canonical format) ──────────
  // Format: "HAVEN_ATTEST_V1:{chain}:{tokenAddress}:{threshold}:{evmAddress}:{cidHash}:{timestamp}:{balanceAtCheck}"
  func encodeAttestation(a : Attestation) : Blob {
    let preimage = "HAVEN_ATTEST_V1:"
      # chainToText(a.chain) # ":"
      # a.tokenAddress # ":"
      # Nat.toText(a.threshold) # ":"
      # a.evmAddress # ":"
      # a.cidHash # ":"
      # Nat.toText(a.timestamp) # ":"
      # Nat.toText(a.balanceAtCheck);
    Text.encodeUtf8(preimage);
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

  // ── Derivation input hash (Protocol v3) ────────────────────────────
  // Per docs/derivation-spec.md §"Protocol v3 — Corpus + Epoch Derivation":
  //   effectiveEpoch = if (threshold == 0) 0 else epoch        // collapse rule
  //   preimage = "accessol_v3:" + chain + ":" + tokenAddress + ":"
  //                            + str(threshold) + ":" + str(effectiveEpoch)
  //   derivation_input = SHA-256(UTF-8(preimage))
  //
  // Byte-identity vectors live in tests/fixtures/derivation-v3-vectors.json.
  // The threshold-zero collapse is observable here: any (threshold=0, epoch=*)
  // input produces the same digest as (threshold=0, epoch=0).
  func computeDerivationInputV3(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    epoch : Nat,
  ) : Blob {
    let effectiveEpoch : Nat = if (threshold == 0) { 0 } else { epoch };
    let preimage =
      "accessol_v3:"
      # chainToText(chain) # ":"
      # tokenAddress # ":"
      # Nat.toText(threshold) # ":"
      # Nat.toText(effectiveEpoch);
    Sha256.fromBlob(#sha256, Text.encodeUtf8(preimage));
  };

  // ── Epoch helper (Protocol v3) ─────────────────────────────────────
  // currentEpoch = floor(unix_seconds / EPOCH_LENGTH_SECONDS).
  // Used by v3 endpoints for future-epoch rejection and by the
  // `getCurrentEpoch` ops diagnostic query.
  func currentEpoch() : Nat {
    Int.abs(Time.now() / 1_000_000_000) / EPOCH_LENGTH_SECONDS;
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

  // Protocol v3: identical to deriveKey() but uses VETKD_CONTEXT_V3
  // ("accessol_v3") so v1 and v3 keys are partitioned at the VetKD layer
  // even when the same (chain, token, threshold) tuple is in play.
  func deriveKeyV3(
    derivationInput : Blob,
    transportPublicKey : Blob,
  ) : async Blob {
    let response = await (with cycles = CYCLE_BUDGET) vetkdCanister.vetkd_derive_key({
      input = derivationInput;
      context = VETKD_CONTEXT_V3;
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

  /// Protocol-v3 counterpart of `getVetKDPublicKey`. Returns the
  /// memoized v3 verification key; traps if `warmupVetKDPublicKeyV3`
  /// has not yet been called. Separate from the v1 query because v1
  /// and v3 use distinct VetKD `context` blobs ("accessol_v1" vs
  /// "accessol_v3") and therefore distinct master public keys —
  /// returning the wrong one would cause SDK-side BLS verification
  /// of every v3 response to fail.
  public query func getVetKDPublicKeyV3() : async Blob {
    switch (cachedVetKDPublicKeyV3) {
      case (?key) { key };
      case null {
        Runtime.trap("VetKD v3 public key not yet cached. Call warmupVetKDPublicKeyV3() first.");
      };
    };
  };

  /// Populate the protocol-v3 VetKD public-key cache. Call once after
  /// deploy or on key rotation. Independent of `warmupVetKDPublicKey`
  /// because v1 and v3 use distinct context blobs and therefore
  /// distinct master public keys.
  public func warmupVetKDPublicKeyV3() : async Blob {
    let response = await vetkdCanister.vetkd_public_key({
      canister_id = null;
      context = VETKD_CONTEXT_V3;
      key_id = vetkdKeyId();
    });
    cachedVetKDPublicKeyV3 := ?response.public_key;
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
    // Protocol v3: req.epoch refers to a future epoch (> currentEpoch()).
    #InvalidEpoch;
  };

  public type GateResult = {
    #ok : { encrypted_key : Blob; verification_key : Blob };
    #err : GateError;
  };

  // ── Public types for batch gate endpoint ────────────────────────────

  public type BatchGateRequest = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    cids : [Text];
    evmAddress : Text;
    transportPublicKey : Blob;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  public type BatchKeyEntry = {
    cid : Text;
    encrypted_key : Blob;
  };

  public type BatchGateResult = {
    #ok : { keys : [BatchKeyEntry]; verification_key : Blob };
    #err : GateError;
  };

  // ── Public types for protocol v3 gate endpoints ─────────────────────

  // Single-CID v3 gate request. Field order mirrors backend.did
  // (GateRequestV3). The `epoch` replaces v1's `cid`; the response is
  // shared with v1 (`GateResult`).
  public type GateRequestV3 = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    epoch : Nat;
    evmAddress : Text;
    transportPublicKey : Blob;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  // Multi-CID v3 gate request. The `cids : [Text]` field is used ONLY to
  // shape the response (one entry per CID); it does NOT participate in
  // derivation or in the EIP-712 signature. One VetKey is derived from
  // (chain, tokenAddress, threshold, epoch) and replicated per CID.
  public type BatchGateRequestV3 = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    epoch : Nat;
    cids : [Text];
    evmAddress : Text;
    transportPublicKey : Blob;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  // ── Public types for attestation endpoint ──────────────────────────

  public type AttestRequest = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    cidHash : Text;
    evmAddress : Text;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  public type Attestation = {
    evmAddress : Text;
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    balanceAtCheck : Nat;
    cidHash : Text;
    timestamp : Nat;
  };

  public type AttestResult = {
    #ok : { attestation : Attestation; signature : Blob };
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

  // ── Batch gate endpoint ────────────────────────────────────────────

  /// Batch decryption key request: verify token holding once, derive N VetKD keys.
  /// Steps: validate → EIP-712 batch signature verify → single balance check → N VetKD derivations.
  /// Hard limit: 20 CIDs per call (ICP instruction budget constraint).
  public func batchRequestDecryptionKey(req : BatchGateRequest) : async BatchGateResult {
    // ── Step A: Input validation ──
    if (req.cids.size() == 0 or req.cids.size() > 20) return #err(#InvalidThreshold);
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
    for (cid in req.cids.vals()) {
      if (cid.size() == 0) return #err(#InvalidAddress("cid must not be empty"));
    };
    if (Blob.toArray(req.transportPublicKey).size() == 0) return #err(#InvalidAddress("transportPublicKey must not be empty"));
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes [r||s||v]"));

    // ── Step B: EIP-712 signature verification ──
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };

    // Nonce replay check (scoped to :batch_gate: namespace)
    let nonceScopeKey = batchGateNonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":batch_gate:" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    let structHash = switch (eip712BatchGateStructHash(req.evmAddress, req.transportPublicKey, req.cids, req.chain, req.tokenAddress, req.threshold, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct batch gate struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    // ecrecover
    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // ── Step C: Single balance check ──
    let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
    let balance = switch (balanceResult) {
      case (#ok(b)) { b };
      case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
      case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
    };
    if (balance < req.threshold) {
      return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
    };

    // ── Step D: VetKD key derivation loop ──
    let count = req.cids.size();
    let keys = VarArray.tabulate<BatchKeyEntry>(count, func _ = { cid = ""; encrypted_key = Blob.fromArray([]) });

    try {
      var idx : Nat = 0;
      for (cid in req.cids.vals()) {
        let derivationInput = computeDerivationInput(req.chain, req.tokenAddress, req.threshold, cid);
        let encryptedKey = await deriveKey(derivationInput, req.transportPublicKey);
        keys[idx] := { cid = cid; encrypted_key = encryptedKey };
        idx += 1;
      };

      // Bundle the verification key — read from memoized state (zero cost).
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

      #ok({ keys = VarArray.toArray(keys); verification_key = verificationKey });
    } catch (e) {
      #err(#VetKDError(Error.message(e)));
    };
  };

  // ── Protocol v3 — approval cache ───────────────────────────────────
  //
  // Sprint 1 · Task 02 — corpus-gate-proposal-v3 §6.1.
  //
  // Cache key: `(chain, tokenAddress_lower, threshold, epoch, evmAddress_lower)`
  // joined with `|` (see `approvalCacheKey`). Both addresses are
  // lowercased so case variants of the same wallet/token coalesce.
  // Including `epoch` in the key means each epoch advance auto-rotates
  // the cache: an entry written at epoch N can never serve a request at
  // epoch N+1 (lookup uses the new epoch and misses). The 30-day TTL is
  // a backstop for entries that age out *within* their epoch (relevant
  // only at the protocol-bootstrap boundary).
  //
  // v1 endpoints DO NOT consult this cache — v1 has per-CID semantics
  // and its callers expect a balance check on every request.

  func approvalCacheKey(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    epoch : Nat,
    evmAddress : Text,
  ) : Text {
    chainToText(chain)
      # "|" # toLowerHex(stripHexPrefix(tokenAddress))
      # "|" # Nat.toText(threshold)
      # "|" # Nat.toText(epoch)
      # "|" # toLowerHex(stripHexPrefix(evmAddress));
  };

  /// Cache lookup with lazy expiry on read. Returns `true` iff a
  /// non-stale row exists for the composite key. A stale row
  /// (`verifiedAt + APPROVAL_TTL_SECONDS <= now`) is *deleted* as a side
  /// effect and the function returns `false`, forcing the endpoint to
  /// re-check the chain — a stale row is never served and never
  /// silently refreshed without an on-chain probe.
  func isApprovedHolder(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    epoch : Nat,
    evmAddress : Text,
  ) : Bool {
    let key = approvalCacheKey(chain, tokenAddress, threshold, epoch, evmAddress);
    switch (Map.get(approvedHolders, Text.compare, key)) {
      case (?verifiedAt) {
        let now = Int.abs(Time.now() / 1_000_000_000);
        if (verifiedAt + APPROVAL_TTL_SECONDS <= now) {
          // Stale — drop the row and force the EVM-RPC fallthrough.
          ignore Map.delete(approvedHolders, Text.compare, key);
          false;
        } else {
          true;
        };
      };
      case null { false };
    };
  };

  /// Write or refresh the approval cache row for this composite key with
  /// the current canister timestamp. Called by the v3 endpoints *only*
  /// after a successful `checkBalance` returned `balance >= threshold`.
  /// Insufficient-balance outcomes are never cached (the holder might
  /// top up later), and threshold-zero requests skip the cache entirely
  /// (no chain probe ran).
  func recordApproval(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    epoch : Nat,
    evmAddress : Text,
  ) {
    let key = approvalCacheKey(chain, tokenAddress, threshold, epoch, evmAddress);
    let now = Int.abs(Time.now() / 1_000_000_000);
    // `Map.add` upserts (it is `ignore swap`); a refresh updates verifiedAt
    // for an existing row, a write inserts a new row.
    Map.add(approvedHolders, Text.compare, key, now);
  };


  // ── Protocol v3 gate endpoints ─────────────────────────────────────

  /// Single-CID v3 decryption key request.
  ///
  /// Derivation: SHA-256("accessol_v3:" + chain + ":" + tokenAddress + ":"
  ///                     + str(threshold) + ":" + str(effectiveEpoch))
  /// where effectiveEpoch = if (threshold == 0) 0 else req.epoch.
  /// VetKD context: "accessol_v3" (UTF-8, no trailing colon).
  /// EIP-712 type:  GateRequestV3(address evmAddress,bytes transportPublicKey,
  ///                              uint256 epoch,uint256 nonce)
  /// Nonce scope:   distinct from v1; shared with batchRequestDecryptionKeyV3.
  ///
  /// Future-epoch policy: a request with `req.epoch > currentEpoch()` is
  /// rejected with `#InvalidEpoch` BEFORE consuming a nonce, hitting EVM
  /// RPC, or calling VetKD. Threshold-zero collapse: when `req.threshold
  /// == 0` the derivation input always uses `effectiveEpoch = 0`; the
  /// wire `req.epoch` is still validated against future-epoch (so e.g.
  /// `threshold=0, epoch=9_999_999_999` is rejected).
  public func requestDecryptionKeyV3(req : GateRequestV3) : async GateResult {
    // ── Step 0: Future-epoch rejection (before any side effect) ──
    // Note: threshold=0 still has its req.epoch validated here, even though
    // the derivation will collapse to effectiveEpoch=0 a few steps later.
    if (req.epoch > currentEpoch()) {
      return #err(#InvalidEpoch);
    };

    // ── Step A: Input validation ──
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
    if (Blob.toArray(req.transportPublicKey).size() == 0) return #err(#InvalidAddress("transportPublicKey must not be empty"));
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes [r||s||v]"));

    // ── Step B: EIP-712 signature verification ──
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };

    // Nonce replay check (scoped to v3 typehash; never collides with v1)
    let nonceScopeKey = gateV3NonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":gate_v3:" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    let structHash = switch (eip712GateStructHashV3(req.evmAddress, req.transportPublicKey, req.epoch, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct v3 struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // ── Step C: Approval check (approval cache → EVM RPC fallthrough) ──
    // For `threshold != 0`, consult the per-(chain, token, threshold,
    // epoch, wallet) approval cache. On hit (non-stale row exists) the
    // EVM RPC eth_call is skipped — this is the hot-path optimisation
    // promised by corpus-gate-proposal-v3 §6.1. On miss / stale row,
    // make the eth_call and, on success, record an approval row.
    // Insufficient-balance is NOT cached (the holder may top up later).
    // For `threshold == 0` the cache is skipped entirely (no chain
    // probe ran), preserving the §v3.2 threshold-zero free-tier shape.
    if (req.threshold != 0) {
      if (not isApprovedHolder(req.chain, req.tokenAddress, req.threshold, req.epoch, req.evmAddress)) {
        let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
        let balance = switch (balanceResult) {
          case (#ok(b)) { b };
          case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
          case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
        };
        if (balance < req.threshold) {
          return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
        };
        recordApproval(req.chain, req.tokenAddress, req.threshold, req.epoch, req.evmAddress);
      };
    };

    // ── Step D: VetKD derivation (uses v3 context + collapsed input) ──
    let derivationInput = computeDerivationInputV3(req.chain, req.tokenAddress, req.threshold, req.epoch);
    try {
      let encryptedKey = await deriveKeyV3(derivationInput, req.transportPublicKey);
      // verification_key MUST be fetched under the same context the
      // derivation used (VETKD_CONTEXT_V3) — Sprint 1 · Task 03 Finding 11.
      // Mismatch would cause SDK-side BLS verification of the encrypted
      // key against this verification key to fail for every v3 response.
      let verificationKey = switch (cachedVetKDPublicKeyV3) {
        case (?k) { k };
        case null {
          let resp = await vetkdCanister.vetkd_public_key({
            canister_id = null;
            context = VETKD_CONTEXT_V3;
            key_id = vetkdKeyId();
          });
          cachedVetKDPublicKeyV3 := ?resp.public_key;
          resp.public_key;
        };
      };
      #ok({ encrypted_key = encryptedKey; verification_key = verificationKey });
    } catch (e) {
      #err(#VetKDError(Error.message(e)));
    };
  };

  /// Multi-CID v3 decryption key request. One VetKey is derived from

  /// `(chain, tokenAddress, threshold, epoch)` and replicated for every
  /// CID in `req.cids` — the response shape matches v1's BatchGateResult.
  /// The CID list does NOT participate in derivation or the EIP-712
  /// signature; it only shapes the response (and any future audit hook).
  /// Hard limit: 20 CIDs per call (parity with v1 batch endpoint).
  public func batchRequestDecryptionKeyV3(req : BatchGateRequestV3) : async BatchGateResult {
    // ── Step 0: Future-epoch rejection (before any side effect) ──
    if (req.epoch > currentEpoch()) {
      return #err(#InvalidEpoch);
    };

    // ── Step A: Input validation ──
    if (req.cids.size() == 0 or req.cids.size() > 20) return #err(#InvalidThreshold);
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
    for (cid in req.cids.vals()) {
      if (cid.size() == 0) return #err(#InvalidAddress("cid must not be empty"));
    };
    if (Blob.toArray(req.transportPublicKey).size() == 0) return #err(#InvalidAddress("transportPublicKey must not be empty"));
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes [r||s||v]"));

    // ── Step B: EIP-712 signature verification ──
    // Shares the v3 typehash with the single-CID endpoint, so the same
    // signed message is honoured by either; nonce scope is shared too.
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };

    let nonceScopeKey = gateV3NonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":gate_v3:" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    let structHash = switch (eip712GateStructHashV3(req.evmAddress, req.transportPublicKey, req.epoch, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct v3 struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // ── Step C: Approval check (approval cache → EVM RPC fallthrough) ──
    // Shares the same cache as the single-CID v3 endpoint. The batch
    // shape derives only ONE VetKey (CIDs do not enter derivation), so
    // it consults the cache with the SAME `(chain, token, threshold,
    // epoch, wallet)` tuple that the single-CID flow would use — a
    // single-CID hit warms the batch endpoint and vice-versa.
    if (req.threshold != 0) {
      if (not isApprovedHolder(req.chain, req.tokenAddress, req.threshold, req.epoch, req.evmAddress)) {
        let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
        let balance = switch (balanceResult) {
          case (#ok(b)) { b };
          case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
          case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
        };
        if (balance < req.threshold) {
          return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
        };
        recordApproval(req.chain, req.tokenAddress, req.threshold, req.epoch, req.evmAddress);
      };
    };

    // ── Step D: ONE VetKD derivation, replicated per CID ──

    let derivationInput = computeDerivationInputV3(req.chain, req.tokenAddress, req.threshold, req.epoch);
    let count = req.cids.size();
    let keys = VarArray.tabulate<BatchKeyEntry>(count, func _ = { cid = ""; encrypted_key = Blob.fromArray([]) });

    try {
      let encryptedKey = await deriveKeyV3(derivationInput, req.transportPublicKey);
      // Replicate the same key into the response for every CID. Doing
      // it this way (rather than a vec of N identical blobs in the wire
      // format) keeps backward-compatible the v1 BatchGateResult shape
      // that SDK clients already parse.
      var idx : Nat = 0;
      for (cid in req.cids.vals()) {
        keys[idx] := { cid = cid; encrypted_key = encryptedKey };
        idx += 1;
      };

      // verification_key MUST be fetched under the same context the
      // derivation used (VETKD_CONTEXT_V3) — Sprint 1 · Task 03 Finding 11.
      // Mismatch would cause SDK-side BLS verification of the encrypted
      // key against this verification key to fail for every v3 response.
      let verificationKey = switch (cachedVetKDPublicKeyV3) {
        case (?k) { k };
        case null {
          let resp = await vetkdCanister.vetkd_public_key({
            canister_id = null;
            context = VETKD_CONTEXT_V3;
            key_id = vetkdKeyId();
          });
          cachedVetKDPublicKeyV3 := ?resp.public_key;
          resp.public_key;
        };
      };
      #ok({ keys = VarArray.toArray(keys); verification_key = verificationKey });
    } catch (e) {
      #err(#VetKDError(Error.message(e)));
    };
  };

  /// Ops diagnostic only; NEVER call this on the hot path (upload or
  /// decrypt flows). Uploaders compute the current epoch from local UNIX
  /// time per docs/derivation-spec.md §v3.2; decryptors read the epoch
  /// from gate metadata. Calling this from a request flow would create
  /// an unnecessary IC round trip and a time-of-check / time-of-use race
  /// against the canister's own clock.
  public query func getCurrentEpoch() : async Nat {
    currentEpoch();
  };

  // ── Attestation endpoints ──────────────────────────────────────────

  /// Returns the canister's t-Schnorr/Ed25519 attestation public key.
  /// Query call — returns from memoized state (no inter-canister call).
  /// Readers use this to verify attestation signatures offline.
  public query func getAttestationPublicKey() : async Blob {
    switch (cachedAttestPublicKey) {
      case (?key) { key };
      case null {
        Runtime.trap("Attestation public key not yet cached. Call warmupAttestationPublicKey() first.");
      };
    };
  };

  /// Populate the attestation public key cache. Call once after deploy.
  public func warmupAttestationPublicKey() : async Blob {
    let response = await (with cycles = SCHNORR_CYCLE_BUDGET) ic.schnorr_public_key({
      canister_id = null;
      derivation_path = [Text.encodeUtf8("haven_attest_v1")];
      key_id = schnorrKeyId();
    });
    cachedAttestPublicKey := ?response.public_key;
    response.public_key;
  };

  /// Verify token holding and produce a canister-signed attestation.
  /// Steps: EIP-712 wallet proof → balance check → t-Schnorr sign attestation.
  public func attestHolding(req : AttestRequest) : async AttestResult {
    // ── Step A: Input validation ──
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
    if (req.cidHash.size() == 0) return #err(#InvalidAddress("cidHash must not be empty"));
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes"));

    // ── Step B: EIP-712 signature verification ──
    // Uses AttestRequest type hash (distinct from GateRequest to prevent cross-endpoint replay)
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };

    // Nonce replay check (scoped separately from requestDecryptionKey nonces)
    let nonceScopeKey = attestNonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":attest:" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    let structHash = switch (eip712AttestStructHash(req.evmAddress, req.cidHash, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct attest struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    // ecrecover
    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // ── Step C: Balance check ──
    let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
    let balance = switch (balanceResult) {
      case (#ok(b)) { b };
      case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
      case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
    };
    if (balance < req.threshold) {
      return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
    };

    // ── Step D: Build attestation struct ──
    let attestation : Attestation = {
      evmAddress = req.evmAddress;
      chain = req.chain;
      tokenAddress = req.tokenAddress;
      threshold = req.threshold;
      balanceAtCheck = balance;
      cidHash = req.cidHash;
      timestamp = Int.abs(Time.now() / 1_000_000_000);
    };

    // ── Step E: Sign with t-Schnorr/Ed25519 ──
    let attestationBytes = encodeAttestation(attestation);

    try {
      let signatureResult = await (with cycles = SCHNORR_CYCLE_BUDGET) ic.sign_with_schnorr({
        message = attestationBytes;
        derivation_path = [Text.encodeUtf8("haven_attest_v1")];
        key_id = schnorrKeyId();
      });

      #ok({ attestation = attestation; signature = signatureResult.signature });
    } catch (e) {
      #err(#VetKDError("t-Schnorr signing failed: " # Error.message(e)));
    };
  };

  // ── Public types for batch attestation endpoint ──────────────────

  public type MerkleAttestRequest = {
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    cidHashes : [Text];
    evmAddress : Text;
    nonce : Nat;
    signature : Blob;
    eip712ChainId : Nat;
    eip712VerifyingContract : Text;
  };

  public type MerkleSide = { #left; #right };

  public type MerkleProofEntry = {
    side : MerkleSide;
    hash : Blob;
  };

  public type MerkleAttestLeaf = {
    cidHash : Text;
    merkleProof : [MerkleProofEntry];
  };

  public type MerkleAttestation = {
    evmAddress : Text;
    chain : Chain;
    tokenAddress : Text;
    threshold : Nat;
    balanceAtCheck : Nat;
    timestamp : Nat;
    cidCount : Nat;
    merkleRoot : Blob;
    leaves : [MerkleAttestLeaf];
    rootSignature : Blob;
  };

  public type MerkleAttestResult = {
    #ok : MerkleAttestation;
    #err : GateError;
  };

  // ── Merkle tree helpers (RFC 6962-style domain separation) ─────────

  // Leaf  hash = SHA-256( 0x00 ‖ leafPreimage )
  // Inner hash = SHA-256( 0x01 ‖ left ‖ right )
  // ZERO_LEAF  = SHA-256( 0x00 ‖ "HAVEN_MERKLE_ZERO" )
  // These prefixes are required to prevent second-preimage attacks where a
  // chosen leaf could collide with an internal node hash.

  func sha256Blob(b : Blob) : Blob = Sha256.fromBlob(#sha256, b);

  func hashLeaf(preimage : Blob) : Blob {
    let inner = Blob.toArray(preimage);
    let buf = VarArray.tabulate<Nat8>(
      inner.size() + 1,
      func(i : Nat) : Nat8 {
        if (i == 0) { 0x00 } else { inner[i - 1] };
      },
    );
    sha256Blob(Blob.fromArray(VarArray.toArray(buf)));
  };

  func hashNode(left : Blob, right : Blob) : Blob {
    let l = Blob.toArray(left);
    let r = Blob.toArray(right);
    let total = 1 + l.size() + r.size();
    let buf = VarArray.tabulate<Nat8>(
      total,
      func(i : Nat) : Nat8 {
        if (i == 0) { 0x01 }
        else if (i <= l.size()) { l[i - 1] }
        else { r[i - 1 - l.size()] };
      },
    );
    sha256Blob(Blob.fromArray(VarArray.toArray(buf)));
  };

  func zeroLeafHash() : Blob {
    hashLeaf(Text.encodeUtf8("HAVEN_MERKLE_ZERO"));
  };

  // Leaf preimage matches the existing encodeAttestation byte layout exactly so
  // a single-CID attestHolding signature would verify against the same string;
  // this keeps the offline verifier identical for both shapes.
  func merkleLeafPreimage(
    chain : Chain,
    tokenAddress : Text,
    threshold : Nat,
    evmAddress : Text,
    cidHash : Text,
    timestamp : Nat,
    balanceAtCheck : Nat,
  ) : Blob {
    Text.encodeUtf8(
      "HAVEN_ATTEST_V1:"
      # chainToText(chain) # ":"
      # tokenAddress # ":"
      # Nat.toText(threshold) # ":"
      # evmAddress # ":"
      # cidHash # ":"
      # Nat.toText(timestamp) # ":"
      # Nat.toText(balanceAtCheck)
    );
  };

  // Normalize a submitted cidHash: strip 0x, lower-case, require 64 hex chars.
  // Returns the canonical form to use in *both* the leaf preimage and the
  // returned MerkleAttestLeaf.cidHash. This makes the dapp's job trivial:
  // it just rebuilds the preimage from the field it received.
  func normalizeCidHash(cidHash : Text) : ?Text {
    let stripped = stripHexPrefix(cidHash);
    if (stripped.size() != 64) return null;
    for (c in stripped.chars()) {
      if (not isHexChar(c)) return null;
    };
    ?toLowerHex(stripped);
  };

  // Smallest power of two ≥ n (for n ≥ 1).
  func nextPowerOfTwo(n : Nat) : Nat {
    var p : Nat = 1;
    while (p < n) { p *= 2 };
    p;
  };

  // Build a heap-shaped balanced binary tree.
  // Storage: nodes[0..2*limit-2], root at index 0, leaves at [limit-1..2*limit-2].
  // For node index p (p > 0): parent = (p-1)/2; siblings differ by 1 bit in lsb.
  // Returns the populated nodes array (limit = nextPow2(n)).
  func buildMerkleHeap(sortedLeafHashes : [Blob], limit : Nat) : [var Blob] {
    let totalNodes = 2 * limit - 1;
    let nodes = VarArray.tabulate<Blob>(totalNodes, func _ = Blob.fromArray([]));
    let zero = zeroLeafHash();
    // Place leaves; pad with zeroLeaf for non-power-of-two N.
    var i : Nat = 0;
    while (i < limit) {
      let heapIdx = limit - 1 + i;
      nodes[heapIdx] := if (i < sortedLeafHashes.size()) {
        sortedLeafHashes[i];
      } else {
        zero;
      };
      i += 1;
    };
    // Build internals bottom-up. For limit=1 this loop is empty (no internals).
    if (limit > 1) {
      var p : Nat = limit - 2;
      loop {
        nodes[p] := hashNode(nodes[2 * p + 1], nodes[2 * p + 2]);
        if (p == 0) { return nodes };
        p -= 1;
      };
    };
    nodes;
  };

  // Walk the parent chain from a leaf heap-index to the root, emitting siblings.
  // side semantics (matches docs/ipld-batch-attestation-proposal-v2.md §1.4 step 10):
  //   #left  → sibling is on the LEFT  → verifier computes SHA-256(0x01 ‖ sibling ‖ current)
  //   #right → sibling is on the RIGHT → verifier computes SHA-256(0x01 ‖ current ‖ sibling)
  // For limit=1, returns the empty proof.
  func merkleProofForLeaf(nodes : [var Blob], leafHeapIdx : Nat) : [MerkleProofEntry] {
    let proof = VarArray.tabulate<MerkleProofEntry>(64, func _ = { side = #left; hash = Blob.fromArray([]) });
    var depth : Nat = 0;
    var p = leafHeapIdx;
    while (p > 0) {
      let parent = (p - 1) / 2;
      // p odd  → left child  → sibling is right
      // p even → right child → sibling is left
      let (siblingIdx, side) : (Nat, MerkleSide) =
        if (p % 2 == 1) { (p + 1, #right) } else { (p - 1, #left) };
      proof[depth] := { side = side; hash = nodes[siblingIdx] };
      depth += 1;
      p := parent;
    };
    Array.tabulate<MerkleProofEntry>(depth, func i = proof[i]);
  };

  /// Batch attestation (Merkle): verify token holding once, produce ONE Schnorr
  /// signature over a Merkle root committing to all N leaves, return per-leaf
  /// proofs in submission order. See docs/ipld-batch-attestation-proposal-v2.md.
  /// Hard limit: 20 cidHashes per call (matches dapp page size).
  public func batchAttestHolding(req : MerkleAttestRequest) : async MerkleAttestResult {
    // ── Step A: Input validation ──
    if (req.cidHashes.size() == 0 or req.cidHashes.size() > 20) return #err(#InvalidThreshold);
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
    if (Blob.toArray(req.signature).size() != 65) return #err(#InvalidSignature("signature must be 65 bytes"));

    // Normalize cidHashes; we use the normalized form in *both* the leaf preimage
    // and the returned MerkleAttestLeaf.cidHash field so the offline verifier
    // can rebuild the preimage from the response without further normalization.
    let count = req.cidHashes.size();
    let normalized = VarArray.tabulate<Text>(count, func _ = "");
    var nIdx : Nat = 0;
    for (cidHash in req.cidHashes.vals()) {
      switch (normalizeCidHash(cidHash)) {
        case (?n) { normalized[nIdx] := n };
        case null {
          return #err(#InvalidAddress("cidHash must be 64-char hex (with optional 0x prefix)"));
        };
      };
      nIdx += 1;
    };
    let normalizedArr = VarArray.toArray(normalized);

    // ── Step B: EIP-712 signature verification ──
    // EIP-712 hash uses the *submitted* cidHashes (post-normalization for parity
    // with the leaf preimage); sorting happens later, only for tree construction.
    let domainSeparator = switch (eip712DomainSeparator(APP_NAME, req.eip712ChainId, req.eip712VerifyingContract)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct domain separator")) };
    };

    // Nonce replay check (scoped to the merkle attest namespace, distinct from
    // the legacy :batch_attest: scope so v1 nonces cannot collide).
    let nonceScopeKey = merkleAttestNonceReplayKey(domainSeparator);
    let scopedNonce = blobToHex(nonceScopeKey) # ":merkle_attest:" # Nat.toText(req.nonce);
    if (Map.get(usedNonces, Text.compare, scopedNonce) != null) {
      return #err(#NonceAlreadyUsed);
    };
    Map.add(usedNonces, Text.compare, scopedNonce, true);

    let structHash = switch (eip712MerkleAttestStructHash(req.evmAddress, normalizedArr, req.nonce)) {
      case (?h) { h };
      case null { return #err(#InvalidSignature("failed to construct merkle attest struct hash")) };
    };
    let digest = switch (eip712Digest(domainSeparator, structHash)) {
      case (?d) { d };
      case null { return #err(#InvalidSignature("failed to construct digest")) };
    };

    // ecrecover
    let signatureBytes = Blob.toArray(req.signature);
    let rBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i]));
    let sBlob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 = signatureBytes[i + 32]));
    let vByte = signatureBytes[64];
    if (vByte != 27 and vByte != 28) return #err(#InvalidSignature("v must be 27 or 28"));

    let recoveredAddressLower = switch (Secp256k1.ecrecover(digest, vByte, rBlob, sBlob, keccak256)) {
      case (#ok(addressBlob)) { blobToHex(addressBlob) };
      case (#err(msg)) { return #err(#InvalidSignature("ecrecover failed: " # msg)) };
    };
    let expectedAddressLower = toLowerHex(stripHexPrefix(req.evmAddress));
    if (recoveredAddressLower != expectedAddressLower) return #err(#InvalidSignature("signature does not match evmAddress"));

    // ── Step C: Single balance check (no caching — see proposal v2 §1.4) ──
    let balanceResult = await checkBalance(req.chain, req.tokenAddress, req.evmAddress);
    let balance = switch (balanceResult) {
      case (#ok(b)) { b };
      case (#err(#InvalidAddress(msg))) { return #err(#InvalidAddress(msg)) };
      case (#err(#EvmRpcError(msg))) { return #err(#EvmRpcError(msg)) };
    };
    if (balance < req.threshold) {
      return #err(#InsufficientBalance({ required = req.threshold; actual = balance }));
    };

    // ── Step D: Build leaves in submission order, then sort for tree build ──
    let timestamp = Int.abs(Time.now() / 1_000_000_000);

    // Pair each (normalized cidHash, submission index) and sort lexicographically
    // by hash. submissionToSorted[i] gives the post-sort heap-leaf-position k for
    // the i-th submitted cidHash.
    let pairs = Array.tabulate<(Text, Nat)>(count, func i = (normalizedArr[i], i));
    let sorted = Array.sort<(Text, Nat)>(pairs, func((a, _), (b, _)) = Text.compare(a, b));
    let submissionToSorted = VarArray.tabulate<Nat>(count, func _ = 0);
    var k : Nat = 0;
    while (k < count) {
      let (_, sub) = sorted[k];
      submissionToSorted[sub] := k;
      k += 1;
    };

    // Compute leaf hashes in *sorted* order.
    let sortedLeafHashes = Array.tabulate<Blob>(count, func k2 {
      let (cidHash, _) = sorted[k2];
      hashLeaf(merkleLeafPreimage(req.chain, req.tokenAddress, req.threshold, req.evmAddress, cidHash, timestamp, balance));
    });

    // ── Step E: Build the heap tree, extract root ──
    let limit = nextPowerOfTwo(count);
    let nodes = buildMerkleHeap(sortedLeafHashes, limit);
    let merkleRoot : Blob = nodes[0];

    // ── Step F: Sign the batch commitment ──
    let merkleRootHex = blobToHex(merkleRoot);
    let batchPreimage = Text.encodeUtf8(
      "HAVEN_BATCH_ATTEST_V1:"
      # chainToText(req.chain) # ":"
      # req.tokenAddress # ":"
      # Nat.toText(req.threshold) # ":"
      # req.evmAddress # ":"
      # merkleRootHex # ":"
      # Nat.toText(count) # ":"
      # Nat.toText(timestamp) # ":"
      # Nat.toText(balance)
    );

    let rootSignature : Blob = try {
      let signatureResult = await (with cycles = SCHNORR_CYCLE_BUDGET) ic.sign_with_schnorr({
        message = batchPreimage;
        derivation_path = [Text.encodeUtf8("haven_attest_v1")];
        key_id = schnorrKeyId();
      });
      signatureResult.signature;
    } catch (e) {
      return #err(#VetKDError("t-Schnorr signing failed: " # Error.message(e)));
    };

    // ── Step G: Emit per-leaf proofs in *submission* order ──
    let leaves = Array.tabulate<MerkleAttestLeaf>(count, func i {
      let sortedIdx = submissionToSorted[i];
      let leafHeapIdx = limit - 1 + sortedIdx;
      let proof = merkleProofForLeaf(nodes, leafHeapIdx);
      {
        cidHash = normalizedArr[i];
        merkleProof = proof;
      };
    });

    #ok({
      evmAddress = req.evmAddress;
      chain = req.chain;
      tokenAddress = req.tokenAddress;
      threshold = req.threshold;
      balanceAtCheck = balance;
      timestamp = timestamp;
      cidCount = count;
      merkleRoot = merkleRoot;
      leaves = leaves;
      rootSignature = rootSignature;
    });
  };

  // ── Approval-cache eviction (controller-only) ──────────────────────
  //
  // Sprint 1 · Task 02 — corpus-gate-proposal-v3 §6.2.
  //
  // Bounded-batch janitor for the `approvedHolders` map. Deletes up to
  // `maxBatch` *expired* rows in a single call and returns the count of
  // deletions. The operator cron (Sprint 2) is expected to invoke this
  // in a loop until it returns `0`, then sleep until the next pass.
  //
  // Why a controller-gated push endpoint instead of a canister-side
  // timer / heartbeat: timers/heartbeats steal cycles from the request
  // hot path and have no admission control. An operator-driven cron
  // lets us bound work per call, observe each pass, and pause sweeps
  // during incidents — see proposal §6.2.
  //
  // Implementation notes:
  //   • Iteration collects expired keys into a buffer first, then
  //     deletes — never mutate `Map` while iterating its entries.
  //   • The `maxBatch == 0` case is a no-op fast path (controller may
  //     poll the endpoint for liveness without scheduling work).
  //   • Lazy expiry on `isApprovedHolder` is the primary safeguard
  //     against staleness; this endpoint exists purely to reclaim
  //     memory occupied by rows whose composite key (which embeds
  //     `epoch`) the hot path will never look up again.
  public shared (msg) func evictExpiredApprovals(maxBatch : Nat) : async Nat {
    if (not Principal.isController(msg.caller)) {
      Runtime.trap("evictExpiredApprovals: caller is not a controller");
    };
    if (maxBatch == 0) { return 0 };
    let now = Int.abs(Time.now() / 1_000_000_000);
    // Collect first, delete second — Map mutation during iteration is unsafe.
    let toDelete = VarArray.tabulate<Text>(maxBatch, func _ = "");
    var found : Nat = 0;
    label scan for ((key, verifiedAt) in Map.entries(approvedHolders)) {
      if (verifiedAt + APPROVAL_TTL_SECONDS <= now) {
        toDelete[found] := key;
        found += 1;
        if (found == maxBatch) { break scan };
      };
    };
    var deleted : Nat = 0;
    var i : Nat = 0;
    while (i < found) {
      if (Map.delete(approvedHolders, Text.compare, toDelete[i])) {
        deleted += 1;
      };
      i += 1;
    };
    deleted;
  };

  // ── Health check ───────────────────────────────────────────────────

  public query func health() : async Text { "ok" };
};

