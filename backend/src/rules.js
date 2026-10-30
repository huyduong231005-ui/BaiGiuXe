// Quy tắc nghiệp vụ thuần, chép từ app/lib/logic.dart để API và app tính giống nhau.
// Giờ địa phương lấy theo TZ của tiến trình (render.yaml đặt TZ=Asia/Ho_Chi_Minh).

export const normPlate = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');

/** OCR hay nhầm đúng 1 ký tự nên cho lệch tối đa 1 (giống maxPlateDiff trong app). */
export const MAX_PLATE_DIFF = 1;
export const MIN_PLATE_SCORE = 0.8;

export function plateDistance(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1), prev[j] + 1, cur[j - 1] + 1);
    }
    prev = cur;
  }
  return prev[b.length];
}

export const samePlate = (a, b) => plateDistance(normPlate(a), normPlate(b)) <= MAX_PLATE_DIFF;

/** "22:00" hoặc "22:00:00" -> số phút từ 00:00. */
export const minutesOf = (hhmm) => {
  const [h, m] = String(hhmm).split(':').map(Number);
  return h * 60 + m;
};

/** Số lần mốc đêm (giờ địa phương) rơi vào khoảng [inT, outT). */
export function nightsCrossed(inT, outT, markMinutes) {
  const a = new Date(inT), b = new Date(outT);
  let mark = new Date(a.getFullYear(), a.getMonth(), a.getDate(), 0, markMinutes);
  if (mark < a) mark = new Date(mark.getFullYear(), mark.getMonth(), mark.getDate() + 1, 0, markMinutes);
  let n = 0;
  while (mark < b) {
    n++;
    mark = new Date(mark.getFullYear(), mark.getMonth(), mark.getDate() + 1, 0, markMinutes);
  }
  return n;
}

/** Phí: không qua mốc đêm thì 1 giá ngày, mỗi lần qua mốc đêm 1 giá đêm; vé tháng miễn phí. */
export function calcFee(inT, outT, settings, monthly = false) {
  if (monthly) return 0;
  const n = nightsCrossed(inT, outT, minutesOf(settings.night_mark));
  return n === 0 ? settings.price_day : n * settings.price_night;
}

const deny = (message) => ({ ok: false, open: false, message });

/** Quyết định cho xe vào (cùng thứ tự kiểm tra với decideEntry trong app). */
export function decideEntry({ card, hasOpenSession, free, plate, score = 1, candidates = [], parkedPlates = [] }) {
  if (!card) return deny('The chua dang ky');
  if (!card.active) return deny('The bi khoa');
  if (hasOpenSession) return deny('The dang gui xe');
  if (free <= 0) return deny('Bai da day');
  if (!normPlate(plate)) return deny('Khong doc duoc bien');
  if (score < MIN_PLATE_SCORE) return deny('Bien mo, quet lai');
  if (parkedPlates.some((p) => samePlate(p, plate))) return deny('Xe da o trong bai');
  const matches = samePlate(card.plate, plate) || candidates.some((c) => samePlate(card.plate, c));
  if (card.kind === 'monthly' && !matches) return deny('Sai xe ve thang');
  return { ok: true, open: false, message: 'Moi vao' };
}

/** Quyết định cho xe ra: biển ra phải khớp biển lúc vào, kèm phí. */
export function decideExit({ card, session, plate, candidates = [], now, settings }) {
  if (!session) return deny('Khong co luot gui');
  if (!normPlate(plate)) return deny('Khong doc duoc bien');
  if (!session.plate_in) return deny('Thieu bien luc vao');
  const ok = samePlate(session.plate_in, plate) || candidates.some((c) => samePlate(session.plate_in, c));
  if (!ok) return deny('Sai bien so');
  const fee = calcFee(session.time_in, now, settings, card?.kind === 'monthly');
  return { ok: true, open: true, message: `Phi: ${fee}d`, fee };
}

// ---------- Chấm công ----------

/** Thống kê một lượt chấm công (giống attStat trong app). Quên chấm ra không tính giờ làm, không tính về sớm. */
export function attStat(r) {
  const t = (k) => (r[k] ? new Date(r[k]) : null);
  const inT = t('time_in'), outT = t('time_out'), start = t('shift_start'), end = t('shift_end');
  const missingOut = r.method_out === 'auto';
  const counted = outT && !missingOut;
  const pos = (ms) => (ms > 0 ? Math.floor(ms / 60000) : 0);
  return {
    lateMin: start ? pos(inT - start) : 0,
    earlyMin: counted && end ? pos(end - outT) : 0,
    workedMin: counted ? pos(outT - inT) : 0,
    open: !outT,
    missingOut,
  };
}

/** Gộp các lượt chấm công thành bảng công theo bảo vệ. */
export function summarize(rows) {
  const by = new Map();
  for (const r of rows) {
    const s = attStat(r);
    const g = by.get(r.guard_id) ?? { guardId: r.guard_id, name: r.guard_name, shifts: 0, workedMin: 0,
      lateCount: 0, lateMin: 0, earlyCount: 0, earlyMin: 0, missingOut: 0 };
    g.shifts++;
    g.workedMin += s.workedMin;
    if (s.lateMin) { g.lateCount++; g.lateMin += s.lateMin; }
    if (s.earlyMin) { g.earlyCount++; g.earlyMin += s.earlyMin; }
    if (s.missingOut) g.missingOut++;
    by.set(r.guard_id, g);
  }
  return [...by.values()];
}
