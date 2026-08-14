import Foundation

/// Where a call site finds the thing presenting errors.
///
/// **A holder rather than an `@Environment` value, and rather than a property
/// on `AppModel`.** Plan 1 owns `ErrorPanel` and plan 2 owns the call sites,
/// and the two are built in parallel worktrees: a property on `AppModel` would
/// mean both branches editing that 2,800-line file at the same place, and an
/// environment key would only reach views — but the sentence about a folder
/// outside the download root is raised by the model, from inside a file dialog
/// callback, where there is no environment to read.
///
/// It is set once, by whatever owns the window. Nil until plan 1 merges, which
/// is why `AppModel.report` falls back to the app-level banner rather than
/// dropping the sentence.
@MainActor
enum ErrorPresenting {
    /// Weak: the presenter belongs to the window, and a global holding it
    /// strongly would keep a closed window's panel alive to be shown into.
    static weak var current: (any ErrorPresenter)?
}
