// Sơ đồ bãi chung cư: loại xe + bảng giá, khu, ô đậu. Cư dân thuê vé tháng có ô riêng (slot.card_uid);
// khách vãng lai được API chỉ ô trống gần cổng nhất, đúng loại xe, không đụng ô của cư dân.
import { Router } from 'express';
import { HttpError, str } from './auth.js';
import { Card, insert, row, Session, Slot, VehicleType, Zone } from './db.js';
import { IN_USE } from './guards.js';

const CODE_RE = /^[a-z][a-z0-9_]{1,19}$/;
const ZONE_RE = /^[A-Z0-9]{1,4}$/;
const MAX_GRID = 20;

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

const slotCode = (zone, n) => `${zone}-${String(n).padStart(2, '0')}`;

/** Ô đang có xe: code -> lượt gửi đang mở. */
async function occupiedSlots() {
  const parked = await Session.find({ parked: true, slot_code: { $type: 'string' } }, { slot_code: 1, plate_in: 1, card_uid: 1, time_in: 1 }).lean();
  return new Map(parked.map((s) => [s.slot_code, s]));
}

/**
 * Chọn ô cho xe vào. Thẻ tháng có ô riêng -> ô đó. Còn lại: ô trống đầu tiên (khu gần cổng trước, rồi theo hàng / cột),
 * đúng loại xe, không phải ô riêng của cư dân, không tạm khoá. Trả { code } | { full: true } | null (bãi chưa vẽ sơ đồ).
 */
export async function assignSlot(card, vehicleType) {
  if (!(await Slot.exists({}))) return null;
  if (card?.kind === 'monthly') {
    const own = await Slot.findOne({ card_uid: card.uid }).lean();
    if (own) return { code: own.code };
  }
  const zones = await Zone.find({ vehicle_type: vehicleType }).sort({ order: 1, name: 1 }).lean();
  const busy = await occupiedSlots();
  for (const z of zones) {
    const slots = await Slot.find({ zone_id: z._id, card_uid: null, active: true }).sort({ row: 1, col: 1 }).lean();
    const free = slots.find((s) => !busy.has(s.code));
    if (free) return { code: free.code };
  }
  return { full: true };
}

/** Tạo / bổ sung ô cho khu theo lưới rows x cols; bỏ ô thừa khi thu nhỏ (chỉ khi ô đó trống và chưa gán cư dân). */
async function layoutZone(zone) {
  const want = new Set();
  let n = 0;
  for (let r = 0; r < zone.rows; r++) {
    for (let c = 0; c < zone.cols; c++) {
      const code = slotCode(zone.name, ++n);
      want.add(code);
      await Slot.updateOne({ code }, { $set: { zone_id: zone._id, row: r, col: c, vehicle_type: zone.vehicle_type } })
        .then(async ({ matchedCount }) => {
          if (!matchedCount) await insert(Slot, { code, zone_id: zone._id, row: r, col: c, vehicle_type: zone.vehicle_type });
        });
    }
  }
  const extra = await Slot.find({ zone_id: zone._id, code: { $nin: [...want] } }).lean();
  const busy = await occupiedSlots();
  if (extra.some((s) => s.card_uid || busy.has(s.code))) throw new HttpError(409, 'Có ô sắp bị bỏ đang có xe hoặc đã gán cư dân');
  await Slot.deleteMany({ _id: { $in: extra.map((s) => s._id) } });
}

function zoneInput(body, types) {
  const name = str(body?.name).toUpperCase();
  const vt = str(body?.vehicleType);
  const [rows, cols, order] = [body?.rows, body?.cols, body?.order ?? 0];
  if (!ZONE_RE.test(name)) throw new HttpError(400, 'Tên khu 1-4 ký tự chữ / số (VD: A, B1, OTO)');
  if (!types[vt]) throw new HttpError(400, `Loại xe là một trong: ${Object.keys(types).join(', ')}`);
  if (![rows, cols].every((v) => Number.isInteger(v) && v >= 1 && v <= MAX_GRID)) {
    throw new HttpError(400, `Số hàng / cột từ 1 đến ${MAX_GRID}`);
  }
  if (!Number.isInteger(order)) throw new HttpError(400, 'Thứ tự là số nguyên');
  return { name, vehicle_type: vt, rows, cols, order };
}

function typeInput(body) {
  const name = str(body?.name);
  const prices = ['priceDay', 'priceNight', 'priceMonth'].map((k) => body?.[k]);
  if (!name) throw new HttpError(400, 'Cần tên loại xe');
  if (!prices.every((v) => Number.isInteger(v) && v >= 0)) throw new HttpError(400, 'Giá là số nguyên ≥ 0');
  return { name, price_day: prices[0], price_night: prices[1], price_month: prices[2] };
}

/** Sơ đồ bãi đầy đủ: khu + ô kèm trạng thái (free | resident | parked) và xe đang đậu. */
export async function lotMap({ withPlates = true } = {}) {
  const [zones, slots, busy, types] = await Promise.all([
    Zone.find().sort({ order: 1, name: 1 }).lean(), Slot.find().sort({ row: 1, col: 1 }).lean(), occupiedSlots(), vehicleTypes(),
  ]);
  const owners = new Map((await Card.find({ uid: { $in: slots.map((s) => s.card_uid).filter(Boolean) } },
    { uid: 1, owner: 1, apartment: 1, plate: 1 }).lean()).map((c) => [c.uid, c]));
  return {
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
      if (s.state === 'free' && !s.card_uid) t.visitorFree++;
    }
  }
  return out;
}

export function lotRouter() {
  const router = Router();

  router.get('/lot/map', async (_req, res) => res.json(await lotMap()));

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

  // ---- Khu (tự sinh ô theo lưới) ----
  router.post('/zones', async (req, res) => {
    const zone = await insert(Zone, zoneInput(req.body, await vehicleTypes()));
    await layoutZone({ ...zone, _id: zone.id });
    res.status(201).json(zone);
  });

  router.put('/zones/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    const old = await Zone.findById(id).lean();
    if (!old) throw new HttpError(404, 'Không có khu này');
    const data = zoneInput(req.body, await vehicleTypes());
    if (data.name !== old.name || data.vehicle_type !== old.vehicle_type) {
      const busy = await occupiedSlots();
      const slots = await Slot.find({ zone_id: id }).lean();
      if (slots.some((s) => busy.has(s.code))) throw new HttpError(409, 'Khu đang có xe, không đổi tên / loại xe được');
      if (data.vehicle_type !== old.vehicle_type && slots.some((s) => s.card_uid)) {
        throw new HttpError(409, 'Khu có ô đã gán cư dân, không đổi loại xe được');
      }
      // Đổi tên khu: đổi mã các ô theo, giữ ô đã gán cư dân.
      for (const s of slots) await Slot.updateOne({ _id: s._id }, { code: `tmp-${s._id}` });
      for (const s of slots) await Slot.updateOne({ _id: s._id }, { code: slotCode(data.name, s.row * old.cols + s.col + 1) });
    }
    const zone = row(await Zone.findByIdAndUpdate(id, data, { returnDocument: 'after' }).lean());
    await layoutZone({ ...zone, _id: id });
    res.json(zone);
  });

  router.delete('/zones/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    if (!(await Zone.exists({ _id: id }))) throw new HttpError(404, 'Không có khu này');
    const busy = await occupiedSlots();
    const slots = await Slot.find({ zone_id: id }).lean();
    if (slots.some((s) => busy.has(s.code) || s.card_uid)) throw new HttpError(409, 'Khu đang có xe hoặc có ô của cư dân');
    await Slot.deleteMany({ zone_id: id });
    await Zone.deleteOne({ _id: id });
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
