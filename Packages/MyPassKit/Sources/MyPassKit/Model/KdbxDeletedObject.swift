import Foundation

/// A tombstone recording that an object (identified by UUID) was deleted at a
/// given time. Used by later merge/sync phases to distinguish "deleted elsewhere"
/// from "never existed" when reconciling two databases by UUID.
struct KdbxDeletedObject: Equatable {
    var uuid: UUID
    var deletionTime: Date

    init(uuid: UUID, deletionTime: Date) {
        self.uuid = uuid
        self.deletionTime = deletionTime
    }
}
