.PHONY: build test lint format check run app

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

# Đóng gói bản release thành build/SSH Desk.app (ký ad-hoc).
app:
	./scripts/build-app.sh
