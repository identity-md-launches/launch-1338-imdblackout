// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDBlackoutToken} from "../src/IMDBlackoutToken.sol";

/// @notice Stateless property tests at the arithmetic edges, with the failure paths fuzzed as hard as
///         the happy ones. The edge cases already known (zero, one wei, the whole supply, the maximum)
///         are pinned as plain unit tests beside the fuzzed ones.
/// forge-config: default.fuzz.runs = 1000
contract IMDBlackoutTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant REQUESTER = 0x6616Cb624cec0B46C9718D423098150587D1272b;

    IMDBlackoutToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        // This contract is the deployer and so plays the factory holding the supply.
        token = new IMDBlackoutToken();
    }

    function _fund(address who, uint256 amount) internal {
        assertTrue(token.transfer(who, amount));
    }

    // ------------------------------------------------------------------ deployment

    /// @dev Whoever runs the constructor receives the whole supply, no matter who they are.
    function testFuzz_anyDeployerReceivesTheWholeSupply(address deployer) public {
        assumeNotForgeAddress(deployer);
        if (deployer == address(0)) {
            // OpenZeppelin refuses to mint to the zero address, so a construction from address(0) is
            // the one case that fails. No real deployer is the zero address; pinned here so the edge is known.
            vm.prank(address(0));
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            new IMDBlackoutToken();
            return;
        }
        vm.prank(deployer);
        IMDBlackoutToken fresh = new IMDBlackoutToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.balanceOf(REQUESTER), deployer == REQUESTER ? SUPPLY : 0);
    }

    /// @dev Pinned edge of the above: the constructor cannot run from the zero address. Harmless in
    ///      practice (the factory is a real contract), recorded so the behaviour is known.
    function test_deployingFromZeroAddressReverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new IMDBlackoutToken();
    }

    /// @dev Two deployments are independent: a holder of one has nothing in the other.
    function test_deploymentsAreIndependent() public {
        IMDBlackoutToken other = new IMDBlackoutToken();
        _fund(alice, 1 ether);
        assertEq(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    // ------------------------------------------------------------------ transfer: edges

    function test_transferOneWei() public {
        _fund(alice, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferWholeSupplyInOneCall() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        // And the drained deployer can no longer move even one wei.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferMaxUintRevertsEvenForTheWholeSupplyHolder() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    /// @dev Sending exactly the balance empties the sender; sending one more than the balance reverts
    ///      with the exact shortfall reported, and leaves both sides untouched.
    function testFuzz_transferExactBalanceEmptiesSender(uint256 funded) public {
        funded = bound(funded, 0, SUPPLY);
        _fund(alice, funded);
        vm.prank(alice);
        assertTrue(token.transfer(bob, funded));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), funded);
    }

    function testFuzz_transferOverBalanceRevertsAndMovesNothing(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - funded);
        _fund(alice, funded);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, funded + excess)
        );
        token.transfer(bob, funded + excess);
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Self-transfer of any amount up to the balance is a no-op; above it, it reverts.
    function testFuzz_selfTransferIsANoOp(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(alice, funded);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferToZeroAddressAlwaysReverts(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, type(uint256).max);
        _fund(alice, funded);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Splitting an amount across two transfers delivers the same total as one transfer would.
    function testFuzz_transferIsAdditive(uint256 funded, uint256 first) public {
        funded = bound(funded, 0, SUPPLY);
        first = bound(first, 0, funded);
        _fund(alice, funded);
        vm.startPrank(alice);
        token.transfer(bob, first);
        token.transfer(bob, funded - first);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), funded);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev A chain of transfers through several holders loses nothing on the way.
    function testFuzz_transferChainConservesEveryWei(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fund(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(carol, amount);
        vm.prank(carol);
        token.transfer(REQUESTER, amount);
        vm.prank(REQUESTER);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY, "a wei was lost on the way round");
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(REQUESTER), 0);
    }

    // ------------------------------------------------------------------ approvals: edges

    function testFuzz_approveOverwritesNotAccumulates(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        assertTrue(token.approve(bob, first));
        assertEq(token.allowance(alice, bob), first);
        assertTrue(token.approve(bob, second));
        assertEq(token.allowance(alice, bob), second, "approve must overwrite, not add");
        vm.stopPrank();
        // Approvals are directional and per spender.
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.allowance(alice, carol), 0);
    }

    /// @dev An approval is independent of the owner's balance: it may exceed it, and it does not move anything.
    function testFuzz_approveNeverMovesTokens(uint256 amount) public {
        vm.prank(alice);
        token.approve(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Oracle: transferFrom succeeds iff amount <= allowance and amount <= balance, and the revert
    ///      names the first constraint OpenZeppelin checks (the allowance).
    function testFuzz_transferFromOutcomeMatchesAllowanceAndBalance(uint256 funded, uint256 allowed, uint256 amount)
        public
    {
        funded = bound(funded, 0, SUPPLY);
        _fund(alice, funded);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount)
            );
            token.transferFrom(alice, carol, amount);
            assertEq(token.allowance(alice, bob), allowed);
            assertEq(token.balanceOf(alice), funded);
        } else if (amount > funded) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount)
            );
            token.transferFrom(alice, carol, amount);
            assertEq(token.allowance(alice, bob), allowed, "a failed transferFrom must not spend allowance");
            assertEq(token.balanceOf(alice), funded);
        } else {
            assertTrue(token.transferFrom(alice, carol, amount));
            assertEq(token.balanceOf(alice), funded - amount);
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.allowance(alice, bob), allowed == type(uint256).max ? allowed : allowed - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Spending an allowance in several pieces consumes exactly the sum, and the piece that
    ///      overshoots the remainder is refused.
    function testFuzz_allowanceIsConsumedExactly(uint256 allowed, uint256 first) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        first = bound(first, 0, allowed);
        _fund(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.startPrank(bob);
        token.transferFrom(alice, carol, first);
        assertEq(token.allowance(alice, bob), allowed - first);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed - first, allowed - first + 1
            )
        );
        token.transferFrom(alice, carol, allowed - first + 1);
        token.transferFrom(alice, carol, allowed - first);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), allowed);
    }

    /// @dev The owner is not implicitly its own spender: transferFrom(self) needs a self-approval.
    function testFuzz_transferFromBySelfStillNeedsAllowance(uint256 funded, uint256 amount) public {
        funded = bound(funded, 1, SUPPLY);
        amount = bound(amount, 1, funded);
        _fund(alice, funded);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, amount));
        token.transferFrom(alice, bob, amount);

        vm.startPrank(alice);
        token.approve(alice, amount);
        assertTrue(token.transferFrom(alice, bob, amount));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, alice), 0);
    }

    /// @dev An approval survives the owner's balance going to zero and back, and a spender cannot use
    ///      an allowance to reach tokens the owner no longer has.
    function testFuzz_allowanceDoesNotFollowTheBalance(uint256 allowed) public {
        allowed = bound(allowed, 1, SUPPLY);
        _fund(alice, allowed);
        vm.startPrank(alice);
        token.approve(bob, allowed);
        token.transfer(carol, allowed); // alice spends it herself first
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), allowed, "the allowance should still stand");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, allowed));
        token.transferFrom(alice, bob, allowed);
    }

    function test_transferFromToZeroAddressReverts() public {
        _fund(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1);
        assertEq(token.allowance(alice, bob), 10, "a failed transferFrom must not spend allowance");
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        // Nobody holds an allowance from address(0), so the allowance check fires first and nothing
        // can be pulled out of the zero address even though its balance is zero anyway.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    // ------------------------------------------------------------------ burn: edges

    function test_burnZeroIsANoOp() public {
        _fund(alice, 5);
        vm.prank(alice);
        token.burn(0);
        assertEq(token.balanceOf(alice), 5);
        assertEq(token.totalSupply(), SUPPLY);
        // Even an account with nothing can burn nothing.
        vm.prank(bob);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnOneWei() public {
        _fund(alice, 1);
        vm.prank(alice);
        token.burn(1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_burnWholeSupplyLeavesNothingToMove() public {
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
        // Nothing brings it back: the only path to a larger supply would be a mint, and there is none.
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 0);
    }

    function test_burnWithNoBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    /// @dev Burning reduces holder and supply by exactly the amount, and one wei more than held reverts.
    function testFuzz_burnReducesExactlyAndOverBurnReverts(uint256 funded, uint256 burned, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY);
        burned = bound(burned, 0, funded);
        _fund(alice, funded);

        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), funded - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        // The deployer's remainder is untouched by someone else's burn.
        assertEq(token.balanceOf(address(this)), SUPPLY - funded);

        uint256 left = funded - burned;
        excess = bound(excess, 1, type(uint256).max - left);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, left, left + excess)
        );
        token.burn(left + excess);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    /// @dev Burns from several holders add up: supply after = supply before - sum of burns.
    function testFuzz_burnsFromSeveralHoldersAddUp(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY / 3);
        b = bound(b, 0, SUPPLY / 3);
        c = bound(c, 0, SUPPLY / 3);
        _fund(alice, a);
        _fund(bob, b);
        _fund(carol, c);
        vm.prank(alice);
        token.burn(a);
        vm.prank(bob);
        token.burn(b);
        vm.prank(carol);
        token.burn(c);
        assertEq(token.totalSupply(), SUPPLY - a - b - c);
        assertEq(token.balanceOf(address(this)), token.totalSupply(), "the deployer should hold all that is left");
    }

    /// @dev An allowance does not let the spender burn: there is no burnFrom, and `burn` always acts on
    ///      msg.sender, so a spender calling burn only burns its own tokens.
    function testFuzz_burnByAnApprovedSpenderBurnsOnlyItsOwn(uint256 ownerFunds, uint256 spenderFunds) public {
        ownerFunds = bound(ownerFunds, 0, SUPPLY / 2);
        spenderFunds = bound(spenderFunds, 0, SUPPLY / 2);
        _fund(alice, ownerFunds);
        _fund(bob, spenderFunds);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.burn(spenderFunds);
        assertEq(token.balanceOf(alice), ownerFunds, "the owner's balance was burned by its spender");
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY - spenderFunds);
    }

    // ------------------------------------------------------------------ the ABI surface

    /// @dev Any selector outside the token's ABI reverts, from any caller, with any arguments, and
    ///      changes nothing. This is the fuzzed form of "there is no hidden admin function".
    function testFuzz_unknownSelectorRevertsAndChangesNothing(address caller, bytes4 selector, bytes calldata args)
        public
    {
        if (_isKnownSelector(selector)) selector = bytes4(uint32(selector) ^ 0x80000000);
        if (_isKnownSelector(selector)) selector = 0xdeadbeef;
        if (caller == address(0)) caller = alice;
        assumeNotForgeAddress(caller);
        _fund(alice, 10 ether);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "a selector outside the ABI was accepted");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        assertEq(token.balanceOf(caller), caller == alice ? 10 ether : caller == address(this) ? SUPPLY - 10 ether : 0);
    }

    /// @dev Calls to real selectors with short or malformed calldata revert rather than reading garbage.
    function testFuzz_truncatedCalldataReverts(uint8 keep) public {
        bytes memory full = abi.encodeCall(token.transfer, (alice, 1 ether));
        uint256 len = bound(keep, 4, full.length - 1); // at least the selector, never the whole call
        bytes memory truncated = new bytes(len);
        for (uint256 i; i < len; ++i) {
            truncated[i] = full[i];
        }
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok, "a truncated transfer call was accepted");
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_etherIsAlwaysRefused(uint256 value, bytes4 selector) public {
        value = bound(value, 1, 1_000_000 ether);
        vm.deal(address(this), value);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "plain ether was accepted");
        (ok,) = address(token).call{value: value}(abi.encodePacked(selector));
        assertFalse(ok, "ether with calldata was accepted");
        (ok,) = address(token).call{value: value}(abi.encodeCall(token.transfer, (alice, 0)));
        assertFalse(ok, "a payable transfer was accepted");
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, value);
    }

    /// @dev Views are pure functions of state: calling them never changes anything, from any caller.
    function testFuzz_viewsNeverMutate(address caller, address a, address b) public {
        assumeNotForgeAddress(caller);
        _fund(alice, 7);
        vm.startPrank(caller);
        token.name();
        token.symbol();
        token.decimals();
        token.totalSupply();
        token.balanceOf(a);
        token.allowance(a, b);
        token.TOTAL_SUPPLY();
        token.SUPPLY_WHOLE_TOKENS();
        token.REQUESTER();
        vm.stopPrank();
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 7);
        assertEq(token.balanceOf(address(this)), SUPPLY - 7);
        assertEq(token.allowance(a, b), 0);
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
