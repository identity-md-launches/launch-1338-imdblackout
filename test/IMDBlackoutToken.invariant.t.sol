// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IMDBlackoutToken} from "../src/IMDBlackoutToken.sol";

/// @notice Drives the token with random, bounded call sequences from several actors and keeps ghost
///         accounting of what every balance and allowance should be. The handler itself is the
///         deployer, so it plays the ProjectFactory: it holds the whole supply at the start and is
///         one of the actors that may move tokens.
///
/// Every handler function is written so that it never reverts on its own: happy-path calls are
/// bounded to what the token must accept, and the failure-path functions make the call through a
/// low-level `call`, assert it failed, and assert nothing moved. The invariant contract runs with
/// `fail-on-revert` on, so a revert inside a handler is itself a finding.
contract TokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    IMDBlackoutToken public token;

    /// @dev The actors the fuzzer may act as. Index 0 is the handler itself (the deployer / factory).
    address[] public actors;
    /// @dev An address that never takes part. Its balance must stay zero forever.
    address public immutable outsider;

    // ------------------------------------------------------------------ ghost state
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostBurned;
    uint256 public ghostMovedByTransfer;
    uint256 public ghostMovedByTransferFrom;

    // ------------------------------------------------------------------ call counters
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_burn;
    uint256 public calls_rejectedTransferOverBalance;
    uint256 public calls_rejectedTransferFromOverAllowance;
    uint256 public calls_rejectedTransferFromWithoutApproval;
    uint256 public calls_rejectedTransferToZero;
    uint256 public calls_rejectedBurnOverBalance;
    uint256 public calls_rejectedUnknownSelector;
    uint256 public calls_rejectedEther;

    constructor(uint256 fuzzedActors) {
        token = new IMDBlackoutToken();
        ghostBalance[address(this)] = INITIAL_SUPPLY;

        actors.push(address(this));
        for (uint256 i = 1; i < fuzzedActors; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        // The requester's wallet from the brief is one of the actors so that any special treatment
        // of it, either way, would surface in the ghost accounting.
        actors.push(0x6616Cb624cec0B46C9718D423098150587D1272b);
        outsider = makeAddr("outsider");
        vm.deal(address(this), 100 ether);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ------------------------------------------------------------------ happy paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender did not decrease by amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver did not increase by amount");
        }

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMovedByTransfer += amount;
        ++calls_transfer;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not overwrite the allowance");

        ghostAllowance[owner][spender] = amount;
        ++calls_approve;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);

        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed the balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner did not decrease by amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver did not increase by amount");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented by amount");
            ghostAllowance[owner][spender] = allowed - amount;
        }

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostMovedByTransferFrom += amount;
        ++calls_transferFrom;
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(who));

        uint256 before = token.balanceOf(who);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(who);
        token.burn(amount);

        assertEq(token.balanceOf(who), before - amount, "burn did not reduce the burner by amount");
        assertEq(token.totalSupply(), supplyBefore - amount, "burn did not reduce the supply by amount");

        ghostBalance[who] -= amount;
        ghostBurned += amount;
        ++calls_burn;
    }

    // ------------------------------------------------------------------ failure paths
    // Each one makes a call the token must refuse, asserts that it was refused, and asserts the
    // state is exactly as before. A success here is a finding.

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "transfer of more than the balance succeeded");
        assertEq(token.balanceOf(from), balance, "a failed transfer changed the sender");
        assertEq(token.balanceOf(to), toBefore, "a failed transfer changed the receiver");
        ++calls_rejectedTransferOverBalance;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // nothing exceeds an infinite allowance
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertFalse(ok, "transferFrom above the allowance succeeded");
        assertEq(token.balanceOf(owner), ownerBefore, "a failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "a failed transferFrom changed the receiver");
        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        ++calls_rejectedTransferFromOverAllowance;
    }

    function transferFromWithoutApproval(uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        // A stranger with no approval at all tries to move a holder's tokens.
        address stranger = makeAddr("stranger-with-no-approval");
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 1, type(uint256).max);

        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(stranger);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertFalse(ok, "an unapproved spender moved a holder's tokens");
        assertEq(token.balanceOf(owner), ownerBefore, "a failed transferFrom changed the owner");
        ++calls_rejectedTransferFromWithoutApproval;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);

        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to the zero address succeeded");
        assertEq(token.balanceOf(from), before, "a failed transfer changed the sender");
        ++calls_rejectedTransferToZero;
    }

    function burnOverBalance(uint256 actorSeed, uint256 excess) external {
        address who = _actor(actorSeed);
        uint256 balance = token.balanceOf(who);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(who);
        (bool ok,) = address(token).call(abi.encodeCall(token.burn, (balance + excess)));
        assertFalse(ok, "burn of more than the balance succeeded");
        assertEq(token.balanceOf(who), balance, "a failed burn changed the balance");
        assertEq(token.totalSupply(), supplyBefore, "a failed burn changed the supply");
        ++calls_rejectedBurnOverBalance;
    }

    function callUnknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata args) external {
        if (_isKnownSelector(selector)) return;
        address caller = _actor(callerSeed);
        uint256 supplyBefore = token.totalSupply();
        uint256 callerBefore = token.balanceOf(caller);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "a selector outside the token's ABI was accepted");
        assertEq(token.totalSupply(), supplyBefore, "an unknown selector changed the supply");
        assertEq(token.balanceOf(caller), callerBefore, "an unknown selector changed a balance");
        ++calls_rejectedUnknownSelector;
    }

    function sendEther(uint256 value) external {
        value = bound(value, 1, address(this).balance);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        ++calls_rejectedEther;
    }

    function _isKnownSelector(bytes4 selector) internal view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.balanceOf.selector || selector == token.transfer.selector
            || selector == token.allowance.selector || selector == token.approve.selector
            || selector == token.transferFrom.selector || selector == token.burn.selector
            || selector == token.SUPPLY_WHOLE_TOKENS.selector || selector == token.TOTAL_SUPPLY.selector
            || selector == token.REQUESTER.selector;
    }

    receive() external payable {}
}

/// @notice Invariants over random call sequences driven through {TokenHandler}.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IMDBlackoutTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;

    TokenHandler internal handler;
    IMDBlackoutToken internal token;

    function setUp() public {
        handler = new TokenHandler(6);
        token = handler.token();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.transferOverBalance.selector;
        selectors[5] = handler.transferFromOverAllowance.selector;
        selectors[6] = handler.transferFromWithoutApproval.selector;
        selectors[7] = handler.transferToZero.selector;
        selectors[8] = handler.burnOverBalance.selector;
        selectors[9] = handler.callUnknownSelector.selector;
        selectors[10] = handler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is fixed at deployment and may only ever shrink through burns.
    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), INITIAL_SUPPLY, "the supply grew");
        assertEq(token.TOTAL_SUPPLY(), INITIAL_SUPPLY);
    }

    /// @dev Conservation: what is left equals what was minted minus what holders burned.
    function invariant_supplyEqualsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY - handler.ghostBurned(), "supply != minted - burned");
    }

    /// @dev Sum of parts equals the tracked whole. Only actors ever receive tokens, so their balances
    ///      must add up to the supply exactly: nothing is created, lost or parked anywhere else.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances != totalSupply");
    }

    /// @dev Every actor holds exactly what the ghost accounting says it received minus sent and burned.
    function invariant_balancesMatchGhostAccounting() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "balance drifted from ghost");
        }
    }

    /// @dev Allowances are exactly what was approved minus what was spent, and infinite stays infinite.
    function invariant_allowancesMatchGhostAccounting() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance drifted from ghost"
                );
            }
        }
    }

    /// @dev No single holder can hold more than exists.
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.actorCount();
        uint256 supply = token.totalSupply();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.actors(i)), supply, "a balance exceeds the supply");
        }
    }

    /// @dev Tokens never land on the zero address, on the token itself, or on an address nobody acted as.
    function invariant_nothingLeaksToBystanders() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(handler.outsider()), 0, "a bystander received tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Metadata is immutable: no call sequence can change what the token says it is.
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "IMDBlackout");
        assertEq(token.symbol(), "IMDBLACKOUT");
        assertEq(token.decimals(), 18);
        assertEq(token.REQUESTER(), 0x6616Cb624cec0B46C9718D423098150587D1272b);
    }

    /// @dev Everything that left the deployer's balance is accounted for by movements and burns:
    ///      no path other than transfer, transferFrom and burn changes a balance.
    function invariant_onlyKnownPathsMoveTokens() public view {
        uint256 n = handler.actorCount();
        uint256 others;
        for (uint256 i = 1; i < n; ++i) {
            others += token.balanceOf(handler.actors(i));
        }
        // Everything not held by the deployer was either burned or is held by the other actors, and
        // it can only have got there through the two transfer paths.
        assertEq(INITIAL_SUPPLY - token.balanceOf(address(handler)), others + handler.ghostBurned());
        assertLe(others, handler.ghostMovedByTransfer() + handler.ghostMovedByTransferFrom());
    }

    /// @dev Not an invariant of the token but of the suite: the failure paths were actually reached.
    ///      Printed so a vacuous run (all rejected calls returning early) is visible in the log.
    function invariant_callSummary() public {
        // Only logs; the assertions live in the handler.
        emit log_named_uint("transfer", handler.calls_transfer());
        emit log_named_uint("transferFrom", handler.calls_transferFrom());
        emit log_named_uint("approve", handler.calls_approve());
        emit log_named_uint("burn", handler.calls_burn());
        emit log_named_uint("rejected transfer over balance", handler.calls_rejectedTransferOverBalance());
        emit log_named_uint("rejected transferFrom over allowance", handler.calls_rejectedTransferFromOverAllowance());
        emit log_named_uint("rejected transferFrom unapproved", handler.calls_rejectedTransferFromWithoutApproval());
        emit log_named_uint("rejected transfer to zero", handler.calls_rejectedTransferToZero());
        emit log_named_uint("rejected burn over balance", handler.calls_rejectedBurnOverBalance());
        emit log_named_uint("rejected unknown selector", handler.calls_rejectedUnknownSelector());
        emit log_named_uint("rejected ether", handler.calls_rejectedEther());
    }
}

/// @notice The token's raw ABI surface under unguided fuzzing: forge calls the token directly, from
///         random senders with random arguments, with reverts allowed. Whatever sequence it finds,
///         the supply may never grow and the zero address may never hold anything.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = false
contract IMDBlackoutTokenOpenSurfaceInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;

    IMDBlackoutToken internal token;
    address internal stranger;

    function setUp() public {
        token = new IMDBlackoutToken();
        stranger = makeAddr("stranger");
        targetContract(address(token));
        // The deployer holds everything; let the fuzzer act as it as well as as strangers.
        targetSender(address(this));
        targetSender(stranger);
        targetSender(0x6616Cb624cec0B46C9718D423098150587D1272b);
    }

    function invariant_open_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), INITIAL_SUPPLY, "the supply grew under open fuzzing");
    }

    function invariant_open_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_open_deployerPlusStrangersNeverExceedSupply() public view {
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(stranger)
            + token.balanceOf(0x6616Cb624cec0B46C9718D423098150587D1272b);
        assertLe(held, token.totalSupply(), "known holders hold more than exists");
    }
}
