// Gửi email qua Brevo HTTP API (Render free chặn cổng SMTP nên không dùng Gmail SMTP được).
const BREVO_URL = 'https://api.brevo.com/v3/smtp/email';

const SUBJECTS = {
  register: 'Mã xác minh đăng ký tài khoản',
  login: 'Mã OTP đăng nhập',
};

export function brevoMailer({ apiKey, from }) {
  return async (to, code, purpose) => {
    const res = await fetch(BREVO_URL, {
      method: 'POST',
      headers: { 'api-key': apiKey, 'content-type': 'application/json' },
      body: JSON.stringify({
        sender: { email: from, name: 'Bãi giữ xe' },
        to: [{ email: to }],
        // Mã đặt đầu tiêu đề: mỗi thư một tiêu đề nên Gmail không gộp vào luồng cũ và thấy mã ngay ở thông báo.
        subject: `${code} – ${SUBJECTS[purpose]}`,
        htmlContent: `<p>Mã OTP của bạn là:</p><h2 style="letter-spacing:4px">${code}</h2><p>Mã có hiệu lực trong 5 phút. Không chia sẻ mã này cho ai.</p>`,
      }),
    });
    if (!res.ok) throw new Error(`Brevo ${res.status}: ${await res.text()}`);
  };
}
