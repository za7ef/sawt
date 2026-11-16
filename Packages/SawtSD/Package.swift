// swift-tools-version: 5.9
// نسخة مضمّنة من مكتبة Apple ml-stable-diffusion (رخصة MIT، انظر LICENSE.md)
// بدون أجزاء SD3/T5 اللي تحتاج swift-transformers 0.1.8 (تتعارض مع النسخة اللي يستخدمها التطبيق).
import PackageDescription

let package = Package(
    name: "SawtSD",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StableDiffusion", targets: ["StableDiffusion"])],
    targets: [.target(name: "StableDiffusion", path: "Sources/StableDiffusion")]
)
