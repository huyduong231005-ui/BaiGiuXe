// Sơ đồ bãi chung cư: loại xe + bảng giá, khu, mặt bằng (lối vào, lối ra, đường đi, ô đậu), chỉ đường.
// Cư dân thuê vé tháng có ô riêng (slot.card_uid); khách vãng lai được API chỉ ô trống gần lối vào nhất theo
// quãng đường xe chạy, đúng loại xe, không đụng ô của cư dân, kèm đường đi từ cổng tới ô.
import { Router } from 'express';
import { HttpError, str } from './auth.js';
import { Card, insert, row, Session, Settings, Slot, VehicleType, Zone } from './db.js';
import { IN_USE } from './guards.js';
import { cellsOf, layoutError, route, slotDistances, ZONE_LETTER_RE } from './layout.js';

const CODE_RE = /^[a-z][a-z0-9_]{1,19}$/;

/** Loại xe theo code: { motorbike: {...}, car: {...} }. */
export async function vehicleTypes() {
  return Object.fromEntries((await VehicleType.find().sort({ _id: 1 }).lean()).map((t) => [t.code, row(t)]));
}

/** Giá áp cho một loại xe (dạng settings mà calcFee dùng). Loại lạ thì lấy giá xe máy. */
export const priceOf = (settings, types, code) => {
  const t = types[code] ?? types.motorbike ?? Object.values(types)[0] ?? {};
  return { night_mark: settings.night_mark, price_day: t.price_day ?? 0, price_night: t.price_night ?? 0 };
};

/** Plate Recognizer trả loại phương tiện (Motorcycle, Sedan, SUV, Van...) -> code loại xe của bãi. */
export function vehicleFromOcr(type) {
  if (!type || /unknown/i.test(type)) return null;
  return /motor/i.test(type) ? 'motorbike' : 'car';
}

const getLayout = async () => (await Settings.findById(1, { layout: 1 }).lean())?.layout ?? [];

/** Ô đang có xe: code -> lượt gửi đang mở. */
async function occupiedSlots() {
  const parked = await Session.find({ parked: true, slot_code: { $type: 'string' } }, { slot_code: 1, plate_in: 1, card_uid: 1, time_in: 1 }).lean();
  return new Map(parked.map((s) => [s.slot_code, s]));
}

/**
 * Chọn ô cho xe vào. Thẻ tháng có ô riêng -> ô đó. Còn lại: ô trống gần lối vào nhất theo quãng đường xe chạy,
 * đúng loại xe, không phải ô riêng của cư dân, không tạm khoá. Trả { code } | { full: true } | null (bãi chưa vẽ).
 */
export async function assignSlot(card, vehicleType) {
  if (!(await Slot.exists({}))) return null;
  if (card?.kind === 'monthly') {
    const own = await Slot.findOne({ card_uid: card.uid }).lean();
    if (own) return { code: own.code };
  }
  const [busy, layout, slots] = await Promise.all([
    occupiedSlots(), getLayout(), Slot.find({ vehicle_type: vehicleType, card_uid: null, active: true }).lean(),
  ]);
  const dist = slotDistances(layout);
  const free = slots.filter((s) => !busy.has(s.code) && dist.has(`${s.row},${s.col}`))
    .sort((a, b) => dist.get(`${a.row},${a.col}`) - dist.get(`${b.row},${b.col}`) || a.code.localeCompare(b.code));
  return free.length ? { code: free[0].code } : { full: true };
}

/** Đường từ lối vào tới ô (và từ ô ra lối ra) + lời chỉ dẫn. null nếu ô không có trên mặt bằng. */
export async function slotRoute(code) {
  const slot = await Slot.findOne({ code }).lean();
  if (!slot) return null;
  const r = route(await getLayout(), slot.row, slot.col, slot.code);
  return r && { slot: slot.code, ...r };
}

/**
 * Đồng bộ ô đậu theo mặt bằng mới. Ô giữ nguyên mã nếu vẫn ở đúng vị trí và cùng khu (không làm lệch ô của cư dân);
 * ô mới lấy số tiếp theo của khu. Ô bị xoá khỏi mặt bằng mà đang có xe hoặc đã gán cư dân thì từ chối.
 */
async function syncSlots(layout) {
  const zones = new Map((await Zone.find().lean()).map((z) => [z.name, z]));
  const old = await Slot.find().lean();
  const byPos = new Map(old.map((s) => [`${s.row},${s.col}`, s]));
  const keep = new Set();
  const created = [];
  for (const [r, c] of cellsOf(layout, (ch) => ZONE_LETTER_RE.test(ch))) {
    const z = zones.get(layout[r][c]);
    const s = byPos.get(`${r},${c}`);
    if (s && s.zone_id === z._id) {
      keep.add(s._id);
      if (s.vehicle_type !== z.vehicle_type) await Slot.updateOne({ _id: s._id }, { vehicle_type: z.vehicle_type });
    } else {
      created.push({ r, c, z });
    }
  }
  const removed = old.filter((s) => !keep.has(s._id));
  const busy = await occupiedSlots();
  const blocked = removed.filter((s) => s.card_uid || busy.has(s.code));
  if (blocked.length) {
    throw new HttpError(409, `Ô ${blocked.map((s) => s.code).slice(0, 5).join(', ')} đang có xe hoặc đã gán cư dân, không xoá khỏi mặt bằng được`);
  }
  await Slot.deleteMany({ _id: { $in: removed.map((s) => s._id) } });
  // Số tiếp theo của mỗi khu: lớn hơn mọi số đang dùng
  const next = new Map();
  for (const s of await Slot.find({}, { code: 1 }).lean()) {
    const [zn, n] = s.code.split('-');
    next.set(zn, Math.max(next.get(zn) ?? 0, Number(n)));
  }
  for (const { r, c, z } of created) {
    const n = (next.get(z.name) ?? 0) + 1;
    next.set(z.name, n);
    await insert(Slot, { code: `${z.name}-${String(n).padStart(2, '0')}`, zone_id: z._id, row: r, col: c, vehicle_type: z.vehicle_type });
  }
}

function typeInput(body) {
  const name = str(body?.name);
  const prices = ['priceDay', 'priceNight', 'priceMonth'].map((k) => body?.[k]);
  if (!name) throw new HttpError(400, 'Cần tên loại xe');
  if (!prices.every((v) => Number.isInteger(v) && v >= 0)) throw new HttpError(400, 'Giá là số nguyên ≥ 0');
  return { name, price_day: prices[0], price_night: prices[1], price_month: prices[2] };
}

function zoneInput(body, types) {
  const name = str(body?.name).toUpperCase();
  const vt = str(body?.vehicleType);
  if (!ZONE_LETTER_RE.test(name)) throw new HttpError(400, 'Tên khu là 1 chữ cái A-Z (trừ I, O dùng cho lối vào / lối ra)');
  if (!types[vt]) throw new HttpError(400, `Loại xe là một trong: ${Object.keys(types).join(', ')}`);
  return { name, vehicle_type: vt };
}

/** Sơ đồ bãi đầy đủ: mặt bằng + khu + ô kèm trạng thái (free | resident | parked | off) và xe đang đậu. */
export async function lotMap({ withPlates = true } = {}) {
  const [zones, slots, busy, types, layout] = await Promise.all([
    Zone.find().sort({ name: 1 }).lean(), Slot.find().sort({ code: 1 }).lean(), occupiedSlots(), vehicleTypes(), getLayout(),
  ]);
  const owners = new Map((await Card.find({ uid: { $in: slots.map((s) => s.card_uid).filter(Boolean) } },
    { uid: 1, owner: 1, apartment: 1, plate: 1 }).lean()).map((c) => [c.uid, c]));
  return {
    layout,
    types: Object.values(types),
    zones: zones.map((z) => ({
      ...row(z),
      slots: slots.filter((s) => s.zone_id === z._id).map((s) => {
        const car = busy.get(s.code);
        const owner = owners.get(s.card_uid);
        return {
          ...row(s),
          state: !s.active ? 'off' : car ? 'parked' : s.card_uid ? 'resident' : 'free',
          ...(withPlates ? {
            plate: car?.plate_in ?? null, since: car?.time_in ?? null,
            owner: owner?.owner ?? null, apartment: owner?.apartment ?? null, resident_plate: owner?.plate ?? null,
          } : {}),
        };
      }),
    })),
  };
}

/** Chỗ trống theo loại xe (cho trang chủ, OLED, khách xem trên app). */
export async function freeByType() {
  const map = await lotMap({ withPlates: false });
  const out = {};
  for (const z of map.zones) {
    const t = (out[z.vehicle_type] ??= { capacity: 0, free: 0, visitorFree: 0 });
    for (const s of z.slots) {
      if (s.state === 'off') continue;
      t.capacity++;
      if (s.state !== 'parked') t.free++;
      if (s.state === 'free') t.visitorFree++;
    }
  }
  return out;
}

/** Đường tới ô: ai đăng nhập cũng xem được (cư dân xem đường tới ô của mình, ĐT cổng chỉ đường cho khách). */
export async function routeHandler(req, res) {
  const r = await slotRoute(str(req.query.slot).toUpperCase());
  if (!r) throw new HttpError(404, 'Không có ô này trên mặt bằng');
  res.json(r);
}

/** Kiểm tra + lưu mặt bằng, đồng bộ ô đậu. */
export async function applyLayout(raw) {
  const layout = Array.isArray(raw) ? raw.map((l) => String(l).toUpperCase()) : null;
  const err = layoutError(layout, (await Zone.find({}, { name: 1 }).lean()).map((z) => z.name));
  if (err) throw new HttpError(400, err);
  await syncSlots(layout);
  await Settings.updateOne({ _id: 1 }, { layout });
}

export function lotRouter() {
  const router = Router();

  router.get('/lot/map', async (_req, res) => res.json(await lotMap()));

  // Lưu mặt bằng: kiểm tra lối vào / ra, mọi ô đậu có đường tới, rồi đồng bộ ô đậu.
  router.put('/lot/layout', async (req, res) => {
    await applyLayout(req.body?.layout);
    res.json(await lotMap());
  });

  // ---- Loại xe + bảng giá ----
  router.get('/vehicle-types', async (_req, res) => res.json(Object.values(await vehicleTypes())));

  router.post('/vehicle-types', async (req, res) => {
    const code = str(req.body?.code).toLowerCase();
    if (!CODE_RE.test(code)) throw new HttpError(400, 'Mã loại xe 2-20 ký tự: chữ thường, số, _ (VD: ebike)');
    res.status(201).json(await insert(VehicleType, { code, ...typeInput(req.body) }));
  });

  router.put('/vehicle-types/:id', async (req, res) => {
    const t = await VehicleType.findByIdAndUpdate(Number(req.params.id) || 0, typeInput(req.body), { returnDocument: 'after' }).lean();
    if (!t) throw new HttpError(404, 'Không có loại xe này');
    res.json(row(t));
  });

  router.delete('/vehicle-types/:id', async (req, res) => {
    const t = await VehicleType.findById(Number(req.params.id) || 0).lean();
    if (!t) throw new HttpError(404, 'Không có loại xe này');
    const used = await Promise.all([Zone.exists({ vehicle_type: t.code }), Card.exists({ vehicle_type: t.code }),
      Session.exists({ vehicle_type: t.code })]);
    if (used.some(Boolean)) throw new HttpError(409, IN_USE);
    await VehicleType.deleteOne({ _id: t._id });
    res.status(204).end();
  });

  // ---- Khu (ô của khu vẽ trên mặt bằng bằng chữ cái tên khu) ----
  router.post('/zones', async (req, res) => res.status(201).json(await insert(Zone, zoneInput(req.body, await vehicleTypes()))));

  router.put('/zones/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    const old = await Zone.findById(id).lean();
    if (!old) throw new HttpError(404, 'Không có khu này');
    const data = zoneInput(req.body, await vehicleTypes());
    if (data.name !== old.name) throw new HttpError(400, 'Không đổi tên khu (tên trùng ký tự trên mặt bằng); tạo khu mới rồi vẽ lại');
    if (data.vehicle_type !== old.vehicle_type) {
      const slots = await Slot.find({ zone_id: id }).lean();
      const busy = await occupiedSlots();
      if (slots.some((s) => s.card_uid || busy.has(s.code))) throw new HttpError(409, 'Khu đang có xe hoặc có ô cư dân, không đổi loại xe được');
      await Slot.updateMany({ zone_id: id }, { vehicle_type: data.vehicle_type });
    }
    res.json(row(await Zone.findByIdAndUpdate(id, data, { returnDocument: 'after' }).lean()));
  });

  router.delete('/zones/:id', async (req, res) => {
    const z = await Zone.findById(Number(req.params.id) || 0).lean();
    if (!z) throw new HttpError(404, 'Không có khu này');
    if (await Slot.exists({ zone_id: z._id })) throw new HttpError(409, `Khu ${z.name} còn ô trên mặt bằng, xoá các ô đó trước`);
    await Zone.deleteOne({ _id: z._id });
    res.status(204).end();
  });

  // ---- Ô: gán cho cư dân (thẻ tháng cùng loại xe) / bỏ gán / tạm khoá ----
  router.patch('/slots/:code', async (req, res) => {
    const code = req.params.code.toUpperCase();
    const slot = await Slot.findOne({ code }).lean();
    if (!slot) throw new HttpError(404, 'Không có ô này');
    const changes = {};
    if (req.body && 'cardUid' in req.body) {
      const uid = req.body.cardUid ? String(req.body.cardUid).toUpperCase() : null;
      if (uid) {
        const card = await Card.findOne({ uid }).lean();
        if (!card || card.kind !== 'monthly') throw new HttpError(400, 'Chỉ gán ô cho thẻ vé tháng');
        if (card.vehicle_type && card.vehicle_type !== slot.vehicle_type) throw new HttpError(400, 'Ô này khác loại xe của thẻ');
        await Slot.updateMany({ card_uid: uid, code: { $ne: code } }, { card_uid: null }); // mỗi thẻ 1 ô
      }
      changes.card_uid = uid;
    }
    if (typeof req.body?.active === 'boolean') changes.active = req.body.active;
    res.json(row(await Slot.findOneAndUpdate({ code }, changes, { returnDocument: 'after' }).lean()));
  });
  return router;
}
