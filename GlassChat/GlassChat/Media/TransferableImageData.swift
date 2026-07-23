import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct TransferableImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            TransferableImageData(data: data)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            TransferableImageData(data: data)
        }
        DataRepresentation(importedContentType: .png) { data in
            TransferableImageData(data: data)
        }
        DataRepresentation(importedContentType: .heic) { data in
            TransferableImageData(data: data)
        }
    }
}
