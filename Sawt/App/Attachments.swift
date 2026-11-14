import CoreImage
import Foundation
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

/// مرفق في رسالة: صورة أو ملف نصي. كل شي محفوظ في مجلد التطبيق الخاص.
struct Attachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case image, file }
    var id = UUID()
    var kind: Kind
    var name: String
    /// النص المستخرج (للملفات، أو OCR للصور لما النموذج ما يشوف)
    var text: String?
    var pages: Int?

    var imageURL: URL { Attachments.dir.appendingPathComponent("\(id.uuidString).jpg") }
    var thumbURL: URL { Attachments.dir.appendingPathComponent("\(id.uuidString)-t.jpg") }
    var textURL: URL { Attachments.dir.appendingPathComponent("\(id.uuidString).txt") }

    /// نص الملف: محفوظ بملف منفصل (عشان ملف المحادثات يبقى خفيف).
    var fullText: String { text ?? (try? String(contentsOf: textURL, encoding: .utf8)) ?? "" }

    /// يحفظ النص في ملف ويرجع المرفق بدونه.
    func storingText() -> Attachment {
        guard let t = text else { return self }
        try? Data(t.utf8).write(to: textURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var c = self; c.text = nil
        return c
    }

    func deleteFiles() {
        for u in [imageURL, thumbURL, textURL] { try? FileManager.default.removeItem(at: u) }
    }
}

enum AttachmentError: LocalizedError {
    case unreadable, unsupported(String), tooBig
    var errorDescription: String? {
        switch self {
        case .unreadable: return "ما قدرت أقرأ الملف."
        case .unsupported(let e): return "نوع الملف (\(e)) مو مدعوم للحين. جرّب PDF أو نص أو صورة."
        case .tooBig: return "الملف كبير مرة (أكثر من 50MB)."
        }
    }
}

enum Attachments {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// أنواع الملفات المسموحة في منتقي الملفات.
    static var fileTypes: [UTType] {
        var t: [UTType] = [.pdf, .plainText, .utf8PlainText, .commaSeparatedText, .json, .image, .rtf]
        if let md = UTType("net.daringfireball.markdown") { t.append(md) }
        return t
    }

    // MARK: الصور

    /// يصغّر الصورة (أقصى ضلع 1024) ويحفظها مع مصغّرة. نرجع المرفق بدون نص.
    static func addImage(_ image: UIImage, name: String = "صورة") throws -> Attachment {
        let a = Attachment(kind: .image, name: name)
        guard let big = downscale(image, maxSide: 1024).jpegData(compressionQuality: 0.85),
              let small = downscale(image, maxSide: 240).jpegData(compressionQuality: 0.7) else {
            throw AttachmentError.unreadable
        }
        try big.write(to: a.imageURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        try small.write(to: a.thumbURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        return a
    }

    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let s = image.size
        let scale = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: max(1, floor(s.width * scale)), height: max(1, floor(s.height * scale)))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: الملفات

    static func addFile(_ url: URL) async throws -> Attachment {
        try await readFile(url).storingText()
    }

    private static func readFile(_ url: URL) async throws -> Attachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 50_000_000 { throw AttachmentError.tooBig }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let name = url.lastPathComponent

        if let type, type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { throw AttachmentError.unreadable }
            return try addImage(img, name: name)
        }
        if let type, type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { throw AttachmentError.unreadable }
            let text = await pdfText(doc)
            var a = Attachment(kind: .file, name: name, text: text, pages: doc.pageCount)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { a.text = "" }
            return a
        }
        if let type, type.conforms(to: .rtf) {
            let s = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                           documentAttributes: nil).string
            return Attachment(kind: .file, name: name, text: s)
        }
        let textual = ["txt", "md", "markdown", "csv", "json", "tsv", "log", "xml", "html", "swift", "py", "js"]
        if textual.contains(url.pathExtension.lowercased()) || (type?.conforms(to: .text) ?? false) {
            guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable }
            let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))))
                ?? String(decoding: data, as: UTF8.self)
            return Attachment(kind: .file, name: name, text: s)
        }
        throw AttachmentError.unsupported(url.pathExtension.isEmpty ? "؟" : url.pathExtension)
    }

    /// نص PDF، والصفحات الممسوحة (بدون نص) نقرأها بـ OCR. حد أقصى للصفحات عشان الوقت والذاكرة.
    static func pdfText(_ doc: PDFDocument) async -> String {
        var out: [String] = []
        var ocrPages = 0
        for i in 0 ..< min(doc.pageCount, 200) {
            guard let page = doc.page(at: i) else { continue }
            let s = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 20 {
                out.append(s)
            } else if ocrPages < 20 {
                ocrPages += 1
                let box = page.bounds(for: .mediaBox)
                let scale = min(2.0, 1600 / max(box.width, box.height))
                let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
                if let cg = img.cgImage {
                    let t = await ocr(cg)
                    if !t.isEmpty { out.append(t) }
                }
            }
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: Vision

    /// يقرأ النص في الصورة (عربي وإنجليزي إذا مدعوم).
    static func ocr(_ cg: CGImage) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                let supported = (try? req.supportedRecognitionLanguages()) ?? []
                let wanted = ["ar-SA", "ar", "en-US"].filter { supported.contains($0) }
                if !wanted.isEmpty { req.recognitionLanguages = wanted }
                let h = VNImageRequestHandler(cgImage: cg, options: [:])
                try? h.perform([req])
                let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// وصف بسيط للصورة للنماذج اللي ما تشوف: تصنيفات + النص المكتوب فيها.
    static func describe(_ a: Attachment) async -> String {
        guard let img = UIImage(contentsOfFile: a.imageURL.path), let cg = img.cgImage else { return "" }
        let labels: [String] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNClassifyImageRequest()
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                let top = (req.results ?? []).filter { $0.confidence > 0.3 }.prefix(6).map { $0.identifier }
                cont.resume(returning: Array(top))
            }
        }
        let text = await ocr(cg)
        var parts: [String] = []
        if !labels.isEmpty { parts.append("تصنيفات تقريبية (من Apple Vision، بالإنجليزي): " + labels.joined(separator: ", ")) }
        if !text.isEmpty { parts.append("النص المكتوب في الصورة:\n" + String(text.prefix(2500))) }
        if parts.isEmpty { parts.append("ما قدرت أستخرج شي من الصورة.") }
        return parts.joined(separator: "\n")
    }

    // MARK: السياق

    /// يقسم النص الطويل لقطع ويختار الأقرب للسؤال، بحد أقصى من الحروف (عشان سياق النموذج والذاكرة).
    static func context(for text: String, query: String, budget: Int, requireMatch: Bool = false) -> (String, Bool) {
        let clean = text.replacingOccurrences(of: "\r", with: "")
        if !requireMatch, clean.count <= budget { return (clean, false) }
        let size = 700
        var chunks: [String] = []
        var cur = ""
        for para in clean.components(separatedBy: "\n") {
            if cur.count + para.count > size, !cur.isEmpty { chunks.append(cur); cur = "" }
            if para.count > size {
                var p = Substring(para)
                while !p.isEmpty { chunks.append(String(p.prefix(size))); p = p.dropFirst(size) }
            } else {
                cur += (cur.isEmpty ? "" : "\n") + para
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        let q = MemoryStore.tokens(query)
        let scored = chunks.enumerated().map { (i, c) -> (Int, Double) in
            let s = Double(q.intersection(MemoryStore.tokens(c)).count)
            return (i, s + (i == 0 && !requireMatch ? 0.5 : 0))   // أول قطعة غالبًا فيها العنوان والمقدمة
        }
        if requireMatch {
            // للرسائل اللاحقة: بس إذا السؤال فعلًا يطابق شي في الملف
            guard scored.contains(where: { $0.1 >= 1 }) else { return ("", false) }
        }
        var picked = Set<Int>()
        var used = 0
        for (i, sc) in scored.sorted(by: { $0.1 > $1.1 }) {
            if requireMatch, sc < 1 { continue }
            if used + chunks[i].count > budget { continue }
            picked.insert(i); used += chunks[i].count
        }
        let out = picked.sorted().map { chunks[$0] }.joined(separator: "\n…\n")
        return (out, true)
    }
}

/// كاميرا الجوال.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// مصغّرة مرفق في الفقاعة أو فوق خانة الكتابة.
struct AttachmentChip: View {
    let a: Attachment
    var size: CGFloat = 64
    var body: some View {
        Group {
            if a.kind == .image, let img = UIImage(contentsOfFile: a.thumbURL.path) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: a.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).lineLimit(1).font(.caption)
                        if let p = a.pages { Text("\(p) صفحة").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 10).frame(height: size)
                .frame(maxWidth: 200)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
