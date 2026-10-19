/// The one `System` member the shared helper sources use outside the app (AppReplay's replay
/// polling). Dispatch/Helper/System.swift needs AppKit and TermApple; the iOS target will need the
/// same seam (the plan's SystemProvider). Live runs never poll.
enum System {
  static var polling: Bool { false }
}
