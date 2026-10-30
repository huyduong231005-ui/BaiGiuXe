// Mặt bằng bãi dạng lưới ký tự (mỗi chuỗi là một hàng, mỗi ký tự là một ô vuông trên mặt đất):
//   '#' tường   '.' bỏ trống (cột, bồn cây...)   '=' đường đi   'I' lối vào   'O' lối ra
//   'A'..'Z' (trừ I, O) ô đậu của khu cùng tên.
// Xe chỉ chạy trên đường đi / lối vào / lối ra; ô đậu phải nằm cạnh đường. Đường đi tìm bằng BFS (ngắn nhất theo số ô).

export const WALKABLE = new Set(['=', 'I', 'O']);
export const ZONE_LETTER_RE = /^[A-HJ-NP-Z]$/;
const ALLOWED_RE = /^[#.=IOA-Z]+$/;
const MAX_SIZE = 40;
const DIRS = [[-1, 0], [0, 1], [1, 0], [0, -1]];

export const cellsOf = (layout, test) => {
  const out = [];
  layout.forEach((line, r) => [...line].forEach((ch, c) => test(ch) && out.push([r, c])));
  return out;
};

const inside = (layout, r, c) => r >= 0 && r < layout.length && c >= 0 && c < layout[0].length;
const at = (layout, r, c) => (inside(layout, r, c) ? layout[r][c] : '#');

/** Kiểm tra mặt bằng; trả về thông báo lỗi tiếng Việt hoặc null. zoneNames = các khu đã tạo. */
export function layoutError(layout, zoneNames) {
  if (!Array.isArray(layout) || layout.length < 3 || layout.length > MAX_SIZE) return `Mặt bằng 3-${MAX_SIZE} hàng`;
  const w = layout[0]?.length ?? 0;
  if (w < 3 || w > MAX_SIZE || layout.some((l) => typeof l !== 'string' || l.length !== w)) {
    return `Mọi hàng phải dài bằng nhau, 3-${MAX_SIZE} ô`;
  }
  if (layout.some((l) => !ALLOWED_RE.test(l))) return 'Ký tự không hợp lệ trong mặt bằng';
  const letters = new Set(cellsOf(layout, (ch) => ZONE_LETTER_RE.test(ch)).map(([r, c]) => layout[r][c]));
  const unknown = [...letters].filter((l) => !zoneNames.includes(l));
  if (unknown.length) return `Khu ${unknown.join(', ')} chưa tạo (tạo khu trước rồi mới vẽ ô)`;
  const entrances = cellsOf(layout, (ch) => ch === 'I');
  if (!entrances.length) return 'Cần ít nhất 1 lối vào';
  if (!cellsOf(layout, (ch) => ch === 'O').length) return 'Cần ít nhất 1 lối ra';
  const { dist } = bfs(layout, entrances);
  if (!cellsOf(layout, (ch) => ch === 'O').some(([r, c]) => dist.has(`${r},${c}`))) return 'Không có đường từ lối vào tới lối ra';
  const stuck = cellsOf(layout, (ch) => ZONE_LETTER_RE.test(ch)).filter(([r, c]) => slotAccess(layout, dist, r, c) == null);
  if (stuck.length) {
    const [r, c] = stuck[0];
    return `${stuck.length} ô đậu không có đường xe tới (VD ô ở hàng ${r + 1}, cột ${c + 1})`;
  }
  return null;
}

/** BFS trên đường đi từ các ô xuất phát. dist: "r,c" -> số bước; prev: "r,c" -> ô trước đó. */
export function bfs(layout, starts) {
  const dist = new Map(), prev = new Map();
  const queue = [];
  for (const [r, c] of starts) {
    dist.set(`${r},${c}`, 0);
    queue.push([r, c]);
  }
  for (let i = 0; i < queue.length; i++) {
    const [r, c] = queue[i];
    for (const [dr, dc] of DIRS) {
      const nr = r + dr, nc = c + dc, key = `${nr},${nc}`;
      if (!WALKABLE.has(at(layout, nr, nc)) || dist.has(key)) continue;
      dist.set(key, dist.get(`${r},${c}`) + 1);
      prev.set(key, `${r},${c}`);
      queue.push([nr, nc]);
    }
  }
  return { dist, prev };
}

/** Ô đường gần lối vào nhất nằm sát ô đậu (r, c): xe đỗ từ đây vào ô. null = không tới được. */
function slotAccess(layout, dist, r, c) {
  let best = null;
  for (const [dr, dc] of DIRS) {
    const key = `${r + dr},${c + dc}`;
    if (dist.has(key) && (!best || dist.get(key) < dist.get(best))) best = key;
  }
  return best;
}

/** Quãng đường (số ô) từ lối vào gần nhất tới mọi ô đậu: "r,c" -> bước. Dùng để chỉ ô gần nhất cho khách. */
export function slotDistances(layout) {
  const { dist } = bfs(layout, cellsOf(layout, (ch) => ch === 'I'));
  const out = new Map();
  for (const [r, c] of cellsOf(layout, (ch) => ZONE_LETTER_RE.test(ch))) {
    const a = slotAccess(layout, dist, r, c);
    if (a) out.set(`${r},${c}`, dist.get(a) + 1);
  }
  return out;
}

const pathTo = (prev, key) => {
  const path = [];
  for (let k = key; k; k = prev.get(k)) path.unshift(k.split(',').map(Number));
  return path;
};

const turn = (a, b) => {
  const cross = a[0] * b[1] - a[1] * b[0]; // hàng tăng xuống dưới: cross < 0 là rẽ phải
  return cross === 0 ? (a[0] === b[0] && a[1] === b[1] ? 'thẳng' : 'quay lại') : cross < 0 ? 'phải' : 'trái';
};

/** Gom đường đi thành các đoạn thẳng: [{dir:[dr,dc], n}] */
function segments(path) {
  const segs = [];
  for (let i = 1; i < path.length; i++) {
    const d = [path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1]];
    const last = segs.at(-1);
    if (last && last.dir[0] === d[0] && last.dir[1] === d[1]) last.n++;
    else segs.push({ dir: d, n: 1 });
  }
  return segs;
}

/**
 * Đường từ lối vào gần nhất tới ô (r, c) và từ ô tới lối ra gần nhất, kèm lời chỉ dẫn.
 * path: các ô [hàng, cột] từ lối vào tới ô đậu (ô cuối là ô đậu); exitPath: từ ô đậu tới lối ra.
 */
export function route(layout, r, c, code = '') {
  const toSlot = bfs(layout, cellsOf(layout, (ch) => ch === 'I'));
  const access = slotAccess(layout, toSlot.dist, r, c);
  if (!access) return null;
  const path = [...pathTo(toSlot.prev, access), [r, c]];
  const fromSlot = bfs(layout, [access.split(',').map(Number)]);
  const exits = cellsOf(layout, (ch) => ch === 'O').map(([er, ec]) => `${er},${ec}`).filter((k) => fromSlot.dist.has(k));
  const exitKey = exits.sort((a, b) => fromSlot.dist.get(a) - fromSlot.dist.get(b))[0];
  const exitPath = exitKey ? [[r, c], ...pathTo(fromSlot.prev, exitKey)] : [];

  // Lời chỉ dẫn: hướng đầu tiên là hướng đi từ lối vào vào trong bãi.
  const segs = segments(path.slice(0, -1));
  const steps = ['Qua cổng vào'];
  let heading = segs[0]?.dir;
  segs.forEach((s, i) => {
    if (i === 0) steps.push(`đi thẳng ${s.n} ô`);
    else steps.push(`rẽ ${turn(heading, s.dir)} đi ${s.n} ô`);
    heading = s.dir;
  });
  const last = path.at(-2), into = [r - last[0], c - last[1]];
  const side = heading ? turn(heading, into) : 'thẳng';
  const sideText = side === 'thẳng' ? 'ngay phía trước' : side === 'quay lại' ? 'phía sau' : `bên ${side}`;
  steps.push(`ô ${code} ở ${sideText}`);
  // Bản ngắn không dấu cho OLED: hướng rẽ đầu tiên + phía của ô.
  const firstTurn = segs[1] ? `re ${turn(segs[0].dir, segs[1].dir) === 'phải' ? 'phai' : 'trai'}` : 'di thang';
  return { path, exitPath, distance: path.length - 1, hint: steps.join(', '),
    short: `${firstTurn}, o ben ${side === 'phải' ? 'phai' : side === 'trái' ? 'trai' : 'truoc'}` };
}

/** Mặt bằng mẫu cho bãi chung cư: lối vào / lối ra ở tường trên, 3 làn đường, khu A, B xe máy, C ô tô, D xe đạp. */
export const SAMPLE_LAYOUT = [
  '##I################O##',
  '#==AAAAAAAAAAAAAAAA==#',
  '#====================#',
  '#==BBBBBBBBBBBBBBBB==#',
  '#==BBBBBBBBBBBBBBBB==#',
  '#====================#',
  '#==CCCCCCCC.DDDDDDD==#',
  '######################',
];
