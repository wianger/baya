class ContextUsageSnapshot {
  const ContextUsageSnapshot({this.tokens, this.window, this.source});
  final int? tokens;
  final int? window;
  final String? source;
  double? get percent => tokens != null && window != null && window! > 0
      ? tokens! * 100 / window!
      : null;
}
