------------------------- MODULE InterleavedBridge -------------------------
EXTENDS Integers, FiniteSets, Functions

CONSTANTS CHAINS, SESSIONS, TOKENS, USERS,
          BRIDGES, INITIAL_BALANCE, MAX_AMOUNT, Empty, TIMEOUT,
          BRIDGE_CHAIN   \* exactly one bridge per chain, one chain per bridge

ASSUME BRIDGE_CHAIN \in Bijection(BRIDGES, CHAINS)

VARIABLES initialBalances,
          chainSessionStates,
          chainSendRoles,
          chainRecvRoles,
          chainSessionMembers,
          generalSessionStates,
          accountBalances,
          msgs,
          bridgesTokenBalances,
          inbox,
          outbox,
          spClock,
          chainClock

(*************************************************************************)
(* OBS:                                                                  *)
(* This spec assumes sessionId uniquely identifies a bridging process.   *)
(* This is crucial to ensure that different processes do not affect the  *)
(* same messages of the inboxes/outboxes.                                *)
(*************************************************************************)

vars == <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
          generalSessionStates, accountBalances, msgs,
          bridgesTokenBalances, inbox, outbox,spClock, chainClock>>

Messages2PC ==
        [sessionId: SESSIONS, chain: CHAINS, type: {"Vote"},    value: BOOLEAN]
        \union
        [sessionId: SESSIONS,               type: {"Decided"}, value: BOOLEAN]

SessionStateSet == {"unprocessed", "processing", "confirmed", "aborted"}

LABEL == {"SEND", "ACK SEND"}

MessageData == [sender: USERS, receiver: USERS, token: TOKENS,
                amount: 0..MAX_AMOUNT, consumed: BOOLEAN, finalized: BOOLEAN]

(*************************************************************************)
(* Type Invariant                                                        *)
(*************************************************************************)

TPTypeOK ==
    /\ initialBalances      \in [SESSIONS -> [CHAINS \X USERS -> 0..MAX_AMOUNT]]
    /\ accountBalances      \in [CHAINS \X USERS -> 0..MAX_AMOUNT]
    /\ generalSessionStates \in [SESSIONS -> SessionStateSet]
    /\ chainSessionStates   \in [CHAINS \X SESSIONS -> SessionStateSet]
    /\ chainSendRoles \in [CHAINS \X SESSIONS -> Nat]
    /\ chainRecvRoles \in [CHAINS \X SESSIONS -> Nat]
    /\ chainSessionMembers \in [SESSIONS -> SUBSET CHAINS]
    /\ bridgesTokenBalances  \in [BRIDGES \X TOKENS -> 0..MAX_AMOUNT]
    /\ msgs                 \subseteq Messages2PC
    /\ inbox                \in [BRIDGES \X CHAINS \X CHAINS \X USERS \X USERS
                                \X SESSIONS \X LABEL
                                 -> MessageData \cup {Empty}]
    /\ outbox               \in [BRIDGES \X CHAINS \X CHAINS \X USERS \X USERS
                                \X SESSIONS \X LABEL
                                -> MessageData \cup {Empty}]
    /\ spClock              \in [SESSIONS -> 0..TIMEOUT]
    /\ chainClock           \in [CHAINS \X SESSIONS -> 0..TIMEOUT]

(*************************************************************************)
(* Initialization                                                        *)
(*************************************************************************)

TPInit ==
    /\ initialBalances = [s \in SESSIONS |-> [cu \in CHAINS \X USERS |-> 0]]
    /\ accountBalances = [cu \in CHAINS \X USERS |-> INITIAL_BALANCE]
    /\ generalSessionStates = [s \in SESSIONS |-> "unprocessed"]
    /\ chainSessionStates   = [chain \in CHAINS, s \in SESSIONS |-> "unprocessed"]
    /\ chainSendRoles = [chain \in CHAINS, s \in SESSIONS |-> 0]
    /\ chainRecvRoles = [chain \in CHAINS, s \in SESSIONS |-> 0]
    /\ chainSessionMembers = [s \in SESSIONS |-> {}]
    /\ bridgesTokenBalances  = [bridge \in BRIDGES, token \in TOKENS |-> 0]
    /\ msgs                 = {}
    /\ inbox  = [b \in BRIDGES, sc \in CHAINS, dc \in CHAINS,
                 u \in USERS,   v \in USERS,   s \in SESSIONS,
                 l \in LABEL |-> Empty]
    /\ outbox = [b \in BRIDGES, sc \in CHAINS, dc \in CHAINS,
                 u \in USERS,   v \in USERS,   s \in SESSIONS,
                 l \in LABEL |-> Empty]
    /\ spClock    = [s \in SESSIONS |-> 0]
    /\ chainClock = [chain \in CHAINS, s \in SESSIONS |-> 0]

(*************************************************************************)
(* Helper Functions                                                      *)
(*************************************************************************)

ChainsInvolvedInSession(sessId) == chainSessionMembers[sessId]

ChainHasVoted(chain, sessId) ==
    \/ [sessionId |-> sessId, chain |-> chain, type |-> "Vote", value |-> TRUE]  \in msgs
    \/ [sessionId |-> sessId, chain |-> chain, type |-> "Vote", value |-> FALSE] \in msgs

(*************************************************************************)
(* Mailbox Operations (not called, changed directly by functions)        *)
(*************************************************************************)

(*Write(bridge, chainSender, chainReceiver, sender, receiver, sessionId, label, data) ==
    /\ outbox' = [outbox EXCEPT
                    ![bridge, chainSender, chainReceiver,
                      sender, receiver, sessionId, label] = data]
    /\ UNCHANGED <<inbox, chainSessionStates, generalSessionStates,
                   accountBalances, bridgesTokenBalances, msgs>>

PutInbox(bridge, chainSender, chainReceiver, sender, receiver, sessionId, label, data) ==
    /\ inbox' = [inbox EXCEPT
                    ![bridge, chainSender, chainReceiver,
                      sender, receiver, sessionId, label] = data]
    /\ UNCHANGED <<outbox, chainSessionStates, generalSessionStates,
                   accountBalances, bridgesTokenBalances, msgs>>*)


(*************************************************************************)
(* Clock Ticking                                                         *)
(* Clocks only advance while session is processing                       *)
(*************************************************************************)

SPTick(sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ spClock[sessId] < TIMEOUT
    /\ spClock' = [spClock EXCEPT ![sessId] = @ + 1]
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   generalSessionStates, accountBalances,
                   msgs, bridgesTokenBalances, inbox, outbox, chainClock>>

ChainTick(chain, sessId) ==
    /\ chainSessionStates[chain, sessId] = "processing"
    /\ chainClock[chain, sessId] < TIMEOUT
    /\ chainClock' = [chainClock EXCEPT ![chain, sessId] = @ + 1]
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   generalSessionStates, accountBalances,
                   msgs, bridgesTokenBalances, inbox, outbox, spClock>>

(*************************************************************************)
(* Timeout Actions                                                       *)
(* Timeout triggers abort of the whole session                           *)
(*************************************************************************)

SPTimeout(sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ spClock[sessId] = TIMEOUT
    /\ generalSessionStates' = [generalSessionStates EXCEPT ![sessId] = "aborted"]
    /\ msgs' = msgs \union {[sessionId |-> sessId, type |-> "Decided", value |-> FALSE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   accountBalances, bridgesTokenBalances,
                   inbox, outbox, spClock, chainClock>>

ChainTimeout(chain, sessId) ==
    /\ chainSessionStates[chain, sessId] = "processing"
    /\ chainClock[chain, sessId] = TIMEOUT
    \* Chain votes abort due to timeout
    /\ ~ChainHasVoted(chain, sessId)
    /\ msgs' = msgs \union {[sessionId |-> sessId, chain |-> chain,
                              type |-> "Vote", value |-> FALSE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   generalSessionStates, accountBalances, bridgesTokenBalances,
                   inbox, outbox, spClock, chainClock>>

\* A chain with no outstanding roles follows the decision directly, without a
\* SendConfirm/SendAbort/RecvConfirm/RecvAbort to move it. Covers both
\* decisions: without the "confirmed" case a chain that started but never sent
\* or received is stranded in "processing" forever.
ChainSkipDecision(chain, sessId) ==
    /\ generalSessionStates[sessId] \in {"aborted", "confirmed"}
    /\ chainSessionStates[chain, sessId] \in {"unprocessed", "processing"}
    /\ chainSendRoles[chain, sessId] = 0
    /\ chainRecvRoles[chain, sessId] = 0
    /\ [sessionId |-> sessId, type |-> "Decided",
        value |-> (generalSessionStates[sessId] = "confirmed")] \in msgs
    /\ chainSessionStates' = [chainSessionStates EXCEPT
                                ![chain, sessId] = generalSessionStates[sessId]]
    /\ UNCHANGED <<initialBalances, generalSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   accountBalances, msgs,
                   bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

(*************************************************************************)
(* Simulation Phase                                                      *)
(* User sends and receives tokens between two chains                     *)
(*************************************************************************)

Send(srcChain, destChain, sender, receiver, token, amount, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ ~ChainHasVoted(srcChain, sessionId)
    /\ generalSessionStates[sessionId] = "processing"
    /\ chainSessionStates[srcChain, sessionId] = "processing"
    /\ accountBalances[srcChain, sender] >= amount
    /\ amount > 0
    /\ outbox[senderBridge, srcChain, destChain, sender, receiver, sessionId, "SEND"] = Empty
    /\  ~(\E dChain \in CHAINS, u, v \in USERS: (outbox[senderBridge, srcChain, dChain, u, v,
            sessionId, "SEND"] # Empty))
    /\ LET msg == [sender   |-> sender,   receiver |-> receiver,
                   token    |-> token,    amount   |-> amount,
                   consumed |-> FALSE,    finalized |-> FALSE]
       IN
       /\ accountBalances' = [accountBalances EXCEPT ![srcChain, sender] = @ - amount]
       /\ outbox'          = [outbox EXCEPT
                                ![senderBridge, srcChain, destChain,
                                  sender, receiver, sessionId, "SEND"] = msg]
    /\ chainSendRoles' = [chainSendRoles EXCEPT ![srcChain, sessionId] = @ + 1]
    /\ chainSessionMembers' = [chainSessionMembers EXCEPT ![sessionId] = @ \cup {srcChain}]
    /\ UNCHANGED <<initialBalances, inbox, chainSessionStates, chainRecvRoles, generalSessionStates,
                   bridgesTokenBalances, msgs, spClock, chainClock>>

\* Sequencer relays SEND from src bridge outbox to dest bridge inbox
SeqRelay(srcChain, destChain, sender, receiver, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ generalSessionStates[sessionId] = "processing"
    /\ outbox[senderBridge, srcChain, destChain,
               sender, receiver, sessionId, "SEND"] # Empty
    /\ inbox[destBridge, srcChain, destChain,
              sender, receiver, sessionId, "SEND"] = Empty
    /\ LET msg == outbox[senderBridge, srcChain, destChain,
                          sender, receiver, sessionId, "SEND"]
       IN inbox' = [inbox EXCEPT
                        ![destBridge, srcChain, destChain,
                          sender, receiver, sessionId, "SEND"] = msg]
    /\ UNCHANGED <<initialBalances, outbox, accountBalances, chainSessionStates, chainSessionMembers,
                   chainSendRoles, chainRecvRoles,
                   generalSessionStates, bridgesTokenBalances, msgs, spClock, chainClock>>

\* Sequencer relays ACK SEND from dest bridge outbox to src bridge inbox
SeqRelayAck(srcChain, destChain, sender, receiver, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ generalSessionStates[sessionId] = "processing"
    /\ outbox[destBridge, destChain, srcChain,
               sender, receiver, sessionId, "ACK SEND"] # Empty
    /\ inbox[senderBridge, destChain, srcChain,
              sender, receiver, sessionId, "ACK SEND"] = Empty
    /\ LET msg == outbox[destBridge, destChain, srcChain,
                          sender, receiver, sessionId, "ACK SEND"]
       IN inbox' = [inbox EXCEPT
                        ![senderBridge, destChain, srcChain,
                          sender, receiver, sessionId, "ACK SEND"] = msg]
    /\ UNCHANGED <<initialBalances, outbox, accountBalances, chainSessionStates, chainSessionMembers,
                   chainSendRoles, chainRecvRoles,
                   generalSessionStates, bridgesTokenBalances, msgs, spClock, chainClock>>

Recv(srcChain, destChain, sender, receiver, token, amount, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ ~ChainHasVoted(destChain, sessionId)
    /\ generalSessionStates[sessionId] = "processing"
    /\ chainSessionStates[destChain, sessionId] = "processing"
    /\ amount > 0
    /\ inbox[destBridge, srcChain, destChain,
              sender, receiver, sessionId, "SEND"] # Empty
    /\  ~(\E dChain \in CHAINS, u, v \in USERS: (inbox[destBridge, srcChain, dChain, u, v,
            sessionId, "SEND"] # Empty) /\ (u # sender \/ v # receiver))
    /\ LET msg == inbox[destBridge, srcChain, destChain,
                         sender, receiver, sessionId, "SEND"]
       IN
       /\ msg.sender    = sender
       /\ msg.receiver  = receiver
       /\ msg.token     = token
       /\ msg.amount    = amount
       /\ msg.consumed  = FALSE
       /\ chainRecvRoles' = [chainRecvRoles EXCEPT ![destChain, sessionId] = @ + 1]
       /\ chainSessionMembers' = [chainSessionMembers EXCEPT ![sessionId] = @ \cup {destChain}]
       /\ bridgesTokenBalances' = [bridgesTokenBalances EXCEPT ![destBridge, token] = @ + amount]
       /\ inbox' = [inbox EXCEPT
                        ![destBridge, srcChain, destChain,
                          sender, receiver, sessionId, "SEND"] =
                            [msg EXCEPT !.consumed = TRUE]]
       /\ LET ackMsg == [sender   |-> sender, receiver |-> receiver,
                         token    |-> token,    amount   |-> amount,
                         consumed |-> FALSE, finalized |-> FALSE]
          IN outbox' = [outbox EXCEPT
                            ![destBridge, destChain, srcChain,
                              sender, receiver, sessionId, "ACK SEND"] = ackMsg]
    /\ UNCHANGED <<initialBalances, accountBalances, chainSessionStates, chainSendRoles,
                   generalSessionStates, msgs, spClock, chainClock>>

(*************************************************************************)
(* 2PC: Chain Voting                                                     *)
(*************************************************************************)

ChainStart(chain, sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ chainSessionStates[chain, sessId] = "unprocessed"
    /\ chainSessionStates' = [chainSessionStates EXCEPT ![chain, sessId] = "processing"]
    /\ UNCHANGED <<initialBalances, generalSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                   accountBalances, msgs,
                   bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

\* A chain votes confirm once it has nothing outstanding for this session.
\* Both conditions read only mailboxes of bridges deployed on `chain` itself.
ChainVoteConfirm(chain, sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ chainSessionStates[chain, sessId] = "processing"
    /\ chainClock[chain, sessId] < TIMEOUT
    /\ ~ChainHasVoted(chain, sessId)
    /\ \* Every SEND this chain placed has come back ACKed into its own inbox
       \A b \in BRIDGES, oC \in CHAINS, u, v \in USERS :
          outbox[b, chain, oC, u, v, sessId, "SEND"] # Empty =>
              \E b2 \in BRIDGES :
                  /\ BRIDGE_CHAIN[b2] = chain
                  /\ inbox[b2, oC, chain, u, v, sessId, "ACK SEND"] # Empty
    /\ \* Every SEND delivered to this chain has been consumed by a Recv
       \A b \in BRIDGES, oC \in CHAINS, u, v \in USERS :
          inbox[b, oC, chain, u, v, sessId, "SEND"] # Empty =>
              inbox[b, oC, chain, u, v, sessId, "SEND"].consumed = TRUE
    /\ msgs' = msgs \union {[sessionId |-> sessId, chain |-> chain,
                              type |-> "Vote", value |-> TRUE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSessionMembers, generalSessionStates,
                   chainSendRoles, chainRecvRoles, accountBalances,
                   bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

ChainVoteAbort(chain, sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ chainSessionStates[chain, sessId] = "processing"
    /\ chainClock[chain, sessId] < TIMEOUT
    /\ ~ChainHasVoted(chain, sessId)
    /\ msgs'               = msgs \union {[sessionId |-> sessId, chain |-> chain,
                                           type |-> "Vote", value |-> FALSE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSessionMembers, generalSessionStates,
                   chainSendRoles, chainRecvRoles, accountBalances,
                   bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

(*************************************************************************)
(* 2PC: Shared Publisher Decision                                        *)
(*************************************************************************)

SPStartTransfer(sessId) ==
    /\ generalSessionStates[sessId] = "unprocessed"
    /\ generalSessionStates' = [generalSessionStates EXCEPT ![sessId] = "processing"]
    /\ initialBalances' = [initialBalances EXCEPT  ![sessId] = accountBalances]
    /\ UNCHANGED <<chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers, accountBalances, msgs,
                   bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

AllVotedConfirm(sessId) ==
    \A chain \in ChainsInvolvedInSession(sessId) :
        [sessionId |-> sessId, chain |-> chain, type |-> "Vote", value |-> TRUE] \in msgs

OneVotedAbort(sessId) ==
    \E chain \in CHAINS :
        [sessionId |-> sessId, chain |-> chain, type |-> "Vote", value |-> FALSE] \in msgs

SPDecideConfirm(sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ ChainsInvolvedInSession(sessId) # {}
    /\ AllVotedConfirm(sessId)
    /\ ~OneVotedAbort(sessId)   \* any abort vote wins, even from a non-member chain
    /\ spClock[sessId] < TIMEOUT
    /\ generalSessionStates' = [generalSessionStates EXCEPT ![sessId] = "confirmed"]
    /\ msgs' = msgs \union {[sessionId |-> sessId, type |-> "Decided", value |-> TRUE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                    accountBalances, bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

SPDecideAbort(sessId) ==
    /\ generalSessionStates[sessId] = "processing"
    /\ (OneVotedAbort(sessId) \/ spClock[sessId] = TIMEOUT)
    /\ generalSessionStates' = [generalSessionStates EXCEPT ![sessId] = "aborted"]
    /\ msgs' = msgs \union {[sessionId |-> sessId, type |-> "Decided", value |-> FALSE]}
    /\ UNCHANGED <<initialBalances, chainSessionStates, chainSendRoles, chainRecvRoles, chainSessionMembers,
                    accountBalances, bridgesTokenBalances, inbox, outbox, spClock, chainClock>>

(*************************************************************************)
(* Post-Decision Phase                                                   *)
(*************************************************************************)

SendConfirm(srcChain, destChain, sender, receiver,
            sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ chainSendRoles[srcChain, sessionId] > 0
    /\ generalSessionStates[sessionId] = "confirmed"
    /\ chainSessionStates[srcChain, sessionId] = "processing"
    /\ [sessionId |-> sessionId, type |-> "Decided", value |-> TRUE] \in msgs
    /\ LET ackMsg == inbox[senderBridge, destChain, srcChain, sender, receiver, sessionId, "ACK SEND"]
           remainingSend == chainSendRoles[srcChain, sessionId] - 1
           remainingRecv == chainRecvRoles[srcChain, sessionId]
       IN /\ ackMsg # Empty
          /\ ackMsg.consumed = FALSE
          /\ inbox' = [inbox EXCEPT ![senderBridge, destChain, srcChain, sender, receiver, sessionId,
                        "ACK SEND"] = [ackMsg EXCEPT !.consumed = TRUE]]
          /\ chainSendRoles' = [chainSendRoles EXCEPT ![srcChain, sessionId] = remainingSend]
          /\ chainSessionStates' = IF /\ remainingSend = 0
                                      /\ remainingRecv = 0
                                   THEN [chainSessionStates EXCEPT ![srcChain, sessionId] = "confirmed"]
                                   ELSE chainSessionStates
    /\ UNCHANGED <<initialBalances, outbox, accountBalances, chainRecvRoles, chainSessionMembers,
                   generalSessionStates, bridgesTokenBalances, msgs, spClock, chainClock>>

SendAbort(srcChain, destChain, sender, receiver, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ chainSendRoles[srcChain, sessionId] > 0
    /\ generalSessionStates[sessionId] = "aborted"
    /\ chainSessionStates[srcChain, sessionId] = "processing"
    /\ [sessionId |-> sessionId, type |-> "Decided", value |-> FALSE] \in msgs
    /\ LET sentMsg == outbox[senderBridge, srcChain, destChain, sender, receiver, sessionId, "SEND"]
           remainingSend == chainSendRoles[srcChain, sessionId] - 1
           remainingRecv == chainRecvRoles[srcChain, sessionId]
       IN /\ sentMsg # Empty
          /\ accountBalances' = [accountBalances EXCEPT ![srcChain, sender] = @ + sentMsg.amount]
          /\ outbox' = [outbox EXCEPT ![senderBridge, srcChain, destChain, sender, receiver, sessionId,
                        "SEND"] = Empty]
          /\ inbox' = [inbox EXCEPT ![senderBridge, destChain, srcChain, sender, receiver, sessionId,
                        "ACK SEND"] = Empty]
          /\ chainSendRoles' = [chainSendRoles EXCEPT ![srcChain, sessionId] = remainingSend]
          /\ chainSessionStates' = IF /\ remainingSend = 0
                                      /\ remainingRecv = 0
                                   THEN [chainSessionStates EXCEPT ![srcChain, sessionId] = "aborted"]
                                   ELSE chainSessionStates
    /\ UNCHANGED <<initialBalances, generalSessionStates, chainSessionMembers, chainRecvRoles, bridgesTokenBalances,
                    msgs, spClock, chainClock>>

RecvConfirm(srcChain, destChain, sender, receiver, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ chainRecvRoles[destChain, sessionId] > 0
    /\ generalSessionStates[sessionId] = "confirmed"
    /\ chainSessionStates[destChain, sessionId] = "processing"
    /\ [sessionId |-> sessionId, type |-> "Decided", value |-> TRUE] \in msgs
    /\ LET recvdMsg == inbox[destBridge, srcChain, destChain, sender, receiver,sessionId, "SEND"]
           remainingSend == chainSendRoles[destChain, sessionId]
           remainingRecv == chainRecvRoles[destChain, sessionId] - 1
       IN  /\ recvdMsg # Empty
           /\ recvdMsg.consumed = TRUE
           /\ recvdMsg.finalized = FALSE
           /\ bridgesTokenBalances[destBridge, recvdMsg.token] >= recvdMsg.amount
           /\ accountBalances'     = [accountBalances
                                     EXCEPT ![destChain, receiver] = @ + recvdMsg.amount]
           /\ bridgesTokenBalances' = [bridgesTokenBalances
                                     EXCEPT ![destBridge, recvdMsg.token] = @ - recvdMsg.amount]
           /\ inbox' = [inbox EXCEPT ![destBridge, srcChain, destChain, sender, receiver, sessionId,
                                       "SEND"] = [recvdMsg EXCEPT !.finalized = TRUE]]
           /\ chainRecvRoles' = [chainRecvRoles EXCEPT ![destChain, sessionId] = remainingRecv]
           /\ chainSessionStates' = IF /\ remainingSend = 0
                                       /\ remainingRecv = 0
                                    THEN [chainSessionStates EXCEPT ![destChain, sessionId] = "confirmed"]
                                    ELSE chainSessionStates
     /\ UNCHANGED <<initialBalances, outbox, chainSendRoles, chainSessionMembers, generalSessionStates,
                    msgs, spClock, chainClock>>

RecvAbort(srcChain, destChain, sender, receiver, sessionId, senderBridge, destBridge) ==
    /\ srcChain # destChain
    /\ BRIDGE_CHAIN[senderBridge] = srcChain
    /\ BRIDGE_CHAIN[destBridge]   = destChain
    /\ sender = receiver
    /\ chainRecvRoles[destChain, sessionId] > 0
    /\ generalSessionStates[sessionId] = "aborted"
    /\ chainSessionStates[destChain, sessionId] = "processing"
    /\ [sessionId |-> sessionId, type |-> "Decided", value |-> FALSE] \in msgs
    /\ LET recvdMsg == inbox[destBridge, srcChain, destChain,sender, receiver, sessionId, "SEND"]
           remainingSend == chainSendRoles[destChain, sessionId]
           remainingRecv == chainRecvRoles[destChain, sessionId] - 1
       IN  /\ recvdMsg # Empty
           /\ recvdMsg.consumed = TRUE
           /\ recvdMsg.finalized = FALSE
           /\ bridgesTokenBalances[destBridge, recvdMsg.token] >= recvdMsg.amount
           /\ bridgesTokenBalances' = [bridgesTokenBalances EXCEPT ![destBridge, recvdMsg.token]
                                       = @ - recvdMsg.amount]
           /\ outbox' = [outbox EXCEPT ![destBridge, destChain, srcChain, sender, receiver, sessionId,
                                         "ACK SEND"] = Empty]
           /\ inbox'  = [inbox EXCEPT ![destBridge, srcChain, destChain, sender, receiver, sessionId,
                                             "SEND"] = Empty]
           /\ chainRecvRoles' = [chainRecvRoles EXCEPT ![destChain, sessionId] = remainingRecv]
           /\ chainSessionStates' = IF /\ remainingSend = 0
                                       /\ remainingRecv = 0
                                    THEN [chainSessionStates EXCEPT ![destChain, sessionId] = "aborted"]
                                    ELSE chainSessionStates
    /\ UNCHANGED <<initialBalances, accountBalances, chainSessionMembers, chainSendRoles,  generalSessionStates,
                     msgs, spClock, chainClock>>

(*************************************************************************)
(* Invariants                                                            *)
(*************************************************************************)

2PConsistent ==
    \A chainA, chainB \in CHAINS : \A s \in SESSIONS :
        ~ /\ chainSessionStates[chainA, s] = "aborted"
          /\ chainSessionStates[chainB, s] = "confirmed"

\* Every session has reached a terminal state, on the SP and on every chain it
\* involved. Bridge escrow is only expected to be empty at this point: a single
\* finished session says nothing while another session is still in flight.
AllSessionsTerminal ==
    /\ \A s \in SESSIONS : generalSessionStates[s] \in {"aborted", "confirmed"}
    /\ \A s \in SESSIONS : \A c \in ChainsInvolvedInSession(s) :
           chainSessionStates[c, s] \in {"aborted", "confirmed"}

NoStrandedTokens ==
    AllSessionsTerminal =>
        \A b \in BRIDGES, t \in TOKENS : bridgesTokenBalances[b, t] = 0

CleanupAbortedDone(s) ==
    \A chain \in ChainsInvolvedInSession(s) :
        chainSessionStates[chain, s] = "aborted"

CleanupConfirmedDone(s) ==
    \A chain \in ChainsInvolvedInSession(s) :
        chainSessionStates[chain, s] = "confirmed"

CleanupAbortedChains ==
    \A s \in SESSIONS : generalSessionStates[s] = "aborted" ~> CleanupAbortedDone(s)

CleanupConfirmedChains ==
    \A s \in SESSIONS : generalSessionStates[s] = "confirmed" ~> CleanupConfirmedDone(s)

ConfirmRequiresConsensus ==
    \A s \in SESSIONS :
        generalSessionStates[s] = "confirmed" => AllVotedConfirm(s)

AbortRequiresDissent ==
    \A s \in SESSIONS :
        generalSessionStates[s] = "aborted" => \/ OneVotedAbort(s)
                                               \/ spClock[s] = TIMEOUT

ConsumedMessagesNotReprocessed ==
    \A b \in BRIDGES, sc, dc \in CHAINS, u, v \in USERS,
       s \in SESSIONS, l \in LABEL :
        LET msg == inbox[b, sc, dc, u, v, s, l]
        IN msg # Empty /\ msg.consumed = TRUE =>
            generalSessionStates[s] # "unprocessed"

SessionDone(s) ==
    /\ generalSessionStates[s] = "confirmed"
    /\ \A c \in ChainsInvolvedInSession(s) :
          chainSessionStates[c, s] = "confirmed"

\* Sum of all amounts sent from (chain c, user u) across confirmed sessions
TotalSent(c, u) ==
    LET sends == { <<sb, dc, s>> \in BRIDGES \X CHAINS \X SESSIONS :
                       /\ SessionDone(s)
                       /\ outbox[sb, c, dc, u, u, s, "SEND"] # Empty }
    IN SumFunction([key \in sends |->
                       outbox[key[1], c, key[2], u, u, key[3], "SEND"].amount])

\* Sum of all amounts received at (chain c, user u) across confirmed sessions
TotalReceived(c, u) ==
    LET recvs == { <<db, sc, s>> \in BRIDGES \X CHAINS \X SESSIONS :
                       /\ SessionDone(s)
                       /\ inbox[db, sc, c, u, u, s, "SEND"] # Empty
                       /\ inbox[db, sc, c, u, u, s, "SEND"].consumed = TRUE }
    IN SumFunction([key \in recvs |->
                       inbox[key[1], key[2], c, u, u, key[3], "SEND"].amount])

\* Aborted sessions clear their mailbox entries (SendAbort / RecvAbort), so
\* TotalSent / TotalReceived only ever count confirmed sessions.
BalancesConsistentWhenAllDone ==
    AllSessionsTerminal =>
        \A c \in CHAINS, u \in USERS :
            accountBalances[c, u] = INITIAL_BALANCE + TotalReceived(c, u) - TotalSent(c, u)

\* Capital conservation: nothing is minted or burned, including on abort paths
\* that BalancesConsistentWhenAllDone cannot see.
TotalSupply ==
    SumFunction(accountBalances) + SumFunction(bridgesTokenBalances)

SupplyConservedAtEnd ==
    AllSessionsTerminal =>
        TotalSupply = Cardinality(CHAINS) * Cardinality(USERS) * INITIAL_BALANCE
        
(*************************************************************************)
(* Fairness, Done, Next and Spec                                         *)
(*************************************************************************)

Fairness ==
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(SendAbort(sc, dc, u, v, s, sb, db))
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(RecvAbort(sc, dc, u, v, s, sb, db))
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(SeqRelay(sc, dc, u, v, s, sb, db))
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(SeqRelayAck(sc, dc, u, v, s, sb, db))
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(SendConfirm(sc, dc, u, v, s, sb, db))
    /\ \A sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
          WF_vars(RecvConfirm(sc, dc, u, v, s, sb, db))

Done ==
    /\ \A s \in SESSIONS :
        generalSessionStates[s] = "aborted" \/ generalSessionStates[s] = "confirmed"
    /\ \A chain \in CHAINS, s \in SESSIONS :
        LET state == chainSessionStates[chain, s]
        IN state = "aborted" \/ state = "confirmed" \/ state = "unprocessed"
    /\ UNCHANGED vars

Next ==
    \* Clock ticks
    \/ \E s \in SESSIONS : SPTick(s)
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainTick(chain, s)
    \* Timeouts
    \/ \E s \in SESSIONS : SPTimeout(s)
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainTimeout(chain, s)
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainSkipDecision(chain, s)
    \* Simulation phase
    \/ \E sc, dc \in CHAINS, u, v \in USERS, t \in TOKENS,
          a \in 0..MAX_AMOUNT, s \in SESSIONS, sb, db \in BRIDGES :
        Send(sc, dc, u, v, t, a, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS,
          s \in SESSIONS, sb, db \in BRIDGES :
        SeqRelay(sc, dc, u, v, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS,
          s \in SESSIONS, sb, db \in BRIDGES :
        SeqRelayAck(sc, dc, u, v, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS, t \in TOKENS,
          a \in 0..MAX_AMOUNT, s \in SESSIONS, sb, db \in BRIDGES :
        Recv(sc, dc, u, v, t, a, s, sb, db)
    \* 2PC voting phase
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainStart(chain, s)
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainVoteConfirm(chain, s)
    \/ \E chain \in CHAINS, s \in SESSIONS : ChainVoteAbort(chain, s)
    \* Shared publisher decision
    \/ \E s \in SESSIONS : SPStartTransfer(s)
    \/ \E s \in SESSIONS : SPDecideConfirm(s)
    \/ \E s \in SESSIONS : SPDecideAbort(s)
    \* Post-decision phase
    \/ \E sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
        SendConfirm(sc, dc, u, v, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
        SendAbort(sc, dc, u, v, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
        RecvConfirm(sc, dc, u, v, s, sb, db)
    \/ \E sc, dc \in CHAINS, u, v \in USERS, s \in SESSIONS, sb, db \in BRIDGES :
        RecvAbort(sc, dc, u, v, s, sb, db)
    \/ Done

Spec == TPInit /\ [][Next]_vars /\ Fairness

=============================================================================