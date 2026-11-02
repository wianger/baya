/// Numeric `x.y.z` version comparison.
///
/// Pre-release and build suffixes (`-beta`, `+1`) are ignored. Missing or
/// non-numeric components count as 0 (`1.2` == `1.2.0`).
library;

List<int> _parse(String v) {
  // Drop pre-release / build metadata.
  final core = v.trim().split(RegExp(r'[-+]')).first;
  final parts = core.split('.');
  return List<int>.generate(3, (i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i].trim()) ?? 0;
  });
}

/// `-1` if [a] < [b], `0` if equal, `1` if [a] > [b].
int compareSemver(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

/// Whether [candidate] is newer than [current].
bool isNewerVersion(String candidate, String current) =>
    compareSemver(candidate, current) > 0;
