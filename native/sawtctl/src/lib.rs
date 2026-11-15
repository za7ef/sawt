// sawtctl: تجربة "تحكم بالجوال" في صوت — يتصل بخدمات المطوّر في نفس الجوال عن طريق
// الـloopback (10.7.0.1 عبر LocalDevVPN) وملف الاقتران، ويقرأ شجرة الوصول ويرسل لمسات.
// مبني على مكتبة idevice (MIT). كتابة مستقلة؛ ما فيه كود منسوخ من Poki.

mod ax;
mod stream;
mod tlog;

use idevice::{
    IdeviceService, RsdService,
    core_device::{ButtonState, IndigoHidClient, UniversalHidServiceClient},
    core_device::hid::{KeyboardUsage, MainKeyboardService, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE},
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
    #[serde(default)]
    rp_port: u16,
    #[serde(default)]
    rp_host: String,
    #[serde(default = "default_hostname")]
    rp_hostname: String,
}
fn default_hostname() -> String {
    "Sawt".into()
}
fn default_host() -> String {
    "10.7.0.1".into()
}

/// نوع ملف الاقتران: lockdown الكلاسيكي (HostID/DeviceCertificate…) أو RemotePairing (public_key/private_key/identifier)
fn pairing_kind(bytes: &[u8]) -> &'static str {
    match plist::Value::from_reader(std::io::Cursor::new(bytes)) {
        Ok(plist::Value::Dictionary(d)) => {
            if d.contains_key("public_key") && d.contains_key("private_key") && d.contains_key("identifier") {
                "rppairing"
            } else if d.contains_key("HostID") || d.contains_key("DeviceCertificate") || d.contains_key("HostPrivateKey") {
                "lockdown"
            } else {
                "unknown"
            }
        }
        _ => "invalid",
    }
}

async fn connect(cfg: &Config, steps: &mut Vec<Json>) -> Res<Session> {
    let bytes = std::fs::read(&cfg.pairing_file).map_err(|e| format!("ملف الاقتران: {e}"))?;
    let kind = pairing_kind(&bytes);
    steps.push(json!({"step": "pairing_kind", "kind": kind}));
    if kind == "rppairing" {
        return connect_rp(cfg, &bytes, steps).await;
    }
    match connect_lockdown(cfg, &bytes, steps).await {
        Ok(s) => Ok(s),
        // إذا فشل تحليل lockdown نجرب RemotePairing
        Err(e) if e.contains("ملف الاقتران (lockdown)") => {
            steps.push(json!({"step": "lockdown_parse_failed", "error": e}));
            connect_rp(cfg, &bytes, steps).await.map_err(|e2| format!("{e} | RP: {e2}"))
        }
        Err(e) => Err(e),
    }
}

async fn connect_lockdown(cfg: &Config, bytes: &[u8], steps: &mut Vec<Json>) -> Res<Session> {
    let t0 = Instant::now();
    let pairing = PairingFile::from_bytes(bytes).map_err(|e| format!("ملف الاقتران (lockdown): {e:?}"))?;
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

/// مسار RemotePairing: اتصال RPPairing مباشر بمنفذ _remotepairing._tcp (يكتشفه التطبيق عبر Bonjour)
/// → تحقق الاقتران → نفق TLS-PSK → RSD (نفس تسلسل tunnel_create_rppairing في idevice، MIT)
async fn connect_rp(cfg: &Config, bytes: &[u8], steps: &mut Vec<Json>) -> Res<Session> {
    use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native};
    let t0 = Instant::now();
    let _ = tlog::install();
    let mut rpf = RpPairingFile::from_bytes(bytes).map_err(|e| format!("ملف الاقتران (RP): {e:?}"))?;
    tlog::clear();   // سجل القراءة فيه المفاتيح: نمسحه
    {
        let pubb = rpf.public_key_bytes();
        let derived = rpf.e_private_key.verifying_key().to_bytes().to_vec();
        let fp: String = pubb.iter().take(4).map(|b| format!("{b:02x}")).collect();
        steps.push(json!({"step": "pairing_check", "identifier": rpf.identifier(), "pub_matches_priv": derived == pubb,
                          "pub_fp": fp, "alt_irk": rpf.alt_irk().map(|x| x.len())}));
    }
    let ip: std::net::IpAddr = cfg.host.parse().map_err(|e| format!("العنوان: {e:?}"))?;
    // المنافذ: المكتشف أولًا، بعدين 49152 (الافتراضي)، بعدين مسح سريع
    let mut ports: Vec<u16> = Vec::new();
    if cfg.rp_port != 0 { ports.push(cfg.rp_port) }
    if !ports.contains(&49152) { ports.push(49152) }
    for p in 49153..=49200u16 { if !ports.contains(&p) { ports.push(p) } }
    // نجرب 10.7.0.1 أولًا، وبعدين عنوان Bonjour (إن وُجد)
    // عنوان Bonjour أولًا (الخدمة الفعلية)، بعدين 10.7.0.1 (مثل StikDebug)، بعدين loopback
    // 10.7.0.1 أولًا (هو اللي رد على المصافحة، مثل StikDebug)، بعدين عنوان Bonjour
    let mut hosts: Vec<std::net::IpAddr> = vec![ip];
    if let Ok(h) = cfg.rp_host.split('%').next().unwrap_or("").parse::<std::net::IpAddr>() { if !hosts.contains(&h) { hosts.push(h) } }
    steps.push(json!({"step": "rp_hosts", "order": hosts.iter().map(|h| h.to_string()).collect::<Vec<_>>()}));
    let mut last_err = String::from("ما فيه عنوان");
    let mut done: Option<(RemotePairingClient<RpPairingSocket<tokio::net::TcpStream>>, std::net::IpAddr)> = None;
    for host in hosts {
        match rp_try_host(host, &ports, &mut rpf, &cfg.rp_hostname, steps).await {
            Ok(rpc) => { done = Some((rpc, host)); break }
            Err(e) => { steps.push(json!({"step": "rp_host_failed", "host": host.to_string(), "error": e.clone()})); last_err = e }
        }
    }
    let (mut rpc, ip) = done.ok_or(last_err)?;
    let lport = rpc.create_tcp_listener().await.map_err(|e| format!("tcp listener: {e:?}"))?;
    steps.push(json!({"step": "rp_listener", "port": lport}));
    let tstream = tokio::net::TcpStream::connect(std::net::SocketAddr::new(ip, lport))
        .await
        .map_err(|e| format!("TLS tunnel: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tstream, rpc.encryption_key())
        .await
        .map_err(|e| format!("TLS-PSK: {e:?}"))?;
    let client_ip: std::net::IpAddr = tunnel.info.client_address.parse().map_err(|e| format!("{e}"))?;
    let server_ip: std::net::IpAddr = tunnel.info.server_address.parse().map_err(|e| format!("{e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let raw = tunnel.into_inner();
    let mut a = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    a.set_mss(mtu.min(8192) - 60);
    let mut adapter = a.to_async_handle();
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
async fn rp_try_host(
    ip: std::net::IpAddr,
    ports: &[u16],
    rpf: &mut idevice::remote_pairing::RpPairingFile,
    hostname: &str,
    steps: &mut Vec<Json>,
) -> Res<idevice::remote_pairing::RemotePairingClient<idevice::remote_pairing::RpPairingSocket<tokio::net::TcpStream>>> {
    use idevice::remote_pairing::{RemotePairingClient, RpPairingSocket};
    let t0 = Instant::now();
    let mut closed = Vec::new();
    let mut last = format!("ما لقيت منفذ RemotePairing يرد على {ip}");
    let mut handshakes = 0;
    for &p in ports {
        let addr = std::net::SocketAddr::new(ip, p);
        let st = match tokio::time::timeout(Duration::from_millis(400), tokio::net::TcpStream::connect(addr)).await {
            Ok(Ok(st)) => st,
            Ok(Err(e)) => { if closed.len() < 8 { closed.push(json!({"port": p, "r": e.kind().to_string()})) } continue }
            Err(_) => { if closed.len() < 8 { closed.push(json!({"port": p, "r": "timeout"})) } continue }
        };
        // المنفذ مفتوح: ما نعتمده إلا إذا نجح handshake حق RPPairing
        handshakes += 1;
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(st), hostname);
        tlog::clear();
        let hs = tokio::time::timeout(Duration::from_secs(4), rpc.attempt_pair_verify()).await;
        match hs {
            Ok(Ok(v)) => {
                let keys: Vec<String> = v.as_dictionary().map(|d| d.keys().cloned().collect()).unwrap_or_default();
                steps.push(json!({"step": "rp_handshake_ok", "host": ip.to_string(), "port": p, "response_keys": keys, "trace": tlog::take()}));
            }
            Ok(Err(e)) => {
                last = format!("handshake {ip}:{p}: {e:?}");
                steps.push(json!({"step": "rp_handshake_failed", "host": ip.to_string(), "port": p, "error": format!("{e:?}"), "trace": tlog::take()}));
                if handshakes >= 4 { break }
                continue;
            }
            Err(_) => {
                last = format!("handshake {ip}:{p}: timeout");
                steps.push(json!({"step": "rp_handshake_timeout", "host": ip.to_string(), "port": p, "trace": tlog::take()}));
                if handshakes >= 4 { break }
                continue;
            }
        }
        let v = rpc.validate_pairing(rpf).await;
        steps.push(json!({"step": "rp_verify", "host": ip.to_string(), "port": p, "ok": v.is_ok(), "error": v.as_ref().err().map(|e| format!("{e:?}")), "trace": tlog::take()}));
        match v {
            // ما نسوي اقتران جديد بـPIN هنا
            Ok(()) => return Ok(rpc),
            Err(e) => { last = format!("pair-verify {ip}:{p}: {e:?}"); if handshakes >= 4 { break } }
        }
    }
    steps.push(json!({"step": "rp_ports_summary", "host": ip.to_string(), "not_open": closed, "handshakes": handshakes, "ms": t0.elapsed().as_millis()}));
    Err(last)
}

/// اقتران جديد من الجوال نفسه (pair-setup عبر RPPairing على 10.7.0.1، PIN 000000 مثل iOS)
/// ويحفظ الملف الجديد مكان القديم (مع نسخة .bak)
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_pair(cfg: *const c_char) -> *mut c_char {
    run(cfg, async |cfg, steps| {
        use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
        let _ = tlog::install();
        let ip: std::net::IpAddr = cfg.host.parse().map_err(|e| format!("العنوان: {e:?}"))?;
        let mut ports: Vec<u16> = Vec::new();
        if cfg.rp_port != 0 { ports.push(cfg.rp_port) }
        if !ports.contains(&49152) { ports.push(49152) }
        let mut last = String::from("ما فيه منفذ");
        for p in ports {
            let addr = std::net::SocketAddr::new(ip, p);
            let st = match tokio::time::timeout(Duration::from_secs(2), tokio::net::TcpStream::connect(addr)).await {
                Ok(Ok(st)) => st,
                Ok(Err(e)) => { last = format!("{addr}: {e}"); continue }
                Err(_) => { last = format!("{addr}: timeout"); continue }
            };
            let mut rpc = RemotePairingClient::new(RpPairingSocket::new(st), &cfg.rp_hostname);
            tlog::clear();
            let hs = rpc.attempt_pair_verify().await;
            steps.push(json!({"step": "pair_handshake", "port": p, "ok": hs.is_ok(), "error": hs.as_ref().err().map(|e| format!("{e:?}"))}));
            if let Err(e) = hs { last = format!("handshake: {e:?}"); continue }
            let mut rpf = RpPairingFile::generate(&cfg.rp_hostname);
            tlog::clear();
            // ممكن يطلع للمستخدم طلب ثقة على الشاشة: ننتظر لين دقيقتين
            let r = tokio::time::timeout(Duration::from_secs(120), rpc.pair(&mut rpf, async || "000000".to_string())).await;
            let trace = tlog::take();
            match r {
                Ok(Ok(())) => {
                    let path = std::path::Path::new(&cfg.pairing_file);
                    if path.exists() { let _ = std::fs::copy(path, path.with_extension("plist.bak")); }
                    std::fs::write(path, rpf.to_bytes()).map_err(|e| format!("حفظ الملف: {e}"))?;
                    tlog::clear();
                    steps.push(json!({"step": "pair_saved", "identifier": rpf.identifier()}));
                    return Ok(json!({"paired": true, "port": p, "identifier": rpf.identifier()}));
                }
                Ok(Err(e)) => { steps.push(json!({"step": "pair_failed", "error": format!("{e:?}"), "trace": trace})); last = format!("pair: {e:?}") }
                Err(_) => { steps.push(json!({"step": "pair_timeout", "trace": trace})); last = "انتهى الوقت (ما وصل رد/موافقة)".into() }
            }
        }
        Err(last)
    })
}

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

/// جلسة إدخال: بث الشاشة لازم يكون شغال عشان dtuhidd يقبل أحداث اللمس والكيبورد.
/// نفرّغ حزم UDP أول بأول (وإلا تتكدس)، وننتظر ثانية كاملة قبل أول حدث.
struct Input {
    client: idevice::core_device::DisplayServiceClient<Box<dyn idevice::ReadWrite>>,
    drains: Vec<tokio::task::JoinHandle<()>>,
}
async fn open_input(s: &mut Session, steps: &mut Vec<Json>) -> Res<Input> {
    let st = stream::start_screen_media_stream(&mut s.adapter, &mut s.rsd, 1).await?;
    steps.push(json!({"step": "media_stream"}));
    let mut drains = Vec::new();
    for sock in [st.audio_udp, st.video_udp] {
        drains.push(tokio::spawn(async move { while sock.recv().await.is_ok() {} }));
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
    Ok(Input { client: st.client, drains })
}
async fn close_input(mut i: Input) {
    let _ = tokio::time::timeout(Duration::from_secs(2), i.client.stop_media_stream()).await;
    for d in i.drains { d.abort(); }
}

type Uhid = UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>;

/// لمسة بإحداثيات طبيعية 0..65535
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_tap(cfg: *const c_char, x: u16, y: u16) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let inp = open_input(&mut s, steps).await?;
        let r: Res<()> = async {
            let mut hid = Uhid::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("hid: {e:?}"))?;
            hid.send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None).await.map_err(|e| format!("touch down: {e:?}"))?;
            tokio::time::sleep(Duration::from_millis(80)).await;
            hid.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None).await.map_err(|e| format!("touch up: {e:?}"))?;
            steps.push(json!({"step": "tap"}));
            // الجوال أحيانًا يتجاهل لمسة لو انقفل الاتصال بعدها مباشرة
            tokio::time::sleep(Duration::from_millis(400)).await;
            drop(hid);
            Ok(())
        }.await;
        close_input(inp).await;
        r?;
        Ok(json!({"tapped": [x, y]}))
    })
}

/// سحب (للتمرير)
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_drag(cfg: *const c_char, x1: u16, y1: u16, x2: u16, y2: u16) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let inp = open_input(&mut s, steps).await?;
        let r: Res<()> = async {
            let mut hid = Uhid::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("hid: {e:?}"))?;
            hid.drag(x1, y1, x2, y2, 20, 16).await.map_err(|e| format!("drag: {e:?}"))?;
            tokio::time::sleep(Duration::from_millis(400)).await;
            drop(hid);
            Ok(())
        }.await;
        close_input(inp).await;
        r?;
        Ok(json!({"dragged": [x1, y1, x2, y2]}))
    })
}

/// كيبورد افتراضي (UniversalHID mainKeyboard): نسجّله، نضغط، ونشيله
async fn kb_press(hid: &mut Uhid, kb: &mut MainKeyboardService, mods: &[u16], key: u16, gap: u64) -> Res<()> {
    let e = |e| format!("kbd: {e:?}");
    let mut held = Vec::new();
    for m in mods {
        let u = KeyboardUsage::new(*m).map_err(e)?;
        hid.main_keyboard_key_down(kb, u).await.map_err(e)?;
        held.push(u);
        tokio::time::sleep(Duration::from_millis(gap)).await;
    }
    let k = KeyboardUsage::new(key).map_err(e)?;
    hid.main_keyboard_key_down(kb, k).await.map_err(e)?;
    tokio::time::sleep(Duration::from_millis(gap)).await;
    hid.main_keyboard_key_up(kb, k).await.map_err(e)?;
    for u in held.into_iter().rev() {
        tokio::time::sleep(Duration::from_millis(gap)).await;
        hid.main_keyboard_key_up(kb, u).await.map_err(e)?;
    }
    tokio::time::sleep(Duration::from_millis(gap)).await;
    Ok(())
}

/// زر (home) أو كتابة: paste / paste:<نص> = Cmd+V، return، أو نص إنجليزي حرف حرف
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_keys(cfg: *const c_char, what: *const c_char) -> *mut c_char {
    let what = cstr(what);
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let mut what = what;
        if let Some(t) = what.strip_prefix("paste:").map(|x| x.to_string()) {
            let mut pb = idevice::core_device::PasteboardServiceClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("pasteboard: {e:?}"))?;
            pb.set_text(&t, idevice::core_device::GENERAL_PASTEBOARD).await.map_err(|e| format!("pasteboard set: {e:?}"))?;
            steps.push(json!({"step": "pasteboard_set", "chars": t.chars().count()}));
            what = "paste".into();
        }
        let inp = open_input(&mut s, steps).await?;
        let r: Res<()> = async {
            if what == "home" {
                let mut ind = IndigoHidClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("indigo: {e:?}"))?;
                let e = |e| format!("key: {e:?}");
                ind.send_button(0x0C, 0x40, ButtonState::Down).await.map_err(e)?;
                tokio::time::sleep(Duration::from_millis(80)).await;
                ind.send_button(0x0C, 0x40, ButtonState::Up).await.map_err(e)?;
                tokio::time::sleep(Duration::from_millis(300)).await;
                return Ok(());
            }
            let mut hid = Uhid::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("hid: {e:?}"))?;
            let mut kb = hid.create_main_keyboard().await.map_err(|e| format!("kbd create: {e:?}"))?;
            steps.push(json!({"step": "keyboard_attached"}));
            tokio::time::sleep(Duration::from_millis(250)).await;
            let res: Res<()> = async {
                match what.as_str() {
                    "paste" => kb_press(&mut hid, &mut kb, &[0xE3], 0x19, 50).await?,
                    "return" => kb_press(&mut hid, &mut kb, &[], 0x28, 30).await?,
                    text => {
                        for ch in text.chars() {
                            let Some((u, shift)) = ascii_usage(ch) else { continue };
                            let mods: &[u16] = if shift { &[0xE1] } else { &[] };
                            kb_press(&mut hid, &mut kb, mods, u as u16, 12).await?;
                        }
                    }
                }
                Ok(())
            }.await;
            let _ = hid.set_main_keyboard_usages(&mut kb, []).await;
            steps.push(json!({"step": "keys", "ok": res.is_ok()}));
            tokio::time::sleep(Duration::from_millis(300)).await;
            let _ = hid.remove_main_keyboard(&mut kb).await;
            res
        }.await;
        close_input(inp).await;
        r?;
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

/// يفتح تطبيق: معرّف حزمة مباشرة، أو اسم نطابقه من قائمة التطبيقات المثبتة. "list" يرجع القائمة.
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_launch(cfg: *const c_char, query: *const c_char) -> *mut c_char {
    let q = unsafe { std::ffi::CStr::from_ptr(query) }.to_string_lossy().trim().to_string();
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let mut asvc = idevice::core_device::AppServiceClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("appservice: {e:?}"))?;
        let looks_id = q.contains('.') && !q.contains(' ');
        let mut bundle = if looks_id { Some(q.clone()) } else { None };
        let mut names = Vec::new();
        if bundle.is_none() || q == "list" {
            let apps = asvc.list_apps(false, true, false, false, true).await.map_err(|e| format!("list_apps: {e:?}"))?;
            let norm = |x: &str| x.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<String>();
            let nq = norm(&q);
            let mut best: Option<(u8, String)> = None;
            for a in &apps {
                names.push(json!([a.name, a.bundle_identifier]));
                let na = norm(&a.name);
                if nq.is_empty() || na.is_empty() { continue }
                let score = if na == nq { 3 } else if na.starts_with(&nq) || nq.starts_with(&na) { 2 } else if na.contains(&nq) || nq.contains(&na) { 1 } else { 0 };
                if score > 0 && best.as_ref().map_or(true, |b| score > b.0) { best = Some((score, a.bundle_identifier.clone())) }
            }
            steps.push(json!({"step": "apps", "count": apps.len()}));
            if q == "list" { return Ok(json!({"apps": names})) }
            bundle = best.map(|b| b.1);
        }
        let b = bundle.ok_or_else(|| format!("ما لقيت تطبيق باسم «{q}»"))?;
        let r = asvc.launch_application(b.clone(), &[], false, false, None, None, None).await.map_err(|e| format!("launch {b}: {e:?}"))?;
        Ok(json!({"bundle": b, "pid": r.pid}))
    })
}

/// لقطة شاشة (PNG) عبر خدمة الأدوات، تنحفظ في المسار المعطى
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_shot(cfg: *const c_char, path: *const c_char) -> *mut c_char {
    let out = unsafe { std::ffi::CStr::from_ptr(path) }.to_string_lossy().to_string();
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        let mut rs = idevice::dvt::remote_server::RemoteServerClient::connect_rsd(&mut s.adapter, &mut s.rsd).await.map_err(|e| format!("dtservicehub: {e:?}"))?;
        rs.read_message(0).await.map_err(|e| format!("dtservicehub read: {e:?}"))?;
        let mut sc = idevice::dvt::screenshot::ScreenshotClient::new(&mut rs).await.map_err(|e| format!("screenshot: {e:?}"))?;
        let png = sc.take_screenshot().await.map_err(|e| format!("take_screenshot: {e:?}"))?;
        std::fs::write(&out, &png).map_err(|e| format!("write: {e}"))?;
        steps.push(json!({"step": "shot", "bytes": png.len()}));
        Ok(json!({"path": out, "bytes": png.len()}))
    })
}

/// عناصر الشاشة الظاهرة مع إطاراتها (للوكيل)
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_screen(cfg: *const c_char, wait_ms: u32) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        let mut s = connect(&cfg, steps).await?;
        ax::elements(&mut s.adapter, &s.rsd, Duration::from_millis(wait_ms.max(1500) as u64), steps).await
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

// ===== اقتران يبدأه الجوال (iOS 27): التطبيق يتصرف كـ"كمبيوتر قابل للاقتران" =====
// نفس طريقة idevice (pairable_host) اللي تستخدمها StikJIT: نفتح منفذ TCP، والتطبيق
// (Swift) يعلن خدمة _remotepairing-pairable-host._tcp عبر Bonjour، والجوال يتصل ويسوي pair-setup
// بالرمز اللي نعرضه للمستخدم.
struct HostPairing {
    listener: std::net::TcpListener,
    rpf: idevice::remote_pairing::RpPairingFile,
    info: idevice::remote_pairing::PairableHostInfo,
}
static HOST_PAIRING: std::sync::Mutex<Option<HostPairing>> = std::sync::Mutex::new(None);
static HOST_CANCEL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// يجهز المنفذ والهوية، ويرجّع {port, identifier, txt} عشان Swift يعلن الخدمة
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_host_begin(cfg: *const c_char) -> *mut c_char {
    run(cfg, async |cfg, _steps| {
        use idevice::remote_pairing::{PairableHostInfo, RpPairingFile};
        HOST_CANCEL.store(false, std::sync::atomic::Ordering::SeqCst);
        let listener = std::net::TcpListener::bind(("0.0.0.0", 0)).map_err(|e| format!("bind: {e}"))?;
        listener.set_nonblocking(true).map_err(|e| format!("{e}"))?;
        let port = listener.local_addr().map_err(|e| format!("{e}"))?.port();
        let name = if cfg.rp_hostname.is_empty() { "Sawt".to_string() } else { cfg.rp_hostname.clone() };
        let rpf = RpPairingFile::generate(&name);
        let info = PairableHostInfo::generate(&name, "Mac17,7");
        let id = rpf.identifier.clone();
        let txt: serde_json::Map<String, Json> = info.mdns_txt_records(&id).into_iter().map(|(k, v)| (k, Json::String(v))).collect();
        *HOST_PAIRING.lock().map_err(|_| "lock")? = Some(HostPairing { listener, rpf, info });
        Ok(json!({"port": port, "identifier": id, "name": name, "txt": txt}))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_host_cancel() {
    HOST_CANCEL.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// ينتظر الجوال يتصل (لين timeout_s)، ويستدعي pin_cb بالرمز، ويحفظ الملف الجديد
#[unsafe(no_mangle)]
pub extern "C" fn sawtctl_host_accept(cfg: *const c_char, timeout_s: u32, pin_cb: Option<extern "C" fn(*const c_char)>) -> *mut c_char {
    run(cfg, async move |cfg, steps| {
        use idevice::remote_pairing::{PairableHost, RpPairingSocket};
        let _ = tlog::install();
        let HostPairing { listener, mut rpf, info } = HOST_PAIRING.lock().map_err(|_| "lock")?.take().ok_or("ما فيه اقتران مجهّز")?;
        let listener = tokio::net::TcpListener::from_std(listener).map_err(|e| format!("{e}"))?;
        let deadline = Instant::now() + Duration::from_secs(timeout_s.max(10) as u64);
        let (stream, peer) = loop {
            if HOST_CANCEL.load(std::sync::atomic::Ordering::SeqCst) { return Err("انلغى".into()) }
            if Instant::now() > deadline { return Err("انتهى الوقت وما اتصل الجوال".into()) }
            match tokio::time::timeout(Duration::from_millis(300), listener.accept()).await {
                Ok(Ok(x)) => break x,
                Ok(Err(e)) => return Err(format!("accept: {e}")),
                Err(_) => continue,
            }
        };
        steps.push(json!({"step": "host_connected", "peer": peer.to_string()}));
        tlog::clear();
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
        let r = tokio::time::timeout(Duration::from_secs(180), host.accept(&mut rpf, |pin: String| async move {
            if let (Some(cb), Ok(c)) = (pin_cb, CString::new(pin)) { cb(c.as_ptr()) }
        })).await;
        let trace = tlog::take();
        match r {
            Ok(Ok(peer_dev)) => {
                let path = std::path::Path::new(&cfg.pairing_file);
                if path.exists() { let _ = std::fs::copy(path, path.with_extension("plist.bak")); }
                std::fs::write(path, rpf.to_bytes()).map_err(|e| format!("حفظ الملف: {e}"))?;
                tlog::clear();
                steps.push(json!({"step": "host_paired"}));
                Ok(json!({"paired": true, "identifier": rpf.identifier, "device": format!("{:?}", peer_dev.name)}))
            }
            Ok(Err(e)) => { steps.push(json!({"step": "host_pair_failed", "trace": trace})); Err(format!("{e:?}")) }
            Err(_) => { steps.push(json!({"step": "host_pair_timeout", "trace": trace})); Err("ما كمل الاقتران (ما انكتب الرمز؟)".into()) }
        }
    })
}
