# Sơ đồ SSH Desk

| File | Nội dung |
| --- | --- |
| `01-kien-truc.drawio` | Module UI → Core → file app sở hữu → công cụ ngoài |
| `02-luong-mo-warp.drawio` | Luồng mở SSH trong Warp, askpass (ADR-006, 007, 010) |
| `03-luong-nhap-excel.drawio` | Luồng nhập Excel/CSV, tự thêm máy mới, lưu mật khẩu (ADR-026, 026b, 031) |
| `04-quy-trinh-agent.drawio` | Quy trình đội agent (skill `ssh-desk-delivery`) |

`*.drawio.png` là ảnh có nhúng sơ đồ, mở bằng draw.io để sửa được.
Muốn đọc code theo sơ đồ (bấm khối → xem source): mở [`docs/code-map/index.html`](../code-map/index.html).

## Sinh lại

- `make diagrams` — sinh lại `.drawio` từ `scripts/diagrams/gen_diagrams.py` (sửa bố cục/nhãn ở đó, không sửa tay file `.drawio`).
  Ảnh `.drawio.png` không tự sinh lại; xuất bằng draw.io khi cần (`draw.io -x -f png -e -s 2`).
- `make code-map` — sinh lại bản đồ code từ `scripts/code-map/build.py` + `template.html`.
  - Mỗi view có `lanes`, `nodes` (làn, cột, hàng, tiêu đề, dòng phụ, mô tả, refs) và `edges`.
  - Mỗi ref là `(file hoặc glob, regex anchor | None)`. Anchor là regex của dòng khai báo; script tự lấy cả khối
    `{ … }` (Swift), cả mục (Markdown) hoặc cả đoạn (Makefile) để tô. Không ghi cứng số dòng.
  - Đổi tên/xoá hàm mà quên cập nhật → `make code-map` dừng và báo "Bản đồ lệch với code" kèm khối bị lệch.
  - Trang tự chứa (không CDN, không mạng); có sáng/tối theo hệ thống, điều hướng bằng Tab/Enter, link `#view/khối`.
