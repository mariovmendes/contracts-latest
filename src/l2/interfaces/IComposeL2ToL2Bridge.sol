// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

interface IComposeL2ToL2Bridge {
    event TokensSendQueued(
        uint256 indexed chainDest, address indexed sender, address indexed receiver, address remoteAsset, uint256 amount, uint256 sessionId, bytes32 messageId
    );
    event TokensLocked(address indexed token, address indexed sender, uint256 amount);
    event CETBurned(address indexed token, address indexed sender, uint256 amount);
    event TokensReceived(address indexed token, uint256 amount);
    event ETHLocked(address indexed sender, uint256 amount);
    event ETHBridged(uint256 indexed chainDest, address indexed sender, address indexed receiver, uint256 amount, uint256 sessionId, bytes32 messageId);
    event ETHReceived(address indexed receiver, uint256 amount);
    event WrappedCETRedeemed(address indexed wrappedCET, address indexed coreCET, address indexed caller, uint256 amount);

    error ZeroAddress();
    error AssetMismatch();
    event MailboxWrite(uint256 indexed chainId, address indexed account, uint256 indexed sessionId, string label);
    event MailboxAckWrite(uint256 indexed chainId, address indexed account, uint256 indexed sessionId, string label);

    /// @notice Emitted when the coordinator finalizes a send after observing its ACK.
    event SendConfirmed(uint256 indexed chainDest, address indexed receiver, uint256 indexed sessionId, string label);
    /// @notice Emitted when the coordinator compensates (rolls back) a send.
    event SendAborted(uint256 indexed chainDest, address indexed sender, uint256 indexed sessionId, string label);
    /// @notice Emitted when the coordinator finalizes a recv, delivering funds to the receiver.
    event RecvConfirmed(uint256 indexed chainSrc, address indexed receiver, uint256 indexed sessionId, string label);
    /// @notice Emitted when the coordinator compensates (rolls back) a recv.
    event RecvAborted(uint256 indexed chainSrc, address indexed receiver, uint256 indexed sessionId, string label);

    error InvalidCoordinator();
    error Unauthorized();
    error WrongDestinationChain();
    error InvalidMessage();
    error NoSendMessage();
    error NoETHSent();
    error CETAddressMismatch();
    error TransferFailed();
    error NoAckMessage();
    error AckTokenMismatch();
    error AckAmountMismatch();
    error InvalidCetAddress();
    error NotReceiver();
    error UseBridgeCETTo();
    error NotCoreComposeable();
    error InsufficientEscrowBalance();
    /// @notice The `sender` the coordinator passed to an abort is not the depositor the mailbox
    ///         recorded at send time.
    error DepositorMismatch();
}
