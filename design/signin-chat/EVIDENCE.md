# Bằng chứng · LM-SC-01

Tài liệu này ghi bằng chứng giai đoạn preview. Human đã duyệt LM-SC-01 và cho
phép triển khai native ngày 2026-10-13. Checkpoint chờ duyệt bên dưới là lịch sử.
Kết quả triển khai và kiểm chứng mới nằm trong `docs/STATUS.md`.

## Phân loại

| Loại | Nguồn | Kết luận được phép |
| --- | --- | --- |
| Runtime đã lưu | Cleanup, 2026-10-13 03:26–03:31 UTC | Account signed-out và Chat disabled đã được quan sát ở bundle cũ ghi bên dưới. |
| Suy luận từ code | Base `8b791b7ca6caf0b9fcbcd8fc224c68c456efb1a0` | Luồng và điều kiện được mô tả trong README; không chứng minh UI thật hoạt động. |
| Mockup | `preview.html` và chín PNG cạnh file | Thiết kế đề xuất, dữ liệu mẫu. Không phải ảnh của LessMeet.app. |
| Runtime preview | Chrome mở file local, 2026-10-13 04:48–04:55 UTC | Một số control HTML đã được bấm và quan sát. Không có auth/chat thật. |

## Quy trình app-check và version

Đã đọc cả hai bản skill; không chép bản main vào workspace.

- Workspace `.agents/skills/lessmeet-app-check/SKILL.md` tại base 8b791b7:
  SHA256 `a5f1607d6b8ab7931d8835dc6f025693417feaebab5bb7e0d1c450489631f33e`.
- Bản main hiện hành tại
  `/Users/tubakhuym/projects/lessmeet/.agents/skills/lessmeet-app-check/SKILL.md`:
  SHA256 `befb2e063499d5f8976d054318550e19859535c4e040551c2ce1d5014ea2470d`.
- Session này không có `mcp__cua_repl__js`; có `mcp__node_repl__js`.
  Đã đọc đầy đủ Computer Use skill từ bundled marketplace được tìm thấy trong catalog local:
  `/Users/tubakhuym/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/skills/computer-use/SKILL.md`.
  SHA256 `e6a2b212bacad8d16a9a07e2fef5d428ea00c7b9a8f8529bec1bd2ba48a49c4f`.
- Dùng đường fallback được bản main cho phép: `node_repl` + `@oai/sky`.
  Không cài automation stack khác. Không mở LessMeet.app trong tác vụ này.

Skill yêu cầu phân biệt bằng chứng UI thật với suy luận. Vì vậy bản vẽ dùng ảnh
cleanup làm baseline, còn kiểm tra mới chỉ áp dụng cho preview offline.
Tại thời điểm bàn giao preview, UI native mới là **UNVERIFIED** vì chưa triển khai.

## Baseline đã quan sát

Đọc trực tiếp, không phục hồi toàn bộ backup:

`/Users/tubakhuym/lessmeet-backups/cleanup-20261013.o0nk81/retained-cleanup/.artifacts/cleanup/runtime/`

- `RESULT.md` ghi bundle `dist/local/LessMeet.app`, executable SHA256
  `7f150840f82c7a2993c8c1389f7f030c6178352618d9f81694867c5c2406b274`.
- Đã xem `12-account.png`: sheet signed-out có Continue with ChatGPT, Add account,
  Sign out và Manage usage cùng hiện trên một vùng nhỏ.
- Đã xem `14-chat-signed-out.png`: vùng history trống lớn; các dòng trạng thái,
  model, disclosure, editor và Send tập trung ở đáy; model và Send bị vô hiệu hóa.
- Đây là bằng chứng lịch sử của cleanup. Không chạy lại scenario hoặc suy ra
  rằng OAuth, model catalog hay chat có mạng đã được kiểm tra.
- Ảnh raw có thể chứa metadata thư viện. Không sao chép vào artifact thiết kế.

Handoff retained ghi cleanup, commit/push và hosted build hoàn tất tại 8b791b7.
Run `38342265359` SUCCESS lúc 03:40:27 UTC. Tác vụ preview chỉ hòa giải status;
không gọi lại workflow, không push và không xác minh remote lần nữa.

## Kiểm tra preview mới

Môi trường: macOS 26.4, Chrome 155.0.8059.40, Node v22.22.3.
HTML candidate SHA256:
`207a39ece311a8478cad1b1fb0cb740a21f0e27c79e09d3fec1f89f4da9209d7`.

| Kiểm tra | Kết quả quan sát |
| --- | --- |
| `check-preview.mjs` | PASS 20 trạng thái; disclosure, welcome không có Done, send gating, draft editable khi busy, escaping và không có network entry point. Đây là kiểm tra DOM giả trong Node, không phải browser test. |
| Export PNG | PASS chín ảnh từ Chrome headless, profile tạm riêng. Không dùng profile cá nhân. Trang chỉ đọc HTML và logo local. |
| Xem ảnh | Đã xem cả chín PNG. Light/dark, disclosure, model controls và primary action đọc được. |
| Cửa sổ mặc định | Bản vẽ app 1180 × 760 trong ảnh 1360 × 960. Composer và playback đều nằm trong cửa sổ. |
| Cửa sổ tối thiểu | Bản vẽ app 1000 × 640 trong ảnh 1064 × 840. History cuộn độc lập; composer và disclosure còn thấy. Không phải bằng chứng layout SwiftUI. |
| Click Continue with ChatGPT | PASS chỉ đổi sang hình “Continue in your browser.” Không mở OAuth. |
| Click Cancel sign-in | PASS về trạng thái signed-out của mockup. |
| Draft trống → nhập câu mẫu | PASS Send từ disabled sang enabled trong mockup. |
| Click Send giả lập | PASS hiện “Incomplete answer · not saved”, Cancel; Send và model disabled; draft vẫn hiện. |
| Click Cancel khi trả lời | PASS bỏ partial, trở về lịch sử mẫu và giữ draft “Summarize this sample meeting.” |
| Diff phạm vi | Không đổi `Sources`, test sản phẩm, package hoặc workflow. Chỉ `design/signin-chat/` và `docs/STATUS.md`. |

Đã xem screenshot runtime preview sau click Send. Bản raw riêng tư được giữ ở
`.artifacts/signin-chat-preview/streaming-browser.png`, đã kiểm tra là ignored.
Không đưa browser chrome hoặc dữ liệu phiên cá nhân vào PNG bàn giao.
Lần đọc trạng thái browser đầu tiên trả metadata của tab đang mở ngoài phạm vi.
Không dùng hoặc chép metadata đó vào tài liệu/ảnh. Các thao tác sau chỉ ở cửa sổ
riêng chứa file preview local. Không thao tác tài khoản hoặc tab ngoài phạm vi.

Một export đầu bị cắt phần footer do chiều cao tối thiểu của CSS grid.
Đã sửa `grid-template-rows: minmax(0,1fr)` và `min-height:0`, xuất lại và xem ảnh.
Kết quả đầu là lỗi layout đã sửa, không phải PASS. Chrome cũng in diagnostic
`CVDisplayLinkCreateWithCGDisplay failed`; export vẫn kết thúc 0 và tạo ảnh đọc được.

## Kiểm tra độc lập

- ACCEPT checklist source trên base `8b791b7ca6caf0b9fcbcd8fc224c68c456efb1a0`
  làm đầu vào thiết kế. Lý do: điều kiện consent, chọn model, quyền sở hữu lịch sử
  và câu trả lời chưa lưu khớp code được kiểm tra. Phạm vi chỉ đọc đã đóng.
- Kiểm tra độc lập đã đối chiếu HTML candidate ghi ở trên và README SHA256
  `a115f656cadfebc471a6802aa394da9892f728a97b4ef5cece5c62dc50d46ff6`.
  Đã xem `signin.png`, `chat.png`, `chat-compact.png`, `chat-error.png` và
  `chat-streaming.png`; đối chiếu các view/model trong README; chạy lại
  `check-preview.mjs` với 20 trạng thái PASS.
- ACCEPT kết quả kiểm tra giới hạn này: không có lỗi cần sửa candidate trước
  khi duyệt. LM-SC-01 đủ làm tài liệu xem trước. Checkpoint chờ duyệt lúc đó đã
  được quyết định triển khai nêu trên thay thế. Phạm vi kiểm tra đã đóng;
  quyền triển khai đến từ quyết định mới, không đến từ kết quả kiểm tra này.
- Kết luận này chỉ nói về bản vẽ và ý nghĩa trạng thái. Không thay thế quyết định
  thẩm mỹ của Human hoặc kiểm tra native sau khi có quyền triển khai.

## Tham khảo và giới hạn

Đã thử mở `https://mobbin.com/browse/macos/apps` qua công cụ web. Công cụ trả
“URL ... is not accessible via this tool.” Không truy cập được thư viện Mobbin;
không mua dịch vụ, không vượt paywall. Dùng code, ảnh retained và `docs/DESIGN.md`.

Chưa kiểm tra native rendering, VoiceOver, text scaling, increased contrast,
auth thật, catalog thật, stream thật, save/reopen hoặc acoustic quality.
Không login, gửi chat thật, upload recording, gọi API model, deploy, release,
push hay sửa cấu hình toàn cục. Không sửa main hoặc phục hồi backup.
Giữ các mục **UNVERIFIED** này riêng với quyền duyệt bản thiết kế.

## Bằng chứng native mới · LM-SC-NATIVE-01

Base: `8b791b7ca6caf0b9fcbcd8fc224c68c456efb1a0`.
Source manifest: `NATIVE-SHA256SUMS`, SHA256
`668814a6ebeea6f35c51f26407008bf3a6939b1bd98a15b4c44404aabf3fa21d`.
Đối chiếu từ root repository. Candidate chưa commit; không push hoặc merge.
HTML đã duyệt và chín PNG giữ nguyên byte. Nghiệm thu ghi tại `docs/STATUS.md`.

### Build và tests

Môi trường: macOS 26.4, arm64, Apple Swift 6.3.3, Swift Build, Metal compiler
32023.883. Hai lệnh build trả exit 0 và `codesign --verify --strict` thành công:

- `LESSMEET_SIGNING_IDENTITY=- bash scripts/build-app.sh local`
- `bash scripts/build-app.sh chat-ui-check`

Bundle thường `dist/local/LessMeet.app` chưa chạy. Executable SHA256:
`06a9a997cca7cd7b9a599541e452754081e4940351864c936e7b5d5a7e694d8b`.
Bundle đã quan sát: `dist/chat-ui-check/LessMeet.app`, ID
`com.lessmeet.app.chat-ui-check`. Executable SHA256:
`329d4f6d2616737696be55e7a7ac957ea2c05777df4525ad68ce2505cb653136`.
Info.plist SHA256: `3493c2e950319700d7bf396361c372d15f758ebfa3d22cfab9e677a7b9a53266`.
Không có service configuration hoặc OAuth URL callback trong bundle thử.

PASS 138 XCTest, zero failures:

```sh
swift test -c release --build-system swiftbuild --arch arm64 \
  --disable-keychain --disable-netrc --scratch-path dist/local/swift-build \
  --filter 'ChatGPTAuthTests|ResponsesClientTests|ResponsesFinalizedOutputTests|ChatGPTChatIntegrationTests|LocalChatModelTests|LocalPivotIntegrationTests|RecordingStoreTests|RecordingFinalizationTests|ChatTextEditorTests'
```

PASS 21 tests đóng gói: `python3 -m unittest discover -s Tests/packaging -p test_agent_checks.py`.
Các tests dùng dữ liệu tạm và transport giả. Auth tests có callback loopback
synthetic; không phải OAuth thật. Build có warning cũ về
`kSecUseAuthenticationUIFail` deprecated; không có lỗi build.
Log lưu trong `.artifacts/signin-chat/`. Kiểm tra độc lập chỉ đọc đã xác nhận
11 file source không trôi hash và không tìm thấy hồi quy chức năng/safety mới.

### Quan sát native

Đã dùng `lessmeet-app-check`, `verify-lessmeet` và Computer Use qua `@oai/sky`.
Chúng yêu cầu quan sát đúng bundle và tách bằng chứng runtime khỏi tests.
Khoảng UTC: 2026-10-13 05:22:21–05:28:38. Một người vận hành UI duy nhất.
Evidence: `.artifacts/signin-chat/native/`, gồm `identity.txt`, `actions.jsonl`,
46 cặp screenshot/accessibility, file chat mẫu và kiểm tra cleanup.
Các ảnh dưới đây là native. Chín PNG preview ở thư mục thiết kế vẫn là mockup.

| Kịch bản | Kết quả quan sát | Evidence trong thư mục native |
| --- | --- | --- |
| Signed-out | Một CTA, disclosure trước nút; sheet 490 × 608, không cắt nội dung | `02-account-signed-out` |
| Waiting, Done, reopen, Cancel | Done không hủy; mở lại vẫn chờ; Cancel về signed-out | `03`–`07` |
| Consent thiếu | Account có Enable ChatGPT plan usage; Chat khóa Load models/Send | `09`, `10` |
| Welcome | Hiện usage; Escape không bỏ qua; Got it đóng welcome | `14`–`16` |
| Connected, Back to chat | Profile mẫu hiện; Back to chat đóng sheet | `16`, `17` |
| Load/select và gợi ý | Load không tự chọn model; gợi ý chỉ điền draft; Send còn khóa đến khi chọn model | `18`–`21` |
| Return / ⌘Return | Return thêm dòng; ⌘Return gửi câu hỏi mẫu và xóa draft sau lưu | `22`, `23` |
| Lưu và đọc lại | `chat.json` có đúng cặp hoàn tất; Reopen đọc lại cùng nội dung | `chat-after-completion.json`, `24` |
| Streaming và Cancel | Hiện Incomplete answer, khóa model/Send; draft vẫn sửa được; Cancel bỏ partial và giữ draft mới | `28`–`30` |
| Lỗi request | Hiện safe error HTTP 503; giữ draft và lịch sử | `33` |
| Light/dark | Đã xem screenshot của Chat và Account; text, logo, controls, disclosure đọc được | `02`, `23`, `34`, `36` |
| Cửa sổ nhỏ | Fixture 820 × 668, content cao 640; composer/disclosure không bị cắt; history cuộn riêng | `35`, `44` |
| Đổi/thêm account | Chỉ đổi lựa chọn picker; profile đang kết nối chưa đổi | `37`, `38` |
| Transcript callback | Mở sheet transcript mẫu; không chạy transcription | `40` |
| Signed-out có history | Lịch sử còn đọc được; Send và model bị khóa | `43`, `44` |

`cmp` xác nhận `chat.json` không đổi trong partial, sau Cancel, sau lỗi và sau
đổi fixture về signed-out. Đây là lưu/đọc lại trong cùng lần chạy, không phải
kiểm tra full app quit/relaunch. Nội dung do transport cố định tạo, không phải AI thật.

`lsof` trước/sau không thấy network socket hoặc handle tới thư viện recording thật.
Đây là kiểm tra tại hai thời điểm, không phải packet trace. Bằng chứng isolation
chính là entry compile-time riêng, memory credentials và transport/listener/browser
giả tại các điểm nối sẵn có. Không đọc credentials hoặc recording thật để kiểm tra.
Đã phục hồi light/window size, quit đúng bundle và xác nhận process không còn.
Không xóa bundle, dữ liệu mẫu hoặc evidence. Live UI ownership đã được trả lại.

### Giới hạn native còn lại

- Full Library/runtime shell và production 1000-point minimum width: **UNVERIFIED**.
  Bản thường không chạy vì startup đọc credential store thật. Fixture dùng view
  sản phẩm nhưng không dựng lại toàn bộ Library hoặc mọi điều kiện của shell.
- OAuth, real catalog/chat/stream, token refresh/revocation, account switching thật,
  sign-out failure/retry thật, acoustic quality: **UNVERIFIED** và chưa được cấp quyền.
- Full quit/relaunch với cùng dữ liệu, đổi recording trong UI, recording-active UI,
  tên rất dài, VoiceOver, full keyboard traversal, text scaling, increased contrast:
  **UNVERIFIED**. Tests không thay thế các quan sát này.
- Lỗi copy cũ: mở lại Account khi sign-out đang chạy có thể hiện hướng dẫn browser
  và Cancel sign-in. Nút đó không hủy sign-out hoặc khôi phục access. Không coi là PASS.
- Native offline không thay thế kiểm chứng live. Không có quyền push, merge,
  deploy, release, upload hoặc sửa cấu hình toàn cục từ nghiệm thu này.
