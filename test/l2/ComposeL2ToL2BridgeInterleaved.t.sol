// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

import {ComposeL2IntegrationSetup} from "test/l2/setup/ComposeL2IntegrationSetup.sol";
import {ComposableERC20} from "src/l2/ComposableERC20.sol";
import {IUniversalBridgeMailbox} from "src/l2/interfaces/IUniversalBridgeMailbox.sol";
import {IComposeL2ToL2Bridge} from "src/l2/interfaces/IComposeL2ToL2Bridge.sol";

/// @title ComposeL2ToL2BridgeInterleaved
/// @notice Covers the interleaved (Saga-pattern) send/sendConfirm/sendAbort and
///         recv/recvConfirm/recvAbort state machine on ComposeL2ToL2Bridge, mirroring
///         ../contracts/L2/test/InterleavedBridge.t.sol's structure: happy-path confirm, happy-path
///         abort (compensation), access control, and an interleaved multi-session scenario proving
///         steps from independent sessions can be executed out of order.
contract ComposeL2ToL2BridgeInterleaved is ComposeL2IntegrationSetup {
    function _sendTokensHeader(uint256 chainDest, address receiver, uint256 sessionId) internal view returns (IUniversalBridgeMailbox.MessageHeader memory) {
        return IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(l2l2Bridge), receiver: receiver, sessionId: sessionId, label: "SEND_TOKENS"
        });
    }

    function _sendEthHeader(uint256 chainDest, address receiver, uint256 sessionId) internal view returns (IUniversalBridgeMailbox.MessageHeader memory) {
        return IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(l2l2Bridge), receiver: receiver, sessionId: sessionId, label: "SEND_ETH"
        });
    }

    function _recvHeader(uint256 chainSrc, address receiver, uint256 sessionId, string memory label)
        internal
        view
        returns (IUniversalBridgeMailbox.MessageHeader memory)
    {
        return IUniversalBridgeMailbox.MessageHeader({
            chainSrc: chainSrc, chainDest: block.chainid, sender: address(l2l2Bridge), receiver: receiver, sessionId: sessionId, label: label
        });
    }

    // ============================================================
    // send -> sendConfirm
    // ============================================================

    function test_sendConfirm_erc20_finalizesRootsWithoutBalanceChange() public {
        uint256 amount = 50e18;
        uint256 sessionId = 0x1001;

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);
        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), amount, bob, sessionId);

        uint256 bridgeBalanceAfterSend = nativeToken.balanceOf(address(l2l2Bridge));

        _coordinatorRelayAck(REMOTE_L2_CHAIN_ID, sessionId, abi.encode(address(nativeToken), amount));

        vm.expectEmit(true, true, true, true, address(l2l2Bridge));
        emit IComposeL2ToL2Bridge.SendConfirmed(REMOTE_L2_CHAIN_ID, bob, sessionId, "SEND_TOKENS");

        _coordinatorSendConfirm(_sendTokensHeader(REMOTE_L2_CHAIN_ID, bob, sessionId));

        // No balance change on confirm: funds were already locked at send time.
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), bridgeBalanceAfterSend);
        assertTrue(mailbox.outboxRootPerChain(REMOTE_L2_CHAIN_ID) != bytes32(0));
        assertTrue(mailbox.inboxRootPerChain(REMOTE_L2_CHAIN_ID) != bytes32(0));
    }

    function test_sendConfirm_revertsWithoutRelayedAck() public {
        uint256 amount = 10e18;
        uint256 sessionId = 0x1002;

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);
        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), amount, bob, sessionId);

        vm.prank(coordinator);
        vm.expectRevert(IUniversalBridgeMailbox.MessageNotFound.selector);
        l2l2Bridge.sendConfirm(_sendTokensHeader(REMOTE_L2_CHAIN_ID, bob, sessionId));
    }

    function test_sendConfirm_revertsOnDoubleConfirm() public {
        uint256 amount = 10e18;
        uint256 sessionId = 0x1003;

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);
        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), amount, bob, sessionId);

        _coordinatorRelayAck(REMOTE_L2_CHAIN_ID, sessionId, abi.encode(address(nativeToken), amount));

        IUniversalBridgeMailbox.MessageHeader memory sendHeader = _sendTokensHeader(REMOTE_L2_CHAIN_ID, bob, sessionId);
        _coordinatorSendConfirm(sendHeader);

        vm.prank(coordinator);
        vm.expectRevert(IUniversalBridgeMailbox.MessageAlreadyConsumed.selector);
        l2l2Bridge.sendConfirm(sendHeader);
    }

    function test_sendConfirm_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.sendConfirm(_sendTokensHeader(REMOTE_L2_CHAIN_ID, bob, 0x1));
    }

    // ============================================================
    // send -> sendAbort (compensation)
    // ============================================================

    function test_sendAbortToken_erc20_returnsEscrowToSender() public {
        uint256 amount = 25e18;
        uint256 sessionId = 0x2001;
        uint256 aliceBefore = nativeToken.balanceOf(alice);

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), amount);
        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), amount, bob, sessionId);

        assertEq(nativeToken.balanceOf(alice), aliceBefore - amount);

        bytes32 outKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS");
        assertTrue(mailbox.createdKeys(outKey));

        vm.expectEmit(true, true, true, true, address(l2l2Bridge));
        emit IComposeL2ToL2Bridge.SendAborted(REMOTE_L2_CHAIN_ID, alice, sessionId, "SEND_TOKENS");

        _coordinatorSendAbortToken(REMOTE_L2_CHAIN_ID, address(nativeToken), alice, bob, amount, sessionId);

        assertEq(nativeToken.balanceOf(alice), aliceBefore);
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), 0);
        assertFalse(mailbox.createdKeys(outKey));
    }

    function test_sendAbortToken_cet_reMintsToSender() public {
        address l1Token = makeAddr("fakeL1TokenAbort");
        address predictedCet = cetFactory.predictAddress(l1Token, L1_CHAIN_ID);
        uint256 amount = 40e18;
        uint256 sessionId = 0x2002;

        bytes memory packed = abi.encode("T", "T", uint8(18), bytes(""));
        bytes memory depositMsg = abi.encodeWithSelector(l2Bridge.finalizeBridgeERC20.selector, predictedCet, l1Token, alice, alice, amount, packed);
        (bool okDep,) = _relayFromL1Bridge(address(l2Bridge), 0, depositMsg);
        assertTrue(okDep);

        vm.prank(alice);
        l2l2Bridge.bridgeCETTo(REMOTE_L2_CHAIN_ID, predictedCet, amount, bob, sessionId);

        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(alice), 0);
        assertEq(cet.totalSupply(), 0);

        _coordinatorSendAbortToken(REMOTE_L2_CHAIN_ID, predictedCet, alice, bob, amount, sessionId);

        assertEq(cet.balanceOf(alice), amount);
        assertEq(cet.totalSupply(), amount);
    }

    function test_sendAbortETH_returnsLiquidityToSender() public {
        uint256 amount = 2 ether;
        uint256 sessionId = 0x2003;
        uint256 aliceBefore = alice.balance;
        uint256 lqBefore = address(ethLiquidity).balance;

        vm.prank(alice);
        l2l2Bridge.bridgeEthTo{value: amount}(sessionId, REMOTE_L2_CHAIN_ID, bob);

        assertEq(alice.balance, aliceBefore - amount);
        assertEq(address(ethLiquidity).balance, lqBefore + amount);

        _coordinatorSendAbortETH(REMOTE_L2_CHAIN_ID, alice, bob, amount, sessionId);

        assertEq(alice.balance, aliceBefore);
        assertEq(address(ethLiquidity).balance, lqBefore);
        assertEq(address(l2l2Bridge).balance, 0);
    }

    function test_sendAbortToken_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.sendAbortToken(REMOTE_L2_CHAIN_ID, address(nativeToken), alice, bob, 1e18, 0x2);
    }

    function test_sendAbortETH_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.sendAbortETH(REMOTE_L2_CHAIN_ID, alice, bob, 1 ether, 0x3);
    }

    // ============================================================
    // recv -> recvConfirm / recvAbort
    // ============================================================

    function test_recvConfirmToken_revertsWithoutPriorRecv() public {
        vm.prank(coordinator);
        vm.expectRevert(IUniversalBridgeMailbox.MessageNotConsumed.selector);
        l2l2Bridge.recvConfirmToken(_recvHeader(REMOTE_L2_CHAIN_ID, bob, 0x3001, "SEND_TOKENS"));
    }

    function test_recvAbortToken_cet_burnsPendingMint() public {
        address remoteAsset = makeAddr("remoteAssetAbort");
        uint256 amount = 60e18;
        uint256 sessionId = 0x3002;

        bytes memory payload = abi.encode(REMOTE_L2_CHAIN_ID, remoteAsset, amount, "Remote", "RMT", uint8(18));
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS", payload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = _recvHeader(REMOTE_L2_CHAIN_ID, bob, sessionId, "SEND_TOKENS");

        vm.prank(bob);
        l2l2Bridge.receiveTokens(hdr);

        address predictedCet = cetFactory.predictAddress(remoteAsset, REMOTE_L2_CHAIN_ID);
        ComposableERC20 cet = ComposableERC20(predictedCet);
        assertEq(cet.balanceOf(address(l2l2Bridge)), amount);

        bytes32 ackKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), address(l2l2Bridge), sessionId, "ACK");
        assertTrue(mailbox.createdKeys(ackKey));

        vm.expectEmit(true, true, true, true, address(l2l2Bridge));
        emit IComposeL2ToL2Bridge.RecvAborted(REMOTE_L2_CHAIN_ID, bob, sessionId, "SEND_TOKENS");

        vm.prank(coordinator);
        l2l2Bridge.recvAbortToken(hdr);

        assertEq(cet.balanceOf(address(l2l2Bridge)), 0);
        assertEq(cet.totalSupply(), 0);
        assertEq(cet.balanceOf(bob), 0);
        assertFalse(mailbox.createdKeys(ackKey));
    }

    function test_recvAbortToken_escrow_leavesFundsHeldNoOp() public {
        uint256 amount = 15e18;
        uint256 sessionId = 0x3003;

        nativeToken.mint(address(l2l2Bridge), amount);
        uint256 bridgeBefore = nativeToken.balanceOf(address(l2l2Bridge));
        uint256 bobBefore = nativeToken.balanceOf(bob);

        bytes memory payload = abi.encode(block.chainid, address(nativeToken), amount, nativeToken.name(), nativeToken.symbol(), nativeToken.decimals());
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_TOKENS", payload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = _recvHeader(REMOTE_L2_CHAIN_ID, bob, sessionId, "SEND_TOKENS");

        vm.prank(bob);
        l2l2Bridge.receiveTokens(hdr);

        vm.prank(coordinator);
        l2l2Bridge.recvAbortToken(hdr);

        // Escrowed native tokens were never moved on recv, so abort is a no-op on balances.
        assertEq(nativeToken.balanceOf(address(l2l2Bridge)), bridgeBefore);
        assertEq(nativeToken.balanceOf(bob), bobBefore);
    }

    function test_recvAbortETH_returnsPendingMintToLiquidity() public {
        uint256 amount = 3 ether;
        uint256 sessionId = 0x3004;
        uint256 lqBefore = address(ethLiquidity).balance;
        uint256 bridgeBefore = address(l2l2Bridge).balance;

        bytes memory payload = abi.encode(REMOTE_L2_CHAIN_ID, amount);
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionId, "SEND_ETH", payload);

        IUniversalBridgeMailbox.MessageHeader memory hdr = _recvHeader(REMOTE_L2_CHAIN_ID, bob, sessionId, "SEND_ETH");

        vm.prank(bob);
        l2l2Bridge.receiveETH(hdr);

        assertEq(address(ethLiquidity).balance, lqBefore - amount);
        assertEq(address(l2l2Bridge).balance, bridgeBefore + amount);

        vm.prank(coordinator);
        l2l2Bridge.recvAbortETH(hdr);

        assertEq(address(ethLiquidity).balance, lqBefore);
        assertEq(address(l2l2Bridge).balance, bridgeBefore);
    }

    function test_recvConfirmToken_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.recvConfirmToken(_recvHeader(REMOTE_L2_CHAIN_ID, bob, 0x4, "SEND_TOKENS"));
    }

    function test_recvAbortToken_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.recvAbortToken(_recvHeader(REMOTE_L2_CHAIN_ID, bob, 0x5, "SEND_TOKENS"));
    }

    function test_recvConfirmETH_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.recvConfirmETH(_recvHeader(REMOTE_L2_CHAIN_ID, bob, 0x6, "SEND_ETH"));
    }

    function test_recvAbortETH_revertsForNonCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(IComposeL2ToL2Bridge.InvalidCoordinator.selector);
        l2l2Bridge.recvAbortETH(_recvHeader(REMOTE_L2_CHAIN_ID, bob, 0x7, "SEND_ETH"));
    }

    // ============================================================
    // Interleaving: independent sessions progress out of order
    // ============================================================

    /// @dev Two independent send sessions (an ERC20 send and an ETH send, to the same remote
    ///      chain) are confirmed out of the order they were initiated in, demonstrating that
    ///      neither step of one session depends on the other session's steps completing first
    ///      (non-serial execution / Serializability property).
    function test_interleaved_twoSessionsConfirmOutOfOrder() public {
        uint256 erc20Amount = 12e18;
        uint256 erc20Session = 0x5001;
        uint256 ethAmount = 1 ether;
        uint256 ethSession = 0x5002;

        vm.prank(alice);
        nativeToken.approve(address(l2l2Bridge), erc20Amount);
        vm.prank(alice);
        l2l2Bridge.bridgeERC20To(REMOTE_L2_CHAIN_ID, address(nativeToken), erc20Amount, bob, erc20Session);

        vm.prank(alice);
        l2l2Bridge.bridgeEthTo{value: ethAmount}(ethSession, REMOTE_L2_CHAIN_ID, bob);

        // Confirm the *second* session (ETH) before the first (ERC20) — out of initiation order.
        _coordinatorRelayAck(REMOTE_L2_CHAIN_ID, ethSession, abi.encode(address(0), ethAmount));
        _coordinatorSendConfirm(_sendEthHeader(REMOTE_L2_CHAIN_ID, bob, ethSession));

        // The ERC20 session is untouched by the ETH session's confirm.
        bytes32 erc20OutKey = mailbox.getKey(block.chainid, REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, erc20Session, "SEND_TOKENS");
        assertTrue(mailbox.createdKeys(erc20OutKey));

        _coordinatorRelayAck(REMOTE_L2_CHAIN_ID, erc20Session, abi.encode(address(nativeToken), erc20Amount));
        _coordinatorSendConfirm(_sendTokensHeader(REMOTE_L2_CHAIN_ID, bob, erc20Session));

        // Both sessions' outbox roots ended up finalized independently of execution order.
        assertTrue(mailbox.outboxRootPerChain(REMOTE_L2_CHAIN_ID) != bytes32(0));
    }

    /// @dev Two independent recv sessions on unrelated remote assets: one is confirmed (delivered)
    ///      while the other is aborted (compensated), each unaffected by the other's outcome.
    function test_interleaved_recvSessionsConfirmAndAbortIndependently() public {
        address remoteAssetConfirmed = makeAddr("remoteAssetConfirmed");
        address remoteAssetAborted = makeAddr("remoteAssetAborted");
        uint256 amount = 20e18;
        uint256 sessionConfirmed = 0x6001;
        uint256 sessionAborted = 0x6002;

        bytes memory payloadConfirmed = abi.encode(REMOTE_L2_CHAIN_ID, remoteAssetConfirmed, amount, "A", "A", uint8(18));
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionConfirmed, "SEND_TOKENS", payloadConfirmed);
        IUniversalBridgeMailbox.MessageHeader memory hdrConfirmed = _recvHeader(REMOTE_L2_CHAIN_ID, bob, sessionConfirmed, "SEND_TOKENS");
        vm.prank(bob);
        l2l2Bridge.receiveTokens(hdrConfirmed);

        bytes memory payloadAborted = abi.encode(REMOTE_L2_CHAIN_ID, remoteAssetAborted, amount, "B", "B", uint8(18));
        _coordinatorPutInbox(REMOTE_L2_CHAIN_ID, address(l2l2Bridge), bob, sessionAborted, "SEND_TOKENS", payloadAborted);
        IUniversalBridgeMailbox.MessageHeader memory hdrAborted = _recvHeader(REMOTE_L2_CHAIN_ID, bob, sessionAborted, "SEND_TOKENS");
        vm.prank(bob);
        l2l2Bridge.receiveTokens(hdrAborted);

        // Abort the second session first.
        vm.prank(coordinator);
        l2l2Bridge.recvAbortToken(hdrAborted);

        address cetAborted = cetFactory.predictAddress(remoteAssetAborted, REMOTE_L2_CHAIN_ID);
        assertEq(ComposableERC20(cetAborted).totalSupply(), 0);

        // Confirming the unrelated first session still works, independent of the abort above.
        vm.prank(coordinator);
        (address token, uint256 delivered) = l2l2Bridge.recvConfirmToken(hdrConfirmed);

        address cetConfirmed = cetFactory.predictAddress(remoteAssetConfirmed, REMOTE_L2_CHAIN_ID);
        assertEq(token, cetConfirmed);
        assertEq(delivered, amount);
        assertEq(ComposableERC20(cetConfirmed).balanceOf(bob), amount);
    }
}
