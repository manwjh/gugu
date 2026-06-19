import Foundation
import GuguKernel
import Vision
import CoreML

/// 本地物品识别。优先用主人放置的目标检测模型(YOLO 类,COCO 80 类,能认手持的杯子/手机/书…);
/// 没有模型时退回系统内置的动物检测(只认猫/狗)。全部纯本地、看完即弃、不需要联网。
/// 检测模型查找位置(任选其一,命名 gugu-objects):app 包 Resources 或 ~/.../Gugu/models/,
/// 支持 .mlmodelc / .mlmodel / .mlpackage(后两者运行时自动编译)。
final class BuiltInRecognizer: @unchecked Sendable {
    private let detectionModel: VNCoreMLModel?

    init() { detectionModel = BuiltInRecognizer.loadDetectionModel() }

    var available: Bool { true }
    var modelLoaded: Bool { detectionModel != nil }

    func makeRequests() -> [VNRequest] {
        if let detectionModel {
            let r = VNCoreMLRequest(model: detectionModel)
            r.imageCropAndScaleOption = .scaleFill   // 与 Ultralytics iOS 示例一致
            return [r]
        }
        return [VNRecognizeAnimalsRequest()]         // 无模型:至少认猫/狗
    }

    func results(from requests: [VNRequest]) -> [VisionObjectObservation] {
        var out: [VisionObjectObservation] = []
        for req in requests {
            guard let objects = req.results as? [VNRecognizedObjectObservation] else { continue }
            for obs in objects {
                guard let label = obs.labels.first, label.confidence >= 0.35 else { continue }
                // 只上报我们关心、且有中文名的具体物(过滤掉 person 等)。
                guard VisionObjectObservation.concreteLabel(label.identifier) != nil else { continue }
                out.append(VisionObjectObservation(
                    label: label.identifier,
                    confidence: label.confidence,
                    center: CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY),
                    area: obs.boundingBox.width * obs.boundingBox.height))
            }
        }
        return out
    }

    /// 调试用:未过滤的原始检测(含 person 等),按置信度取前几个,带归一化外框。
    func rawResults(from requests: [VNRequest]) -> [(label: String, conf: Float, rect: CGRect)] {
        var out: [(String, Float, CGRect)] = []
        for req in requests {
            guard let objects = req.results as? [VNRecognizedObjectObservation] else { continue }
            for obs in objects where obs.labels.first != nil {
                out.append((obs.labels.first!.identifier, obs.labels.first!.confidence, obs.boundingBox))
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(8).map { $0 }
    }

    private static func loadDetectionModel() -> VNCoreMLModel? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        var candidates: [URL] = []
        for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
            if let u = Bundle.main.url(forResource: "gugu-objects", withExtension: ext) { candidates.append(u) }
            candidates.append(Paths.modelsDir.appendingPathComponent("gugu-objects.\(ext)"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                // .mlmodelc 直接加载;.mlpackage/.mlmodel 先编译。
                let loadURL = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
                let model = try MLModel(contentsOf: loadURL, configuration: cfg)
                let vm = try VNCoreMLModel(for: model)
                Log.info("vision", "物品检测模型已加载:\(url.lastPathComponent)")
                Audit.record(kind: "vision.object_model", summary: "物品检测模型已加载",
                             detail: ["file": url.lastPathComponent])
                return vm
            } catch {
                Log.info("vision", "物品检测模型加载失败(\(url.lastPathComponent)):\(error)")
            }
        }
        Log.info("vision", "未放置物品检测模型;只认猫/狗。放入 models/gugu-objects.mlpackage 可认更多物品")
        return nil
    }
}
