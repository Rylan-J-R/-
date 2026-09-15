import Foundation
import SwiftUI

@Observable
final class HistoryViewModel: @unchecked Sendable {
    var records: [HistoryRecord] = []
    var searchText: String = ""
    var selectedToolFilter: String? = nil
    var expandedRecordIDs: Set<UUID> = []
    var isLoading = false

    private let service = HistoryService()
    private var changeObserver: NSObjectProtocol?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .historyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadRecords()
        }
    }

    deinit {
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 计算属性

    /// 筛选 + 搜索后的记录
    var filteredRecords: [HistoryRecord] {
        service.fetchFiltered(toolName: selectedToolFilter, searchText: searchText)
    }

    /// 可用工具名列表（用于筛选菜单）
    var availableTools: [String] {
        let all = service.fetchAll()
        return Array(Set(all.map(\.toolName))).sorted()
    }

    // MARK: - 操作

    func loadRecords() {
        records = service.fetchAll()
    }

    func deleteRecord(_ record: HistoryRecord) {
        service.deleteRecord(record)
        loadRecords()
    }

    func clearAll() {
        service.clearAll()
        records = []
    }

    func toggleExpand(_ id: UUID) {
        if expandedRecordIDs.contains(id) {
            expandedRecordIDs.remove(id)
        } else {
            expandedRecordIDs.insert(id)
        }
    }

    func isExpanded(_ id: UUID) -> Bool {
        expandedRecordIDs.contains(id)
    }
}
