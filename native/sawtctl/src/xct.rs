// تفويض جلسة اختبار واجهة لتطبيق صوت نفسه عبر testmanagerd (iOS 17+ عن طريق RSD).
// نفس تسلسل Xcode: مصافحة DTX ← قناة XCTestManager_IDEInterface (عبر الوكيل) ←
// _IDE_initiateControlSessionWithCapabilities: ← _IDE_authorizeTestSessionWithProcessID: برقم عملية صوت.
// أسماء الخدمات والدوال وتنسيق أرشيف XCTCapabilities مأخوذة من مكتبة idevice
// (services/dvt/xctest، رخصة MIT، Jackson Coxson) لأن دوالها هناك غير عامة.

use crate::{Res, Session, connect};
use idevice::dvt::message::AuxValue;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::provider::RsdProvider;
use idevice::ReadWrite;
use plist::{Dictionary, Uid, Value};
use serde_json::{Value as Json, json};
use std::time::{Duration, Instant};

const TESTMANAGERD_RSD_SERVICE: &str = "com.apple.dt.testmanagerd.remote";
const IDE_IFACE: &str = "XCTestManager_IDEInterface";
const DAEMON_IFACE: &str = "XCTestManager_DaemonConnectionInterface";
const INIT_CTRL: &str = "_IDE_initiateControlSessionWithCapabilities:";
const AUTHORIZE: &str = "_IDE_authorizeTestSessionWithProcessID:";

/// الجلسة لازم تبقى مفتوحة طول ما XCUIApplication شغال
pub(crate) struct XctHold {
    _s: Session,
    _tm: RemoteServerClient<Box<dyn ReadWrite>>,
}
pub(crate) static HOLD: std::sync::Mutex<Option<XctHold>> = std::sync::Mutex::new(None);

/// أرشيف NSKeyedArchiver لكائن XCTCapabilities فاضي (نفس تنسيق idevice/pymobiledevice3)
fn empty_caps_archive() -> Res<Vec<u8>> {
    let mut root = Dictionary::new();
    root.insert("$class".into(), Value::Uid(Uid::new(2)));
    root.insert("capabilities-dictionary".into(), Value::Uid(Uid::new(3)));
    let mut cls = Dictionary::new();
    cls.insert("$classes".into(), Value::Array(vec![Value::String("XCTCapabilities".into())]));
    cls.insert("$classname".into(), Value::String("XCTCapabilities".into()));
    let mut dict = Dictionary::new();
    dict.insert("$class".into(), Value::Uid(Uid::new(4)));
    dict.insert("NS.keys".into(), Value::Array(vec![]));
    dict.insert("NS.objects".into(), Value::Array(vec![]));
    let mut dcls = Dictionary::new();
    dcls.insert("$classes".into(), Value::Array(vec![Value::String("NSDictionary".into())]));
    dcls.insert("$classname".into(), Value::String("NSDictionary".into()));
    let objects = vec![
        Value::String("$null".into()),
        Value::Dictionary(root),
        Value::Dictionary(cls),
        Value::Dictionary(dict),
        Value::Dictionary(dcls),
    ];
    let mut top = Dictionary::new();
    top.insert("root".into(), Value::Uid(Uid::new(1)));
    let mut a = Dictionary::new();
    a.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
    a.insert("$objects".into(), Value::Array(objects));
    a.insert("$top".into(), Value::Dictionary(top));
    a.insert("$version".into(), Value::Integer(100000u64.into()));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &Value::Dictionary(a)).map_err(|e| format!("archive: {e}"))?;
    Ok(buf)
}

fn short(v: &Option<Value>) -> String {
    let s = format!("{v:?}");
    s.chars().take(300).collect()
}

/// فحص الشروط + تفويض رقم العملية. يرجع خطوات القائمة (checks) ونتيجة التفويض
pub(crate) async fn authorize(cfg: &crate::Config, pid: u32, steps: &mut Vec<Json>) -> Res<Json> {
    let t0 = Instant::now();
    // ١) ملف الاقتران + الـloopback + RSD
    let mut s = connect(cfg, steps).await?;
    let has_tm = s.rsd.services.contains_key(TESTMANAGERD_RSD_SERVICE);
    steps.push(json!({"step": "check", "item": "loopback", "ok": true}));
    // testmanagerd يظهر بس لو وضع المطوّر شغال وصورة المطوّر مركّبة
    steps.push(json!({"step": "check", "item": "testmanagerd", "ok": has_tm}));
    let port = s.rsd.services.get(TESTMANAGERD_RSD_SERVICE).map(|x| x.port)
        .ok_or("خدمة testmanagerd مو موجودة (وضع المطوّر أو صورة المطوّر؟)")?;

    // ٢) اتصال DTX + مصافحة القدرات (مثل perform_handshake في idevice)
    let stream = s.adapter.connect_to_service_port(port).await.map_err(|e| format!("testmanagerd connect: {e:?}"))?;
    let mut tm = RemoteServerClient::with_label(stream, "sawt-tm");
    let mut caps = Dictionary::new();
    caps.insert("com.apple.private.DTXBlockCompression".into(), Value::Integer(0i64.into()));
    caps.insert("com.apple.private.DTXConnection".into(), Value::Integer(1i64.into()));
    tm.root_channel()
        .call_method(Some("_notifyOfPublishedCapabilities:"), Some(vec![AuxValue::archived_value(Value::Dictionary(caps))]), false)
        .await
        .map_err(|e| format!("handshake: {e:?}"))?;
    steps.push(json!({"step": "dtx_handshake", "ms": t0.elapsed().as_millis() as u64}));

    // ٣) قناة التحكم + بدء جلسة التحكم + التفويض
    let (init_reply, auth_reply) = {
        let mut ch = tokio::time::timeout(Duration::from_secs(10), tm.make_channel(format!("dtxproxy:{IDE_IFACE}:{DAEMON_IFACE}")))
            .await
            .map_err(|_| "انتهى الوقت وهو يفتح قناة XCTestManager".to_string())?
            .map_err(|e| format!("channel: {e:?}"))?;
        ch.call_method(Some(INIT_CTRL), Some(vec![AuxValue::Array(empty_caps_archive()?)]), true)
            .await
            .map_err(|e| format!("initiateControlSession: {e:?}"))?;
        let r1 = tokio::time::timeout(Duration::from_secs(10), ch.read_message())
            .await
            .map_err(|_| "انتهى الوقت ينتظر رد initiateControlSession".to_string())?
            .map_err(|e| format!("initiateControlSession reply: {e:?}"))?;
        ch.call_method(Some(AUTHORIZE), Some(vec![AuxValue::archived_value(Value::Integer((pid as i64).into()))]), true)
            .await
            .map_err(|e| format!("authorize: {e:?}"))?;
        let r2 = tokio::time::timeout(Duration::from_secs(15), ch.read_message())
            .await
            .map_err(|_| "انتهى الوقت ينتظر رد authorize".to_string())?
            .map_err(|e| format!("authorize reply: {e:?}"))?;
        (r1.data, r2.data)
    };
    steps.push(json!({"step": "init_ctrl", "reply": short(&init_reply)}));
    // الرد الناجح true (أو فاضي في بعض الإصدارات)؛ false أو كائن خطأ (NSError) = رفض
    let reply_text = short(&auth_reply);
    let authorized = !matches!(auth_reply, Some(Value::Boolean(false)))
        && !reply_text.contains("NSError") && !reply_text.contains("NSLocalizedDescription") && !reply_text.contains("ErrorDomain");
    steps.push(json!({"step": "authorize", "pid": pid, "reply": short(&auth_reply), "ok": authorized}));

    *HOLD.lock().unwrap() = Some(XctHold { _s: s, _tm: tm });
    if !authorized { return Err(format!("testmanagerd رفض التفويض: {}", short(&auth_reply))) }
    Ok(json!({"authorized": true, "pid": pid}))
}
