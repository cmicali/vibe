import AppKit

let WaveColor = NSColor(calibratedRed: 0.52, green: 0.39, blue: 0.00, alpha: 1.0)

@objc protocol WaveSampleProviderDelegate: NSObjectProtocol {
    func sampleProcessed(_ provider: WaveSampleProvider?)
    func statusUpdated(_ provider: WaveSampleProvider?)
}

@objc class WaveFormViewOSX: NSView, WaveSampleProviderDelegate {
    
    var positionPath = CGMutablePath()
    var progress: NSProgressIndicator?
    var waveData : [CGPoint]?
    var waveLength: Int = 0
    var sampleDataLength: Int = 0
    var wsp: WaveSampleProvider!
    var playProgress: CGFloat = 0.0
    var disabled = false
    
    func sampleProcessed(_ provider: WaveSampleProvider?) {
        if provider?.status == WaveSampleStatus.loaded {
            let sampleData = provider?.data(forResolution: Int(waveWidth()))
            waveData = convertSamples(toCGPoints: sampleData!)
            playProgress = 0.0
        }
    }
    
    func convertSamples(toCGPoints samples: [Float]) -> [CGPoint]? {
        progress?.isHidden = false
        progress?.startAnimation(self)
        waveLength = 0
        if samples.count == 0 { return nil }
        
        let length   = samples.count
        var tempData = [CGPoint](repeating: CGPoint(), count: length)
        //
        // fill the path with sample data
        //
        var index = 0
        for sample in samples {
            tempData[index] = CGPoint(x: CGFloat(index),
                                      y: CGFloat(sample))
            index += 1
        }
        //
        // set first and last point in path to 0.0
        //
        tempData[0] = CGPoint(x: 0.0, y: 0.0)
        tempData[length - 1] = CGPoint(x: CGFloat(length) - 1.0, y: 0.0)
        waveLength = length
        progress?.isHidden = true
        progress?.stopAnimation(self)
        return tempData
    }
    
    func statusUpdated(_ provider: WaveSampleProvider?) {}
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initView()
    }
    
    override func layout() {
        super.layout()
        if progressRect().size.width < 40 {
            progress?.controlSize = .small
        } else {
            progress?.controlSize = .regular
        }
        progress?.frame = progressRect()
    }
    
    func initView() {
        playProgress = 0.0
        progress = NSProgressIndicator(frame: progressRect())
        progress?.isBezeled = false
        progress?.style = .spinning
        progress?.controlSize = .small
        progress?.controlTint = .clearControlTint
        addSubview(progress!)
        progress?.isHidden = true
        wsp = nil
    }
    
    func releaseSample() {
        waveData = []
        wsp = nil
        waveLength = 0
    }
    
    @objc func setDisabled(_ state: Bool) {
        disabled = state
        needsDisplay = true
    }
    
    func openAudioURL(_ url: URL, withLength totalFrames: UInt32) {
        //
        // called from pbc
        //
        openAudioURL(url, startFrame: 0, withLength: totalFrames)
    }
    
    @objc func openAudioURL(_ url: URL, startFrame: Int64, withLength totalFrames: UInt32) {
        //
        // we start here, called from pbc
        //
        releaseSample()
        progress?.isHidden = false
        progress?.startAnimation(self)
        if wsp != nil {
            wsp = nil
        }
        let width = Int(bounds.size.width)
        wsp = WaveSampleProvider(url: url,
                                 startFrame: startFrame,
                                 withLength: totalFrames,
                                 viewWidth: width)
        wsp.delegate = self
        wsp.createWaveData()
    }
    
    // MARK: Drawing
    func isOpaque() -> Bool { return false }
    
    func progressRect() -> NSRect {
        let margin: CGFloat = 5.0
        let heigth: CGFloat = bounds.size.height - margin * 2.0
        return NSMakeRect((bounds.size.width - heigth) / 2.0, margin, heigth, heigth)
    }
    
    func waveWidth() -> CGFloat {
        return bounds.size.width
    }
    
    func waveHeight() -> CGFloat {
        return bounds.size.height
    }
    
    func waveRect() -> NSRect {
        return NSMakeRect(0, 0, bounds.size.width, bounds.size.height)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        let lineSize: CGFloat = 2.0
        let waveFill: NSColor = WaveColor.blended(withFraction: 0.27, of: .clear)!
        let waveMarkFill: NSColor = WaveColor
        let waveRect: NSRect = dirtyRect
        var clipRect: NSRect = NSRect.zero
        if waveData != nil && waveLength > 0 && !disabled {
            positionPath = .init()
            let halfWave = CGMutablePath()
            
            halfWave.addLines(between: waveData!, transform: .identity)
            
            let xscale: CGFloat = waveRect.size.width / CGFloat(waveLength)
            let halfHeight: CGFloat = waveRect.size.height / 2.0
            
            var xf: CGAffineTransform = .identity
            //
            // transform halfWave to upper half
            //
            xf = xf.translatedBy(x: 0.0, y: halfHeight + lineSize / 2.0)
            xf = xf.scaledBy(x: xscale, y: halfHeight - lineSize / 2.0)
            
            positionPath.addPath(halfWave, transform: xf)
            //
            // transform halfWave to lower half
            //
            xf = .identity
            xf = xf.translatedBy(x: 0.0, y: halfHeight - lineSize / 2.0)
            xf = xf.scaledBy(x: xscale, y: -halfHeight + lineSize / 2.0)
            
            positionPath.addPath(halfWave, transform: xf)
            //
            // draw zero line
            //
            let zeroLine = CGPath(rect: NSMakeRect(0.0,
                                                   (waveRect.size.height - lineSize) / 2.0,
                                                   waveRect.size.width,
                                                   lineSize),
                                  transform: nil)
            
            positionPath.addPath(zeroLine, transform: .identity)
        } else {
            //
            // we draw a Flat liner when disabled, with colored playProgress
            //
            positionPath = CGPath(rect: NSMakeRect(0.0,
                                                   (waveRect.size.height - lineSize) / 2.0,
                                                   waveRect.size.width,
                                                   lineSize),
                                  transform: nil) as! CGMutablePath
        }
        
        //
        // draw played part
        //
        NSGraphicsContext.current?.saveGraphicsState()
        var cr = NSGraphicsContext.current?.cgContext
        
        clipRect = waveRect
        clipRect.size.width = waveRect.size.width * playProgress
        
        clipRect.clip()
        
        cr?.addPath(positionPath)
        waveMarkFill.setFill()
        cr?.fillPath()
        NSGraphicsContext.current?.restoreGraphicsState()
        //
        // draw unplayed part
        //
        NSGraphicsContext.current?.saveGraphicsState()
        cr = NSGraphicsContext.current?.cgContext
        clipRect = waveRect
        clipRect.origin.x = waveRect.size.width * playProgress
        clipRect.size.width = waveRect.size.width - waveRect.size.width * playProgress
        
        clipRect.clip()
        
        cr?.addPath(positionPath)
        waveFill.setFill()
        cr?.fillPath()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    
    func updateProgress(_ progress: Float) {
        playProgress = CGFloat(progress)
        needsDisplay = true
    }
}
