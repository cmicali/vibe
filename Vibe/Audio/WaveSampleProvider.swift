import AppKit
import AudioToolbox

@objc enum WaveSampleStatus: Int {
    case loading
    case loaded
    case error
}

class WaveSampleProvider: NSObject {
    private(set) var status: WaveSampleStatus?
    private(set) var statusMessage: String = ""
    private(set) var audioURL: URL?
    
    var scanStepSize: Int = 0
    var waveWidth: Int = 0
    var wTotalFrames: UInt32 = 0
    var wStartFrame : Int64 = 0
    
    var delegate: WaveSampleProviderDelegate?
    var extAFRef: ExtAudioFileRef?
    var extAFNumChannels: UInt32 = 0
    var extAFReachedEOF = false
    var waveData: [Float]!
    
    init(url theURL: URL, startFrame: Int64, withLength totalFrames: UInt32, viewWidth width: Int) {
        super.init()
        wStartFrame     = startFrame
        wTotalFrames    = totalFrames
        waveWidth       = width
        scanStepSize    = 166
        audioURL        = theURL
        waveData        = [Float](repeating: 0.0, count: 0)
        status(status: WaveSampleStatus.loading, message: "Processing")
    }
    
    @objc func status(status theStatus: WaveSampleStatus, message desc: String?) {
        status = theStatus
        statusMessage = desc!
        performSelector(onMainThread: #selector(WaveSampleProvider.informDelegateOfStatusChange), with: nil, waitUntilDone: false)
    }
    
    @objc func informDelegateOfStatusChange() {
        if delegate != nil {
            if (delegate?.responds(to: #selector(WaveSampleProvider.status(status:message:))))! {
                delegate?.statusUpdated(self)
            }
        }
    }
    
    @objc func informDelegateOfFinish() {
        if delegate != nil {
            if (delegate?.responds(to: #selector(WaveSampleProviderDelegate.sampleProcessed(_:))))! {
                delegate?.sampleProcessed(self)
            }
        }
    }
    
    func createWaveData() {
        waveData = [Float](repeating: 0.0, count: 0)
        performSelector(inBackground: #selector(loadSampleData), with: nil)
    }
    
    @objc func loadSampleData() {
        processSampleData()
        performSelector(onMainThread: #selector(informDelegateOfFinish), with: nil, waitUntilDone: false)
    }
    
    func data(forResolution graphWidth: Int) -> [Float] {
        //
        // put the sample data in an array
        //
        var length = waveData.count
        
        let DEBUG = false
        if graphWidth != length && DEBUG {
            print("WSP_data(forResolution: Error: Size Difference:  \n graphWidth :", graphWidth,
                  " \n  dataCount :", length,
                  " \n difference :", length - graphWidth)
        }
        while length > graphWidth {
            waveData.removeLast()
            length -= 1
        }
        while length < graphWidth {
            waveData.append(0.0)
            length += 1
        }
        return waveData
    }
    
    func createZeroWave(length: Int) {
        if length < 1 { return }
        
        waveData = [Float](repeating: 0.0, count: length)
        status(status: WaveSampleStatus.loaded, message: "WSP_Zero Sample data created")
    }
    
    func clientDataFormat(from fileFormat: AudioStreamBasicDescription) -> AudioStreamBasicDescription {
        var clientFormat = AudioStreamBasicDescription()
        /*
         print("WSP_laadSampleData: \n",
         "\nmSampleRate",        fileFormat.mSampleRate,
         "\nmFramesPerPacket",   fileFormat.mFramesPerPacket,
         "\nmChannelsPerFrame",  fileFormat.mChannelsPerFrame,
         "\nmBitsPerChannel",    fileFormat.mBitsPerChannel, // flac : 0
         "\nmBytesPerFrame",     fileFormat.mBytesPerFrame,  // flac : 0
         "\nmBytesPerPacket",    fileFormat.mBytesPerPacket) // flac : 0
         */
        clientFormat.mFormatID          = kAudioFormatLinearPCM // needed to draw wave of most flacs, some are still unsupported
        clientFormat.mFormatFlags       = kAudioFormatFlagIsFloat
        clientFormat.mSampleRate        = fileFormat.mSampleRate
        clientFormat.mChannelsPerFrame  = fileFormat.mChannelsPerFrame
        clientFormat.mFramesPerPacket   = 1
        
        clientFormat.mBitsPerChannel    = UInt32(MemoryLayout<Float32>.size * 8)
        clientFormat.mBytesPerFrame     = UInt32(Int(fileFormat.mChannelsPerFrame) * MemoryLayout<Float32>.size)
        clientFormat.mBytesPerPacket    = UInt32(Int(fileFormat.mChannelsPerFrame) * MemoryLayout<Float32>.size)
        return clientFormat
    }
    
    func processSampleData() {
        //
        // processSampleData ia actually loadingSampleData() and processSampleData()
        // we should split this up properly
        //
        extAFReachedEOF = false
        //
        // load SampleData
        //
        if ExtAudioFileOpenURL(audioURL! as CFURL, &extAFRef) != noErr {
            status(status: WaveSampleStatus.error, message: "WSP_Cannot open audio file")
            createZeroWave(length: waveWidth)
            return
        }
        var fileFormat = AudioStreamBasicDescription()
        var propSize   = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        if ExtAudioFileGetProperty(extAFRef!, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat) != noErr {
            status(status: WaveSampleStatus.error, message: "WSP_Cannot get audio file properties")
            createZeroWave(length: waveWidth)
            return
        }
        
        var clientFormat = clientDataFormat(from: fileFormat)
        
        propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        if ExtAudioFileSetProperty(extAFRef!, kExtAudioFileProperty_ClientDataFormat, propSize, &clientFormat) != noErr {
            status(status: WaveSampleStatus.error, message: "WSP_Cannot convert audio file to PCM format")
            createZeroWave(length: waveWidth)
            return
        }
        extAFNumChannels = clientFormat.mChannelsPerFrame
        
        let framesPerPixel = UInt32(round(Float(wTotalFrames) / Float(waveWidth)))
        
        if ExtAudioFileSeek(extAFRef!, Int64(wStartFrame) ) != noErr {
            status(status: WaveSampleStatus.error, message: "WSP_Cannot Seek to startFrame")
            createZeroWave(length: waveWidth)
            return
        }
        var audio = [[Float]](repeating: [], count: Int(extAFNumChannels))
        
        for channel in 0 ..< Int(extAFNumChannels) {
            audio[channel] = [Float].init(repeating: Float(), count: Int(framesPerPixel))
        }
        var totalFramesRead: Int = 0
        var readCount: UInt = 0
        
        while !extAFReachedEOF {
            var frames: Int = 0
            frames = readNext(framesPerPixel, intoArray: &audio)
            
            if frames == NSNotFound {
                status(status: WaveSampleStatus.error, message: "WSP_AudioFile contains no samples")
                createZeroWave(length: waveWidth)
                return
            }
            let waveValue = getWaveValueFor(samples: audio, length: frames)
            waveData.append(waveValue)
            
            totalFramesRead += frames
            readCount += 1
        }
        
        if ExtAudioFileDispose(extAFRef!) != noErr {
            status(status: WaveSampleStatus.error, message: "WSP_Error closing audio file")
            return
        }
        for channel in 0 ..< Int(extAFNumChannels) {
            audio[channel].removeAll()
        }
        status(status: WaveSampleStatus.loaded, message: "WSP_Sample data loaded")
    }
    
    func readNext(_ numFrames: UInt32, intoArray audio: inout [[Float]]) -> Int {
        var err: OSStatus = noErr
        if extAFRef == nil { return NSNotFound }
        let dataCount: UInt32 = numFrames * extAFNumChannels
        
        var data = [Float].init(repeating: 0.0, count: Int(dataCount))
        
        if data.count == 0 { return NSNotFound }
        
        let dataSize: UInt32 = dataCount * UInt32(MemoryLayout<Float32>.size)
        let buffer  = AudioBuffer(mNumberChannels: extAFNumChannels, mDataByteSize: dataSize, mData: &data)
        var bufList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        
        bufList.mBuffers.mDataByteSize = dataSize
        var loadedFrames: UInt32 = numFrames
        err = ExtAudioFileRead(extAFRef!, &loadedFrames, &bufList)
        if err != noErr { return Int(err) }
        
        if audio.count != 0
        {
            for channel in 0 ..< Int(extAFNumChannels) {
                if audio[channel].count == 0 { continue }
                
                for frame in 0 ..< Int(loadedFrames) { // numFrames or loadedFrames
                    audio[channel][frame] = data[frame * Int(extAFNumChannels) + channel]
                }
            }
        }
        data.removeAll()
        if (loadedFrames < numFrames) { extAFReachedEOF = true }

        return Int(loadedFrames)
    }
    
    func getWaveValueFor(samples audio: [[Float]], length: Int) -> Float {
        //
        // get the max value in framesPerRead, and add that single value to sampleData
        //
        var maxValue: Float = 0.0
        var frame = 0
        //
        // to speed things up increase scanStepSize, if you don't want to miss a peakvalue, decrease
        // for small files we add some resolution
        //
        let scanStep = length / scanStepSize >= 1 ? scanStepSize : 1
        
        while frame < length { 
            for channel in 0 ..< Int(extAFNumChannels) {
                let val: Float = abs(audio[channel][frame])
                if val > maxValue {
                    maxValue = val
                }
            }
            frame += scanStep
        }
        return maxValue
    }
}
