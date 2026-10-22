---
name: ssh-desk-delivery
description: Quy trình giao việc của đội SSH Desk (ý tưởng: product-advisor → người dùng chọn → pm → coder → qa-reviewer → PM duyệt/commit; doc-writer cho tài liệu; researcher tra cứu). Dùng khi làm tiếp tính năng/bước trong plan.md, sửa theo phản hồi người dùng, "làm nốt việc còn lại", chạy lại QA, cập nhật hoặc viết lại tài liệu (README, KNOWN_LIMITATIONS…). Không dùng cho câu hỏi đơn giản trả lời trực tiếp được.
---

# Giao việc SSH Desk

**Kiểu chạy:** giao cho subagent (`Agent` với `subagent_type`, chạy nền). Các agent không nói chuyện với nhau; PM nhận báo cáo và chuyển tiếp.

## Vì sao có quy trình này
Một thư mục làm việc, một `.build` dùng chung. Hai agent cùng build hoặc cùng sửa một file sẽ đè nhau. Worktree tạo từ `main`, không phải từ nhánh đang làm (xem CLAUDE.md), nên coder làm thẳng trên nhánh, **mỗi lúc chỉ một coder**. Quyết định nằm trong `docs/architecture.md`, nên agent đọc ADR thay vì đoán.

## Ý tưởng và tư vấn: `product-advisor`
- Khi người dùng xin ý tưởng, roadmap hoặc hỏi "nên thêm gì": giao `product-advisor`. Nếu cần lưu lại thì nhờ ghi `docs/ideas.md`.
- Agent chính trình bày lại cho người dùng và hỏi họ chọn. Chỉ ý tưởng được người dùng chọn mới chuyển sang PM.

## Điều phối: `pm`
- Việc triển khai có thể giao trọn cho agent `pm`; nó làm các bước 0–4 bên dưới.
- Nếu subagent không gọi được `Agent` (không lồng được), `pm` trả về kế hoạch giao việc và agent chính chạy theo kế hoạch đó.

## 0. Trước khi giao
1. Đọc `progress.md` và `plan.md` để biết bước nào `[ ]` (chưa làm) và bước nào `[~]` (code xong, chờ thử).
2. Có quyết định mới thì PM ghi ADR trước rồi commit. Nếu người dùng chỉ muốn chạy lại một phần (vd "chỉ QA lại D4"), chỉ giao đúng phần đó.

## 1. Code — `coder`
- Prompt gồm: ADR cần đọc, số migration kế tiếp, các việc theo thứ tự, "làm trực tiếp trên nhánh, không worktree, không commit", và lệnh `perl -e 'alarm 550; exec @ARGV' make check`.
- Mỗi lúc chỉ một coder.

## 2. Tài liệu — `doc-writer` (chạy song song với coder được)
- Chỉ đụng file `.md` và không build, nên không xung đột với coder.
- D3 gồm: `README.md` (cài bằng `make install`, tính năng, cách dùng nhanh), `docs/ARCHITECTURE.md` (bản đọc dễ của architecture.md: module, luồng SSH config/Warp/askpass/ControlMaster), `docs/TESTING.md` (`make check`, plugin-path, sshd tạm, kịch bản thử tay), `docs/KNOWN_LIMITATIONS.md` (gom mọi "Rủi ro chấp nhận" và "Chưa kiểm chứng" trong ADR).
- Khi tính năng mới vào sau, giao doc-writer cập nhật lại các file liên quan.

## 3. QA — `qa-reviewer`
- Giao sau khi coder báo xong. Truyền phạm vi (file/diff) và ADR liên quan, và nói rõ có được chạy `make check` không (chỉ khi không có coder nào đang chạy).
- Checklist nằm ở `references/qa-checklist.md`.
- Mục "Chặn": giao lại cho coder (SendMessage tới coder vừa làm nếu còn ngữ cảnh, nếu không thì tạo coder mới kèm danh sách phát hiện), sau đó QA lại.

## 4. PM duyệt
- Tự chạy `make check`, xem qua phần diff nhạy cảm (argv, SQL, Keychain, file ghi ra).
- Ghi "Đã làm (…, PM duyệt)" vào ADR. Cập nhật `plan.md` (`[~]` nếu còn chờ người dùng thử) và `progress.md`. Commit có dòng Co-Authored-By.
- Push hoặc mở PR chỉ khi người dùng yêu cầu.

## Lỗi
- Agent báo `make check` đỏ hoặc bỏ dở: PM xem `git status` / `git diff`, rồi giao tiếp đúng chỗ dở cho một coder mới, nêu rõ việc đã xong. Không tự đoán phần agent chưa báo.
- Hết hạn mức hoặc bị từ chối quyền: không thử lại. Ghi phần còn dở vào `progress.md` và báo người dùng.
- `make check` treo: lệnh đã bọc `alarm`. Treo lặp lại thì ghi vào progress.md và kiểm `TempSshd`.

## Test thử quy trình
- Đường chạy bình thường: "làm nốt D4" → coder (D4) → qa-reviewer (D4, được chạy make check) → PM commit; doc-writer cập nhật KNOWN_LIMITATIONS nếu D4 có giới hạn mới.
- Đường lỗi: QA báo "Chặn" vì cài đặt tắt tự điền nhưng askpass vẫn trả password → giao lại coder kèm `file:dòng` → QA lại → mới commit.
