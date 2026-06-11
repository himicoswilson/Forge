import Foundation
import Testing
@testable import ForgeCore

@Suite("AggregateState")
struct AggregateStateTests {

    private func status(_ name: String, _ state: ServiceState, memoryKB: Int? = nil) -> ServiceStatus {
        ServiceStatus(service: ServiceConfig(name: name, port: 1), state: state, memoryKB: memoryKB)
    }

    @Test("all up → allUp")
    func allUp() {
        #expect(AggregateState.aggregate([status("a", .up), status("b", .up)]) == .allUp)
    }

    @Test("all down → allDown")
    func allDown() {
        #expect(AggregateState.aggregate([status("a", .down), status("b", .down)]) == .allDown)
    }

    @Test("mixed and booting states → partial")
    func partial() {
        #expect(AggregateState.aggregate([status("a", .up), status("b", .down)]) == .partial)
        #expect(AggregateState.aggregate([status("a", .starting), status("b", .down)]) == .partial)
        #expect(AggregateState.aggregate([status("a", .up), status("b", .starting)]) == .partial)
    }

    @Test("no services → empty")
    func empty() {
        #expect(AggregateState.aggregate([]) == .empty)
    }

    @Test("memory formats as MB above 1024 KB, KB below")
    func memoryFormatting() {
        #expect(status("a", .up, memoryKB: 129_024).memoryDescription == "126 MB")
        #expect(status("a", .up, memoryKB: 512).memoryDescription == "512 KB")
        #expect(status("a", .down).memoryDescription == nil)
    }
}
