import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { loginAs, startApp } from './helpers.js';
import { bestPlate } from '../src/plates.js';

let ctx, token;
const sent = [];
before(async () => {
  ctx = await startApp({
    fetchFn: async (url, init) => {
      sent.push({ url, auth: init.headers.authorization, form: init.body });
      return Response.json({ results: [
        { plate: '59x112345', score: 0.71, candidates: [] },
        { plate: '30a99999', score: 0.98, candidates: [{ plate: '30a99999' }, { plate: '30a99998' }] },
      ] });
    },
    signImage: async (path) => `https://signed.example/${path}?token=t`,
  });
  token = await loginAs(ctx, 'manager', 'quanly');
});
after(() => ctx.close());

test('bestPlate lấy biển tin cậy cao nhất, chuẩn hoá kèm các phương án', () => {
  assert.deepEqual(bestPlate([]), { plate: null, score: 0, candidates: [] });
  assert.deepEqual(bestPlate([{ plate: 'ab-1', score: 0.9 }]), { plate: 'AB1', score: 0.9, candidates: ['AB1'] });
});

test('nhận diện biển: gửi ảnh qua API, token Plate Recognizer chỉ nằm ở máy chủ', async () => {
  const r = await ctx.call('POST', '/plates/recognize', {
    token, raw: new Uint8Array([0xff, 0xd8, 0xff]), headers: { 'content-type': 'image/jpeg' } });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { plate: '30A99999', score: 0.98, candidates: ['30A99999', '30A99998'] });
  assert.equal(sent[0].auth, 'Token plate-token');
  assert.equal(sent[0].form.get('regions'), 'vn');

  const empty = await ctx.call('POST', '/plates/recognize', { token, body: {} });
  assert.equal(empty.status, 400);
  assert.equal((await ctx.call('POST', '/plates/recognize', { raw: 'x', headers: { 'content-type': 'image/jpeg' } })).status, 401);
});

test('ảnh biển số: chỉ ký đúng dạng đường dẫn của ĐT camera', async () => {
  const ok = await ctx.call('GET', '/plates/url?path=in/2026-10-30/1761800000000_A1B2C3D4.jpg', { token });
  assert.equal(ok.body.url, 'https://signed.example/in/2026-10-30/1761800000000_A1B2C3D4.jpg?token=t');
  assert.equal((await ctx.call('GET', '/plates/url?path=../secret', { token })).status, 400);
});
