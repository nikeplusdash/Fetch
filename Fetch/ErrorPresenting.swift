import Foundation

@MainActor
enum ErrorPresenting {
    static weak var current: (any ErrorPresenter)?
}
