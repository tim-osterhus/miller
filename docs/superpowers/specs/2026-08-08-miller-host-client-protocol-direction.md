# Miller host and client protocol direction

**Status:** Architecture direction for v0.1.2 and later.
**Baseline:** Miller v0.1.1.
**Purpose:** Keep current feature work compatible with future desktop, web,
and mobile clients without building distributed infrastructure prematurely.

## Decision

Miller should have one account-local runtime authority and one or more
presentation clients. Clients must not synchronize separate Miller databases
or copy provider credentials among devices.

The next architectural seam is `MillerHost`: a composition boundary around the
authoritative runtime that already exists inside the desktop application. It
should begin in-process. A daemon, XPC service, network transport, or mobile
client is justified only when a real second client needs it.

## Ownership

### MillerCore

Owns portable identities, value types, contracts, and state machines. It does
not become an application service locator.

### MillerStorage

Owns the authoritative SQLite store for conversations, turns, Live transcript
entries, provider profiles, capability policy, and audit records.

### MillerGateway and MillerLive

Own provider and Live protocol adapters. They do not become client APIs and do
not own durable conversation authority.

### MillerCapabilities

Owns capability discovery, policy, approval, bounded execution, and audit. Its
existing private RPC remains a narrow provider-bridge protocol.

### MillerHost

Composes storage, providers, Live sessions, capabilities, approvals, and
notifications behind one human-client contract. It owns admission and terminal
state across those subsystems.

### Presentation clients

The macOS application, a future responsive web client, and any later native
mobile client render state and submit intent. They do not own provider secrets,
MCP connections, or a competing conversation database.

## Keep the two protocols separate

### Capability RPC

The existing capability RPC is an internal Unix-socket bridge for admitted
provider tool calls. It should remain narrow, local, and private. It must not be
generalized into the desktop or mobile API.

### Miller Client Protocol

The separate human-facing protocol should eventually cover:

- List, create, open, and delete conversations.
- Submit and cancel turns, and receive ordered turn events.
- Prepare, start, steer, mute, interrupt, and stop Live sessions.
- Receive ordered typed and Live transcript events.
- List capabilities and request allowed invocations.
- Receive, approve, or reject correlated action proposals.
- Inspect provider, connection, and readiness state.
- Receive bounded notifications and delegated-work status.

The first implementation should be ordinary in-process Swift protocols and
types. Transport framing belongs in a later task.

## Required invariants

- SQLite has one writer authority.
- Every mutation has a stable request ID and generation.
- Events are ordered and replayable from a bounded cursor where required.
- Cancellation and terminal state are idempotent.
- Approval accepts exactly one correlated decision. Stale responses fail
  closed.
- Pending changing actions fail closed across host restart.
- Credentials and raw provider authentication never cross the client protocol.
- File attachments use opaque IDs and scoped grants, never host paths.
- Capability results, transcript events, and errors remain bounded.
- The WebRTC media path remains direct whenever the client can carry it.
- Raw audio does not transit the host merely to centralize architecture.

## Extraction sequence

### 1. In-process host

Route the current macOS presentation layer through `MillerHost` interfaces.
Keep behavior and process topology unchanged. Add contract tests around ordered
events, generations, cancellation, approvals, and cleanup.

### 2. Local transport

When a second local client exists, place the host behind XPC or a private Unix
socket. Preserve the same semantic contract and add authentication, framing,
backpressure, and reconnect tests at that boundary.

### 3. Paired remote transport

When remote access becomes a committed feature, add a paired, authenticated,
encrypted transport. The account-local host remains authoritative. A phone or
browser should not receive provider, Codex, OAuth, Keychain, or MCP secrets.

### 4. Mobile proof order

Prove text, status, and approvals in a responsive web client first. Then prove
remote Live signaling with client-carried WebRTC media. Build a native iOS
client only if platform integration justifies it.

## Near-term application to v0.1.2 and v0.1.3

The v0.1.2 Live-text spike should express inputs and ordered events through the
future host seam even while it remains in-process. The v0.1.3 attachment store
should remain host-owned and expose opaque attachment capabilities to clients
and providers.

This does not authorize a daemon extraction, cloud relay, user-account system,
multi-tenant service, database synchronization, or mobile application. Those
require separate product decisions and execution plans.

## Readiness gate for implementation packets

Before compiling tasks from this direction:

1. Map each proposed contract to current source ownership.
2. Validate the supported Codex App Server protocol version and message shapes.
3. Identify the smallest behavior-preserving in-process seam.
4. Define deterministic contract and migration tests.
5. Keep process or network extraction out of scope unless the task has a real
   second client.
