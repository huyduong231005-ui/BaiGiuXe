// Mặt bằng bãi dạng lưới ký tự (mỗi chuỗi là một hàng, mỗi ký tự là một ô vuông trên mặt đất):
//   '#' tường   '.' bỏ trống (cột, bồn cây...)   '=' đường đi   'I' lối vào   'O' lối ra
//   'A'..'Z' (trừ I, O) ô đậu của khu cùng tên.
// Xe chỉ chạy trên đường đi / lối vào / lối ra; ô đậu phải nằm cạnh đường. Đường đi tìm bằng BFS (ngắn nhất theo số ô).

typedef Cell = (int, int);

const walkable = {'=', 'I', 'O'};
final zoneLetterRe = RegExp(r'^[A-HJ-NP-Z]$');
final _allowedRe = RegExp(r'^[#.=IOA-Z]+$');
const _maxSize = 40;
const List<Cell> _dirs = [(-1, 0), (0, 1), (1, 0), (0, -1)];

List<Cell> cellsOf(List<String> layout, bool Function(String ch) test) => [
      for (var r = 0; r < layout.length; r++)
        for (var c = 0; c < layout[r].length; c++)
          if (test(layout[r][c])) (r, c),
    ];

String _at(List<String> layout, int r, int c) =>
    r >= 0 && r < layout.length && c >= 0 && c < layout[0].length ? layout[r][c] : '#';

bool isZoneLetter(String ch) => zoneLetterRe.hasMatch(ch);

/// Kiểm tra mặt bằng; trả về thông báo lỗi tiếng Việt hoặc null. zoneNames = các khu đã tạo.
String? layoutError(List<String>? layout, List<String> zoneNames) {
  if (layout == null || layout.length < 3 || layout.length > _maxSize) return 'Mặt bằng 3-$_maxSize hàng';
  final w = layout[0].length;
  if (w < 3 || w > _maxSize || layout.any((l) => l.length != w)) return 'Mọi hàng phải dài bằng nhau, 3-$_maxSize ô';
  if (layout.any((l) => !_allowedRe.hasMatch(l))) return 'Ký tự không hợp lệ trong mặt bằng';
  final letters = {for (final (r, c) in cellsOf(layout, isZoneLetter)) layout[r][c]};
  final unknown = letters.where((l) => !zoneNames.contains(l)).toList();
  if (unknown.isNotEmpty) return 'Khu ${unknown.join(', ')} chưa tạo (tạo khu trước rồi mới vẽ ô)';
  final entrances = cellsOf(layout, (ch) => ch == 'I');
  if (entrances.isEmpty) return 'Cần ít nhất 1 lối vào';
  final exits = cellsOf(layout, (ch) => ch == 'O');
  if (exits.isEmpty) return 'Cần ít nhất 1 lối ra';
  final (:dist, prev: _) = bfs(layout, entrances);
  if (!exits.any(dist.containsKey)) return 'Không có đường từ lối vào tới lối ra';
  final stuck = cellsOf(layout, isZoneLetter).where((cell) => _slotAccess(dist, cell) == null).toList();
  if (stuck.isNotEmpty) {
    final (r, c) = stuck[0];
    return '${stuck.length} ô đậu không có đường xe tới (VD ô ở hàng ${r + 1}, cột ${c + 1})';
  }
  return null;
}

/// BFS trên đường đi từ các ô xuất phát. dist: ô -> số bước; prev: ô -> ô trước đó.
({Map<Cell, int> dist, Map<Cell, Cell> prev}) bfs(List<String> layout, List<Cell> starts) {
  final dist = <Cell, int>{for (final s in starts) s: 0};
  final prev = <Cell, Cell>{};
  final queue = [...starts];
  for (var i = 0; i < queue.length; i++) {
    final (r, c) = queue[i];
    for (final (dr, dc) in _dirs) {
      final next = (r + dr, c + dc);
      if (!walkable.contains(_at(layout, next.$1, next.$2)) || dist.containsKey(next)) continue;
      dist[next] = dist[(r, c)]! + 1;
      prev[next] = (r, c);
      queue.add(next);
    }
  }
  return (dist: dist, prev: prev);
}

/// Ô đường gần lối vào nhất nằm sát ô đậu: xe đỗ từ đây vào ô. null = không tới được.
Cell? _slotAccess(Map<Cell, int> dist, Cell slot) {
  Cell? best;
  for (final (dr, dc) in _dirs) {
    final key = (slot.$1 + dr, slot.$2 + dc);
    if (dist.containsKey(key) && (best == null || dist[key]! < dist[best]!)) best = key;
  }
  return best;
}

/// Quãng đường (số ô) từ lối vào gần nhất tới mọi ô đậu. Dùng để chỉ ô gần nhất cho khách.
Map<Cell, int> slotDistances(List<String> layout) {
  final (:dist, prev: _) = bfs(layout, cellsOf(layout, (ch) => ch == 'I'));
  return {
    for (final cell in cellsOf(layout, isZoneLetter))
      if (_slotAccess(dist, cell) case final a?) cell: dist[a]! + 1,
  };
}

List<Cell> _pathTo(Map<Cell, Cell> prev, Cell key) {
  final path = <Cell>[];
  for (Cell? k = key; k != null; k = prev[k]) {
    path.insert(0, k);
  }
  return path;
}

String _turn(Cell a, Cell b) {
  final cross = a.$1 * b.$2 - a.$2 * b.$1; // hàng tăng xuống dưới: cross < 0 là rẽ phải
  return cross == 0 ? (a == b ? 'thẳng' : 'quay lại') : cross < 0 ? 'phải' : 'trái';
}

/// Gom đường đi thành các đoạn thẳng: (hướng, số ô).
List<(Cell, int)> _segments(List<Cell> path) {
  final segs = <(Cell, int)>[];
  for (var i = 1; i < path.length; i++) {
    final d = (path[i].$1 - path[i - 1].$1, path[i].$2 - path[i - 1].$2);
    if (segs.isNotEmpty && segs.last.$1 == d) {
      segs.last = (d, segs.last.$2 + 1);
    } else {
      segs.add((d, 1));
    }
  }
  return segs;
}

List<List<int>> _json(List<Cell> path) => [for (final (r, c) in path) [r, c]];

/// Đường từ lối vào gần nhất tới ô (r, c) và từ ô tới lối ra gần nhất, kèm lời chỉ dẫn.
/// path: các ô [hàng, cột] từ lối vào tới ô đậu (ô cuối là ô đậu); exitPath: từ ô đậu tới lối ra.
Map<String, dynamic>? route(List<String> layout, int r, int c, [String code = '']) {
  final toSlot = bfs(layout, cellsOf(layout, (ch) => ch == 'I'));
  final access = _slotAccess(toSlot.dist, (r, c));
  if (access == null) return null;
  final path = [..._pathTo(toSlot.prev, access), (r, c)];
  final fromSlot = bfs(layout, [access]);
  final exits = cellsOf(layout, (ch) => ch == 'O').where(fromSlot.dist.containsKey).toList();
  final exitKey = exits.isEmpty ? null : exits.reduce((a, b) => fromSlot.dist[b]! < fromSlot.dist[a]! ? b : a);
  final exitPath = exitKey != null ? [(r, c), ..._pathTo(fromSlot.prev, exitKey)] : <Cell>[];

  // Lời chỉ dẫn: hướng đầu tiên là hướng đi từ lối vào vào trong bãi.
  final segs = _segments(path.sublist(0, path.length - 1));
  final steps = ['Qua cổng vào'];
  Cell? heading = segs.isEmpty ? null : segs[0].$1;
  for (var i = 0; i < segs.length; i++) {
    final (dir, n) = segs[i];
    steps.add(i == 0 ? 'đi thẳng $n ô' : 'rẽ ${_turn(heading!, dir)} đi $n ô');
    heading = dir;
  }
  final last = path[path.length - 2];
  final side = heading != null ? _turn(heading, (r - last.$1, c - last.$2)) : 'thẳng';
  final sideText = side == 'thẳng' ? 'ngay phía trước' : side == 'quay lại' ? 'phía sau' : 'bên $side';
  steps.add('ô $code ở $sideText');
  // Bản ngắn không dấu cho OLED: hướng rẽ đầu tiên + phía của ô.
  final firstTurn = segs.length > 1 ? 're ${_turn(segs[0].$1, segs[1].$1) == 'phải' ? 'phai' : 'trai'}' : 'di thang';
  return {
    'path': _json(path), 'exitPath': _json(exitPath), 'distance': path.length - 1, 'hint': steps.join(', '),
    'short': '$firstTurn, o ben ${side == 'phải' ? 'phai' : side == 'trái' ? 'trai' : 'truoc'}',
  };
}

/// Mặt bằng mẫu cho bãi chung cư: lối vào / lối ra ở tường trên, 3 làn đường, khu A, B xe máy, C ô tô, D xe đạp.
const sampleLayout = [
  '##I################O##',
  '#==AAAAAAAAAAAAAAAA==#',
  '#====================#',
  '#==BBBBBBBBBBBBBBBB==#',
  '#==BBBBBBBBBBBBBBBB==#',
  '#====================#',
  '#==CCCCCCCC.DDDDDDD==#',
  '######################',
];
