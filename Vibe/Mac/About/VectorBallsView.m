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

static NSString *const kShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Inst { float4 home; float4 scatter; float4 attr; };\n"
     "struct Uniforms {\n"
     "    float4x4 model; float4x4 view; float4x4 projection;\n"
     "    float4 params; float4 lightView;\n"
     "};\n"
     "struct VOut {\n"
     "    float4 position [[position]];\n"
     "    float2 uv;\n"
     "    float3 centerView;\n" // ball centre in view space, for lighting
     "};\n"
     "vertex VOut vb_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
     "                      constant Inst *instances [[buffer(0)]],\n"
     "                      constant Uniforms &u [[buffer(1)]]) {\n"
     "    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);\n"
     "    constant Inst &inst = instances[iid];\n"
     "    float t = u.params.x;\n"
     "    float3 p = mix(inst.scatter.xyz, inst.home.xyz, t);\n"
     "    // Gentle travelling wave across the word once the intro has landed.\n"
     "    p.y += sin(u.params.z * 1.7 + inst.home.x * 0.55) * 0.28 * t;\n"
     "    float4 centerView = u.view * (u.model * float4(p, 1.0));\n"
     "    float4 viewPos = centerView;\n"
     "    viewPos.xy += corner * inst.attr.x;\n" // billboard, per-dot radius
     "    VOut out;\n"
     "    out.position = u.projection * viewPos;\n"
     "    out.uv = corner;\n"
     "    out.centerView = centerView.xyz;\n"
     "    return out;\n"
     "}\n"
     // A procedural studio environment, sampled by the mirror reflection
     // vector and standing in for a chrome cubemap: a floor-to-sky gradient, a
     // broad overhead softbox, and two sharp light streaks that give chrome
     // its signature pop.
     "float3 vb_env(float3 d) {\n"
     "    d = normalize(d);\n"
     "    float up = d.y * 0.5 + 0.5;\n"
     "    float3 col = mix(float3(0.10, 0.11, 0.14), float3(0.80, 0.86, 1.00), up);\n"
     "    col += smoothstep(0.30, 1.0, d.y) * float3(1.0, 1.05, 1.2);\n"        // broad overhead softbox
     "    float key = smoothstep(0.88, 0.999, dot(d, normalize(float3(0.55, 0.65, 0.52))));\n"
     "    col += key * float3(3.2, 3.0, 2.7);\n"                                 // hot key glint
     "    float fill = smoothstep(0.84, 1.0, dot(d, normalize(float3(-0.7, 0.15, 0.35))));\n"
     "    col += fill * float3(0.7, 0.85, 1.1);\n"                               // cool fill streak
     "    col += clamp(-d.y, 0.0, 1.0) * float3(0.14, 0.10, 0.08);\n"           // warm floor bounce
     "    return col;\n"
     "}\n"
     "fragment float4 vb_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {\n"
     "    float r2 = dot(in.uv, in.uv);\n"
     "    if (r2 > 1.0) discard_fragment();\n"
     "    float r = sqrt(r2);\n"
     "    // Flat top with a beveled rim so each dot reads as an embossed disc.\n"
     "    float slope = smoothstep(0.74, 1.0, r);\n"
     "    float2 dir = r > 1e-4 ? in.uv / r : float2(0.0);\n"
     "    float3 n = normalize(float3(dir * slope * 2.1, 1.0));\n"
     "    // Perfect-mirror chrome (metallic 1.0, roughness 0.0): reflect the view\n"
     "    // vector about the normal and sample the environment directly (no blur).\n"
     "    float3 vdir = float3(0.0, 0.0, 1.0);\n"          // surface -> camera
     "    float3 R = reflect(-vdir, n);\n"
     "    float3x3 rot = float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz);\n"
     "    float3 Rw = rot * R + float3(in.centerView.xy * 0.02, 0.0);\n" // world-anchored + per-dot parallax
     "    float3 envc = vb_env(Rw);\n"
     "    // Schlick Fresnel with a chrome F0; a pure metal has no diffuse term.\n"
     "    float3 F0 = float3(0.95, 0.96, 0.98);\n"
     "    float ct = clamp(dot(n, vdir), 0.0, 1.0);\n"
     "    float3 F = F0 + (1.0 - F0) * pow(1.0 - ct, 5.0);\n"
     "    float3 c = envc * F;\n"
     "    // Red point light from the bottom-left. On a mirror metal it reads as a\n"
     "    // red specular hit plus a faint wash, and the quadratic attenuation\n"
     "    // keeps it on the dots nearest the lamp (lower-left quarter).\n"
     "    float3 Lv = u.lightView.xyz - in.centerView;\n"
     "    float ldist = length(Lv);\n"
     "    float3 Ldir = Lv / max(ldist, 1e-3);\n"
     "    float latten = 1.0 / (1.0 + 0.05 * ldist * ldist);\n"
     "    float3 Hl = normalize(Ldir + vdir);\n"
     "    float rspec = pow(max(dot(n, Hl), 0.0), 28.0);\n"
     "    float rdiff = max(dot(n, Ldir), 0.0);\n"
     "    c += float3(1.0, 0.06, 0.05) * (rspec * 5.0 + rdiff * 0.7) * latten;\n"
     "    // Depth cue: fade distant dots toward the dark record background.\n"
     "    float depth = -in.centerView.z;\n"
     "    float fade = clamp((depth - 16.0) / 20.0, 0.0, 1.0);\n"
     "    c = mix(c, float3(0.03, 0.03, 0.04), fade);\n"
     "    return float4(c, 1.0);\n"
     "}\n";

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

// Compile the shader source once per process. The view is deliberately rebuilt
// on every About open, in AboutWindowController, and the source front-end
// compile is the expensive part of the setup. Main thread only, since it is
// called from the view's init. The library is device-bound, so a changed
// default device, after an eGPU unplug, simply recompiles.
static id<MTLLibrary> VibeVectorBallsLibrary(id<MTLDevice> device) {
    static id<MTLLibrary> cached;
    if (cached && cached.device == device) {
        return cached;
    }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:nil error:&error];
    if (!library) {
        LogError(@"VectorBallsView: shader compile failed: %@", error.localizedDescription);
        return nil;
    }
    cached = library;
    return library;
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

    NSError *error = nil;
    id<MTLLibrary> library = VibeVectorBallsLibrary(self.device);
    if (!library) {
        return;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"vb_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"vb_fragment"];
    desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    desc.depthAttachmentPixelFormat = self.depthStencilPixelFormat;
    desc.rasterSampleCount = self.sampleCount;
    id<MTLRenderPipelineState> pipeline = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        LogError(@"VectorBallsView: pipeline creation failed: %@", error.localizedDescription);
        return;
    }

    // The balls are opaque, since depth is a darkening cue rather than
    // transparency, so a plain depth test sorts them correctly with no CPU
    // work.
    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;

    _commandQueue = [self.device newCommandQueue];
    _pipeline = pipeline;
    _depthState = [self.device newDepthStencilStateWithDescriptor:depthDesc];
    [self buildInstances];
    _startTime = CACurrentMediaTime();
    self.delegate = self;
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
