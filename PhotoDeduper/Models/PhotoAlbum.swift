import Foundation
import Photos

struct PhotoAlbum: Identifiable {
    let id: String                         // PHAssetCollection.localIdentifier
    let title: String
    let count: Int                         // image-only count
    let collection: PHAssetCollection
    let collectionType: PHAssetCollectionType
}
