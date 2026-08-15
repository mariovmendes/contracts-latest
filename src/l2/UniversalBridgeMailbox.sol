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

        _removeInboxHeader(chainMessageSender, block.chainid, sender, receiver, sessionId, label);

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

    function writeMessage(Message calldata _message) external onlyBridge {
        MessageHeader calldata h = _message.header;
        bytes32 key = getKey(block.chainid, h.chainDest, msg.sender, h.receiver, h.sessionId, h.label);

        if (createdKeys[key]) revert KeyAlreadyExists();

        outbox[key] = _message.payload;
        createdKeys[key] = true;

        messageHeaderListOutbox.push(MessageHeader(block.chainid, h.chainDest, msg.sender, h.receiver, h.sessionId, h.label));

        emit NewOutboxKey(messageHeaderListOutbox.length - 1, key);
    }

    function unwrite(Message calldata _message) external onlyBridge {
        MessageHeader calldata h = _message.header;
        bytes32 key = getKey(block.chainid, h.chainDest, msg.sender, h.receiver, h.sessionId, h.label);

        if (!createdKeys[key]) revert MessageNotFound();
        if (keccak256(outbox[key]) != keccak256(_message.payload)) revert MessageNotFound();

        delete outbox[key];
        createdKeys[key] = false;

        _removeOutboxHeader(block.chainid, h.chainDest, msg.sender, h.receiver, h.sessionId, h.label);

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
        bytes32 key = getKey(block.chainid, header.chainDest, msg.sender, header.receiver, header.sessionId, header.label);

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

    function _headerEqualsInbox(
        MessageHeader storage h,
        uint256 chainSrc,
        uint256 chainDest,
        address sender,
        address receiver,
        uint256 sessionId,
        string memory label
    ) internal view returns (bool) {
        if (h.chainSrc != chainSrc) return false;
        if (h.chainDest != chainDest) return false;
        if (h.sender != sender) return false;
        if (h.receiver != receiver) return false;
        if (h.sessionId != sessionId) return false;
        if (keccak256(bytes(h.label)) != keccak256(bytes(label))) return false;
        return true;
    }

    function _removeInboxHeader(uint256 chainSrc, uint256 chainDest, address sender, address receiver, uint256 sessionId, string memory label) internal {
        uint256 len = messageHeaderListInbox.length;
        for (uint256 i = 0; i < len; i++) {
            if (_headerEqualsInbox(messageHeaderListInbox[i], chainSrc, chainDest, sender, receiver, sessionId, label)) {
                messageHeaderListInbox[i] = messageHeaderListInbox[len - 1];
                messageHeaderListInbox.pop();
                break;
            }
        }
    }

    function _removeOutboxHeader(uint256 chainSrc, uint256 chainDest, address sender, address receiver, uint256 sessionId, string memory label) internal {
        uint256 len = messageHeaderListOutbox.length;
        for (uint256 i = 0; i < len; i++) {
            if (_headerEqualsInbox(messageHeaderListOutbox[i], chainSrc, chainDest, sender, receiver, sessionId, label)) {
                messageHeaderListOutbox[i] = messageHeaderListOutbox[len - 1];
                messageHeaderListOutbox.pop();
                break;
            }
        }
    }
}
