# Chat virtualization invariants

Short conversations keep their complete DOM and existing geometry. Once a
conversation exceeds 60 messages, Alice renders only the viewport plus 640 px
of overscan on either side.

The virtual layout obeys these invariants:

- Message order is immutable and keyed by message id.
- Estimated heights are replaced by measured heights from `ResizeObserver`.
- Every row starts at the previous row's end; rows cannot overlap or leave gaps.
- Height changes above the viewport compensate `scrollTop` to preserve the
  reader's visual anchor.
- New messages move to the end, while streaming updates follow the response only
  when the reader has not intentionally scrolled away.
- Conversation changes discard measurements; secrets and content never enter
  the layout cache.

The pure range calculations are tested with 10,000 messages. Browser coverage
loads a real 500-message conversation, checks that fewer than 30 message nodes
are mounted, and verifies navigation from the final message back to the first.
