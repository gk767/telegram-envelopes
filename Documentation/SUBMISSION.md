# Suggested Telegram Designers submission

**Envelopes for Telegram iOS**

Send an envelope directly in a private chat. Choose an amount, add a note and an optional opening effect. The recipient opens it to reveal the amount, while the sender sees it unfold in the same chat.

Native Swift/UIKit implementation with Telegram attachment and message-card integration, shared envelope artwork, recipient-only opening, idempotent state transitions and a reproducible two-account test service.

Code and setup: https://github.com/gk767/telegram-envelopes

Animation preview: Media/opening-effect.mp4 (shared rendering component, without private chats). Add the approved final full-app send/open video before the public channel submission.

The current wallet service uses simulated balances. Production integration needs Telegram's own message and settlement APIs. This is an unofficial feature proposal.
