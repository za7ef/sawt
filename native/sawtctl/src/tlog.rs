// يلتقط سجل tracing حق idevice (مستوى debug) في ذاكرة، عشان نرجعه في نتيجة التشخيص.
use std::io::Write;
use std::sync::{Mutex, OnceLock};

static BUF: Mutex<Vec<u8>> = Mutex::new(Vec::new());
static INIT: OnceLock<bool> = OnceLock::new();

struct W;
impl Write for W {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        if let Ok(mut v) = BUF.lock() {
            if v.len() < 256 * 1024 { v.extend_from_slice(b) }
        }
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}

pub fn install() -> bool {
    *INIT.get_or_init(|| {
        let sub = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .with_ansi(false)
            .without_time()
            .with_target(true)
            .with_writer(|| W)
            .finish();
        tracing::subscriber::set_global_default(sub).is_ok()
    })
}

pub fn clear() {
    if let Ok(mut v) = BUF.lock() { v.clear() }
}

/// آخر 60 سطر (كل سطر مقصوص لـ300 حرف) ويفضّي المخزن
pub fn take() -> Vec<String> {
    let s = match BUF.lock() {
        Ok(mut v) => { let s = String::from_utf8_lossy(&v).to_string(); v.clear(); s }
        Err(_) => return vec![],
    };
    let lines: Vec<String> = s.lines().map(|l| redact(l).chars().take(300).collect()).collect();
    let start = lines.len().saturating_sub(60);
    lines[start..].to_vec()
}

/// نخفي أي سلسلة طويلة شكلها مفتاح (hex/base64 ≥ 24 حرف) عشان ما تطلع في السجلات
fn redact(l: &str) -> String {
    let mut out = String::new();
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        if run.chars().count() >= 24 { out.push_str("<redacted>") } else { out.push_str(run) }
        run.clear();
    };
    for c in l.chars() {
        if c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=' { run.push(c) } else { flush(&mut run, &mut out); out.push(c) }
    }
    flush(&mut run, &mut out);
    out
}
