import Combine
import Foundation

/// Joins the prompts the server holds to the board that shows them, for the notch's view model.
@MainActor
enum PermissionLink {
    /// - isOn: the setting; once it is off, every waiting hook is let go and every card taken down.
    /// - enabled: read by the server off the main actor for each request.
    /// - other: takes the answer to a card that isn't one of the hooks' (Paseo's), and says whether it was; the rest go to `gate`.
    static func connect(board: PermissionBoard, gate: PermissionGate, isOn: AnyPublisher<Bool, Never>,
                        enabled: @escaping @Sendable () -> Bool, other: @escaping (UUID, PermissionAnswer) -> Bool = { _, _ in false }) -> [AnyCancellable] {
        gate.isEnabled = enabled
        gate.onPrompt = { [weak board] in board?.add($0) }
        gate.onGone = { [weak board] in board?.remove($0) }
        board.onAnswer = { [gate] in
            if !other($0, $1) { gate.answer($0, $1) }
        }
        return [isOn.removeDuplicates().filter { !$0 }.sink { [weak board] _ in
            gate.cancelAll()
            board?.clear()
        }]
    }
}
