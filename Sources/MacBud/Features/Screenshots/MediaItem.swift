import Foundation
import UniformTypeIdentifiers

nonisolated struct MediaItem: Identifiable, Equatable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable { case image, video }

    let url: URL
    let kind: Kind
    let createdAt: Date
    let byteCount: Int
    let folder: URL

    var id: URL { url }
    var filename: String { url.lastPathComponent }
    var folderName: String { folder.lastPathComponent }

    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .tiff, .webP, .bmp]
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    static func kind(for type: UTType) -> Kind? {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }
}
