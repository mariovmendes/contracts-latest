// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CetFactory} from "../../../src/l2/CETFactory.sol";
import {ComposableERC20} from "../../../src/l2/ComposableERC20.sol";
import {UniversalBridgeMailbox} from "../../../src/l2/UniversalBridgeMailbox.sol";
import {ComposeETHLiquidity} from "../../../src/l2/ComposeETHLiquidity.sol";
import {ComposeL2ToL2Bridge} from "../../../src/l2/ComposeL2ToL2Bridge.sol";
import {L2ComposeBridge} from "../../../src/l2/L2ComposeBridge.sol";

import {IUniversalBridgeMailbox} from "src/l2/interfaces/IUniversalBridgeMailbox.sol";
import {IComposableERC20} from "src/l2/interfaces/IComposableERC20.sol";

import {MockL2CrossDomainMessenger} from "test/l2/mock/MockL2CrossDomainMessenger.sol";

contract MockL2ERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCoreCET {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => bool) public authorizedBridges;
    address public immutable owner;

    constructor(address bridge) {
        owner = msg.sender;
        authorizedBridges[bridge] = true;
    }

    function authorizeBridge(address b) external {
        require(msg.sender == owner, "owner");
        authorizedBridges[b] = true;
    }

    function remoteAsset() external view returns (address) {
        return address(this);
    }

    function remoteChainID() external view returns (uint256) {
        return block.chainid;
    }

    function cetType() external pure returns (IComposableERC20.CetType) {
        return IComposableERC20.CetType.CORE;
    }

    function crosschainMint(address to, uint256 amount) external {
        require(authorizedBridges[msg.sender], "auth");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function crosschainBurn(address from, uint256 amount) external {
        require(authorizedBridges[msg.sender], "auth");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract ComposeL2IntegrationSetup is Test {
    CetFactory public cetFactory;
    UniversalBridgeMailbox public mailbox;
    ComposeETHLiquidity public ethLiquidity;
    ComposeL2ToL2Bridge public l2l2Bridge;
    L2ComposeBridge public l2Bridge;
    MockL2CrossDomainMessenger public messenger;
    MockL2ERC20 public nativeToken;

    address public owner;
    address public coordinator;
    address public alice;
    address public bob;
    address public fakeL1Bridge;
    address public fakeRemoteBridge;

    uint256 public constant L1_CHAIN_ID = 11_155_111;
    uint256 public constant REMOTE_L2_CHAIN_ID = 1_000_001;

    uint256 public constant INITIAL_LIQUIDITY = 100 ether;

    uint256 private _initialChainId;

    event SendMessageCalled(address indexed target, bytes message, uint32 minGasLimit, uint256 value);
    event ETHDepositInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ETHBridgeFinalized(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event DepositFinalized(address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes extraData);
    event WithdrawalInitiated(address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes extraData);
    event ERC20BridgeInitiated(address indexed localToken, address indexed remoteToken, address indexed from, address to, uint256 amount, bytes extraData);
    event ERC20BridgeFinalized(address indexed localToken, address indexed remoteToken, address indexed from, address to, uint256 amount, bytes extraData);

    function setUp() public virtual {
        _initialChainId = block.chainid;

        owner = makeAddr("owner");
        coordinator = makeAddr("coordinator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        fakeL1Bridge = makeAddr("fakeL1Bridge");
        fakeRemoteBridge = makeAddr("fakeRemoteL2Bridge");

        vm.deal(owner, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        messenger = new MockL2CrossDomainMessenger();
        vm.deal(address(messenger), 1000 ether);

        vm.startPrank(owner);

        cetFactory = new CetFactory();
        cetFactory.initialize(owner);
        mailbox = new UniversalBridgeMailbox(coordinator, owner);
        ethLiquidity = new ComposeETHLiquidity(owner);

        l2l2Bridge = new ComposeL2ToL2Bridge(address(mailbox), address(cetFactory), address(ethLiquidity), coordinator);

        l2Bridge = new L2ComposeBridge(address(messenger), address(cetFactory), L1_CHAIN_ID);

        cetFactory.authorizeBridge(address(l2l2Bridge));
        cetFactory.authorizeBridge(address(l2Bridge));
        ethLiquidity.authorizeBridge(address(l2l2Bridge));
        mailbox.authorizeBridge(address(l2l2Bridge));

        ethLiquidity.fund{value: INITIAL_LIQUIDITY}();

        l2Bridge.setOtherBridge(fakeL1Bridge);

        vm.stopPrank();

        nativeToken = new MockL2ERC20("Native", "NAT");
        nativeToken.mint(alice, 1000e18);
        nativeToken.mint(bob, 1000e18);

        vm.label(address(cetFactory), "CetFactory");
        vm.label(address(mailbox), "UniversalBridgeMailbox");
        vm.label(address(ethLiquidity), "ComposeETHLiquidity");
        vm.label(address(l2l2Bridge), "ComposeL2ToL2Bridge");
        vm.label(address(l2Bridge), "L2ComposeBridge");
        vm.label(address(messenger), "MockL2CrossDomainMessenger");
        vm.label(address(nativeToken), "NativeERC20");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(owner, "owner");
        vm.label(coordinator, "coordinator");
        vm.label(fakeL1Bridge, "fakeL1Bridge");
        vm.label(fakeRemoteBridge, "fakeRemoteL2Bridge");
    }

    function _relayFromL1Bridge(address target, uint256 value, bytes memory message) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = messenger.relayFromOtherBridge{value: value}(fakeL1Bridge, target, value, message);
    }

    function _coordinatorPutInbox(uint256 chainSrc, address sender, address receiver, uint256 sessionId, string memory label, bytes memory data) internal {
        vm.prank(coordinator);
        mailbox.putInbox(chainSrc, sender, receiver, sessionId, label, data);
    }

    /// @dev Relays the ACK an l2l2Bridge just wrote to its own outbox (bridge-to-bridge, since the
    ///      bridge is deployed at the same address on every chain) into the local inbox, so the
    ///      remote-chain bridge can later call `sendConfirm`.
    function _coordinatorRelayAck(uint256 ackChainSrc, uint256 sessionId, bytes memory ackPayload) internal {
        _coordinatorPutInbox(ackChainSrc, address(l2l2Bridge), address(l2l2Bridge), sessionId, "ACK", ackPayload);
    }

    function _coordinatorSendConfirm(IUniversalBridgeMailbox.MessageHeader memory sendHeader) internal {
        vm.prank(coordinator);
        l2l2Bridge.sendConfirm(sendHeader);
    }

    function _coordinatorSendAbortToken(uint256 chainDest, address token, address sender, address receiver, uint256 amount, uint256 sessionId) internal {
        vm.prank(coordinator);
        l2l2Bridge.sendAbortToken(chainDest, token, sender, receiver, amount, sessionId);
    }

    function _coordinatorSendAbortETH(uint256 chainDest, address sender, address receiver, uint256 amount, uint256 sessionId) internal {
        vm.prank(coordinator);
        l2l2Bridge.sendAbortETH(chainDest, sender, receiver, amount, sessionId);
    }

    function _coordinatorRecvConfirmToken(IUniversalBridgeMailbox.MessageHeader memory msgHeader) internal returns (address token, uint256 amount) {
        vm.prank(coordinator);
        (token, amount) = l2l2Bridge.recvConfirmToken(msgHeader);
    }

    function _coordinatorRecvAbortToken(IUniversalBridgeMailbox.MessageHeader memory msgHeader) internal {
        vm.prank(coordinator);
        l2l2Bridge.recvAbortToken(msgHeader);
    }

    function _coordinatorRecvConfirmETH(IUniversalBridgeMailbox.MessageHeader memory msgHeader) internal returns (uint256 amount) {
        vm.prank(coordinator);
        amount = l2l2Bridge.recvConfirmETH(msgHeader);
    }

    function _coordinatorRecvAbortETH(IUniversalBridgeMailbox.MessageHeader memory msgHeader) internal {
        vm.prank(coordinator);
        l2l2Bridge.recvAbortETH(msgHeader);
    }

    function _predictCET(address remoteAsset, uint256 remoteChainId) internal view returns (address) {
        return cetFactory.predictAddress(remoteAsset, remoteChainId);
    }

    function test_setup_wiring() public view {
        assertTrue(address(cetFactory) != address(0));
        assertTrue(address(mailbox) != address(0));
        assertTrue(address(ethLiquidity) != address(0));
        assertTrue(address(l2l2Bridge) != address(0));
        assertTrue(address(l2Bridge) != address(0));

        assertTrue(cetFactory.authorizedBridges(address(l2l2Bridge)));
        assertTrue(cetFactory.authorizedBridges(address(l2Bridge)));
        assertTrue(ethLiquidity.authorizedBridges(address(l2l2Bridge)));
        assertTrue(mailbox.authorizedBridges(address(l2l2Bridge)));
        assertEq(l2l2Bridge.COORDINATOR(), coordinator);

        assertEq(address(l2l2Bridge.mailbox()), address(mailbox));
        assertEq(address(l2l2Bridge.cetFactory()), address(cetFactory));
        assertEq(address(l2l2Bridge.ethLiquidity()), address(ethLiquidity));

        assertEq(address(l2Bridge.messenger()), address(messenger));
        assertEq(address(l2Bridge.cetFactory()), address(cetFactory));
        assertEq(l2Bridge.l1ChainId(), L1_CHAIN_ID);
        assertEq(l2Bridge.otherBridge(), fakeL1Bridge);

        assertEq(address(ethLiquidity).balance, INITIAL_LIQUIDITY);
    }

    function test_erc20_l1ToL2_finalize_deploysCetAndMints() public {
        address l1Token = makeAddr("fakeL1Token");
        uint256 amount = 100e18;
        string memory name_ = "L1 Token";
        string memory symbol_ = "L1T";
        uint8 decimals_ = 18;
        bytes memory userExtra = hex"cafe";

        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        assertEq(predictedCet.code.length, 0);

        bytes memory packedExtra = abi.encode(name_, symbol_, decimals_, userExtra);
        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, bob, amount, packedExtra);

        (bool ok,) = _relayFromL1Bridge(address(l2Bridge), 0, message);
        assertTrue(ok);

        assertGt(predictedCet.code.length, 0);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(bob), amount);
        assertEq(cet.totalSupply(), amount);
        assertEq(cet.name(), name_);
        assertEq(cet.symbol(), symbol_);
        assertEq(cet.decimals(), decimals_);
        assertEq(cet.remoteAsset(), l1Token);
        assertEq(cet.remoteChainID(), L1_CHAIN_ID);
    }

    function test_erc20_l1ToL2_finalize_reusesExistingCet() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);

        uint256 firstAmount = 100e18;
        uint256 secondAmount = 50e18;

        bytes memory firstPacked = abi.encode("L1 Token", "L1T", uint8(18), bytes(""));
        bytes memory firstMessage = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, bob, firstAmount, firstPacked);
        (bool ok1,) = _relayFromL1Bridge(address(l2Bridge), 0, firstMessage);
        assertTrue(ok1);

        bytes memory secondPacked = abi.encode("Different", "DIFF", uint8(6), bytes(""));
        bytes memory secondMessage =
            abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, secondAmount, secondPacked);
        (bool ok2,) = _relayFromL1Bridge(address(l2Bridge), 0, secondMessage);
        assertTrue(ok2);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(bob), firstAmount);
        assertEq(cet.balanceOf(alice), secondAmount);
        assertEq(cet.totalSupply(), firstAmount + secondAmount);
        assertEq(cet.name(), "L1 Token");
        assertEq(cet.symbol(), "L1T");
        assertEq(cet.decimals(), 18);
    }

    function test_erc20_l1ToL2_finalize_revertsIfLocalTokenMismatch() public {
        address l1Token = makeAddr("fakeL1Token");
        address wrongCet = makeAddr("wrongCet");
        assertTrue(wrongCet != cetFactory.predictAddress(l1Token, L1_CHAIN_ID));

        bytes memory packedExtra = abi.encode("X", "X", uint8(18), bytes(""));
        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, wrongCet, l1Token, alice, bob, 100e18, packedExtra);

        messenger.setXDomainMessageSender(fakeL1Bridge);
        vm.prank(address(messenger));
        vm.expectRevert(L2ComposeBridge.LocalTokenMismatch.selector);
        (bool ok,) = address(l2Bridge).call(message);
        ok;
    }

    function test_erc20_l1ToL2_finalize_decodesPackedExtra() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);

        string memory name_ = "Weird Name";
        string memory symbol_ = "wXYZ";
        uint8 decimals_ = 6;
        bytes memory userExtra = hex"112233";

        bytes memory packed = abi.encode(name_, symbol_, decimals_, userExtra);
        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, bob, 100e6, packed);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit DepositFinalized(l1Token, predictedCet, alice, bob, 100e6, userExtra);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit ERC20BridgeFinalized(predictedCet, l1Token, alice, bob, 100e6, userExtra);

        (bool ok,) = _relayFromL1Bridge(address(l2Bridge), 0, message);
        assertTrue(ok);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.name(), name_);
        assertEq(cet.symbol(), symbol_);
        assertEq(cet.decimals(), decimals_);
    }

    function test_erc20_l1ToL2_finalize_emitsFinalizedEvents() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        bytes memory userExtra = hex"beef";

        bytes memory packed = abi.encode("T", "T", uint8(18), userExtra);
        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, bob, amount, packed);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit DepositFinalized(l1Token, predictedCet, alice, bob, amount, userExtra);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit ERC20BridgeFinalized(predictedCet, l1Token, alice, bob, amount, userExtra);

        (bool ok,) = _relayFromL1Bridge(address(l2Bridge), 0, message);
        assertTrue(ok);
    }

    function test_eth_l2ToL1_initiate_sendsMessengerMessageWithValue() public {
        uint256 amount = 1 ether;
        uint32 minGas = 200_000;
        bytes memory extra = hex"1234";

        bytes memory expectedMessage = abi.encodeWithSignature("finalizeBridgeETH(address,address,uint256,bytes)", alice, alice, amount, extra);

        vm.prank(alice, alice);
        l2Bridge.bridgeETH{value: amount}(minGas, extra);

        (address target,, uint32 sentMinGas, uint256 sentValue) = messenger.lastSent();
        assertEq(target, fakeL1Bridge);
        assertEq(sentMinGas, minGas);
        assertEq(sentValue, amount);
        assertEq(messenger.callCount(), 1);
        assertEq(keccak256(messenger.lastMessage()), keccak256(expectedMessage));
    }

    function test_erc20_l2ToL1_initiate_burnsAndSends() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        bytes memory extra = hex"abcd";
        uint32 minGas = 200_000;

        bytes memory packed = abi.encode("T", "T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(alice), amount);
        uint256 supplyBefore = cet.totalSupply();

        vm.prank(alice);
        l2Bridge.bridgeERC20To(predictedCet, l1Token, bob, amount, minGas, extra);

        assertEq(cet.balanceOf(alice), 0);
        assertEq(cet.totalSupply(), supplyBefore - amount);

        bytes memory expectedMessage =
            abi.encodeWithSignature("finalizeBridgeERC20(address,address,address,address,uint256,bytes)", l1Token, predictedCet, alice, bob, amount, extra);

        (address target,, uint32 sentMinGas, uint256 sentValue) = messenger.lastSent();
        assertEq(target, fakeL1Bridge);
        assertEq(sentMinGas, minGas);
        assertEq(sentValue, 0);
        assertEq(keccak256(messenger.lastMessage()), keccak256(expectedMessage));
    }

    function test_erc20_l2ToL1_initiate_emitsInitiatedEvents() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        bytes memory extra = hex"abcd";

        bytes memory packed = abi.encode("T", "T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit WithdrawalInitiated(l1Token, predictedCet, alice, bob, amount, extra);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit ERC20BridgeInitiated(predictedCet, l1Token, alice, bob, amount, extra);

        vm.prank(alice);
        l2Bridge.bridgeERC20To(predictedCet, l1Token, bob, amount, 200_000, extra);
    }

    function test_l2l2_bridgeERC20To_locksAndWritesSend() public {
        uint256 amount = 100e18;
        uint256 sessionId = 0xABCD1234;

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);

        uint256 aliceBefore = nativeToken.balanceOf(alice);
        uint256 bridgeBefore = nativeToken.balanceOf(address(l2l2Bridge));

        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), amount, bob, sessionId);

        assertEq(nativeToken.balanceOf(alice), aliceBefore - amount);
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), bridgeBefore + amount);

        bytes32 outKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS");
        bytes memory expectedPayload = abi.encode(block.chainid, address(nativeToken), amount, nativeToken.name(), nativeToken.symbol(), nativeToken.decimals());
        assertEq(keccak256(mailbox.outbox(outKey)), keccak256(expectedPayload));
    }

    function test_l2l2_receiveTokens_nativeChain_releasesEscrow() public {
        uint256 amount = 100e18;
        uint256 sessionId = 0x1111;

        nativeToken.mint(address(l2l2Bridge), amount);

        bytes memory payload = abi.encode(block.chainid, address(nativeToken), amount, nativeToken.name(), nativeToken.symbol(), nativeToken.decimals());
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS", payload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: REMOTE_L2_CHAIN_ID, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_TOKENS"
        });

        uint256 bobBefore = nativeToken.balanceOf(bob);
        uint256 bridgeBefore = nativeToken.balanceOf(address(l2l2Bridge));

        vm.prank(bob);
        (address outToken, uint256 outAmount) = l2l2Bridge.receiveTokens(hdr);

        assertEq(outToken, address(nativeToken));
        assertEq(outAmount, amount);
        // Pending: recv() doesn't deliver yet, only recvConfirmToken does.
        assertEq(nativeToken.balanceOf(bob), bobBefore);
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), bridgeBefore);

        bytes32 ackKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), address(l2l2Bridge), sessionId, "ACK");
        bytes memory expectedAck = abi.encode(address(nativeToken), amount);
        assertEq(keccak256(mailbox.outbox(ackKey)), keccak256(expectedAck));

        _coordinatorRecvConfirmToken(hdr);
        assertEq(nativeToken.balanceOf(bob), bobBefore + amount);
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), bridgeBefore - amount);
    }

    function test_l2l2_receiveTokens_remoteChain_deploysCetAndMints() public {
        address remoteAsset = makeAddr("remoteNativeAsset");
        uint256 amount = 100e18;
        uint256 sessionId = 0x2222;
        address predictedCet = cetFactory.predictAddress(remoteAsset, REMOTE_L2_CHAIN_ID);
        assertEq(predictedCet.code.length, 0);

        _pushSendTokensToInbox(remoteAsset, amount, sessionId, bob);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: REMOTE_L2_CHAIN_ID, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_TOKENS"
        });

        vm.prank(bob);
        (address outToken, uint256 outAmount) = l2l2Bridge.receiveTokens(hdr);

        assertEq(outToken, predictedCet);
        assertEq(outAmount, amount);
        assertGt(predictedCet.code.length, 0);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        // Pending: minted to the bridge itself until recvConfirmToken delivers it.
        assertEq(cet.balanceOf(address(l2l2Bridge)), amount);
        assertEq(cet.balanceOf(bob), 0);
        assertEq(cet.totalSupply(), amount);
        assertEq(cet.name(), "Remote");
        assertEq(cet.symbol(), "RMT");
        assertEq(cet.decimals(), 18);
        assertEq(cet.remoteAsset(), remoteAsset);
        assertEq(cet.remoteChainID(), REMOTE_L2_CHAIN_ID);

        _assertAckOutbox(sessionId, remoteAsset, amount);

        _coordinatorRecvConfirmToken(hdr);
        assertEq(cet.balanceOf(bob), amount);
        assertEq(cet.balanceOf(address(l2l2Bridge)), 0);
    }

    function _pushSendTokensToInbox(address remoteAsset, uint256 amount, uint256 sessionId, address receiver) internal {
        bytes memory payload = abi.encode(REMOTE_L2_CHAIN_ID, remoteAsset, amount, "Remote", "RMT", uint8(18));
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), receiver, sessionId, "SEND_TOKENS", payload);
    }

    function _assertAckOutbox(uint256 sessionId, address remoteAsset, uint256 amount) internal view {
        bytes32 ackKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), address(l2l2Bridge), sessionId, "ACK");
        bytes memory expectedAck = abi.encode(remoteAsset, amount);
        assertEq(keccak256(mailbox.outbox(ackKey)), keccak256(expectedAck));
    }

    function test_l2l2_bridgeCETTo_burnsOnSource() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        uint256 sessionId = 0x3333;

        bytes memory packed = abi.encode("T", "T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(alice), amount);
        assertEq(cet.totalSupply(), amount);

        vm.prank(alice);
        l2l2Bridge.bridgeCETTo(REMOTE_L2_CHAIN_ID, predictedCet, amount, bob, sessionId);

        assertEq(cet.balanceOf(alice), 0);
        assertEq(cet.totalSupply(), 0);
    }

    function test_l2l2_bridgeCETTo_payloadCarriesL1Identity() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        uint256 sessionId = 0x4444;

        bytes memory packed = abi.encode("L1 Token", "L1T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        vm.prank(alice);
        l2l2Bridge.bridgeCETTo(REMOTE_L2_CHAIN_ID, predictedCet, amount, bob, sessionId);

        bytes32 outKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS");
        bytes memory expectedPayload = abi.encode(L1_CHAIN_ID, l1Token, amount, "L1 Token", "L1T", uint8(18));
        assertEq(keccak256(mailbox.outbox(outKey)), keccak256(expectedPayload));
    }

    function test_l2l2_receiveTokens_cetDepositSameAddressAcrossChains() public {
        address remoteAsset = makeAddr("crossChainAsset");
        uint256 amount = 100e18;
        uint256 sessionId = 0x5555;

        address predictedHere = cetFactory.predictAddress(remoteAsset, REMOTE_L2_CHAIN_ID);

        _pushSendTokensToInbox(remoteAsset, amount, sessionId, bob);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: REMOTE_L2_CHAIN_ID, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_TOKENS"
        });

        vm.prank(bob);
        (address deployedHere,) = l2l2Bridge.receiveTokens(hdr);
        assertEq(deployedHere, predictedHere);

        vm.chainId(99_999_999);
        address predictedElsewhere = cetFactory.predictAddress(remoteAsset, REMOTE_L2_CHAIN_ID);
        assertEq(predictedElsewhere, predictedHere);
    }

    function test_l2l2_bridgeEthTo_locksIntoEthLiquidity() public {
        uint256 amount = 1 ether;
        uint256 sessionId = 0x6666;

        uint256 aliceBefore = alice.balance;
        uint256 lqBefore = address(ethLiquidity).balance;
        uint256 bridgeBefore = address(l2l2Bridge).balance;

        vm.prank(alice);
        l2l2Bridge.bridgeEthTo{value: amount}(sessionId, REMOTE_L2_CHAIN_ID, bob);

        assertEq(alice.balance, aliceBefore - amount);
        assertEq(address(ethLiquidity).balance, lqBefore + amount);
        assertEq(address(l2l2Bridge).balance, bridgeBefore);
    }

    function test_l2l2_bridgeEthTo_writesSendEth() public {
        uint256 amount = 1 ether;
        uint256 sessionId = 0x7777;

        vm.prank(alice);
        l2l2Bridge.bridgeEthTo{value: amount}(sessionId, REMOTE_L2_CHAIN_ID, bob);

        bytes32 outKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_ETH");
        bytes memory expectedPayload = abi.encode(block.chainid, amount);
        assertEq(keccak256(mailbox.outbox(outKey)), keccak256(expectedPayload));
    }

    function test_l2l2_receiveETH_releasesFromLiquidity() public {
        uint256 amount = 1 ether;
        uint256 sessionId = 0x8888;

        bytes memory payload = abi.encode(REMOTE_L2_CHAIN_ID, amount);
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_ETH", payload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: REMOTE_L2_CHAIN_ID, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_ETH"
        });

        uint256 bobBefore = bob.balance;
        uint256 lqBefore = address(ethLiquidity).balance;
        uint256 bridgeBefore = address(l2l2Bridge).balance;

        vm.prank(bob);
        uint256 outAmount = l2l2Bridge.receiveETH(hdr);

        assertEq(outAmount, amount);
        // Pending: recv() mints into this contract's own balance; recvConfirmETH forwards it.
        assertEq(bob.balance, bobBefore);
        assertEq(address(ethLiquidity).balance, lqBefore - amount);
        assertEq(address(l2l2Bridge).balance, bridgeBefore + amount);

        _coordinatorRecvConfirmETH(hdr);
        assertEq(bob.balance, bobBefore + amount);
        assertEq(address(ethLiquidity).balance, lqBefore - amount);
        assertEq(address(l2l2Bridge).balance, bridgeBefore);
    }

    function test_redeemWrappedCET_burnsWrappedMintsCore() public {
        MockCoreCET core = new MockCoreCET(address(l2l2Bridge));

        uint256 remoteChain = 99_999;
        vm.prank(address(l2l2Bridge));
        address wrapped = cetFactory.deployIfAbsent(address(core), remoteChain, 18, "Wrapped", "wCORE");

        uint256 amount = 100e18;
        vm.prank(address(l2l2Bridge));
        ComposableERC20(wrapped).crosschainMint(alice, amount);

        assertEq(ComposableERC20(wrapped).balanceOf(alice), amount);
        assertEq(core.balanceOf(alice), 0);

        vm.prank(alice);
        l2l2Bridge.redeemWrappedCET(wrapped, address(core), amount);

        assertEq(ComposableERC20(wrapped).balanceOf(alice), 0);
        assertEq(ComposableERC20(wrapped).totalSupply(), 0);
        assertEq(core.balanceOf(alice), amount);
        assertEq(core.totalSupply(), amount);
    }

    function test_flow_l1ToL2_ethDeposit_l2ToL1_ethWithdraw() public {
        uint256 amount = 1 ether;
        uint32 minGas = 200_000;
        bytes memory extra = hex"";

        uint256 aliceStart = alice.balance;

        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeETH.selector, alice, alice, amount, extra);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), amount, depositMsg);
        assertTrue(okDep);
        assertEq(alice.balance, aliceStart + amount);

        vm.prank(alice, alice);
        l2Bridge.bridgeETH{value: amount}(minGas, extra);

        assertEq(alice.balance, aliceStart);

        bytes memory expectedWithdrawMsg = abi.encodeWithSignature("finalizeBridgeETH(address,address,uint256,bytes)", alice, alice, amount, extra);
        (address target,, uint32 sentMinGas, uint256 sentValue) = messenger.lastSent();
        assertEq(target, fakeL1Bridge);
        assertEq(sentMinGas, minGas);
        assertEq(sentValue, amount);
        assertEq(keccak256(messenger.lastMessage()), keccak256(expectedWithdrawMsg));
    }

    function test_flow_l1ToL2_erc20Deposit_l2ToL1_erc20Withdraw() public {
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        uint32 minGas = 200_000;
        bytes memory withdrawExtra = hex"beef";

        bytes memory packed = abi.encode("L1 Token", "L1T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(alice), amount);
        assertEq(cet.totalSupply(), amount);

        vm.prank(alice);
        l2Bridge.bridgeERC20To(predictedCet, l1Token, bob, amount, minGas, withdrawExtra);

        assertEq(cet.balanceOf(alice), 0);
        assertEq(cet.totalSupply(), 0);

        bytes memory expectedWithdrawMsg = abi.encodeWithSignature(
            "finalizeBridgeERC20(address,address,address,address,uint256,bytes)", l1Token, predictedCet, alice, bob, amount, withdrawExtra
        );
        (address target,, uint32 sentMinGas, uint256 sentValue) = messenger.lastSent();
        assertEq(target, fakeL1Bridge);
        assertEq(sentMinGas, minGas);
        assertEq(sentValue, 0);
        assertEq(keccak256(messenger.lastMessage()), keccak256(expectedWithdrawMsg));
    }

    function test_flow_l2l2_erc20Native_roundTripAcrossChains() public {
        uint256 chainA = _initialChainId;
        uint256 chainB = REMOTE_L2_CHAIN_ID;
        uint256 amount = 100e18;
        uint256 sessionOut = 0xA001;
        uint256 sessionBack = 0xB001;

        uint256 aliceStart = nativeToken.balanceOf(alice);

        _roundTrip_stepOut(chainA, chainB, amount, sessionOut);

        address predictedCet = cetFactory.predictAddress(address(nativeToken), chainA);

        vm.chainId(chainB);
        _roundTrip_receiveOnB(chainA, amount, sessionOut, predictedCet);

        _roundTrip_stepBack(chainA, chainB, amount, sessionBack, predictedCet);

        vm.chainId(chainA);
        _roundTrip_receiveBackOnA(chainB, amount, sessionBack);

        assertEq(nativeToken.balanceOf(alice), aliceStart);
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), 0);
        assertEq(ComposableERC20(predictedCet).totalSupply(), 0);
    }

    function _roundTrip_stepOut(uint256 chainA, uint256 chainB, uint256 amount, uint256 sessionId) internal {
        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);

        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(chainB, address(nativeToken), amount, bob, sessionId);

        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), amount);

        bytes32 outKey = mailbox.getKey(chainA, chainB, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS");
        _clearCreatedKey(outKey);
    }

    function _roundTrip_receiveOnB(uint256 chainA, uint256 amount, uint256 sessionId, address predictedCet) internal {
        bytes memory sendPayload = abi.encode(chainA, address(nativeToken), amount, nativeToken.name(), nativeToken.symbol(), nativeToken.decimals());
        _coordinatorPutInbox(chainA, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS", sendPayload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: chainA, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_TOKENS"
        });

        vm.prank(bob);
        (address outToken, uint256 outAmount) = l2l2Bridge.receiveTokens(hdr);
        assertEq(outToken, predictedCet);
        assertEq(outAmount, amount);
        assertEq(ComposableERC20(predictedCet).balanceOf(bob), 0);

        _coordinatorRecvConfirmToken(hdr);
        assertEq(ComposableERC20(predictedCet).balanceOf(bob), amount);
    }

    function _roundTrip_stepBack(uint256 chainA, uint256 chainB, uint256 amount, uint256 sessionId, address cet) internal {
        vm.prank(bob);
        l2l2Bridge.bridgeCETTo(chainA, cet, amount, alice, sessionId);

        assertEq(ComposableERC20(cet).balanceOf(bob), 0);

        bytes32 outKey = mailbox.getKey(chainB, chainA, address(l2l2Bridge), alice, sessionId, "SEND_TOKENS");
        _clearCreatedKey(outKey);
    }

    function _clearCreatedKey(bytes32 key) internal {
        bytes32 slot = keccak256(abi.encode(key, uint256(7)));
        vm.store(address(mailbox), slot, bytes32(0));
    }

    function _roundTrip_receiveBackOnA(uint256 chainB, uint256 amount, uint256 sessionId) internal {
        bytes memory sendPayload = abi.encode(block.chainid, address(nativeToken), amount, nativeToken.name(), nativeToken.symbol(), nativeToken.decimals());
        _coordinatorPutInbox(chainB, address(l2l2Bridge), alice, sessionId, "SEND_TOKENS", sendPayload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: chainB, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: alice, sessionId: sessionId, label: "SEND_TOKENS"
        });

        vm.prank(alice);
        l2l2Bridge.receiveTokens(hdr);

        _coordinatorRecvConfirmToken(hdr);
    }

    function test_flow_cetDepositedFromL1_canBeBridgedL2L2() public {
        uint256 chainA = block.chainid;
        uint256 chainB = REMOTE_L2_CHAIN_ID;
        address l1Token = makeAddr("fakeL1Token");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 100e18;
        uint256 sessionId = 0xCE711;

        _depositL1ToL2(l1Token, predictedCet, amount);

        assertEq(ComposableERC20(predictedCet).balanceOf(alice), amount);
        assertEq(ComposableERC20(predictedCet).totalSupply(), amount);

        _l2l2_bridgeCET_to_B(chainA, chainB, amount, sessionId, predictedCet, l1Token);

        vm.chainId(chainB);
        _l2l2_receiveCET_on_B(chainA, amount, sessionId, predictedCet, l1Token);
    }

    function _depositL1ToL2(address l1Token, address predictedCet, uint256 amount) internal {
        bytes memory packed = abi.encode("L1 Token", "L1T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);
    }

    function _l2l2_bridgeCET_to_B(uint256 chainA, uint256 chainB, uint256 amount, uint256 sessionId, address cet, address l1Token) internal {
        vm.prank(alice);
        l2l2Bridge.bridgeCETTo(chainB, cet, amount, bob, sessionId);

        assertEq(ComposableERC20(cet).balanceOf(alice), 0);
        assertEq(ComposableERC20(cet).totalSupply(), 0);

        bytes32 outKey = mailbox.getKey(chainA, chainB, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS");
        _clearCreatedKey(outKey);
    }

    function _l2l2_receiveCET_on_B(uint256 chainA, uint256 amount, uint256 sessionId, address predictedCet, address l1Token) internal {
        bytes memory sendPayload = abi.encode(L1_CHAIN_ID, l1Token, amount, "L1 Token", "L1T", uint8(18));
        _coordinatorPutInbox(chainA, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS", sendPayload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: chainA, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: bob, sessionId: sessionId, label: "SEND_TOKENS"
        });

        vm.prank(bob);
        (address outToken, uint256 outAmount) = l2l2Bridge.receiveTokens(hdr);

        assertEq(outToken, predictedCet);
        assertEq(outAmount, amount);
        assertEq(ComposableERC20(predictedCet).balanceOf(bob), 0);
        assertEq(ComposableERC20(predictedCet).totalSupply(), amount);

        _coordinatorRecvConfirmToken(hdr);
        assertEq(ComposableERC20(predictedCet).balanceOf(bob), amount);
        assertEq(ComposableERC20(predictedCet).totalSupply(), amount);
    }

    function test_eth_l1ToL2_finalize_emitsFinalizedEvents() public {
        uint256 amount = 1 ether;
        bytes memory extra = hex"dead";

        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeETH.selector, alice, bob, amount, extra);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit DepositFinalized(address(0), address(0), alice, bob, amount, extra);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit ETHBridgeFinalized(alice, bob, amount, extra);

        (bool ok,) = _relayFromL1Bridge(address(l2Bridge), amount, message);
        assertTrue(ok);
    }

    function test_eth_l1ToL2_finalize_forwardsToRecipient() public {
        uint256 amount = 1 ether;
        bytes memory extra = hex"dead";

        bytes memory message = abi.encodeWithSelector(l2Bridge.finalizeBridgeETH.selector, alice, bob, amount, extra);

        uint256 bobBefore = bob.balance;

        (bool ok,) = _relayFromL1Bridge(address(l2Bridge), amount, message);
        assertTrue(ok);

        assertEq(bob.balance, bobBefore + amount);
    }
}
