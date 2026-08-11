import Foundation

protocol Transcriber {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
    func unload() async
}
