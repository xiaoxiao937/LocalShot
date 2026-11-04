import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

enum TextRecognitionError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "识别时间过长，已停止。请缩小文字区域后重试。"
    }
}

/// Vision performs synchronously on one worker. Repeated requests replace the
/// pending job instead of adding another image and task to an unbounded queue.
final class TextRecognitionService: @unchecked Sendable {
    static let shared = TextRecognitionService()

    final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var timeoutTimer: DispatchSourceTimer?
        fileprivate let image: CGImage
        fileprivate let request = VNRecognizeTextRequest()
        fileprivate let completion: @MainActor (Result<String, Error>) -> Void

        fileprivate init(image: CGImage, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
            self.image = image
            self.completion = completion
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.automaticallyDetectsLanguage = true
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 25)
            timer.setEventHandler { [weak self] in self?.timeOut() }
            timeoutTimer = timer
            timer.resume()
        }

        fileprivate var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func cancel() {
            request.cancel()
            complete(.failure(CancellationError()))
        }

        fileprivate func complete(_ result: Result<String, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let timer = timeoutTimer
            timeoutTimer = nil
            lock.unlock()
            timer?.cancel()
            Task { @MainActor [completion] in completion(result) }
        }

        fileprivate func timeOut() {
            request.cancel()
            complete(.failure(TextRecognitionError.timedOut))
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "LocalShot.text-recognition", qos: .userInitiated)
    private var active: Operation?
    private var pending: Operation?
    private var draining = false

    @discardableResult
    func recognize(
        _ image: CGImage,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> Operation {
        let operation = Operation(image: image, completion: completion)
        lock.lock()
        let previousActive = active
        let previousPending = pending
        pending = operation
        let shouldStart = !draining
        draining = true
        lock.unlock()
        previousActive?.cancel()
        previousPending?.cancel()
        if shouldStart { queue.async { [self] in drain() } }
        return operation
    }

    private func drain() {
        while true {
            lock.lock()
            guard let operation = pending else {
                active = nil
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            active = operation
            lock.unlock()
            autoreleasepool {
                guard !operation.isFinished else { return }
                let request = operation.request
                do {
                    try VNImageRequestHandler(cgImage: operation.image, options: [:]).perform([request])
                    guard !operation.isFinished else { return }
                    operation.complete(.success(Self.readingOrder(request.results ?? [])))
                } catch {
                    operation.complete(.failure(error))
                }
            }
            lock.lock()
            if active === operation { active = nil }
            lock.unlock()
        }
    }

    private struct Fragment {
        let text: String
        let box: CGRect
    }

    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> String {
        let fragments = observations.compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Fragment(text: text, box: observation.boundingBox)
        }
        return orderedBlocks(fragments, depth: 0)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func orderedBlocks(_ fragments: [Fragment], depth: Int) -> [String] {
        guard !fragments.isEmpty else { return [] }
        guard fragments.count >= 4, depth < 6 else { return rows(fragments) }
        let bounds = fragments.dropFirst().reduce(fragments[0].box) { $0.union($1.box) }
        // Full-width headings split a page into bands; each band can then have
        // its own columns instead of interleaving the left and right columns.
        let spanning = fragments.filter { $0.box.width > bounds.width * 0.72 }
            .sorted { $0.box.midY > $1.box.midY }
        if !spanning.isEmpty, spanning.count < fragments.count {
            var remainder = fragments.filter { $0.box.width <= bounds.width * 0.72 }
            var output: [String] = []
            for heading in spanning {
                let above = remainder.filter { $0.box.midY > heading.box.midY }
                remainder.removeAll { $0.box.midY > heading.box.midY }
                output += orderedBlocks(above, depth: depth + 1)
                output.append(heading.text)
            }
            return output + orderedBlocks(remainder, depth: depth + 1)
        }

        let intervals = fragments.map(\.box).sorted { $0.minX < $1.minX }
        var rightEdge = intervals[0].maxX
        var bestSplit: (gap: CGFloat, x: CGFloat)?
        for box in intervals.dropFirst() {
            let gap = box.minX - rightEdge
            if gap >= max(0.025, bounds.width * 0.045) {
                let splitX = (box.minX + rightEdge) / 2
                let left = fragments.filter { $0.box.maxX < splitX }
                let right = fragments.filter { $0.box.minX > splitX }
                if left.count >= 2, right.count >= 2 {
                    let leftBounds = left.dropFirst().reduce(left[0].box) { $0.union($1.box) }
                    let rightBounds = right.dropFirst().reduce(right[0].box) { $0.union($1.box) }
                    let overlap = min(leftBounds.maxY, rightBounds.maxY) - max(leftBounds.minY, rightBounds.minY)
                    if overlap > min(leftBounds.height, rightBounds.height) * 0.35,
                       gap > (bestSplit?.gap ?? 0) {
                        bestSplit = (gap, splitX)
                    }
                }
            }
            rightEdge = max(rightEdge, box.maxX)
        }
        if let split = bestSplit {
            return orderedBlocks(fragments.filter { $0.box.midX < split.x }, depth: depth + 1)
                + orderedBlocks(fragments.filter { $0.box.midX >= split.x }, depth: depth + 1)
        }
        return rows(fragments)
    }

    private static func rows(_ fragments: [Fragment]) -> [String] {
        let sorted = fragments.sorted {
            if $0.box.midY != $1.box.midY { return $0.box.midY > $1.box.midY }
            return $0.box.minX < $1.box.minX
        }
        var lines: [[Fragment]] = []
        for fragment in sorted {
            if let index = lines.indices.last,
               let first = lines[index].first,
               abs(first.box.midY - fragment.box.midY) < min(first.box.height, fragment.box.height) * 0.45 {
                lines[index].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }
}

enum PNGImageEncoder {
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
