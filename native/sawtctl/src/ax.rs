// قراءة شجرة الوصول عبر خدمة remoteAXService (بروتوكول DTX).
// تجربة: نشترك ونجمع كل ما يوصل، ونطلع النصوص (التسميات) وأسماء الرسائل كما هي،
// عشان نعرف شكل البيانات على iOS 27 قبل ما نبني محلل كامل.

use idevice::{
    dvt::message::{Aux, AuxValue, Message, MessageHeader, PayloadHeader},
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use plist::Value;
use serde_json::{Value as Json, json};
use std::collections::BTreeSet;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteAXService";

struct Raw {
    identifier: u32,
    conversation: u32,
    channel: i32,
    expects_reply: bool,
    msg_type: u8,
    aux: Vec<u8>,
    data: Vec<u8>,
}

async fn send<W: AsyncWrite + Unpin>(w: &mut W, id: u32, selector: &str, arg: Option<Value>, reply: bool) -> Result<(), String> {
    let h = MessageHeader::new(0, 1, id, 0, 0, reply);
    let aux = arg.map(|a| Aux::from_values(vec![AuxValue::archived_value(a)]));
    let m = Message::new(h, PayloadHeader::method_invocation(), aux, Some(Value::String(selector.into())));
    w.write_all(&m.serialize()).await.map_err(|e| format!("write: {e}"))?;
    w.flush().await.map_err(|e| format!("flush: {e}"))
}

async fn ack<W: AsyncWrite + Unpin>(w: &mut W, r: &Raw) -> Result<(), String> {
    // رد فاضي بنفس المعرّف (نوع 0)
    let mut b = Vec::with_capacity(48);
    b.extend_from_slice(&0x1F3D5B79u32.to_le_bytes());
    b.extend_from_slice(&32u32.to_le_bytes());
    b.extend_from_slice(&0u16.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&r.identifier.to_le_bytes());
    b.extend_from_slice(&(r.conversation + 1).to_le_bytes());
    b.extend_from_slice(&r.channel.to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    b.extend_from_slice(&[0u8; 16]);
    w.write_all(&b).await.map_err(|e| format!("ack: {e}"))
}

async fn read_raw<R: AsyncRead + Unpin>(r: &mut R) -> Result<Raw, String> {
    let mut body = Vec::new();
    let (identifier, conversation, channel, expects_reply);
    loop {
        let mut h = [0u8; 32];
        r.read_exact(&mut h).await.map_err(|e| format!("read: {e}"))?;
        let u32at = |o: usize| u32::from_le_bytes([h[o], h[o + 1], h[o + 2], h[o + 3]]);
        if u32at(0) != 0x1F3D5B79 { return Err("DTX magic".into()) }
        let frag_id = u16::from_le_bytes([h[8], h[9]]);
        let frag_count = u16::from_le_bytes([h[10], h[11]]);
        let len = u32at(12) as usize;
        if frag_count > 1 && frag_id == 0 {
            continue; // أول جزء من رسالة مقسّمة: هيدر بس
        }
        let mut part = vec![0u8; len];
        r.read_exact(&mut part).await.map_err(|e| format!("read body: {e}"))?;
        body.extend_from_slice(&part);
        if frag_count <= 1 || frag_id + 1 == frag_count {
            identifier = u32at(16);
            conversation = u32at(20);
            channel = u32at(24) as i32;
            expects_reply = u32at(28) != 0;
            break;
        }
    }
    if body.len() < 16 { return Ok(Raw { identifier, conversation, channel, expects_reply, msg_type: 0, aux: vec![], data: vec![] }) }
    let msg_type = body[0];
    let aux_len = u32::from_le_bytes([body[4], body[5], body[6], body[7]]) as usize;
    let total = u32::from_le_bytes([body[8], body[9], body[10], body[11]]) as usize;
    let rest = &body[16..];
    let aux = rest.get(..aux_len.min(rest.len())).unwrap_or(&[]).to_vec();
    let data = rest.get(aux_len.min(rest.len())..total.min(rest.len())).unwrap_or(&[]).to_vec();
    Ok(Raw { identifier, conversation, channel, expects_reply, msg_type, aux, data })
}

/// يطلع القيم الخام (type 2) من قسم aux
fn aux_blobs(aux: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    if aux.len() < 16 { return out }
    let mut i = 16;
    let u32at = |o: usize| aux.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    while i + 8 <= aux.len() {
        let _key = u32at(i);
        let Some(ty) = u32at(i + 4) else { break };
        i += 8;
        match ty {
            1 | 2 => {
                let Some(n) = u32at(i) else { break };
                let n = n as usize;
                i += 4;
                if let Some(b) = aux.get(i..i + n) { if ty == 2 { out.push(b.to_vec()) } }
                i += n;
            }
            3 | 5 => i += 4,
            4 | 6 | 9 => i += 8,
            10 => {}
            _ => break,
        }
    }
    out
}

/// يجمع كل النصوص من أرشيف NSKeyedArchiver (ومن الأرشيفات المتداخلة داخل NSData)
fn collect_strings(bytes: &[u8], out: &mut Vec<String>, keys: &mut BTreeSet<String>, depth: u8) {
    if depth > 4 { return }
    let Ok(v) = Value::from_reader(std::io::Cursor::new(bytes)) else { return };
    walk(&v, out, keys, depth);
}

fn walk(v: &Value, out: &mut Vec<String>, keys: &mut BTreeSet<String>, depth: u8) {
    match v {
        Value::String(s) => {
            if !s.starts_with('$') && !s.starts_with("NS") && s.len() < 400 { out.push(s.clone()) }
        }
        Value::Data(d) => {
            if d.starts_with(b"bplist") { collect_strings(d, out, keys, depth + 1) }
        }
        Value::Array(a) => a.iter().for_each(|x| walk(x, out, keys, depth)),
        Value::Dictionary(d) => {
            for (k, x) in d {
                if keys.len() < 200 { keys.insert(k.clone()); }
                walk(x, out, keys, depth)
            }
        }
        _ => {}
    }
}

pub async fn dump(adapter: &mut AdapterHandle, rsd: &RsdHandshake, wait: Duration, steps: &mut Vec<Json>) -> Result<Json, String> {
    let port = rsd.services.get(SERVICE).ok_or("خدمة remoteAXService مو موجودة (الـDDI مركّب؟)")?.port;
    let mut sock = adapter.connect(port).await.map_err(|e| format!("ax connect: {e:?}"))?;
    let t0 = Instant::now();
    let mut caps = plist::Dictionary::new();
    caps.insert("com.apple.private.DTXBlockCompression".into(), 0.into());
    caps.insert("com.apple.private.DTXConnection".into(), 1.into());
    send(&mut sock, 1, "_notifyOfPublishedCapabilities:", Some(Value::Dictionary(caps)), false).await?;
    send(&mut sock, 2, "clientNeedsAccessibility:", Some(true.into()), true).await?;
    steps.push(json!({"step": "ax_subscribed"}));

    let mut messages = 0usize;
    let mut bytes = 0usize;
    let mut selectors = Vec::new();
    let mut strings = Vec::new();
    let mut keys = BTreeSet::new();
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let r = match tokio::time::timeout_at(deadline, read_raw(&mut sock)).await {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => { steps.push(json!({"step": "ax_read_error", "error": e})); break }
            Err(_) => break,
        };
        messages += 1;
        bytes += r.aux.len() + r.data.len();
        if r.expects_reply { let _ = ack(&mut sock, &r).await; }
        let mut sel = Vec::new();
        let mut k = BTreeSet::new();
        collect_strings(&r.data, &mut sel, &mut k, 0);
        if selectors.len() < 40 {
            selectors.push(json!({"type": r.msg_type, "ch": r.channel, "sel": sel.first(), "aux": r.aux.len(), "data": r.data.len()}));
        }
        for b in aux_blobs(&r.aux) { collect_strings(&b, &mut strings, &mut keys, 0) }
        if strings.len() > 3000 { break }
    }
    let _ = send(&mut sock, 3, "clientNeedsAccessibility:", Some(false.into()), false).await;
    let mut seen = BTreeSet::new();
    let uniq: Vec<String> = strings.into_iter().filter(|s| seen.insert(s.clone())).take(600).collect();
    Ok(json!({
        "ax_ms": t0.elapsed().as_millis() as u64,
        "messages": messages,
        "bytes": bytes,
        "selectors": selectors,
        "keys": keys.into_iter().collect::<Vec<_>>(),
        "strings": uniq,
    }))
}
