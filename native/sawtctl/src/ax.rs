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

// ───────────── شجرة العناصر مع الإطارات (للوكيل) ─────────────
// الرسائل تجي كأرشيف NSKeyedArchiver: نحل الـUID يدويًا ونقرأ الحقول اللي نحتاجها بس.

struct KArc { objs: Vec<Value>, top: Value }

impl KArc {
    fn new(bytes: &[u8]) -> Option<KArc> {
        let v = Value::from_reader(std::io::Cursor::new(bytes)).ok()?;
        let d = v.as_dictionary()?;
        let objs = d.get("$objects")?.as_array()?.clone();
        let top = d.get("$top")?.as_dictionary()?.get("root")?.clone();
        Some(KArc { objs, top })
    }
    fn r<'a>(&'a self, mut v: &'a Value) -> &'a Value {
        for _ in 0..32 {
            match v.as_uid() { Some(u) => match self.objs.get(u.get() as usize) { Some(n) => v = n, None => break }, None => break }
        }
        v
    }
    fn root(&self) -> &Value { self.r(&self.top) }
    fn list<'a>(&'a self, v: &'a Value) -> Vec<&'a Value> {
        let v = self.r(v);
        let a = v.as_array().or_else(|| v.as_dictionary()?.get("NS.objects")?.as_array());
        a.map(|a| a.iter().map(|x| self.r(x)).collect()).unwrap_or_default()
    }
    fn pairs<'a>(&'a self, v: &'a Value) -> Vec<(&'a Value, &'a Value)> {
        let Some(d) = self.r(v).as_dictionary() else { return vec![] };
        match (d.get("NS.keys"), d.get("NS.objects")) {
            (Some(k), Some(o)) => self.list(k).into_iter().zip(self.list(o)).collect(),
            _ => vec![],
        }
    }
    fn get<'a>(&'a self, v: &'a Value, name: &str) -> Option<&'a Value> {
        let d = self.r(v).as_dictionary()?;
        if let Some(x) = d.get(name) { return Some(self.r(x)) }
        self.pairs(v).into_iter().find(|(k, _)| self.text(k).as_deref() == Some(name)).map(|(_, x)| x)
    }
    fn text(&self, v: &Value) -> Option<String> {
        let v = self.r(v);
        if let Some(s) = v.as_string() { return (s != "$null").then(|| s.to_string()) }
        let d = v.as_dictionary()?;
        for k in ["NS.string", "NS.rectval", "NS.pointval"] {
            if let Some(s) = d.get(k).and_then(|x| self.r(x).as_string()) { return Some(s.to_string()) }
        }
        None
    }
    fn num(&self, v: &Value) -> Option<f64> {
        let v = self.r(v);
        v.as_signed_integer().map(|x| x as f64)
            .or_else(|| v.as_unsigned_integer().map(|x| x as f64))
            .or_else(|| v.as_real())
            .or_else(|| v.as_boolean().map(|b| if b { 1.0 } else { 0.0 }))
    }
    fn data<'a>(&'a self, v: &'a Value) -> Option<&'a [u8]> {
        let v = self.r(v);
        v.as_data().or_else(|| self.get(v, "NS.data").and_then(|x| x.as_data()))
    }
    fn nums(&self, v: &Value) -> Vec<f64> {
        self.text(v).unwrap_or_default()
            .split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-'))
            .filter_map(|s| s.parse::<f64>().ok()).collect()
    }
}

#[derive(Default)]
struct Node { label: Option<String>, value: Option<String>, ph: Option<String>, bundle: Option<String>,
              frame: Option<[f64; 4]>, traits: u64, etype: Option<u64>, kids: Vec<u64>, vis: Vec<u64> }

#[derive(Default)]
struct Tree { nodes: std::collections::BTreeMap<u64, Node>, roots: Vec<u64> }

impl Tree {
    fn absorb(&mut self, a: &KArc) {
        let root = a.root();
        if a.get(root, "associatedRequestType").and_then(|v| a.num(v)) != Some(11.0) { return }
        let Some(res) = a.get(root, "resultData") else { return };
        let Some(dumpv) = a.get(res, "treeDump") else { return };
        for resp in a.list(dumpv) {
            let kind = a.get(resp, "associatedRequestType").and_then(|v| a.num(v)).map(|x| x as u64);
            let Some(data) = a.get(resp, "resultData") else { continue };
            match kind {
                Some(4) => {
                    if let Some(id) = a.get(data, "objectID").and_then(|v| a.num(v)) {
                        let id = id as u64;
                        if !self.roots.contains(&id) { self.roots.push(id) }
                    }
                }
                Some(5) => {
                    let Some(id) = a.get(resp, "associatedTranslationObject")
                        .and_then(|t| a.get(t, "objectID")).and_then(|v| a.num(v)) else { continue };
                    let n = self.nodes.entry(id as u64).or_default();
                    for (k, v) in a.pairs(data) {
                        let Some(attr) = a.num(k) else { continue };
                        match attr as u64 {
                            3 | 33 => if n.label.is_none() { n.label = a.text(v) },
                            6 => n.bundle = a.text(v),
                            42 => n.ph = a.text(v),
                            53 => n.value = a.text(v).or_else(|| a.num(v).map(|x| x.to_string())),
                            21 => { let f = a.nums(v); if f.len() == 4 { n.frame = Some([f[0], f[1], f[2], f[3]]) } }
                            77 => n.traits = a.num(v).unwrap_or(0.0) as u64,
                            61 => n.etype = a.num(v).map(|x| x as u64),
                            8 | 9 => {
                                let ids: Vec<u64> = a.list(v).into_iter()
                                    .filter_map(|x| a.num(x).or_else(|| a.get(x, "objectID").and_then(|y| a.num(y))))
                                    .map(|x| x as u64).collect();
                                if attr as u64 == 8 { n.kids = ids } else { n.vis = ids }
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    }
    fn ready(&self) -> bool { !self.roots.is_empty() && self.roots.iter().any(|r| self.nodes.contains_key(r)) && self.nodes.len() > 1 }

    fn kind(&self, n: &Node) -> &'static str {
        let t = n.traits;
        if t & (1 << 18) != 0 { return "field" }
        if t & (1 << 10) != 0 { return "search" }
        if t & (1 << 5) != 0 { return "key" }
        if t & (1 << 53) != 0 { return "switch" }
        if t & (1 << 0) != 0 { return "button" }
        if t & (1 << 1) != 0 { return "link" }
        if t & (1 << 15) != 0 { return "tabbar" }
        if t & (1 << 2) != 0 { return "image" }
        if t & (1 << 6) != 0 { return "text" }
        "other"
    }

    fn flatten_all(&self) -> Json {
        let mut out = Vec::new();
        for n in self.nodes.values() {
            if out.len() >= 300 { break }
            let Some(f) = n.frame else { continue };
            if f[2] < 2.0 || f[3] < 2.0 { continue }
            let k = self.kind(n);
            let has_text = n.label.as_deref().map_or(false, |s| !s.trim().is_empty()) || n.value.is_some() || n.ph.is_some();
            if !has_text && !matches!(k, "button" | "field" | "search" | "switch") { continue }
            out.push(json!({"k": k, "l": n.label, "v": n.value, "p": n.ph,
                            "f": [f[0].round(), f[1].round(), f[2].round(), f[3].round()], "foc": false,
                            "sec": n.traits & (1 << 20) != 0}));
        }
        json!({"app": null, "elements": out})
    }

    /// قائمة مسطّحة بالعناصر الظاهرة اللي لها نص أو قابلة للضغط
    fn flatten(&self) -> Json {
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut stack: Vec<u64> = self.roots.iter().rev().cloned().collect();
        let mut app = None;
        while let Some(id) = stack.pop() {
            if !seen.insert(id) || out.len() >= 300 { continue }
            let Some(n) = self.nodes.get(&id) else { continue };
            if self.roots.contains(&id) && app.is_none() { app = Some(json!({"name": n.label, "bundle": n.bundle})) }
            let kids = if n.vis.is_empty() { &n.kids } else { &n.vis };
            for k in kids.iter().rev() { stack.push(*k) }
            if self.roots.contains(&id) { continue }
            let Some(f) = n.frame else { continue };
            if f[2] < 2.0 || f[3] < 2.0 { continue }
            let k = self.kind(n);
            let has_text = n.label.as_deref().map_or(false, |s| !s.trim().is_empty())
                || n.value.as_deref().map_or(false, |s| !s.trim().is_empty())
                || n.ph.is_some();
            if !has_text && !matches!(k, "button" | "field" | "search" | "switch") { continue }
            out.push(json!({"k": k, "l": n.label, "v": n.value, "p": n.ph,
                            "f": [f[0].round(), f[1].round(), f[2].round(), f[3].round()],
                            "foc": n.traits & (1 << 33) != 0 || n.traits & (1 << 31) != 0,
                            "sec": n.traits & (1 << 20) != 0}));
        }
        json!({"app": app, "elements": out})
    }
}

/// يقرأ عناصر الشاشة الظاهرة مع إطاراتها (بالنقاط)
pub async fn elements(adapter: &mut AdapterHandle, rsd: &RsdHandshake, wait: Duration, steps: &mut Vec<Json>) -> Result<Json, String> {
    let port = rsd.services.get(SERVICE).ok_or("خدمة remoteAXService مو موجودة (الـDDI مركّب؟)")?.port;
    let t0 = Instant::now();
    let deadline = tokio::time::Instant::now() + wait;
    let mut tries = 0;
    let mut best = Tree::default();
    // الاشتراك اللي ينسوى والشاشة تتحرك أحيانًا ما يرد؛ نعيد كل ثانيتين
    while tokio::time::Instant::now() < deadline {
        tries += 1;
        let mut sock = adapter.connect(port).await.map_err(|e| format!("ax connect: {e:?}"))?;
        let mut caps = plist::Dictionary::new();
        caps.insert("com.apple.private.DTXBlockCompression".into(), 0.into());
        caps.insert("com.apple.private.DTXConnection".into(), 1.into());
        send(&mut sock, 1, "_notifyOfPublishedCapabilities:", Some(Value::Dictionary(caps)), false).await?;
        send(&mut sock, 2, "clientNeedsAccessibility:", Some(true.into()), true).await?;
        let mut tree = Tree::default();
        let until = (tokio::time::Instant::now() + Duration::from_millis(2000)).min(deadline);
        let mut done = false;
        loop {
            let r = match tokio::time::timeout_at(until, read_raw(&mut sock)).await {
                Ok(Ok(r)) => r,
                _ => break,
            };
            if r.expects_reply { let _ = ack(&mut sock, &r).await; }
            for b in aux_blobs(&r.aux) {
                let Some(outer) = KArc::new(&b) else { continue };
                let inner = outer.data(outer.root()).and_then(KArc::new);
                if let Some(inner) = inner { tree.absorb(&inner) } else { tree.absorb(&outer) }
            }
            if tree.ready() { done = true; break }
        }
        let _ = send(&mut sock, 3, "clientNeedsAccessibility:", Some(false.into()), false).await;
        if !done && tree.nodes.len() > best.nodes.len() { best = tree; continue }
        if done {
            let mut j = tree.flatten();
            j["ms"] = json!(t0.elapsed().as_millis() as u64);
            j["tries"] = json!(tries);
            steps.push(json!({"step": "ax_tree", "nodes": tree.nodes.len(), "tries": tries}));
            return Ok(j);
        }
    }
    // ما اكتملت: نرجع أفضل جزء وصلنا لو فيه عناصر (بدون جذر التطبيق)
    if best.nodes.len() > 1 {
        if best.roots.is_empty() { best.roots = best.nodes.keys().cloned().take(1).collect() }
        let mut j = best.flatten();
        if j["elements"].as_array().map_or(true, |a| a.is_empty()) {
            // بدون روابط الأبناء: نسطّح كل العقد مباشرة
            let ids: Vec<u64> = best.nodes.keys().cloned().collect();
            best.roots = vec![];
            for id in ids { best.roots.push(id) }
            j = best.flatten_all();
        }
        j["partial"] = json!(true);
        j["tries"] = json!(tries);
        steps.push(json!({"step": "ax_partial", "nodes": best.nodes.len()}));
        return Ok(j);
    }
    Err(format!("ما وصلت شجرة الشاشة خلال {}ms ({} محاولات)", wait.as_millis(), tries))
}
