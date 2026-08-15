// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

import {IComposeL2ToL2Bridge} from "./interfaces/IComposeL2ToL2Bridge.sol";
import {ICETFactory} from "src/l2/interfaces/ICETFactory.sol";
import {IComposableERC20} from "src/l2/interfaces/IComposableERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IETHLiquidity} from "src/l2/interfaces/external/IETHLiquidity.sol";
import {IUniversalBridgeMailbox} from "src/l2/interfaces/IUniversalBridgeMailbox.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ComposeL2ToL2Bridge
/// @notice L2<->L2 leg of the Compose bridge, built as an interleaved (Saga-pattern) bridge:
///         every bridging action is provisional until the coordinator observes agreement between
///         chains and calls the matching confirm, or compensates it via abort. This lets many
///         bridging processes between different chain pairs run interleaved instead of serially,
///         since nothing is permanent (mailbox roots, final balances) until confirmed. See
///         INTERLEAVED_BRIDGE.md in the sibling `contracts` repo for the pattern this mirrors.
///
///         Send leg:  bridgeERC20To/bridgeCETTo/bridgeEthTo lock/burn funds and write a
///                    provisional SEND message. sendConfirm finalizes bookkeeping once the ACK
///                    from the destination chain has been relayed back; sendAbortToken/ETH
///                    return the locked/burned funds to the sender and remove the SEND message.
///         Recv leg:  receiveTokens/receiveETH read a relayed SEND message, hold funds pending
///                    in this contract (mint-to-self / already-escrowed), and write a provisional
///                    ACK message. recvConfirmToken/ETH deliver the held funds to the receiver;
///                    recvAbortToken/ETH reverse the pending hold.
contract ComposeL2ToL2Bridge is IComposeL2ToL2Bridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniversalBridgeMailbox public immutable mailbox;
    ICETFactory public immutable cetFactory;
    IETHLiquidity public immutable ethLiquidity;

    /// @notice Trusted coordinator authorized to confirm/abort provisional bridging actions.
    address public immutable COORDINATOR;

    modifier onlyCoordinator() {
        if (msg.sender != COORDINATOR) revert InvalidCoordinator();
        _;
    }

    constructor(address _mailbox, address _cetFactory, address _ethLiquidity, address _coordinator) {
        mailbox = IUniversalBridgeMailbox(_mailbox);
        cetFactory = ICETFactory(_cetFactory);
        ethLiquidity = IETHLiquidity(_ethLiquidity);
        COORDINATOR = _coordinator;
    }

    receive() external payable {}

    function computeCETAddress(address remoteAsset, uint256 remoteChainID) internal view returns (address) {
        return cetFactory.predictAddress(remoteAsset, remoteChainID);
    }

    function _isComposableERC20(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        try IERC165(token).supportsInterface(type(IComposableERC20).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function isCoreComposeable(address token) internal view returns (bool) {
        try IComposableERC20(token).cetType() returns (IComposableERC20.CetType t) {
            return t == IComposableERC20.CetType.CORE;
        } catch {
            return false;
        }
    }

    function ensureCETAndMint(address remoteAsset, uint256 remoteChainID, string memory name, string memory symbol, uint8 decimals, address to, uint256 amount)
        internal
        returns (address cet)
    {
        if (remoteAsset.code.length > 0 && isCoreComposeable(remoteAsset)) {
            IComposableERC20(remoteAsset).crosschainMint(to, amount);
            return remoteAsset;
        }

        address predicted = computeCETAddress(remoteAsset, remoteChainID);

        cet = cetFactory.deployIfAbsent(remoteAsset, remoteChainID, decimals, name, symbol);

        if (cet != predicted) revert InvalidCetAddress();

        IComposableERC20(cet).crosschainMint(to, amount);
        return cet;
    }

    // ============================================================
    // Send leg
    // ============================================================

    function bridgeERC20To(uint256 chainDest, address tokenSrc, uint256 amount, address receiver, uint256 sessionId) external nonReentrant {
        if (_isComposableERC20(tokenSrc)) revert UseBridgeCETTo();
        address sender = msg.sender;

        IERC20(tokenSrc).safeTransferFrom(sender, address(this), amount);
        emit TokensLocked(tokenSrc, sender, amount);

        string memory name = IERC20Metadata(tokenSrc).name();
        string memory symbol = IERC20Metadata(tokenSrc).symbol();
        uint8 decimals = IERC20Metadata(tokenSrc).decimals();
        bytes memory payload = abi.encode(block.chainid, tokenSrc, amount, name, symbol, decimals);

        IUniversalBridgeMailbox.MessageHeader memory sendHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(this), receiver: receiver, sessionId: sessionId, label: "SEND_TOKENS"
        });
        mailbox.writeMessage(IUniversalBridgeMailbox.Message({header: sendHeader, payload: payload}));
        emit MailboxWrite(chainDest, receiver, sessionId, "SEND_TOKENS");

        bytes32 messageId = keccak256(abi.encodePacked(chainDest, receiver, sessionId, "SEND_TOKENS"));
        emit TokensSendQueued(chainDest, sender, receiver, tokenSrc, amount, sessionId, messageId);
    }

    function bridgeCETTo(uint256 chainDest, address cetTokenSrc, uint256 amount, address receiver, uint256 sessionId) external nonReentrant {
        address remoteAsset = IComposableERC20(cetTokenSrc).remoteAsset();

        IComposableERC20(cetTokenSrc).crosschainBurn(msg.sender, amount);
        emit CETBurned(cetTokenSrc, msg.sender, amount);

        {
            uint256 remoteChainID = IComposableERC20(cetTokenSrc).remoteChainID();
            bytes memory payload = abi.encode(
                remoteChainID,
                remoteAsset,
                amount,
                IERC20Metadata(cetTokenSrc).name(),
                IERC20Metadata(cetTokenSrc).symbol(),
                IERC20Metadata(cetTokenSrc).decimals()
            );

            IUniversalBridgeMailbox.MessageHeader memory sendHeader = IUniversalBridgeMailbox.MessageHeader({
                chainSrc: block.chainid, chainDest: chainDest, sender: address(this), receiver: receiver, sessionId: sessionId, label: "SEND_TOKENS"
            });
            mailbox.writeMessage(IUniversalBridgeMailbox.Message({header: sendHeader, payload: payload}));
        }

        emit MailboxWrite(chainDest, receiver, sessionId, "SEND_TOKENS");

        bytes32 messageId = keccak256(abi.encodePacked(chainDest, receiver, sessionId, "SEND_TOKENS"));
        emit TokensSendQueued(chainDest, msg.sender, receiver, remoteAsset, amount, sessionId, messageId);
    }

    function bridgeEthTo(uint256 sessionId, uint256 chainDest, address receiver) external payable nonReentrant {
        if (msg.value == 0) revert NoETHSent();

        ethLiquidity.burn{value: msg.value}();
        emit ETHLocked(msg.sender, msg.value);

        bytes memory payload = abi.encode(block.chainid, msg.value);

        IUniversalBridgeMailbox.MessageHeader memory sendHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(this), receiver: receiver, sessionId: sessionId, label: "SEND_ETH"
        });
        mailbox.writeMessage(IUniversalBridgeMailbox.Message({header: sendHeader, payload: payload}));
        emit MailboxWrite(chainDest, receiver, sessionId, "SEND_ETH");

        bytes32 messageId = keccak256(abi.encodePacked(chainDest, receiver, sessionId, "SEND_ETH"));
        emit ETHBridged(chainDest, msg.sender, receiver, msg.value, sessionId, messageId);
    }

    /// @notice Finalizes a send once its ACK has been relayed back into the local inbox. Consumes
    ///         the ACK, and finalizes both the original SEND outbox root and the ACK inbox root.
    ///         No balance change: funds were already locked/burned at send time.
    /// @param sendHeader The exact header used when the original SEND message was written.
    function sendConfirm(IUniversalBridgeMailbox.MessageHeader calldata sendHeader) external onlyCoordinator {
        // ACK messages are always keyed bridge-to-bridge: `writeMessage`/`putInbox` key on the
        // calling/relayed bridge address, not the end user, since the l2l2 bridge is deployed at
        // the same address on every chain (CREATE2). This must match what the coordinator relays
        // via `mailbox.putInbox(sendHeader.chainDest, address(this), address(this), ...)`.
        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: sendHeader.chainDest,
            chainDest: block.chainid,
            sender: address(this),
            receiver: address(this),
            sessionId: sendHeader.sessionId,
            label: "ACK"
        });

        bytes memory ackPayload = mailbox.readMessage(ackHeader);
        if (ackPayload.length == 0) revert NoAckMessage();

        mailbox.markConsumed(ackHeader);
        mailbox.updateInboxRoot(ackHeader);
        mailbox.updateOutboxRoot(sendHeader);

        emit SendConfirmed(sendHeader.chainDest, sendHeader.receiver, sendHeader.sessionId, sendHeader.label);
    }

    /// @notice Compensates a rejected ERC20/CET send: removes the provisional SEND message and
    ///         returns the locked/burned amount to `sender`. Distinguishes escrow vs CET by
    ///         inspecting `token`.
    function sendAbortToken(uint256 chainDest, address token, address sender, address receiver, uint256 amount, uint256 sessionId) external onlyCoordinator {
        bool isCET = _isComposableERC20(token);
        bytes memory payload;
        if (isCET) {
            payload = abi.encode(
                IComposableERC20(token).remoteChainID(),
                IComposableERC20(token).remoteAsset(),
                amount,
                IERC20Metadata(token).name(),
                IERC20Metadata(token).symbol(),
                IERC20Metadata(token).decimals()
            );
        } else {
            payload = abi.encode(block.chainid, token, amount, IERC20Metadata(token).name(), IERC20Metadata(token).symbol(), IERC20Metadata(token).decimals());
        }

        IUniversalBridgeMailbox.MessageHeader memory sendHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(this), receiver: receiver, sessionId: sessionId, label: "SEND_TOKENS"
        });
        mailbox.unwrite(IUniversalBridgeMailbox.Message({header: sendHeader, payload: payload}));

        if (isCET) {
            IComposableERC20(token).crosschainMint(sender, amount);
        } else {
            IERC20(token).safeTransfer(sender, amount);
        }

        emit SendAborted(chainDest, sender, sessionId, "SEND_TOKENS");
    }

    /// @notice Compensates a rejected ETH send: removes the provisional SEND message and returns
    ///         the locked amount to `sender` from the ETH liquidity pool.
    function sendAbortETH(uint256 chainDest, address sender, address receiver, uint256 amount, uint256 sessionId) external onlyCoordinator {
        bytes memory payload = abi.encode(block.chainid, amount);

        IUniversalBridgeMailbox.MessageHeader memory sendHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: block.chainid, chainDest: chainDest, sender: address(this), receiver: receiver, sessionId: sessionId, label: "SEND_ETH"
        });
        mailbox.unwrite(IUniversalBridgeMailbox.Message({header: sendHeader, payload: payload}));

        ethLiquidity.mint(amount);
        (bool ok,) = sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit SendAborted(chainDest, sender, sessionId, "SEND_ETH");
    }

    // ============================================================
    // Recv leg
    // ============================================================

    /// @notice Reads a relayed SEND_TOKENS message and holds the funds pending in this contract
    ///         (mints CET to self, or relies on funds already escrowed here for native tokens).
    ///         Writes a provisional ACK. Actual delivery to `receiver` happens in recvConfirmToken.
    function receiveTokens(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external nonReentrant returns (address token, uint256 amount) {
        if (msg.sender != msgHeader.receiver) revert NotReceiver();
        if (msgHeader.chainDest != block.chainid) revert WrongDestinationChain();
        if (keccak256(bytes(msgHeader.label)) != keccak256("SEND_TOKENS")) revert InvalidMessage();

        bytes memory m = mailbox.readMessage(msgHeader);
        if (m.length == 0) revert NoSendMessage();
        mailbox.markConsumed(msgHeader);

        uint256 remoteChainID;
        address remoteAsset;
        string memory name;
        string memory symbol;
        uint8 decimals;
        (remoteChainID, remoteAsset, amount, name, symbol, decimals) = abi.decode(m, (uint256, address, uint256, string, string, uint8));

        if (remoteChainID == block.chainid) {
            if (IERC20(remoteAsset).balanceOf(address(this)) < amount) revert InsufficientEscrowBalance();
            token = remoteAsset;
        } else {
            token = ensureCETAndMint(remoteAsset, remoteChainID, name, symbol, decimals, address(this), amount);
        }

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.writeMessage(IUniversalBridgeMailbox.Message({header: ackHeader, payload: abi.encode(remoteAsset, amount)}));
        emit MailboxAckWrite(msgHeader.chainSrc, msgHeader.sender, msgHeader.sessionId, "ACK");
        emit TokensReceived(token, amount);
    }

    /// @notice Reads a relayed SEND_ETH message and mints the amount into this contract's own
    ///         balance (pending). Writes a provisional ACK. Actual delivery to `receiver` happens
    ///         in recvConfirmETH.
    function receiveETH(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external nonReentrant returns (uint256 amount) {
        if (msg.sender != msgHeader.receiver) revert NotReceiver();
        if (msgHeader.chainDest != block.chainid) revert WrongDestinationChain();
        if (keccak256(bytes(msgHeader.label)) != keccak256("SEND_ETH")) revert InvalidMessage();

        bytes memory m = mailbox.readMessage(msgHeader);
        if (m.length == 0) revert NoSendMessage();
        mailbox.markConsumed(msgHeader);

        uint256 remoteChainID;
        (remoteChainID, amount) = abi.decode(m, (uint256, uint256));

        ethLiquidity.mint(amount);

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.writeMessage(IUniversalBridgeMailbox.Message({header: ackHeader, payload: abi.encode(address(0), amount)}));
        emit MailboxAckWrite(msgHeader.chainSrc, msgHeader.sender, msgHeader.sessionId, "ACK");
        emit ETHReceived(msgHeader.receiver, amount);
    }

    /// @notice Delivers the pending funds held by a confirmed recv to `msgHeader.receiver`, and
    ///         finalizes both the SEND inbox root and the ACK outbox root. Works uniformly for
    ///         escrowed native tokens and minted CETs, since both sit in this contract's ERC20
    ///         balance while pending.
    function recvConfirmToken(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external onlyCoordinator returns (address token, uint256 amount) {
        if (!mailbox.isConsumed(msgHeader)) revert IUniversalBridgeMailbox.MessageNotConsumed();

        bytes memory m = mailbox.readMessage(msgHeader);
        uint256 remoteChainID;
        address remoteAsset;
        (remoteChainID, remoteAsset, amount,,,) = abi.decode(m, (uint256, address, uint256, string, string, uint8));

        token = remoteChainID == block.chainid ? remoteAsset : computeCETAddress(remoteAsset, remoteChainID);
        IERC20(token).safeTransfer(msgHeader.receiver, amount);

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.updateInboxRoot(msgHeader);
        mailbox.updateOutboxRoot(ackHeader);

        emit RecvConfirmed(msgHeader.chainSrc, msgHeader.receiver, msgHeader.sessionId, msgHeader.label);
    }

    /// @notice Compensates a rejected token recv: burns back a pending CET mint (no-op for
    ///         already-escrowed native tokens, which simply remain held), and removes the
    ///         provisional ACK message.
    function recvAbortToken(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external onlyCoordinator {
        if (!mailbox.isConsumed(msgHeader)) revert IUniversalBridgeMailbox.MessageNotConsumed();

        bytes memory m = mailbox.readMessage(msgHeader);
        uint256 remoteChainID;
        address remoteAsset;
        uint256 amount;
        (remoteChainID, remoteAsset, amount,,,) = abi.decode(m, (uint256, address, uint256, string, string, uint8));

        if (remoteChainID != block.chainid) {
            address token = computeCETAddress(remoteAsset, remoteChainID);
            IComposableERC20(token).crosschainBurn(address(this), amount);
        }

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.unwrite(IUniversalBridgeMailbox.Message({header: ackHeader, payload: abi.encode(remoteAsset, amount)}));

        emit RecvAborted(msgHeader.chainSrc, msgHeader.receiver, msgHeader.sessionId, msgHeader.label);
    }

    /// @notice Delivers pending ETH held by a confirmed recv to `msgHeader.receiver`, and
    ///         finalizes both the SEND inbox root and the ACK outbox root.
    function recvConfirmETH(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external onlyCoordinator returns (uint256 amount) {
        if (!mailbox.isConsumed(msgHeader)) revert IUniversalBridgeMailbox.MessageNotConsumed();

        bytes memory m = mailbox.readMessage(msgHeader);
        (, amount) = abi.decode(m, (uint256, uint256));

        (bool ok,) = msgHeader.receiver.call{value: amount}("");
        if (!ok) revert TransferFailed();

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.updateInboxRoot(msgHeader);
        mailbox.updateOutboxRoot(ackHeader);

        emit RecvConfirmed(msgHeader.chainSrc, msgHeader.receiver, msgHeader.sessionId, msgHeader.label);
    }

    /// @notice Compensates a rejected ETH recv: returns the pending amount to the ETH liquidity
    ///         pool (undoing the mint from receiveETH) and removes the provisional ACK message.
    function recvAbortETH(IUniversalBridgeMailbox.MessageHeader calldata msgHeader) external onlyCoordinator {
        if (!mailbox.isConsumed(msgHeader)) revert IUniversalBridgeMailbox.MessageNotConsumed();

        bytes memory m = mailbox.readMessage(msgHeader);
        (, uint256 amount) = abi.decode(m, (uint256, uint256));

        ethLiquidity.burn{value: amount}();

        IUniversalBridgeMailbox.MessageHeader memory ackHeader = IUniversalBridgeMailbox.MessageHeader({
            chainSrc: msgHeader.chainDest,
            chainDest: msgHeader.chainSrc,
            sender: msgHeader.receiver,
            receiver: msgHeader.sender,
            sessionId: msgHeader.sessionId,
            label: "ACK"
        });
        mailbox.unwrite(IUniversalBridgeMailbox.Message({header: ackHeader, payload: abi.encode(address(0), amount)}));

        emit RecvAborted(msgHeader.chainSrc, msgHeader.receiver, msgHeader.sessionId, msgHeader.label);
    }

    function redeemWrappedCET(address wrappedCET, address coreCET, uint256 amount) external nonReentrant {
        if (wrappedCET == address(0) || coreCET == address(0)) revert ZeroAddress();
        if (!isCoreComposeable(coreCET)) revert NotCoreComposeable();
        if (IComposableERC20(wrappedCET).remoteAsset() != coreCET) revert AssetMismatch();

        IComposableERC20(wrappedCET).crosschainBurn(msg.sender, amount);
        IComposableERC20(coreCET).crosschainMint(msg.sender, amount);
        emit WrappedCETRedeemed(wrappedCET, coreCET, msg.sender, amount);
    }
}
