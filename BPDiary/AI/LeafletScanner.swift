import Foundation
import UIKit
import Vision

/// Распознавание текста инструкции с фотографий прямо на iPhone, без интернета.
enum LeafletScanner {
    static func recognizeText(in images: [UIImage]) async throws -> String {
        var pages: [String] = []
        for image in images {
            let text = try await recognize(image)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func recognize(_ image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ru-RU", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try handler.perform([request])

            let observations: [VNRecognizedTextObservation] = request.results ?? []
            // Сортируем строки сверху вниз и слева направо (координаты Vision идут снизу вверх).
            let sorted = observations.sorted { first, second in
                let dy = first.boundingBox.midY - second.boundingBox.midY
                if abs(dy) > 0.01 { return dy > 0 }
                return first.boundingBox.minX < second.boundingBox.minX
            }
            let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
