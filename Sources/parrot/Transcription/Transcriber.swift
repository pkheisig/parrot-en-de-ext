import Foundation

protocol Transcriber {
    var modelID: String { get }
    func warmUp() async throws
    func keepWarm() async throws
    func cancelKeepWarm() async
    func transcribe(_ audio: [Float]) async throws -> String
    func unload() async
}
