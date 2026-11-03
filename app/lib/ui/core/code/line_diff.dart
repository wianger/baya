/// A line diff of two texts, grouped into hunks with a little context.
library;

enum DiffKind { context, added, removed }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNumber, this.newNumber});

  final DiffKind kind;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

typedef DiffHunk = List<DiffLine>;

/// Lines past which the exact diff is skipped for one changed block.
const _maxCells = 1500000;

/// The hunks turning [oldText] into [newText]; a null [oldText] is a new
/// file. Unchanged runs longer than twice [context] are left out between
/// hunks.
List<DiffHunk> lineDiff(String? oldText, String newText, {int context = 3}) {
  final a = oldText == null || oldText.isEmpty
      ? <String>[]
      : oldText.split('\n');
  final b = newText.isEmpty ? <String>[] : newText.split('\n');
  final lines = _diff(a, b);
  final hunks = <DiffHunk>[];
  final changed = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].kind != DiffKind.context) i,
  ];
  if (changed.isEmpty) return hunks;
  var start = (changed.first - context).clamp(0, lines.length);
  var end = (changed.first + context + 1).clamp(0, lines.length);
  for (final index in changed.skip(1)) {
    if (index - context <= end) {
      end = (index + context + 1).clamp(0, lines.length);
    } else {
      hunks.add(lines.sublist(start, end));
      start = index - context;
      end = (index + context + 1).clamp(0, lines.length);
    }
  }
  hunks.add(lines.sublist(start, end));
  return hunks;
}

List<DiffLine> _diff(List<String> a, List<String> b) {
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final out = <DiffLine>[];
  var oldNo = 1;
  var newNo = 1;
  void same(String text) => out.add(
    DiffLine(DiffKind.context, text, oldNumber: oldNo++, newNumber: newNo++),
  );
  void removed(String text) =>
      out.add(DiffLine(DiffKind.removed, text, oldNumber: oldNo++));
  void added(String text) =>
      out.add(DiffLine(DiffKind.added, text, newNumber: newNo++));

  for (var i = 0; i < prefix; i++) {
    same(a[i]);
  }
  final midA = a.sublist(prefix, a.length - suffix);
  final midB = b.sublist(prefix, b.length - suffix);
  final n = midA.length;
  final m = midB.length;
  if (n * m > _maxCells) {
    midA.forEach(removed);
    midB.forEach(added);
  } else {
    // Longest common subsequence, then walk it forwards.
    final width = m + 1;
    final table = List<int>.filled((n + 1) * width, 0);
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        table[i * width + j] = midA[i] == midB[j]
            ? table[(i + 1) * width + j + 1] + 1
            : (table[(i + 1) * width + j] >= table[i * width + j + 1]
                  ? table[(i + 1) * width + j]
                  : table[i * width + j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (midA[i] == midB[j]) {
        same(midA[i]);
        i++;
        j++;
      } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
        removed(midA[i++]);
      } else {
        added(midB[j++]);
      }
    }
    while (i < n) {
      removed(midA[i++]);
    }
    while (j < m) {
      added(midB[j++]);
    }
  }
  for (var i = a.length - suffix; i < a.length; i++) {
    same(a[i]);
  }
  return out;
}

/// Lines added and removed across [hunks].
({int added, int removed}) diffStats(List<DiffHunk> hunks) {
  var added = 0;
  var removed = 0;
  for (final hunk in hunks) {
    for (final line in hunk) {
      if (line.kind == DiffKind.added) added++;
      if (line.kind == DiffKind.removed) removed++;
    }
  }
  return (added: added, removed: removed);
}
