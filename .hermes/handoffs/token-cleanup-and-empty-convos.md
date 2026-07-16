# Handoff: Token Display & Empty Conversation Cleanup

## Context

ZiroEdge is a privacy-first local AI assistant for iOS. The model (Gemma 4 E2B) is now responding correctly through the chat UI after three fixes: seq_id malloc bug, prompt format, memory budget bypass. This handoff covers two remaining polish issues.

---

## Issue 1: Stop tokens leak into displayed response

### Current behavior
The model response shows special tokens in the chat: `Hi<end_of_turn` instead of `Hi`. The trailing stop token fragments (`<`, `end`, `_`, `of`, `_`, `turn`) leak into the user-visible output.

### Root cause
In `LlamaEngine.swift:streamCompletion()`, the autoregressive loop at line 229-273:

```swift
let tokenText = tokenToText(token: newTokenID, vocab: vocab)  // e.g., "<"
generatedText += tokenText                                    // accumulates "Hi<end..."

// Check stop strings like "<end_of_turn>"
for stop in stopStrings {
    if generatedText.hasSuffix(stop) {  // triggers when full stop string matches
        shouldStop = true
        break
    }
}
if shouldStop { break }    // breaks WITHOUT yielding the current token

continuation.yield(tokenText)  // earlier tokens (like "<", "end", "_") WERE yielded
```

The stop check happens on `generatedText.hasSuffix(stop)`. A multi-token stop string (like `<end_of_turn>`) leaks partial fragments into the yield stream because:
- Individual tokens `<`, `end`, `_`, `of`, `_`, `turn` don't individually match the stop string
- They get yielded through `continuation.yield(tokenText)`
- Only the final `>` triggers the hasSuffix match, and the loop breaks without yielding it

Result: the stream yields `["Hi", "<", "end", "_", "of", "_", "turn"]` — the user sees `Hi<end_of_turn`.

### What needs to change

The fix should happen in `streamCompletion()` in the engine (`/Users/irellzane/Work/ziroedge/Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift`), NOT in the UI layer, because this is a general inference issue (affects all models with multi-token stop strings).

**Approach A — Post-generation strip (simplest):**
After the generation loop exits (whether by EOS, stop string, or maxTokens), compute the clean text by stripping any trailing stop string from `generatedText`, then yield the stripped portion.

```swift
// After the while loop exits, before continuation.finish():
// Strip any trailing stop string from the accumulated text
var cleanText = generatedText
for stop in stopStrings {
    if cleanText.hasSuffix(stop) {
        cleanText = String(cleanText.dropLast(stop.count))
        break
    }
}
// Yield the clean remainder if any un-yielded tokens exist
```

This is simple but may not work if there are tokens yielded AFTER the stop string starts forming (which shouldn't happen in practice since the stop string tokens are consecutive).

**Approach B — Buffer before yielding (more robust):**
Instead of yielding tokens immediately, buffer them and only yield when we're confident they're not part of a stop string. This is more complex but handles edge cases better.

```swift
var pendingBuffer = ""  // buffer of un-yielded tokens
var tokenText = tokenToText(...)
pendingBuffer += tokenText

// Check if pendingBuffer ENDS WITH any stop string
var hasStop = false
for stop in stopStrings {
    if pendingBuffer.hasSuffix(stop) {
        hasStop = true
        // Remove the stop string from pendingBuffer and yield the rest
        let clean = String(pendingBuffer.dropLast(stop.count))
        if !clean.isEmpty { continuation.yield(clean) }
        break
    }
}
if hasStop { break }

// Check if any stop string is a SUBSTRING of what we've buffered.
// If so, hold the buffer. Otherwise, safe to flush.
var shouldBuffer = false
for stop in stopStrings {
    if pendingBuffer.contains(stop.prefix(min(pendingBuffer.count, stop.count))) {
        shouldBuffer = true
        break
    }
}
if !shouldBuffer {
    continuation.yield(pendingBuffer)
    pendingBuffer = ""
}
```

**Recommendation:** Start with Approach A for simplicity. The engine's stop check already prevents yielding after a stop match. We just need to strip the trailing stop from what was already yielded.

**File to modify:** `/Users/irellzane/Work/ziroedge/Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift`

**Also apply the same fix to:** `streamVisionCompletion()` (same pattern, line ~285+)

---

## Issue 2: Empty conversations saved to sidebar

### Current behavior
The sidebar shows stale "New Conversation" entries with "0 messages" that were created but never used. These accumulate over repeated app launches and UI test runs.

### Root cause
Every time the user taps "New Conversation" (or the sendtest handler fires), `PersistenceController.createConversation()` is called and the conversation is immediately saved to Core Data — **before** any message is sent.

Looking at the callers:
- `ZiroEdgeApp.swift:171` — `onNewConversation` handler
- `ZiroEdgeApp.swift:116` — `--uitesting-sendtest` handler
- `ChatViewModel.swift:161` — `createNewConversation()`
- `ConversationListViewModel.swift:43` — `createConversation()` (calls persistence directly)

All of these create a Core Data insert BEFORE the user has sent any message. If the user backs out, the empty conversation persists forever.

### What needs to change

**Option A — Defer save until first message (least disruptive):**
Don't persist the conversation to Core Data until the first message is sent. Track a "pending" conversation ID in memory, and only insert into Core Data when `sendMessage()` succeeds.

Requires changes to:
- `PersistenceController.createConversation()` — add a `deferSave: Bool` parameter
- `ChatViewModel.sendMessage()` — if conversation is pending, persist it before inserting the message
- `ZiroEdgeApp.swift` onNewConversation — pass `deferSave: true`

**Option B — Cleanup on app launch (simpler, no refactor):**
Add a `purgeEmptyConversations()` call in the `.task` block of `ZiroEdgeApp`. After model loads, delete any conversations with 0 messages.

Requires:
- `PersistenceController.purgeEmptyConversations()` — fetch conversations with message count = 0 and delete them
- Call it in `ZiroEdgeApp.swift` `.task` after model auto-load

**Option C — Delete on dismiss (also simple):**
When the user backs out of a conversation without sending a message, delete it. Requires tracking whether any message was sent during the conversation's lifetime.

**Recommendation:** Start with Option B (launch cleanup) as the quick fix, then implement Option A (defer save) as the proper long-term solution.

**Files to modify:**
- `/Users/irellzane/Work/ziroedge/ZiroEdge/Persistence/PersistenceController.swift` — add purgeEmptyConversations
- `/Users/irellzane/Work/ziroedge/ZiroEdge/ZiroEdgeApp.swift` — call purgeEmptyConversations in .task

---

## Verification

After implementing:
1. Run `DirectInferenceTest.testGemmaResponds` — response should show `"Hello"` not `"Hello<end_of_turn"`
2. Run `ChatFlowDiagnosticTest.testFullChatFlowWithResponse` — same verification
3. Launch app on device, create a conversation, back out without sending — conversation should NOT appear in sidebar
4. Create a conversation, send a message — conversation should appear with message count > 0

## Key files

| File | Purpose |
|------|---------|
| `Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift` | Engine — fix stop token stripping |
| `ZiroEdge/Persistence/PersistenceController.swift` | Core Data — add purgeEmptyConversations |
| `ZiroEdge/ZiroEdgeApp.swift` | App entry — call purgeEmpty + onNewConversation fixes |
| `ZiroEdge/ViewModels/ChatViewModel.swift` | Chat logic — sendMessage flow |
| `ZiroEdge/ViewModels/ConversationListViewModel.swift` | Sidebar — conversation CRUD |

## Project map (from AGENTS.md)

- `ZiroEdge/` — main app target
- `ZiroEdgeTests/` — unit tests (use ZiroEdge scheme)
- `ZiroEdgeUITests/` — UI tests (use ZiroEdgeUITests scheme)
- `Packages/swift-llama-cpp/` — SPM package wrapping llama.cpp b9821
- Build: `xcodegen generate` then `xcodebuild build-for-testing -scheme ZiroEdge -destination 'id=00008140-000178A1362B001C' -allowProvisioningUpdates`
- Test: `xcodebuild test-without-building -scheme ZiroEdge -destination 'id=00008140-000178A1362B001C' -allowProvisioningUpdates -parallel-testing-enabled NO -only-testing:ZiroEdgeTests/DirectInferenceTest/testGemmaResponds`

## Device
UDID: `00008140-000178A1362B001C` — iPhone 16 (iOS 26.5.2)
Must be unlocked for build/test. Kill stale `lldb-rpc-server` processes before building.

---

## Implementation Notes (2026-07-16)

### Issue 1: Stop tokens — IMPLEMENTED

Approach taken: **Buffered streaming** (hybrid of Approaches A+B).

Instead of yielding tokens immediately, tokens are accumulated in `pendingBuffer`. On each token:

1. If `pendingBuffer.hasSuffix(stop)` — strip the stop, yield clean remainder, clear buffer, break.
2. If any stop string has `prefix(pendingBuffer)` — hold (stop string may be forming).
3. Otherwise — flush and clear buffer.

After loop exit (EOS, maxTokens, cancellation), any remaining buffer is flushed.

**Critical bug found during implementation:** When a stop matched, the stop was stripped from a local `clean` variable for yielding, but `pendingBuffer` itself was never cleared. The post-loop flush then yielded the full buffer including the stop string. Fixed by adding `pendingBuffer = ""` after the stop strip.

**Files modified:**
- `Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift` — `streamCompletion()` and `streamVisionCompletion()`

**Verification:**
- `DirectInferenceTest.testGemmaResponds`: response was `Hi` (2 chars) instead of `Hi<end_of_turn>` (15 chars).
- All 200 ZiroEdgeTests pass (0 failures).

### Issue 2: Empty conversations — IMPLEMENTED

Option B (launch cleanup) with `purgeEmptyConversations()`:
- Uses `NSPredicate(format: "messages.@count == 0")` to find stale conversations.
- Called in `ZiroEdgeApp.swift` `.task` block after `recoverIncompleteStreams()`.

**Files modified:**
- `ZiroEdge/Persistence/PersistenceController.swift` — added `purgeEmptyConversations()`
- `ZiroEdge/ZiroEdgeApp.swift` — call `purgeEmptyConversations()` on launch
