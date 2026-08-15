// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

interface IUniversalBridgeMailbox {
    struct MessageHeader {
        uint256 chainSrc;
        uint256 chainDest;
        address sender;
        address receiver;
        uint256 sessionId;
        string label;
    }

    struct Message {
        MessageHeader header;
        bytes payload;
    }

    error InvalidCoordinator();
    error MessageNotFound();
    error MessageAlreadyConsumed();
    error MessageNotConsumed();
    error KeyAlreadyExists();
    error InvalidId();

    event NewInboxKey(uint256 indexed index, bytes32 key);
    event NewOutboxKey(uint256 indexed index, bytes32 key);
    event DeletedInboxMessage(bytes32 key);
    event DeletedOutboxMessage(bytes32 key);

    /// @notice Reads a message from the inbox without consuming it. Callable only by an authorized bridge.
    function readMessage(MessageHeader calldata header) external view returns (bytes memory message);

    /// @notice Whether the inbox message for `header` has been marked consumed.
    function isConsumed(MessageHeader calldata header) external view returns (bool);

    /// @notice Marks a previously put inbox message as consumed. Reverts if already consumed. Bridge-only.
    function markConsumed(MessageHeader calldata header) external;

    /// @notice Writes a provisional outbox message. Does not update the outbox root. Bridge-only.
    function writeMessage(Message calldata message) external;

    /// @notice Removes a provisional outbox message written by the caller bridge (compensating action). Bridge-only.
    function unwrite(Message calldata message) external;

    /// @notice Adds a message to the inbox. Coordinator-only.
    function putInbox(uint256 chainSrc, address sender, address receiver, uint256 sessionId, string calldata label, bytes calldata data) external;

    /// @notice Removes a previously added inbox message (compensating action). Coordinator-only.
    function removeInbox(uint256 chainSrc, address sender, address receiver, uint256 sessionId, string calldata label, bytes calldata data) external;

    /// @notice Finalizes the inbox root for a consumed message. Bridge-only.
    function updateInboxRoot(MessageHeader calldata header) external;

    /// @notice Finalizes the outbox root for a written message. Bridge-only.
    function updateOutboxRoot(MessageHeader calldata header) external;
}
