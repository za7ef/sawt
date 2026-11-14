// sawtctl: تجربة "تحكم بالجوال" في صوت — يتصل بخدمات المطوّر في نفس الجوال عن طريق
// الـloopback (10.7.0.1 عبر LocalDevVPN) وملف الاقتران، ويقرأ شجرة الوصول ويرسل لمسات.
// مبني على مكتبة idevice (MIT). كتابة مستقلة؛ ما فيه كود منسوخ من Poki.

mod ax;
mod stream;

use idevice::{
    IdeviceService, RsdService,
    core_device::{ButtonState, IndigoHidClient, UniversalHidServiceClient},
    core_device_proxy::CoreDeviceProxy,
    pairing_file::PairingFile,
    provider::TcpProvider,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use serde_json::{Value as Json, json};
use std::ffi::{CStr, CString, c_char};
use std::time::{Duration, Instant};

type Res<T> = Result<T, String>;

struct Session {
    adapter: AdapterHandle,
    rsd: RsdHandshake,
}

#[derive(serde::Deserialize)]
struct Config {
    pairing_file: String,
    #[serde(default = "default_host")]
    host: String,
}
fn default_host() -> String {
    "10.7.0.1".into()
}

async fn connect(cfg: &Config, steps: &mut Vec<Json>) -> Res<Session> {
    let t0 = Instant::now();
    let pairing = PairingFile::read_from_file(&cfg.pairing_file).map_err(|e| format!("ملف الاقتران: {e:?}"))?;
    let addr = cfg.host.parse().map_err(|e| format!("العنوان: {e:?}"))?;
    let provider = TcpProvider { addr, scope_id: None, pairing_file: pairing, label: "Sawt".into() };
    let proxy = tokio::time::timeout(Duration::from_secs(10), CoreDeviceProxy::connect(&provider))
        .await
        .map_err(|_| "انتهى الوقت وهو يتصل بـ CoreDeviceProxy (الـVPN شغال؟)".to_string())?
        .map_err(|e| format!("CoreDeviceProxy: {e:?}"))?;
    steps.push(json!({"step": "core_device_proxy", "ms": t0.elapsed().as_millis()}));
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = proxy.create_software_tunnel().map_err(|e| format!("tunnel: {e:?}"))?;
    let mut adapter = adapter.to_async_handle();
    let s = adapter.connect(rsd_port).await.map_err(|e| format!("RSD connect: {e:?}"))?;
    let rsd = RsdHandshake::new(s).await.map_err(|e| format!("RSD handshake: {e:?}"))?;
    steps.push(json!({"step": "rsd", "ms": t0.elapsed().as_millis(), "services": rsd.services.len()}));
    Ok(Session { adapter, rsd })
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime")
}

fn run(cfg_json: *const c_char, f: impl AsyncFnOnce(Config, &mut Vec<Json>) -> Res<Json>) -> *mut c_char {
    let t0 = Instant::now();
    let mut steps = Vec::new();
    let out = (|| {
        let s = unsafe { CStr::from_ptr(cfg_json) }.to_string_lossy().to_string();
        let cfg: Config = serde_json::from_str(&s).map_err(|e| format!("config: {e}"))?;
        runtime().block_on(f(cfg, &mut steps))
    })();
    let v = match out {
        Ok(mut v) => {
            v["ok"] = true.into();
            v
        }
        Err(e) => json!({"ok": false, "error": e}),
    };
    let mut v = v;
    v["steps"] = steps.into();
    v["ms"] = (t0.elapsed().as_millis() as u64).into();
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

fn cstr(p: *const c_char) -> String {
    if p.is_null() { return String::new() }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().to_string()
}

/// يفحص الاتصال ويسرد الخدمات المهمة
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_probe(cfg: *const c_char) -> *mut c_char {
    run(cfg, async |cfg, steps| {
        let s = connect(&cfg, steps).await?;
        let mut names: Vec<String> = s.rsd.services.keys().cloned().collect();
        names.sort();
        let want = [
            "com.apple.accessibility.axAuditDaemon.remoteAXService",
            "com.apple.accessibility.axAuditDaemon.remoteserver",
            "com.apple.coredevice.hid.universalhidservice",
            "com.apple.coredevice.hid.indigo",
            "com.apple.coredevice.displayservice",
            "com.apple.coredevice.appservice",
            "com.apple.instruments.dtservicehub",
        ];
        let have: Vec<Json> = want.iter().map(|w| json!({"name": w, "present": s.rsd.services.contains_key(*w)})).collect();
        let interesting: Vec<&String> = names.iter().filter(|n| n.contains("hid") || n.contains("access") || n.contains("display") || n.contains("coredevice")).collect();
        Ok(json!({"count": names.len(), "key_services": have, "related": interesting}))
    })
}

/// لمسة بإحداثيات طبيعية 0..65535
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_tap(cfg: *const c_char, x: u16, y: u16) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let st = stream::start_screen_media_stream(&mut s.adapter, &mut s.rsd, 1).await?;
        steps.push(json!({"step": "media_stream"}));
        tokio::time::sleep(Duration::from_millis(300)).await;
        let mut hid = UniversalHidServiceClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("hid: {e:?}"))?;
        hid.tap(x, y).await.map_err(|e| format!("tap: {e:?}"))?;
        steps.push(json!({"step": "tap"}));
        let mut client = st.client;
        let _ = client.stop_media_stream().await;
        drop((st.audio_udp, st.video_udp));
        Ok(json!({"tapped": [x, y]}))
    })
}

/// سحب (للتمرير)
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_drag(cfg: *const c_char, x1: u16, y1: u16, x2: u16, y2: u16) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let st = stream::start_screen_media_stream(&mut s.adapter, &mut s.rsd, 1).await?;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let mut hid = UniversalHidServiceClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("hid: {e:?}"))?;
        hid.drag(x1, y1, x2, y2, 30, 20).await.map_err(|e| format!("drag: {e:?}"))?;
        let mut client = st.client;
        let _ = client.stop_media_stream().await;
        drop((st.audio_udp, st.video_udp));
        Ok(json!({"dragged": [x1, y1, x2, y2]}))
    })
}

/// زر (home / lock) أو مفاتيح لوحة (usage codes) — paste = Cmd+V
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_keys(cfg: *const c_char, what: *const c_char) -> *mut c_char {
    let what = cstr(what);
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let st = stream::start_screen_media_stream(&mut s.adapter, &mut s.rsd, 1).await?;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let mut ind = IndigoHidClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("indigo: {e:?}"))?;
        let e = |e| format!("key: {e:?}");
        match what.as_str() {
            "home" => {
                ind.send_button(0x0C, 0x40, ButtonState::Down).await.map_err(e)?;
                tokio::time::sleep(Duration::from_millis(80)).await;
                ind.send_button(0x0C, 0x40, ButtonState::Up).await.map_err(e)?;
            }
            "paste" => {
                // Cmd (Left GUI 0xE3) + V (0x19)
                ind.send_keyboard(0xE3, ButtonState::Down).await.map_err(e)?;
                ind.send_keyboard(0x19, ButtonState::Down).await.map_err(e)?;
                tokio::time::sleep(Duration::from_millis(40)).await;
                ind.send_keyboard(0x19, ButtonState::Up).await.map_err(e)?;
                ind.send_keyboard(0xE3, ButtonState::Up).await.map_err(e)?;
            }
            "return" => {
                ind.send_keyboard(0x28, ButtonState::Down).await.map_err(e)?;
                ind.send_keyboard(0x28, ButtonState::Up).await.map_err(e)?;
            }
            text => {
                for ch in text.chars() {
                    let Some((u, shift)) = ascii_usage(ch) else { continue };
                    if shift { ind.send_keyboard(0xE1, ButtonState::Down).await.map_err(e)?; }
                    ind.send_keyboard(u, ButtonState::Down).await.map_err(e)?;
                    ind.send_keyboard(u, ButtonState::Up).await.map_err(e)?;
                    if shift { ind.send_keyboard(0xE1, ButtonState::Up).await.map_err(e)?; }
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
            }
        }
        steps.push(json!({"step": "keys"}));
        let mut client = st.client;
        let _ = client.stop_media_stream().await;
        drop((st.audio_udp, st.video_udp));
        Ok(json!({"sent": what}))
    })
}

/// يقرأ شجرة الوصول للتطبيق اللي قدّام (تجربة: نرجع النصوص والرسائل كما هي)
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_ax(cfg: *const c_char, wait_ms: u32) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        ax::dump(&mut s.adapter, &s.rsd, Duration::from_millis(wait_ms as u64), steps).await
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) }
    }
}

fn ascii_usage(c: char) -> Option<(u64, bool)> {
    let lower = "abcdefghijklmnopqrstuvwxyz";
    if let Some(i) = lower.find(c) { return Some((0x04 + i as u64, false)) }
    if let Some(i) = lower.find(c.to_ascii_lowercase()) { return Some((0x04 + i as u64, true)) }
    Some(match c {
        '1'..='9' => (0x1E + (c as u64 - '1' as u64), false),
        '0' => (0x27, false),
        ' ' => (0x2C, false),
        '\n' => (0x28, false),
        '.' => (0x37, false),
        ',' => (0x36, false),
        '-' => (0x2D, false),
        '?' => (0x38, true),
        '!' => (0x1E, true),
        '@' => (0x1F, true),
        '/' => (0x38, false),
        ':' => (0x33, true),
        _ => return None,
    })
}
