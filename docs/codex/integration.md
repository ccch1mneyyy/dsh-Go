# Codex SSH backend

Select Codex when adding an SSH host. The existing chat UI, session drawer,
Markdown renderer, attachment picker, file preview, search page and usage sheet
are reused. DSH connections retain their existing behavior.

## Connection and account

The connection runs the installed `codex app-server proxy` over a verified SSH
transport. It does not start a new daemon or change server credentials. Model
requests use the server account, independently of any phone ChatGPT login.
Default binary/socket paths are derived from the configured SSH username;
custom installation paths can be entered in the host form.

## Supported features

- Session list/history, new conversations, rename, archive/restore, streaming,
  interrupt and steer; command/file approvals and user-input questions.
- Image and file upload over the same SSH connection (SFTP). Images use Codex
  localImage input; regular files are referenced by server path, subject to the
  existing server execution permissions. Uploads are stored in the SSH user's
  `.dsh-go-uploads` directory with random subdirectories and restrictive modes.
- Markdown images/file links, image-generation output and dynamic-tool image
  results use the existing preview/save/share UI. Uploaded files are retained
  so history references remain usable; deleting a server file breaks its download.
- Conversation search combines existing local title matches with server-side
  user/assistant text scans. Python 3 is required. Scans have a 7-second budget,
  a 100-result cap and a per-line limit; incomplete results are explicitly labeled.
- Session tokens/context come from Codex usage notifications and persisted usage
  records. Account quota windows come from account/rateLimits/read and can be
  refreshed. Unknown values and prices are not estimated.

## Boundaries

No DSH engine, plugins or desktop-only dynamic tools are executed by the adapter.
Displaying a desktop tool result does not mean the phone can execute that tool.
Queueing, branching/regeneration, voice, remote directory browsing and Office
server conversion are not implemented. Codex retains a live subscription in the
background because it does not support DSH's quiet-watch option.

Original picker limits remain: images 20 MiB, files 30 MiB, nine attachments per
message. Gallery/camera processing follows the existing picker; file selections
preserve their bytes. Downloads use bounded windows and the existing 300 MiB cap;
image previews have smaller limits. UTF-8 text preview is limited to 2 MiB;
larger text can be downloaded and opened externally.

The protocol was checked against Codex app-server 0.166.0 without experimental
API enablement. Future protocol versions need compatibility checks. Reconnects
reload history but cannot resurrect unresolved approval IDs not resent by the
server. Unknown send outcomes are not automatically retransmitted.

## Validation

The development implementation passed 182 relevant App tests, 25 backend tests
and 12 client tests, plus static analysis. Live SSH/SFTP and Codex checks covered
upload/download byte equality, model file reading, image history, token usage,
quota and search. These results do not replace device validation after changes.

Useful checks from the repository root:

```sh
(cd packages/codex_backend && dart test && dart analyze)
(cd packages/codex_client && dart test && dart analyze)
(cd app && flutter analyze && flutter test test/remote/codex_integration_test.dart)
```

Third-party WebSocket framing sources and licenses remain under codex_client's
vendor directory and THIRD_PARTY_NOTICES.md. Only synthetic fixtures and widget
screenshots are included; private operational logs and live probes are excluded.
