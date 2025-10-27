import Foundation

// Extension to convert between OggVorbisStreamData and OggVorbisStreamInfo
extension OggVorbisStreamData {
    /// Convert to OggVorbisStreamInfo
    func toOggVorbisStreamInfo() -> OggVorbisStreamInfo {
        var info = OggVorbisStreamInfo()
        info.serialNumber = self.serialNumber
        info.pageCount = self.pageCount
        info.totalSamples = self.totalSamples
        info.sampleRate = self.sampleRate
        info.channels = self.channels
        info.bitRate = self.bitRate
        info.nominalBitrate = self.nominalBitrate
        info.minBitrate = self.minBitrate
        info.maxBitrate = self.maxBitrate
        info.blocksize0 = Int(self.blocksize0) // Convert from Int32 to Int
        info.blocksize1 = Int(self.blocksize1) // Convert from Int32 to Int
        info.granulePosition = self.granulePosition
        info.commentHeader = self.commentHeader
        info.pageOffsets = self.pageOffsets
        info.pageGranules = self.pageGranules
        return info
    }
}

// Extension to convert from OggVorbisStreamInfo to OggVorbisStreamData
extension OggVorbisStreamInfo {
    /// Convert to OggVorbisStreamData
    func toOggVorbisStreamData() -> OggVorbisStreamData {
        var data = OggVorbisStreamData()
        data.serialNumber = self.serialNumber
        data.pageCount = self.pageCount
        data.totalSamples = self.totalSamples
        data.sampleRate = self.sampleRate
        data.channels = self.channels
        data.bitRate = self.bitRate
        data.nominalBitrate = self.nominalBitrate
        data.minBitrate = self.minBitrate
        data.maxBitrate = self.maxBitrate
        data.blocksize0 = Int32(self.blocksize0) // Convert from Int to Int32
        data.blocksize1 = Int32(self.blocksize1) // Convert from Int to Int32
        data.granulePosition = self.granulePosition
        data.commentHeader = self.commentHeader
        data.pageOffsets = self.pageOffsets
        data.pageGranules = self.pageGranules
        return data
    }
}
