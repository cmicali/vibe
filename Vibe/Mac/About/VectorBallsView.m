//
//  VectorBallsView.m
//  Vibe
//

#import "VectorBallsView.h"
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "Fonts.h"

// The wordmark, halftoned into dots. "vibe" is rasterised in a rounded font,
// then sampled on a grid: cells with heavy ink coverage become large dots and
// lighter edge cells become small ones, giving a two-size halftone of the
// letters.
static NSString *const kWord = @"vibe";
static const NSUInteger kHalftoneRows = 22;    // dot lattice rows spanning the glyph height
static const float kWordWorldWidth = 18.0f;    // fit the halftone to this many world units wide
static const float kBigDotFraction = 0.52f;    // big-dot radius as a fraction of cell spacing
static const float kSmallDotFraction = 0.30f;  // small-dot radius
static const float kCoverageOn = 0.16f;        // min ink coverage to place a dot
static const float kCoverageBig = 0.55f;       // coverage at/above which the dot is large

static const float kCameraDistance = 26.0f;
static const NSTimeInterval kIntroDuration = 2.4;

// Matches struct Inst in the shader (three float4s, 48 bytes).
typedef struct {
    vector_float4 home;     // resting position in the halftone grid
    vector_float4 scatter;  // random fly-in start position
    vector_float4 attr;     // x: billboard radius (world units)
} VBInstance;

// Matches struct Uniforms in the shader.
typedef struct {
    matrix_float4x4 model;
    matrix_float4x4 view;
    matrix_float4x4 projection;
    vector_float4   params;      // x: intro progress, z: time (y,w unused)
    vector_float4   lightView;   // xyz: red light position in view space
} VBUniforms;

// The view-space position of the red key light, at the bottom left and
// slightly in front of the dot plane, lighting the dots in the lower-left
// quarter.
static const vector_float3 kRedLightViewPos = { -8.0f, -6.0f, -20.0f };

#pragma mark - Matrix helpers

static matrix_float4x4 vb_perspective(float fovyRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovyRadians * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    return (matrix_float4x4){ .columns = {
            { xs, 0, 0, 0 },
            { 0, ys, 0, 0 },
            { 0, 0, zs, -1 },
            { 0, 0, zs * nearZ, 0 },
    }};
}

static matrix_float4x4 vb_rotationX(float a) {
    float c = cosf(a), s = sinf(a);
    return (matrix_float4x4){ .columns = {
            { 1, 0, 0, 0 },
            { 0, c, s, 0 },
            { 0, -s, c, 0 },
            { 0, 0, 0, 1 },
    }};
}

static matrix_float4x4 vb_rotationY(float a) {
    float c = cosf(a), s = sinf(a);
    return (matrix_float4x4){ .columns = {
            { c, 0, -s, 0 },
            { 0, 1, 0, 0 },
            { s, 0, c, 0 },
            { 0, 0, 0, 1 },
    }};
}

static matrix_float4x4 vb_translation(float x, float y, float z) {
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (vector_float4){ x, y, z, 1 };
    return m;
}

static float vb_random01(void) {
    return (float)arc4random() / (float)UINT32_MAX;
}

#pragma mark -

@interface VectorBallsView () <MTKViewDelegate>
@end

@implementation VectorBallsView {
    id<MTLCommandQueue>         _commandQueue;
    id<MTLRenderPipelineState>  _pipeline;
    id<MTLDepthStencilState>    _depthState;
    id<MTLBuffer>               _instanceBuffer;
    NSUInteger                  _instanceCount;
    CFTimeInterval              _startTime;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect device:MTLCreateSystemDefaultDevice()];
    if (self) {
        [self setupMetal];
    }
    return self;
}

typedef void (^VibeVectorBallsPipelineCompletion)(
        id<MTLRenderPipelineState> pipeline);

// The shader stays a readable bundle resource, while compilation and pipeline
// creation run on one utility queue. The queue also owns the device-bound
// cache, so a rapid close/reopen joins the first compile without main-thread
// synchronization.
static void VibeRequestVectorBallsPipeline(
        id<MTLDevice> device,
        MTLPixelFormat colorFormat,
        MTLPixelFormat depthFormat,
        NSUInteger sampleCount,
        VibeVectorBallsPipelineCompletion completion) {
    static dispatch_queue_t queue;
    static id<MTLDevice> cachedDevice;
    static id<MTLRenderPipelineState> cachedPipeline;
    static MTLPixelFormat cachedColorFormat;
    static MTLPixelFormat cachedDepthFormat;
    static NSUInteger cachedSampleCount;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.vibe.vector-balls-pipeline",
                                      DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });

    dispatch_async(queue, ^{
        id<MTLRenderPipelineState> pipeline = nil;
        if (cachedPipeline && cachedDevice == device &&
                cachedColorFormat == colorFormat &&
                cachedDepthFormat == depthFormat &&
                cachedSampleCount == sampleCount) {
            pipeline = cachedPipeline;
        }
        else {
            NSURL *sourceURL = [NSBundle.mainBundle URLForResource:@"VectorBalls.metal"
                                                     withExtension:@"txt"];
            NSError *error = nil;
            NSString *source = sourceURL
                    ? [NSString stringWithContentsOfURL:sourceURL
                                              encoding:NSUTF8StringEncoding
                                                 error:&error]
                    : nil;
            if (!source) {
                LogError(@"VectorBallsView: shader source unavailable: %@",
                         error.localizedDescription ?: @"missing resource");
            }
            id<MTLLibrary> library = source
                    ? [device newLibraryWithSource:source options:nil error:&error]
                    : nil;
            if (!library) {
                LogError(@"VectorBallsView: shader compile failed: %@",
                         error.localizedDescription);
            }
            if (library) {
                MTLRenderPipelineDescriptor *desc =
                        [[MTLRenderPipelineDescriptor alloc] init];
                desc.vertexFunction = [library newFunctionWithName:@"vb_vertex"];
                desc.fragmentFunction = [library newFunctionWithName:@"vb_fragment"];
                desc.colorAttachments[0].pixelFormat = colorFormat;
                desc.depthAttachmentPixelFormat = depthFormat;
                desc.rasterSampleCount = sampleCount;
                pipeline = [device newRenderPipelineStateWithDescriptor:desc
                                                                  error:&error];
                if (!pipeline) {
                    LogError(@"VectorBallsView: pipeline creation failed: %@",
                             error.localizedDescription);
                }
            }
            if (pipeline) {
                cachedDevice = device;
                cachedPipeline = pipeline;
                cachedColorFormat = colorFormat;
                cachedDepthFormat = depthFormat;
                cachedSampleCount = sampleCount;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(pipeline);
        });
    });
}

- (void)setupMetal {
    if (!self.device) {
        LogError(@"VectorBallsView: no Metal device; about animation disabled");
        return;
    }

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    // A transparent clear, so the window's background artwork shows through.
    // Only the balls' opaque pixels cover it, and MSAA gives blended edges.
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.clearDepth = 1.0;
    self.layer.opaque = NO;
    if ([self.device supportsTextureSampleCount:4]) {
        self.sampleCount = 4;
    }

    id<MTLDevice> device = self.device;
    __weak VectorBallsView *weakSelf = self;
    VibeRequestVectorBallsPipeline(device,
                                   self.colorPixelFormat,
                                   self.depthStencilPixelFormat,
                                   self.sampleCount,
                                   ^(id<MTLRenderPipelineState> pipeline) {
        VectorBallsView *strongSelf = weakSelf;
        if (!strongSelf || !pipeline || strongSelf.device != device) {
            return;
        }
        // The balls are opaque, since depth is a darkening cue rather than
        // transparency, so a plain depth test sorts them correctly.
        MTLDepthStencilDescriptor *depthDesc =
                [[MTLDepthStencilDescriptor alloc] init];
        depthDesc.depthCompareFunction = MTLCompareFunctionLess;
        depthDesc.depthWriteEnabled = YES;

        strongSelf->_commandQueue = [device newCommandQueue];
        strongSelf->_pipeline = pipeline;
        strongSelf->_depthState =
                [device newDepthStencilStateWithDescriptor:depthDesc];
        [strongSelf buildInstances];
        strongSelf->_startTime = CACurrentMediaTime();
        strongSelf.delegate = strongSelf;
    });
}

- (void)buildInstances {
    // Rasterise the wordmark to a grayscale coverage map: white ink on black.
    NSUInteger bw = 0, bh = 0, bpr = 0;
    uint8_t *coverage = [self rasterizeWord:kWord width:&bw height:&bh bytesPerRow:&bpr];
    if (!coverage) {
        _instanceCount = 0;
        return;
    }

    // A grid of square cells, sized so that about kHalftoneRows rows span the
    // glyph height.
    NSUInteger cell = MAX((NSUInteger)1, (NSUInteger)llround((double)bh / kHalftoneRows));
    NSUInteger cols = bw / cell;
    NSUInteger rows = bh / cell;
    if (cols == 0 || rows == 0) {
        // A degenerate raster, where the cell is larger than the bitmap. The
        // spacing below would divide by zero, and newBufferWithBytes: would
        // overread the calloc(0) buffer.
        free(coverage);
        _instanceCount = 0;
        return;
    }
    float spacing = kWordWorldWidth / (float)cols;
    float bigRadius = spacing * kBigDotFraction;
    float smallRadius = spacing * kSmallDotFraction;

    // In the worst case, one dot per cell.
    VBInstance *instances = calloc(cols * rows, sizeof(VBInstance));
    NSUInteger count = 0;
    for (NSUInteger cy = 0; cy < rows; cy++) {
        for (NSUInteger cx = 0; cx < cols; cx++) {
            // The average ink coverage over the cell.
            uint32_t sum = 0;
            for (NSUInteger py = 0; py < cell; py++) {
                const uint8_t *rowPtr = coverage + (cy * cell + py) * bpr;
                for (NSUInteger px = 0; px < cell; px++) {
                    sum += rowPtr[cx * cell + px];
                }
            }
            float cov = (float)sum / (float)(cell * cell * 255);
            if (cov < kCoverageOn) {
                continue;
            }
            // Bitmap row 0 is the top scanline, so flip to a world y-up and
            // centre.
            float x = ((float)cx + 0.5f - cols / 2.0f) * spacing;
            float y = ((float)(rows - 1 - cy) + 0.5f - rows / 2.0f) * spacing;
            instances[count].home = (vector_float4){ x, y, 0, 1 };
            instances[count].scatter = [self randomScatterPosition];
            instances[count].attr = (vector_float4){ cov >= kCoverageBig ? bigRadius : smallRadius, 0, 0, 0 };
            count++;
        }
    }
    free(coverage);

    _instanceCount = count;
    _instanceBuffer = [self.device newBufferWithBytes:instances
                                               length:MAX((NSUInteger)1, count) * sizeof(VBInstance)
                                              options:MTLResourceStorageModeShared];
    free(instances);
}

// Draws the word in white on black in a rounded font and returns a malloc'd
// single-channel, 8-bit coverage buffer. The caller frees it. The dimensions
// and stride come back through out parameters.
- (uint8_t *)rasterizeWord:(NSString *)word width:(NSUInteger *)outW height:(NSUInteger *)outH bytesPerRow:(NSUInteger *)outBPR {
    CGFloat pointSize = 128.0;
    NSFont *font = [Fonts font:pointSize bold:YES];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.whiteColor };
    NSSize textSize = [word sizeWithAttributes:attrs];
    NSUInteger pad = (NSUInteger)ceil(pointSize * 0.12);
    NSUInteger w = (NSUInteger)ceil(textSize.width) + pad * 2;
    NSUInteger h = (NSUInteger)ceil(textSize.height) + pad * 2;
    if (w == 0 || h == 0) {
        return NULL;
    }

    uint8_t *buffer = calloc(w * h, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(buffer, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!cg) {
        free(buffer);
        return NULL;
    }

    NSGraphicsContext *nsctx = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = nsctx;
    [word drawAtPoint:NSMakePoint(pad, pad) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(cg);

    // CGBitmapContext memory row 0 is the top scanline, so there is no flip:
    // buildInstances maps a low row index to a high world Y, at the top of the
    // screen.
    *outW = w;
    *outH = h;
    *outBPR = w;
    return buffer;
}

- (vector_float4)randomScatterPosition {
    // A random point on a spherical shell well outside the camera frustum.
    float z = vb_random01() * 2.0f - 1.0f;
    float theta = vb_random01() * (float)(2.0 * M_PI);
    float r = sqrtf(MAX(0.0f, 1.0f - z * z));
    float radius = 18.0f + vb_random01() * 10.0f;
    return (vector_float4){ cosf(theta) * r * radius, sinf(theta) * r * radius, z * radius, 1 };
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_pipeline || _instanceCount == 0) {
        return;
    }
    MTLRenderPassDescriptor *passDescriptor = self.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (!passDescriptor || !drawable) {
        return;
    }

    float time = (float)(CACurrentMediaTime() - _startTime);
    float t = MIN(time / (float)kIntroDuration, 1.0f);
    float introT = t * t * (3.0f - 2.0f * t); // smoothstep fly-in

    CGSize size = self.drawableSize;
    float aspect = size.height > 0 ? (float)(size.width / size.height) : 1.0f;

    VBUniforms uniforms;
    uniforms.projection = vb_perspective(35.0f * (float)M_PI / 180.0f, aspect, 0.1f, 200.0f);
    uniforms.view = vb_translation(0, 0, -kCameraDistance);
    // Spin continuously, phased so that the fly-in lands exactly face-on. The
    // grid rotates toward the viewer while the dots settle, reads "vibe"
    // straight on the moment they land, and then keeps turning.
    float phase = time - (float)kIntroDuration;
    float yaw = phase * 0.9f;
    float tilt = sinf(phase * 0.43f) * 0.38f + 0.15f;
    uniforms.model = matrix_multiply(vb_rotationX(tilt), vb_rotationY(yaw));
    uniforms.params = (vector_float4){ introT, 0, time, 0 };

    // Red key light: fixed in view space (bottom-left) so it lights the dots in
    // the lower-left quarter as the grid spins.
    uniforms.lightView = (vector_float4){ kRedLightViewPos.x, kRedLightViewPos.y, kRedLightViewPos.z, 1 };

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];

    [encoder setRenderPipelineState:_pipeline];
    [encoder setDepthStencilState:_depthState];
    [encoder setVertexBuffer:_instanceBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:_instanceCount];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

// Purely decorative, and it spans the whole window on top of everything else,
// so it must not take the mouse: clicks belong to the version and copyright
// labels beneath it, and to the window's own background drag.
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end
