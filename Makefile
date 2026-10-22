.PHONY: build test lint format check run app install

# Máy chỉ có Command Line Tools (không có Xcode.app): SwiftPM không tự nạp macro plugin
# của Swift Testing, nên phải trỏ thủ công. Có Xcode đầy đủ thì biến này vô hại.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(CLT_TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS))

build:
	swift build

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

# Vòng phản hồi duy nhất: phải xanh trước khi báo "xong".
check: lint build test

run:
	swift run SSHDesk

# Đóng gói bản release thành build/SSH Desk.app.
# Ký bằng chứng chỉ Code Signing tự tạo: make app SIGN_IDENTITY="SSH Desk Local" (hoặc export SSHDESK_SIGN_IDENTITY).
# Không có thì ký ad-hoc và cảnh báo (ADR-023).
# Giá trị đi qua môi trường (export ở cấp Makefile), không nội suy vào dòng lệnh shell.
# Giới hạn: make vẫn mở rộng `$` trong giá trị; tên chứa `$` hãy đặt bằng biến môi trường thay vì SIGN_IDENTITY=.
SIGN_IDENTITY ?=
ifneq ($(SIGN_IDENTITY),)
export SSHDESK_SIGN_IDENTITY := $(SIGN_IDENTITY)
endif
app:
	./scripts/build-app.sh

# Cài vào /Applications để mở bằng icon (Launchpad/Spotlight/Dock). Chạy lại để cập nhật.
INSTALL_APP := /Applications/SSH Desk.app
install: app
	@if pgrep -xq SSHDesk; then echo "SSH Desk đang chạy — thoát app (⌘Q) rồi chạy lại make install."; exit 1; fi
	@if [ -e "$(INSTALL_APP)" ]; then rm -r "$(INSTALL_APP)"; fi
	ditto "build/SSH Desk.app" "$(INSTALL_APP)"
	@echo "Đã cài $(INSTALL_APP)"
