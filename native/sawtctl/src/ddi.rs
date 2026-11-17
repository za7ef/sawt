// صورة المطوّر (DDI): خدمات testmanagerd وdtservicehub وremoteAXService وأطر XCTest في /System/Developer
// ما تظهر إلا وهي مركّبة، وتبقى مركّبة لين يطفي الجوال. iOS 26.4 وأحدث ياخذها كـcryptex عبر cryptexd،
// والأقدم (17.4–26.3) عبر image mounter بالصورة المخصّصة. في الحالتين خادم Apple (TSS) يوقّع تذكرة لهذا الجهاز.
// كتابة مستقلة على واجهات idevice (MIT)؛ ما فيه كود منسوخ من Poki.

use crate::{Res, Session};
use idevice::RsdService;
use serde_json::{Value as Json, json};
use std::path::Path;

/// موجودة بس والصورة مركّبة
pub const MARKERS: [&str; 2] = ["com.apple.instruments.dtservicehub", "com.apple.dt.testmanagerd.remote"];
const CRYPTEXD: &str = "com.apple.security.cryptexd.remote";
const MOUNTER: &str = "com.apple.mobile.mobile_image_mounter.shim.remote";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Method {
    Cryptex,
    Personalized,
}

impl Method {
    fn name(self) -> &'static str {
        match self {
            Method::Cryptex => "cryptex",
            Method::Personalized => "personalized",
        }
    }
}

/// الطريقة حسب نسخة iOS ("27.3"): من 26.4 وفوق cryptex
pub fn method_for(ios: &str) -> Option<Method> {
    let mut p = ios.trim().split('.');
    let major: u32 = p.next()?.trim().parse().ok()?;
    let minor: u32 = p.next().and_then(|x| x.trim().parse().ok()).unwrap_or(0);
    Some(if (major, minor) >= (26, 4) { Method::Cryptex } else { Method::Personalized })
}

pub fn mounted(s: &Session) -> bool {
    MARKERS.iter().all(|m| s.rsd.services.contains_key(*m))
}

pub fn status_json(s: &Session) -> Json {
    json!({
        "mounted": mounted(s),
        "markers": MARKERS.iter().map(|m| json!({"name": m, "present": s.rsd.services.contains_key(*m)})).collect::<Vec<_>>(),
        "cryptexd": s.rsd.services.contains_key(CRYPTEXD),
        "image_mounter": s.rsd.services.contains_key(MOUNTER),
    })
}

/// رمز واضح للخطأ عشان التطبيق يعرض السبب
fn classify(stage: &str, e: impl std::fmt::Debug) -> String {
    let d = format!("{e:?}");
    let code = if d.contains("DeveloperMode") {
        "developer_mode"
    } else if d.contains("DeviceLocked") {
        "locked"
    } else if d.contains("Http") || d.contains("TSS") || d.contains("Tss") {
        "tss"
    } else if d.contains("BadDdiBundle") || d.contains("BadBuildManifest") {
        "ddi_bad"
    } else {
        "mount_failed"
    };
    let short: String = d.chars().take(300).collect();
    format!("ddi:{code}: {stage}: {short}")
}

fn need(dir: &Path, names: &[&str]) -> Res<()> {
    for n in names {
        if !dir.join(n).is_file() {
            return Err(format!("ddi:not_downloaded: الملف {n} غير موجود"));
        }
    }
    Ok(())
}

/// يركّب الصورة إذا ما كانت مركّبة. يرجع الطريقة اللي انستخدمت.
/// قائمة خدمات الجلسة ثابتة من وقت فتحها، فالمنادي يفتح جلسة جديدة بعدها عشان يتأكد.
pub async fn mount(s: &mut Session, dir: &str, ios: &str, steps: &mut Vec<Json>) -> Res<Method> {
    let dir = Path::new(dir);
    let method = method_for(ios).ok_or_else(|| format!("ddi:mount_failed: نسخة iOS غير مفهومة: {ios}"))?;
    steps.push(json!({"step": "ddi_method", "method": method.name(), "ios": ios}));
    match method {
        Method::Cryptex => {
            if !s.rsd.services.contains_key(CRYPTEXD) {
                return Err("ddi:developer_mode: خدمة cryptexd غير متاحة (وضع المطوّر مفعّل؟)".into());
            }
            need(dir, &["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"])?;
            let assets = idevice::cryptexd::Cryptex1Assets::load(dir).await.map_err(|e| classify("assets", e))?;
            let r = idevice::cryptexd::install_ddi(&mut s.adapter, &mut s.rsd, &assets).await.map_err(|e| classify("cryptexd", e))?;
            steps.push(json!({"step": "ddi_cryptex_installed", "identifier": r.identifier, "version": r.version}));
        }
        Method::Personalized => {
            if !s.rsd.services.contains_key(MOUNTER) {
                return Err("ddi:developer_mode: خدمة image mounter غير متاحة (وضع المطوّر مفعّل؟ iOS 17.4 أو أحدث؟)".into());
            }
            need(dir, &["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"])?;
            let rd = |n: &str| std::fs::read(dir.join(n)).map_err(|e| format!("ddi:ddi_bad: {n}: {e}"));
            let manifest = rd("BuildManifest.plist")?;
            let image = rd("Image.dmg")?;
            let trust = rd("Image.dmg.trustcache")?;
            let chip = {
                let mut ld = idevice::lockdown::LockdownClient::connect_rsd(&mut s.adapter, &mut s.rsd)
                    .await
                    .map_err(|e| classify("lockdown", e))?;
                let v = ld.get_value(Some("UniqueChipID"), None).await.map_err(|e| classify("UniqueChipID", e))?;
                v.as_unsigned_integer()
                    .or_else(|| v.as_signed_integer().map(|x| x as u64))
                    .ok_or_else(|| "ddi:mount_failed: الجهاز لم يُرجع UniqueChipID".to_string())?
            };
            let mut m = idevice::mobile_image_mounter::ImageMounter::connect_rsd(&mut s.adapter, &mut s.rsd)
                .await
                .map_err(|e| classify("image_mounter", e))?;
            m.mount_personalized_rsd(&mut s.adapter, &mut s.rsd, image, trust, &manifest, None, chip)
                .await
                .map_err(|e| classify("mount", e))?;
            steps.push(json!({"step": "ddi_personalized_mounted"}));
        }
    }
    Ok(method)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn method_by_version() {
        assert_eq!(method_for("27.3"), Some(Method::Cryptex));
        assert_eq!(method_for("26.4"), Some(Method::Cryptex));
        assert_eq!(method_for("26.3.1"), Some(Method::Personalized));
        assert_eq!(method_for("18.7"), Some(Method::Personalized));
        assert_eq!(method_for("x"), None);
    }
}
