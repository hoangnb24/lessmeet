# LessMeet · Sign-in & Chat · Đề xuất 01

Candidate: **LM-SC-01**. Human đã duyệt bố cục, hướng màu và nội dung ngày
2026-10-13. HTML và PNG là bản vẽ, không phải ảnh UI sản phẩm.
Base: `cleanup/post-pivot-20261013` tại
`8b791b7ca6caf0b9fcbcd8fc224c68c456efb1a0`.
Branch làm việc: `design/signin-chat-preview`.
Các byte bàn giao được liệt kê trong `SHA256SUMS`.

## Thử UI native offline

Candidate triển khai: **LM-SC-NATIVE-01**, cùng base nêu trên. Source được chốt
trong `NATIVE-SHA256SUMS`; đường dẫn trong manifest tính từ root repository.
Trạng thái nghiệm thu và giới hạn nằm tại `docs/STATUS.md`.

1. Từ root repository, chạy `shasum -a 256 -c design/signin-chat/NATIVE-SHA256SUMS`.
2. Nếu chưa có bundle, chạy `bash scripts/build-app.sh chat-ui-check`.
3. Mở `dist/chat-ui-check/LessMeet.app`.
4. Dùng Account để xem sheet. Continue chỉ bắt đầu lần chờ offline; Cancel kết thúc lần chờ.
5. Chọn fixture Consent needed hoặc Connected để xem các trạng thái mẫu.
6. Trong Connected, chọn Load models rồi chọn Synthetic Chat Model.
7. Nhập câu hỏi và chọn Send. Chọn Slow stream hoặc Error để thử hủy và lỗi mẫu.
8. Chọn Reopen saved chat để đọc lại file chat mẫu đã lưu.

Bundle này dùng view và model sản phẩm với các điểm nối dữ liệu giả lập.
Nó không mở trình duyệt, không đọc Keychain, không dùng thư viện recording thật,
không gọi API và không mở link. Câu trả lời cố định không phản ánh câu hỏi.
Mỗi lần khởi động tạo thư mục tạm và defaults riêng. Dữ liệu mẫu còn trên disk
để kiểm tra; nút Reopen không phải phép thử quit/relaunch dùng lại thư mục cũ.
Các menu fixture không có trong app thông thường.

`dist/local/LessMeet.app` cũng đã build, nhưng chưa được mở trong lần kiểm tra này.
Không dùng nó để thử tài khoản thật khi chưa có quyền đọc credentials/login/chat.
Chi tiết kiểm tra native nằm ở cuối [EVIDENCE.md](EVIDENCE.md).

## Mở bản vẽ

1. Mở [preview.html](preview.html) bằng Chrome hoặc Safari. Không cần server hoặc cài package.
2. Chọn **01 · Sign-in** hoặc **02 · Chat**.
3. Chọn trạng thái trong menu phía trên. Dùng **Dark / Light** để đổi bảng màu.
4. Thử nhập câu hỏi hoặc chọn câu hỏi gợi ý. Các nút chỉ mô phỏng trên trang này.

Ảnh chính: [Sign-in](signin.png) · [Chat](chat.png).
Ảnh phụ: [Chờ trình duyệt](signin-waiting.png) · [Cho phép dùng plan](signin-consent.png) ·
[Chat mới](chat-empty.png) · [Đang trả lời](chat-streaming.png) ·
[Lỗi yêu cầu](chat-error.png) · [Dark](chat-dark.png) · [Cửa sổ nhỏ](chat-compact.png).

Giữ nguyên vị trí file trong repository. Preview dùng logo hiện có tại
`Sources/LessMeet/Resources/ChatGPTLogo.svg`; không tải asset từ mạng.
Tên người, recording, model và nội dung chat đều là dữ liệu mẫu.

## Hướng thiết kế đề xuất

- Giữ bố cục native: sidebar, recording đang chọn, Transcript/Chat, playback.
  Phần khung chỉ tạo ngữ cảnh. Nó không phải đề xuất thay đổi toàn bộ Library.
- Dùng ivory/olive từ `docs/DESIGN.md`, system font và đường phân cách nhẹ.
  Không coi layout website là layout app đã duyệt.
- Sign-in là sheet theo ngữ cảnh. Chỉ một nút chính khi chưa có tài khoản.
  Giải thích plan và dữ liệu được gửi trước nút. Chuyển các nút quản lý tài khoản
  sang trạng thái đã có tài khoản.
- Chat ưu tiên nội dung. Câu hỏi có nền nhẹ; câu trả lời không bị bọc trong card lớn.
  Giới hạn độ rộng đọc. Giữ model, Refresh, Cancel và Send sát ô soạn thảo.
- Giữ cảnh báo gửi **toàn bộ transcript và cuộc trò chuyện** ở vùng soạn thảo.
  Không dùng “private” hoặc “local” để ngụ ý yêu cầu ChatGPT chạy trên máy.
- Đề xuất thêm ba câu hỏi gợi ý. Chọn gợi ý chỉ điền draft, không tự gửi.
  “Go to Transcript” chỉ điều hướng; không tự chạy transcription.
- Dark dùng bảng màu riêng trong candidate đã duyệt. Không đảo màu toàn bộ light.

## Luồng chính

1. Từ Chat chưa đăng nhập, mở sheet ChatGPT account.
2. Chọn Continue with ChatGPT. App thật sẽ chờ trình duyệt; preview chỉ đổi hình.
3. Nếu tài khoản chưa cho phép dùng plan, hiển thị Enable ChatGPT plan usage.
4. Khi được phép dùng plan lần đầu, hiển thị thông báo usage với nút Got it.
5. Trở lại Chat, tải danh sách model rồi chọn một model. Không tự chọn model.
6. Soạn câu hỏi và chủ động gửi bằng Send hoặc ⌘Return.
7. Trong khi trả lời, hiện “Incomplete answer · not saved” và Cancel.
8. Chỉ sau khi hoàn tất và lưu thành công mới coi cặp hỏi/đáp là lịch sử đã lưu.

Trong preview, chọn các trạng thái thành công bằng menu ngoài cửa sổ app.
Không có OAuth callback giả hoặc xác nhận rằng tài khoản thật đã kết nối.
Menu này là công cụ duyệt, không phải thành phần sẽ đưa vào app.

## Trạng thái và ràng buộc

| Nhóm | Bản vẽ có | Ý nghĩa cần giữ khi triển khai |
| --- | --- | --- |
| Sign-in | Chưa đăng nhập, chờ trình duyệt, lỗi/hết hạn | Cancel hủy lần đăng nhập. Done chỉ đóng sheet. Lỗi đăng nhập không tự đăng xuất tài khoản cũ. |
| Plan | Chưa cho phép, welcome, đã kết nối | Đăng nhập không đồng nghĩa đã được phép dùng plan. Welcome không đóng bằng Done. |
| Tài khoản | Đổi/thêm, lỗi đăng xuất | Chọn trong picker chưa kích hoạt tài khoản. Tiếp tục trong trình duyệt. Giữ Retry sign-out khi cần. |
| Chat | Mới, lịch sử đã lưu, signed-out | Lịch sử thuộc recording, không thuộc tài khoản. Vẫn đọc được khi signed-out. |
| Model | Chưa tải, đang tải, chưa chọn | Chỉ tải khi được phép; không tự chọn. Refresh cùng phiên thất bại có thể giữ catalog cũ. |
| Đang gửi | Partial answer, Cancel | Editor vẫn cho sửa. Partial không được ghi là đã lưu. Không tự retry. |
| Lỗi | Request, save, history, transcript | Không thay đổi lịch sử cũ. Không gộp lỗi history thành chat rỗng. Manage usage không khẳng định mọi lỗi là hết quota. |
| Đang recording | Chat tạm dừng | Không gửi khi phase khác idle. Không làm gián đoạn recording. |

Source chính để kiểm tra:

- `Sources/LessMeet/ChatGPTChat/ChatGPTAccountView.swift`: consent, welcome, account actions.
- `Sources/LessMeet/ChatGPTAuth/ChatGPTSession.swift`: trạng thái phiên và đăng xuất.
- `Sources/LessMeet/ChatGPTChat/LocalChatView.swift`: disclosure, draft, controls, partial label.
- `Sources/LessMeet/ChatGPTChat/LocalChatModel.swift`: `canSend`, `loadModels`, `send`, `cancel`.
- `Sources/LessMeet/Presentation/LibraryView.swift`: recording context, tab và playback.
- `Sources/LessMeet/LessMeetApp.swift`: cửa sổ mặc định 1180 × 760, tối thiểu 1000 × 640.

Ví dụ từ code: gửi “Summarize”, rồi sửa draft thành “List decisions” trong khi chờ.
Nếu lưu thành công, app lưu cặp hỏi/đáp của “Summarize” nhưng giữ “List decisions”.
`draftRevisions` ngăn xóa draft mới. Không hứa giữ draft sau khi đổi recording hoặc
khởi động lại app; draft hiện là state trong view. Kiểm tra transcript thật từ disk
xảy ra khi Send, không phải chỉ từ trạng thái enabled của nút.

## Giới hạn prototype

- Đây là HTML/CSS vẽ UI native, không phải đề xuất dùng WebView trong app.
- Preview không mô phỏng toàn bộ state machine. Câu trả lời là nội dung tĩnh.
  Không phản ánh ngữ nghĩa câu hỏi vừa nhập. Reload đưa về trạng thái đầu từ URL.
- Library, search, playback và New recording là phần ngữ cảnh không hoạt động.
- `connect-src 'none'` và `form-action 'none'` chặn đường gửi dữ liệu từ trang.
  Manage usage chỉ hiện thông báo; không mở website. Không có fetch, SDK hoặc analytics.
- Không có brand claim mới, model khả dụng thật, streaming thật, quota thật hay save/reopen thật.
- Bản vẽ đổi/thêm tài khoản dùng hai lựa chọn mẫu. Trạng thái chi tiết của lỗi revoke,
  storage và refresh được giữ trong hợp đồng code; không dựng mọi tổ hợp thành ảnh riêng.
- Thông báo native về timeout, lỗi xác thực và lỗi lưu phải dùng safe error từ model.
  Không đưa raw OAuth response vào UI. Không thay cơ chế auth/chat để khớp bản vẽ.

## Kiểm tra và bằng chứng

Chi tiết nguồn, version và kết quả nằm trong [EVIDENCE.md](EVIDENCE.md).

1. Chạy `node design/signin-chat/check-preview.mjs` để kiểm tra 20 trạng thái tĩnh.
2. Chạy `node design/signin-chat/render-previews.mjs` để xuất lại ảnh bằng Chrome có sẵn.
   Lệnh dùng profile tạm riêng, không dùng cookie hoặc profile cá nhân.
3. Chạy `shasum -a 256 -c SHA256SUMS` từ thư mục này để đối chiếu candidate.

Giai đoạn preview không build app. Giai đoạn triển khai đã được cho phép build,
tests và kiểm tra native offline. Kết quả mới được ghi tại `docs/STATUS.md`.
Native rendering, VoiceOver, text scaling, increased contrast và hành vi auth/chat
thật không trở thành PASS chỉ vì thiết kế được duyệt.
Triển khai dùng các view SwiftUI hiện có, system controls và SF Symbols.
Giữ logic model và persistence. Kiểm tra keyboard focus, cửa sổ nhỏ, tên dài,
đổi recording/account, hủy request và save/reopen trên bundle đúng candidate.

## Quyết định đã duyệt

Human đã duyệt **layout Sign-in, layout Chat, hướng màu và copy** của LM-SC-01.
Không còn checkpoint chờ duyệt thiết kế trước triển khai.
Phê duyệt thẩm mỹ không tự cấp quyền login, chat thật, upload, deploy hoặc push.
Trạng thái công việc và quyết định tiếp theo chỉ ghi tại `docs/STATUS.md`.
