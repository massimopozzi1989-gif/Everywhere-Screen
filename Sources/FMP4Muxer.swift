import Foundation

/// Muxer fMP4 minimale (una traccia H.264) per Media Source Extensions.
///
/// La timeline è contigua: ogni frame dura 1/fps, anche se tra due frame è passato più tempo.
/// A schermo fermo il player arriva in fondo al buffer e resta sull'ultimo frame; quando ne
/// arriva uno nuovo riparte subito, senza accumulare ritardo.
struct FMP4Muxer {
    static let timescale: UInt32 = 90_000

    private let frameDuration: UInt32
    private var sequence: UInt32 = 0
    private var decodeTime: UInt64 = 0

    init(fps: Int) {
        frameDuration = Self.timescale / UInt32(max(fps, 1))
    }

    static func initSegment(for frame: EncodedFrame) -> Data {
        let sps = [UInt8](frame.sps), pps = [UInt8](frame.pps)
        let w = UInt16(frame.width), h = UInt16(frame.height)

        let ftyp = box("ftyp", bytes {
            $0.append(Data("isom".utf8)); $0.u32(0x200)
            for brand in ["isom", "iso6", "avc1", "mp41"] { $0.append(Data(brand.utf8)) }
        })
        let matrix = bytes { for v: UInt32 in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { $0.u32(v) } }
        let mvhd = fullBox("mvhd", version: 0, flags: 0, bytes {
            $0.u32(0); $0.u32(0); $0.u32(1000); $0.u32(0)     // creation, modification, timescale, duration
            $0.u32(0x00010000); $0.u16(0x0100)                  // rate, volume
            $0.append(Data(count: 10))                          // reserved
            $0.append(matrix)
            $0.append(Data(count: 24))                          // pre_defined
            $0.u32(2)                                           // next_track_ID
        })
        let tkhd = fullBox("tkhd", version: 0, flags: 0x3, bytes {
            $0.u32(0); $0.u32(0); $0.u32(1); $0.u32(0); $0.u32(0) // creation, modification, track_ID, reserved, duration
            $0.append(Data(count: 8))                               // reserved
            $0.u16(0); $0.u16(0); $0.u16(0); $0.u16(0)              // layer, alternate_group, volume, reserved
            $0.append(matrix)
            $0.u32(UInt32(w) << 16); $0.u32(UInt32(h) << 16)
        })
        let mdhd = fullBox("mdhd", version: 0, flags: 0, bytes {
            $0.u32(0); $0.u32(0); $0.u32(timescale); $0.u32(0)
            $0.u16(0x55C4); $0.u16(0)                           // lingua "und"
        })
        let hdlr = fullBox("hdlr", version: 0, flags: 0, bytes {
            $0.u32(0); $0.append(Data("vide".utf8)); $0.append(Data(count: 12))
            $0.append(Data("VideoHandler".utf8)); $0.u8(0)
        })
        let vmhd = fullBox("vmhd", version: 0, flags: 1, Data(count: 8))
        let dinf = box("dinf", fullBox("dref", version: 0, flags: 0, bytes { $0.u32(1) }, fullBox("url ", version: 0, flags: 1)))
        let avcC = box("avcC", bytes {
            $0.u8(1); $0.u8(sps[1]); $0.u8(sps[2]); $0.u8(sps[3])
            $0.u8(0xFF)                                         // NAL length su 4 byte
            $0.u8(0xE1); $0.u16(UInt16(sps.count)); $0.append(Data(sps))
            $0.u8(1); $0.u16(UInt16(pps.count)); $0.append(Data(pps))
        })
        let avc1 = box("avc1", bytes {
            $0.append(Data(count: 6)); $0.u16(1)                // reserved, data_reference_index
            $0.append(Data(count: 16))                          // pre_defined, reserved
            $0.u16(w); $0.u16(h)
            $0.u32(0x00480000); $0.u32(0x00480000); $0.u32(0)   // 72 dpi, reserved
            $0.u16(1)                                           // frame_count
            $0.append(Data(count: 32))                          // compressorname
            $0.u16(0x0018); $0.u16(0xFFFF)                      // depth, pre_defined
        }, avcC)
        let stsd = fullBox("stsd", version: 0, flags: 0, bytes { $0.u32(1) }, avc1)
        let emptyTable = { (type: String) in fullBox(type, version: 0, flags: 0, bytes { $0.u32(0) }) }
        let stsz = fullBox("stsz", version: 0, flags: 0, bytes { $0.u32(0); $0.u32(0) })
        let stbl = box("stbl", stsd, emptyTable("stts"), emptyTable("stsc"), stsz, emptyTable("stco"))
        let trak = box("trak", tkhd, box("mdia", mdhd, hdlr, box("minf", vmhd, dinf, stbl)))
        let mvex = box("mvex", fullBox("trex", version: 0, flags: 0, bytes {
            $0.u32(1); $0.u32(1); $0.u32(0); $0.u32(0); $0.u32(0)
        }))
        return ftyp + box("moov", mvhd, trak, mvex)
    }

    mutating func mediaSegment(for frame: EncodedFrame) -> Data {
        sequence += 1
        let mfhd = fullBox("mfhd", version: 0, flags: 0, bytes { $0.u32(sequence) })
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020000, bytes { $0.u32(1) })   // default-base-is-moof
        let tfdt = fullBox("tfdt", version: 1, flags: 0, bytes { $0.u64(decodeTime) })
        let duration = frameDuration
        func trun(dataOffset: Int) -> Data {
            // data-offset, sample-duration, sample-size, sample-flags
            fullBox("trun", version: 0, flags: 0x000701, bytes {
                $0.u32(1)
                $0.u32(UInt32(dataOffset))
                $0.u32(duration)
                $0.u32(UInt32(frame.data.count))
                $0.u32(frame.isKey ? 0x0200_0000 : 0x0101_0000)
            })
        }
        let size = box("moof", mfhd, box("traf", tfhd, tfdt, trun(dataOffset: 0))).count
        let moof = box("moof", mfhd, box("traf", tfhd, tfdt, trun(dataOffset: size + 8)))
        decodeTime += UInt64(frameDuration)
        return moof + box("mdat", frame.data)
    }
}

private func bytes(_ build: (inout Data) -> Void) -> Data {
    var d = Data()
    build(&d)
    return d
}

private func box(_ type: String, _ parts: Data...) -> Data {
    let payloadSize = parts.reduce(0) { $0 + $1.count }
    var d = Data(capacity: 8 + payloadSize)
    d.u32(UInt32(8 + payloadSize))
    d.append(Data(type.utf8))
    parts.forEach { d.append($0) }
    return d
}

private func fullBox(_ type: String, version: UInt8, flags: UInt32, _ parts: Data...) -> Data {
    var payload = Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
    parts.forEach { payload.append($0) }
    return box(type, payload)
}

private extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(s)) & 0xFF)) } }
}
