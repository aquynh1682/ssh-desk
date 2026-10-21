import Foundation

/// Định dạng văn bản cho bảng file và thanh trạng thái. Thuần (nhận `now`/`calendar` để test).
public enum BrowserFormat {
    public static func sizeText(_ row: BrowserRow) -> String {
        guard let size = row.size, !row.isDirectory else { return "—" }
        return sizeText(bytes: size)
    }

    public static func sizeText(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// `Hôm nay` / `Hôm qua` / `dd/MM` (cùng năm) / `dd/MM/yyyy`; không có ngày → `—`.
    public static func modifiedText(
        _ date: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        guard let date else { return "—" }
        if calendar.isDate(date, inSameDayAs: now) { return "Hôm nay" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Hôm qua"
        }
        let c = calendar.dateComponents([.day, .month, .year], from: date)
        let dm = String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
        if c.year == calendar.component(.year, from: now) { return dm }
        return dm + "/" + String(c.year ?? 0)
    }

    /// `6 mục · 2 đã chọn`.
    public static func footerText(total: Int, selected: Int) -> String {
        selected > 0 ? "\(total) mục · \(selected) đã chọn" : "\(total) mục"
    }

    /// `64% · 38 MB/s` chỉ khi có dữ liệu thật; không có thì nil.
    public static func progressDetail(for job: TransferJob) -> String? {
        let parts = [TransferPresentation.percentText(for: job), TransferPresentation.speedText(for: job)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
