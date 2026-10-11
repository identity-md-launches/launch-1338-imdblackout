// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDBlackoutToken} from "../src/IMDBlackoutToken.sol";
import {DeployIMDBlackoutToken} from "../script/Deploy.s.sol";

/// @notice Stands in for the ProjectFactory: deploys the token through CREATE2 and holds the supply,
///         the way the launch does, so the tests exercise the real deployment path.
contract FactoryStub {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract IMDBlackoutTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant REQUESTER = 0x6616Cb624cec0B46C9718D423098150587D1272b;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    FactoryStub internal factory;
    IMDBlackoutToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        factory = new FactoryStub();
        token = IMDBlackoutToken(factory.deploy(type(IMDBlackoutToken).creationCode, bytes32(uint256(1))));
    }

    // ------------------------------------------------------------------ metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "IMDBlackout");
        assertEq(token.symbol(), "IMDBLACKOUT");
        assertEq(token.decimals(), 18);
    }

    function test_constantsMatchTheBrief() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.REQUESTER(), REQUESTER);
    }

    function test_mintsWholeSupplyOnceToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(REQUESTER), 0, "the requester is not allocated anything by the constructor");
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsTransferFromZeroAndSupplyMinted() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit SupplyMinted(address(this), SUPPLY);
        new IMDBlackoutToken();
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Deploying the raw creation code with nothing appended must succeed: the manifest's
        // constructorArgs for this token is the empty list.
        address deployed = factory.deploy(type(IMDBlackoutToken).creationCode, bytes32(uint256(2)));
        assertGt(deployed.code.length, 0);
        assertEq(IMDBlackoutToken(deployed).balanceOf(address(factory)), SUPPLY);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, 24_576);
    }

    function test_deployScriptFunctionMintsToItsCaller() public {
        DeployIMDBlackoutToken script = new DeployIMDBlackoutToken();
        IMDBlackoutToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // ------------------------------------------------------------------ transfers

    function test_transferMovesExactAmount() public {
        factory.move(token, alice, 1_000 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 400 ether);
        assertTrue(token.transfer(bob, 400 ether));
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(token, alice, 5 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        factory.move(token, alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_requesterIsAnOrdinaryHolder() public {
        // The requester's address from the brief has no special treatment either way.
        factory.move(token, REQUESTER, 100 ether);
        vm.prank(REQUESTER);
        assertTrue(token.transfer(alice, 60 ether));
        assertEq(token.balanceOf(REQUESTER), 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        vm.prank(REQUESTER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, REQUESTER, 40 ether, 41 ether)
        );
        token.transfer(alice, 41 ether);
    }

    function testFuzz_transferConservesSupplyAndDeliversExactly(uint256 funded, uint256 sent) public {
        funded = bound(funded, 0, SUPPLY);
        sent = bound(sent, 0, funded);
        factory.move(token, alice, funded);
        vm.prank(alice);
        assertTrue(token.transfer(bob, sent));
        assertEq(token.balanceOf(bob), sent, "delivered amount differs from sent amount");
        assertEq(token.balanceOf(alice), funded - sent);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------ approvals

    function test_approveAndTransferFrom() public {
        factory.move(token, alice, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 30 ether);
        assertTrue(token.approve(bob, 30 ether));
        assertEq(token.allowance(alice, bob), 30 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 20 ether));
        assertEq(token.balanceOf(alice), 80 ether);
        assertEq(token.balanceOf(carol), 20 ether);
        assertEq(token.allowance(alice, bob), 10 ether);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        factory.move(token, alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 5 ether, 6 ether));
        token.transferFrom(alice, carol, 6 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        factory.move(token, alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromRevertsOnInsufficientBalanceEvenWithAllowance() public {
        factory.move(token, alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, carol, 2 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 50 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------ burning

    function test_burnReducesHolderAndSupply() public {
        factory.move(token, alice, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 40 ether);
        vm.expectEmit(true, true, true, true);
        emit Burned(alice, 40 ether);
        token.burn(40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), SUPPLY - 40 ether);
    }

    function test_burnRevertsOnInsufficientBalance() public {
        factory.move(token, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.burn(2 ether);
    }

    function test_burnOnlyTouchesTheCaller() public {
        factory.move(token, alice, 10 ether);
        factory.move(token, bob, 10 ether);
        vm.prank(bob);
        token.burn(10 ether);
        assertEq(token.balanceOf(alice), 10 ether, "another holder's burn touched this balance");
        assertEq(token.balanceOf(bob), 0);
    }

    function test_noBurnFromExists() public {
        factory.move(token, alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether));
        assertFalse(ok, "burnFrom must not exist");
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------ no privileged powers

    function test_noMintOrAdminCallGrowsSupply() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        address[3] memory callers = [address(0xBEEF), address(factory), REQUESTER];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), type(uint128).max);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
                assertEq(token.totalSupply(), SUPPLY, signatures[i]);
                assertEq(token.balanceOf(address(0xBEEF)), 0, signatures[i]);
            }
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(token, alice, 1_000 ether);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setExempt(address,bool)"
        ];
        address[2] memory callers = [address(factory), REQUESTER];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, true);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.balanceOf(alice), 1_000 ether, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_unknownSelectorAndPlainEtherRevert() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------ launch flows

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        address poolManager = makeAddr("poolManager");

        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 pool = (SUPPLY * 8_800) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm, "the swarm's share arrived short");

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "a claim arrived short");
        assertEq(token.balanceOf(distributor), 0);

        assertTrue(factory.move(token, poolManager, pool));
        assertEq(token.balanceOf(poolManager), pool, "the seed arrived short");

        assertTrue(factory.move(token, REQUESTER, remainder));
        assertEq(token.balanceOf(REQUESTER), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");

        // A trader buys from and sells back into the pool manager, both legs whole.
        address trader = makeAddr("trader");
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, 1_234 ether));
        assertEq(token.balanceOf(trader), 1_234 ether);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, 1_234 ether));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);

        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }
}
