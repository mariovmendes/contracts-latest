// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.18;

import {IUniversalBridgeMailbox} from "src/l2/interfaces/IUniversalBridgeMailbox.sol";

contract UniversalBridgeMailbox is IUniversalBridgeMailbox {
    address public immutable COORDINATOR;
    mapping(address => bool) public authorizedBridges;
    address public immutable owner;

    uint256[] public chainIDsInbox;
    uint256[] public chainIDsOutbox;

    mapping(uint256 chainId => bytes32 inboxRoot) public inboxRootPerChain;
    mapping(uint256 chainId => bytes32 outboxRoot) public outboxRootPerChain;

    mapping(bytes32 key => bytes message) public inbox;
    mapping(bytes32 key => bytes message) public outbox;

    mapping(bytes32 key => bool used) public createdKeys;
    mapping(bytes32 key => bool consumed) public consumedKeys;

    MessageHeader[] public messageHeaderListInbox;
    MessageHeader[] public messageHeaderListOutbox;

    /// Position of a key's header inside `messageHeaderListInbox`/`Outbox`,
    /// stored 1-based so that 0 means "absent". Without these, removal had to
    /// linearly scan the list comparing every header (including a dynamic string),
    /// so the compensating actions (`unwrite`, `removeInbox`) grew more
    /// expensive with every message ever written and eventually ran out of gas
    /// — permanently stranding escrowed funds on an aborted transfer.
    mapping(bytes32 key => uint256 indexPlusOne) private inboxHeaderIndex;
    mapping(bytes32 key => uint256 indexPlusOne) private outboxHeaderIndex;

    error OnlyBridge();
    error OnlyDeployer();
    error ZeroAddress();

    modifier onlyCoordinator() {
        if (msg.sender != COORDINATOR) revert InvalidCoordinator();
        _;
    }

    modifier onlyBridge() {
        if (!authorizedBridges[msg.sender]) revert OnlyBridge();
        _;
    }

    constructor(address _coordinator, address _owner) {
        COORDINATOR = _coordinator;
        owner = _owner;
    }

    function authorizeBridge(address _bridge) external {
        if (msg.sender != owner) revert OnlyDeployer();
        if (_bridge == address(0)) revert ZeroAddress();
        authorizedBridges[_bridge] = true;
    }

    function revokeBridge(address _bridge) external {
        if (msg.sender != owner) revert OnlyDeployer();
        authorizedBridges[_bridge] = false;
    }

    function getKey(uint256 chainMessageSender, uint256 chainMessageRecipient, address sender, address receiver, uint256 sessionId, string calldata label)
        public
        pure
        returns (bytes32 key)
    {
        key = keccak256(abi.encodePacked(chainMessageSender, chainMessageRecipient, sender, receiver, sessionId, label));
    }

    function putInbox(uint256 chainMessageSender, address sender, address receiver, uint256 sessionId, string calldata label, bytes calldata data)
        external
        onlyCoordinator
    {
        bytes32 key = getKey(chainMessageSender, block.chainid, sender, receiver, sessionId, label);

        if (createdKeys[key]) {
            revert KeyAlreadyExists();
        }

        createdKeys[key] = true;
        inbox[key] = data;

        messageHeaderListInbox.push(MessageHeader(chainMessageSender, block.chainid, sender, receiver, sessionId, label));
        inboxHeaderIndex[key] = messageHeaderListInbox.length;

        if (inboxRootPerChain[chainMessageSender] == bytes32(0)) {
            chainIDsInbox.push(chainMessageSender);
        }

        emit NewInboxKey(messageHeaderListInbox.length - 1, key);
    }

    function removeInbox(uint256 chainMessageSender, address sender, address receiver, uint256 sessionId, string calldata label, bytes calldata data)
        external
        onlyCoordinator
    {
        bytes32 key = getKey(chainMessageSender, block.chainid, sender, receiver, sessionId, label);

        if (!createdKeys[key]) revert MessageNotFound();
        if (keccak256(inbox[key]) != keccak256(data)) revert MessageNotFound();

        delete inbox[key];
        delete consumedKeys[key];
        createdKeys[key] = false;

        _removeInboxHeader(key);

        emit DeletedInboxMessage(key);
    }

    function readMessage(MessageHeader calldata header) external view onlyBridge returns (bytes memory message) {
        bytes32 key = getKey(header.chainSrc, header.chainDest, header.sender, header.receiver, header.sessionId, header.label);

        if (!createdKeys[key]) {
            revert MessageNotFound();
        }

        return inbox[key];
    }

    function isConsumed(MessageHeader calldata header) external view returns (bool) {
        bytes32 key = getKey(header.chainSrc, header.chainDest, header.sender, header.receiver, header.sessionId, header.label);
        return consumedKeys[key];
    }

    function markConsumed(MessageHeader calldata header) external onlyBridge {
        bytes32 key = getKey(header.chainSrc, header.chainDest, header.sender, header.receiver, header.sessionId, header.label);

        if (!createdKeys[key]) revert MessageNotFound();
        if (consumedKeys[key]) revert MessageAlreadyConsumed();

        consumedKeys[key] = true;
    }

    /// @dev Keys on `h.sender` rather than `msg.sender`. The two differ only for ACK messages:
    ///      SEND headers already carry `sender = address(bridge)`, but `receiveTokens`/`receiveETH`
    ///      set the ACK's `sender` to the original SEND's receiver (the end user). Substituting
    ///      `msg.sender` here silently rewrote that to the bridge, so the destination chain stored
    ///      the ACK under a different key than the one the coordinator relays to the source chain
    ///      via `putInbox` — leaving the two chains' ACK roots permanently unable to reconcile.
    function writeMessage(Message calldata _message) external onlyBridge {
        MessageHeader calldata h = _message.header;
        bytes32 key = getKey(block.chainid, h.chainDest, h.sender, h.receiver, h.sessionId, h.label);

        if (createdKeys[key]) revert KeyAlreadyExists();

        outbox[key] = _message.payload;
        createdKeys[key] = true;

        messageHeaderListOutbox.push(MessageHeader(block.chainid, h.chainDest, h.sender, h.receiver, h.sessionId, h.label));
        outboxHeaderIndex[key] = messageHeaderListOutbox.length;

        emit NewOutboxKey(messageHeaderListOutbox.length - 1, key);
    }

    function unwrite(Message calldata _message) external onlyBridge {
        MessageHeader calldata h = _message.header;
        bytes32 key = getKey(block.chainid, h.chainDest, h.sender, h.receiver, h.sessionId, h.label);

        if (!createdKeys[key]) revert MessageNotFound();
        if (keccak256(outbox[key]) != keccak256(_message.payload)) revert MessageNotFound();

        delete outbox[key];
        createdKeys[key] = false;

        _removeOutboxHeader(key);

        emit DeletedOutboxMessage(key);
    }

    function updateInboxRoot(MessageHeader calldata header) external onlyBridge {
        bytes32 key = getKey(header.chainSrc, header.chainDest, header.sender, header.receiver, header.sessionId, header.label);

        if (!createdKeys[key]) revert MessageNotFound();
        if (!consumedKeys[key]) revert MessageNotConsumed();

        if (inboxRootPerChain[header.chainSrc] == bytes32(0)) {
            chainIDsInbox.push(header.chainSrc);
        }

        inboxRootPerChain[header.chainSrc] ^= keccak256(abi.encode(key, inbox[key]));
    }

    function updateOutboxRoot(MessageHeader calldata header) external onlyBridge {
        bytes32 key = getKey(block.chainid, header.chainDest, header.sender, header.receiver, header.sessionId, header.label);

        if (!createdKeys[key]) revert MessageNotFound();

        if (outboxRootPerChain[header.chainDest] == bytes32(0)) {
            chainIDsOutbox.push(header.chainDest);
        }

        outboxRootPerChain[header.chainDest] ^= keccak256(abi.encode(key, outbox[key]));
    }

    function computeKey(uint256 id) external view returns (bytes32) {
        if (id >= messageHeaderListInbox.length) {
            revert InvalidId();
        }

        MessageHeader storage m = messageHeaderListInbox[id];

        return keccak256(abi.encodePacked(m.chainSrc, m.chainDest, m.sender, m.receiver, m.sessionId, m.label));
    }

    /// Key of a stored header, matching `getKey`'s encoding.
    function _headerKey(MessageHeader storage h) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(h.chainSrc, h.chainDest, h.sender, h.receiver, h.sessionId, h.label));
    }

    /// Removes `key`'s header in O(1) via swap-and-pop, re-indexing the element
    /// moved into the vacated slot. No-op when the key has no header.
    function _removeInboxHeader(bytes32 key) internal {
        uint256 indexPlusOne = inboxHeaderIndex[key];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = messageHeaderListInbox.length - 1;
        if (index != lastIndex) {
            // Re-key the moved element before it is overwritten.
            bytes32 movedKey = _headerKey(messageHeaderListInbox[lastIndex]);
            messageHeaderListInbox[index] = messageHeaderListInbox[lastIndex];
            inboxHeaderIndex[movedKey] = index + 1;
        }

        messageHeaderListInbox.pop();
        delete inboxHeaderIndex[key];
    }

    /// Outbox counterpart of `_removeInboxHeader`.
    function _removeOutboxHeader(bytes32 key) internal {
        uint256 indexPlusOne = outboxHeaderIndex[key];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = messageHeaderListOutbox.length - 1;
        if (index != lastIndex) {
            bytes32 movedKey = _headerKey(messageHeaderListOutbox[lastIndex]);
            messageHeaderListOutbox[index] = messageHeaderListOutbox[lastIndex];
            outboxHeaderIndex[movedKey] = index + 1;
        }

        messageHeaderListOutbox.pop();
        delete outboxHeaderIndex[key];
    }
}
