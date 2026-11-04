import Darwin

/// One directory entry as returned by `getattrlistbulk`.
struct BulkEntry {
    enum Kind {
        case directory
        case regular
        case symlink
        case other
    }

    var name: String
    var kind: Kind
    var device: Int32
    var inode: UInt64
    /// Seconds since 1970.
    var modified: Double
    /// Zero for directories: `ATTR_FILE_*` attributes are only returned for non-directories.
    var allocatedSize: Int64
    var linkCount: UInt32
}

/// Reads directory entries in batches with `getattrlistbulk`, which is far cheaper than
/// `readdir` + `lstat` per entry.
enum BulkAttributes {
    private static let bufferSize = 256 * 1024

    private static var requestedAttributes: attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return list
    }

    /// All entries of the open directory `fd`. Entries that carry a per-entry error are skipped.
    /// On a read error, returns the entries read so far together with the `errno` value.
    static func entries(of fd: Int32) -> (entries: [BulkEntry], errorCode: Int32?) {
        var list = requestedAttributes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var result: [BulkEntry] = []

        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, UInt64(FSOPT_NOFOLLOW))
            if count == 0 { return (result, nil) }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return (result, code)
            }
            var record = buffer
            for _ in 0..<count {
                let length = Int(record.load(as: UInt32.self))
                if let entry = parse(record) { result.append(entry) }
                record += length
            }
        }
    }

    /// Fields appear in bit order (common, then file attributes), except that
    /// `ATTR_CMN_RETURNED_ATTRS` and `ATTR_CMN_ERROR` come first.
    private static func parse(_ record: UnsafeMutableRawPointer) -> BulkEntry? {
        var field = UnsafeRawPointer(record) + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let file = returned.fileattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }

        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = field.loadUnaligned(as: attrreference_t.self)
        let namePointer = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        field += MemoryLayout<attrreference_t>.size

        var device: Int32 = 0
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = field.loadUnaligned(as: dev_t.self)
            field += MemoryLayout<dev_t>.size
        }

        var kind = BulkEntry.Kind.other
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            let type = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
            switch type {
            case fsobj_type_t(VDIR.rawValue): kind = .directory
            case fsobj_type_t(VREG.rawValue): kind = .regular
            case fsobj_type_t(VLNK.rawValue): kind = .symlink
            default: kind = .other
            }
        }

        var modified = 0.0
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = field.loadUnaligned(as: timespec.self)
            field += MemoryLayout<timespec>.size
            modified = Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }

        var inode: UInt64 = 0
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            inode = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        var linkCount: UInt32 = 1
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var allocatedSize: Int64 = 0
        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocatedSize = Int64(field.loadUnaligned(as: off_t.self))
            field += MemoryLayout<off_t>.size
        }

        return BulkEntry(
            name: name,
            kind: kind,
            device: device,
            inode: inode,
            modified: modified,
            allocatedSize: allocatedSize,
            linkCount: linkCount
        )
    }
}
