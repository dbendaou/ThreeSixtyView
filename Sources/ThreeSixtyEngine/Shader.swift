import Foundation
import ProjectionMath
#if os(macOS)
import simd

/// Packed to match the Metal `Uniforms` struct. Floats then Int32s, 4-byte stride.
public struct GPUUniforms {
    public var outputWidth: Float = 1
    public var outputHeight: Float = 1
    public var sourceWidth: Float = 1
    public var sourceHeight: Float = 1
    public var backWidth: Float = 1
    public var backHeight: Float = 1
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var roll: Float = 0
    public var fovY: Float = 1
    public var domeFOV: Float = 1
    public var fisheyeOutFOV: Float = 1
    public var planetScale: Float = 1
    public var panoramaHoriz: Float = 1
    public var panoramaVert: Float = 1
    public var magicHoriz: Float = 1
    public var magicVert: Float = 1
    public var ringInner: Float = 0.4
    public var ringLat0: Float = 0
    public var ringLatSpan: Float = 1
    public var throwScale: Float = 0.6
    public var segYawOffset: Float = .pi
    public var brightness: Float = 0
    public var contrast: Float = 1
    public var saturation: Float = 1
    public var sharpness: Float = 0
    public var lens0CX: Float = 0.5
    public var lens0CY: Float = 0.5
    public var lens0Radius: Float = 0.5
    public var lens0FOV: Float = 4
    public var lens0Yaw: Float = 0
    public var lens0Pitch: Float = 0
    public var lens0Roll: Float = 0
    public var lens1CX: Float = 0.75
    public var lens1CY: Float = 0.5
    public var lens1Radius: Float = 0.5
    public var lens1FOV: Float = 4
    public var lens1Yaw: Float = .pi
    public var lens1Pitch: Float = 0
    public var lens1Roll: Float = 0
    public var blendWidth: Float = 0.2
    public var showCalibration: Float = 0
    public var unfoldMode: Int32 = 0
    public var inputMode: Int32 = 1
    public var mount: Int32 = 2
    public var quarterTurns: Int32 = 0
    public var hasBack: Int32 = 0
    public var sharpnessOn: Int32 = 0

    public static func make(
        view: ViewParams,
        input: InputParams,
        sourceWidth: Int,
        sourceHeight: Int,
        backWidth: Int,
        backHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        hasBack: Bool,
        showCalibration: Bool
    ) -> GPUUniforms {
        var uniforms = GPUUniforms()
        uniforms.outputWidth = Float(outputWidth)
        uniforms.outputHeight = Float(outputHeight)
        uniforms.sourceWidth = Float(sourceWidth)
        uniforms.sourceHeight = Float(sourceHeight)
        uniforms.backWidth = Float(max(backWidth, 1))
        uniforms.backHeight = Float(max(backHeight, 1))
        uniforms.yaw = view.yaw
        uniforms.pitch = view.pitch
        uniforms.roll = view.roll
        uniforms.fovY = view.fovY
        uniforms.domeFOV = view.domeFOV
        uniforms.fisheyeOutFOV = view.fisheyeOutFOV
        uniforms.planetScale = view.planetScale
        uniforms.panoramaHoriz = view.panoramaHoriz
        uniforms.panoramaVert = view.panoramaVert
        uniforms.magicHoriz = view.magicHoriz
        uniforms.magicVert = view.magicVert
        uniforms.ringInner = view.ringInner
        uniforms.ringLat0 = view.ringLat0
        uniforms.ringLatSpan = view.ringLatSpan
        uniforms.throwScale = view.throwScale
        uniforms.segYawOffset = view.segYawOffset
        uniforms.brightness = input.grade.brightness
        uniforms.contrast = input.grade.contrast
        uniforms.saturation = input.grade.saturation
        uniforms.sharpness = input.grade.sharpness
        uniforms.lens0CX = input.lensA.centerX
        uniforms.lens0CY = input.lensA.centerY
        uniforms.lens0Radius = input.lensA.radius
        uniforms.lens0FOV = input.lensA.fov
        uniforms.lens0Yaw = input.lensA.yaw
        uniforms.lens0Pitch = input.lensA.pitch
        uniforms.lens0Roll = input.lensA.roll
        uniforms.lens1CX = input.lensB.centerX
        uniforms.lens1CY = input.lensB.centerY
        uniforms.lens1Radius = input.lensB.radius
        uniforms.lens1FOV = input.lensB.fov
        uniforms.lens1Yaw = input.lensB.yaw
        uniforms.lens1Pitch = input.lensB.pitch
        uniforms.lens1Roll = input.lensB.roll
        uniforms.blendWidth = input.blend
        uniforms.showCalibration = showCalibration ? 1 : 0
        uniforms.unfoldMode = view.mode.rawValue
        uniforms.inputMode = input.mode.rawValue
        uniforms.mount = input.mount.rawValue
        uniforms.quarterTurns = Int32(input.userQuarterTurns)
        uniforms.hasBack = hasBack ? 1 : 0
        uniforms.sharpnessOn = (input.grade.sharpnessEnabled && input.grade.sharpness > 0.001) ? 1 : 0
        return uniforms
    }
}
#endif

public enum ShaderSource {
    public static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float outputWidth;
        float outputHeight;
        float sourceWidth;
        float sourceHeight;
        float backWidth;
        float backHeight;
        float yaw;
        float pitch;
        float roll;
        float fovY;
        float domeFOV;
        float fisheyeOutFOV;
        float planetScale;
        float panoramaHoriz;
        float panoramaVert;
        float magicHoriz;
        float magicVert;
        float ringInner;
        float ringLat0;
        float ringLatSpan;
        float throwScale;
        float segYawOffset;
        float brightness;
        float contrast;
        float saturation;
        float sharpness;
        float lens0CX;
        float lens0CY;
        float lens0Radius;
        float lens0FOV;
        float lens0Yaw;
        float lens0Pitch;
        float lens0Roll;
        float lens1CX;
        float lens1CY;
        float lens1Radius;
        float lens1FOV;
        float lens1Yaw;
        float lens1Pitch;
        float lens1Roll;
        float blendWidth;
        float showCalibration;
        int unfoldMode;
        int inputMode;
        int mount;
        int quarterTurns;
        int hasBack;
        int sharpnessOn;
    };

    struct VSOut {
        float4 position [[position]];
    };

    constant float PI = 3.14159265358979323846;

    vertex VSOut vs_main(uint vid [[vertex_id]]) {
        float2 xy[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VSOut out;
        out.position = float4(xy[vid], 0.0, 1.0);
        return out;
    }

    float3 safeNorm(float3 v) {
        float l = length(v);
        if (l < 1e-6) return float3(0.0, 0.0, 1.0);
        return v / l;
    }

    float3 applyCamera(float yaw, float pitch, float roll, float3 v) {
        float cy = cos(yaw), sy = sin(yaw);
        float cp = cos(pitch), sp = sin(pitch);
        float cr = cos(roll), sr = sin(roll);
        float3 z = float3(cr * v.x - sr * v.y, sr * v.x + cr * v.y, v.z);
        float3 x = float3(z.x, cp * z.y + sp * z.z, -sp * z.y + cp * z.z);
        return float3(cy * x.x + sy * x.z, x.y, -sy * x.x + cy * x.z);
    }

    int normTurns(int turns) {
        int t = turns % 4;
        if (t < 0) t += 4;
        return t;
    }

    float2 rotateUV(float u, float v, int turns) {
        int t = normTurns(turns);
        if (t == 1) return float2(v, 1.0 - u);
        if (t == 2) return float2(1.0 - u, 1.0 - v);
        if (t == 3) return float2(1.0 - v, u);
        return float2(u, v);
    }

    int extraTurns(int mount) {
        if (mount == 3 || mount == 4) return 2;
        return 0;
    }

    int baseMount(int mount) {
        if (mount == 3) return 2;
        if (mount == 4) return 1;
        return mount;
    }

    void mountRows(int mount, thread float3& r0, thread float3& r1, thread float3& r2) {
        int base = baseMount(mount);
        if (base == 2) {
            r0 = float3(1, 0, 0); r1 = float3(0, 0, 1); r2 = float3(0, -1, 0);
        } else if (base == 1) {
            r0 = float3(1, 0, 0); r1 = float3(0, 0, -1); r2 = float3(0, 1, 0);
        } else {
            r0 = float3(1, 0, 0); r1 = float3(0, 1, 0); r2 = float3(0, 0, 1);
        }
    }

    float3 mulRows(float3 r0, float3 r1, float3 r2, float3 v) {
        return float3(dot(r0, v), dot(r1, v), dot(r2, v));
    }

    float3 mulTranspose(float3 r0, float3 r1, float3 r2, float3 v) {
        return float3(dot(float3(r0.x, r1.x, r2.x), v),
                      dot(float3(r0.y, r1.y, r2.y), v),
                      dot(float3(r0.z, r1.z, r2.z), v));
    }

    float2 letterbox(float aspect, float outW, float outH, thread float& rx, thread float& ry, thread float& rw, thread float& rh) {
        float viewAspect = outW / max(outH, 1e-4);
        if (aspect > viewAspect) {
            rw = outW;
            rh = outW / aspect;
            rx = 0.0;
            ry = (outH - rh) * 0.5;
        } else {
            rh = outH;
            rw = outH * aspect;
            rx = (outW - rw) * 0.5;
            ry = 0.0;
        }
        return float2(rx, ry);
    }

    bool project(constant Uniforms& u, float x, float y, thread float3& direction, thread float2& sourceUV) {
        bool flat = u.inputMode == 4;
        bool original = flat || u.unfoldMode == 0;
        if (original) {
            float aspect = u.sourceWidth / max(u.sourceHeight, 1.0);
            float rx, ry, rw, rh;
            letterbox(aspect, u.outputWidth, u.outputHeight, rx, ry, rw, rh);
            if (x < rx || y < ry || x > rx + rw || y > ry + rh) return false;
            float uu = (x - rx) / max(rw, 1e-4);
            float vv = (y - ry) / max(rh, 1e-4);
            int turns = u.quarterTurns + extraTurns(u.mount);
            sourceUV = rotateUV(uu, vv, turns);
            direction = float3(0, 0, 0);
            return true;
        }

        float lx = x, ly = y, lw = u.outputWidth, lh = u.outputHeight, yawOff = 0.0;
        if (u.unfoldMode == 5) {
            float halfW = u.outputWidth * 0.5;
            if (x < halfW) { lw = halfW; }
            else { lx = x - halfW; lw = u.outputWidth - halfW; yawOff = u.segYawOffset; }
        } else if (u.unfoldMode == 6) {
            float hw = u.outputWidth * 0.5;
            float hh = u.outputHeight * 0.5;
            int col = x < hw ? 0 : 1;
            int row = y < hh ? 0 : 1;
            lx = x - float(col) * hw;
            ly = y - float(row) * hh;
            lw = col == 0 ? hw : u.outputWidth - hw;
            lh = row == 0 ? hh : u.outputHeight - hh;
            float offs[4] = { 0.0, PI * 0.5, PI * 1.5, PI };
            yawOff = offs[row * 2 + col];
        }

        float yaw = u.yaw + yawOff;
        bool hit = true;
        float3 cam = float3(0, 0, 1);
        if (u.unfoldMode == 1 || u.unfoldMode == 2) {
            float fov = u.unfoldMode == 1 ? u.domeFOV : u.fisheyeOutFOV;
            float cx = lw * 0.5, cy = lh * 0.5;
            float radius = min(lw, lh) * 0.5;
            float dx = lx - cx, dy = cy - ly;
            float r = length(float2(dx, dy));
            if (r > radius) return false;
            float theta = (r / max(radius, 1e-5)) * (fov * 0.5);
            float phi = atan2(dy, dx);
            cam = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
        } else if (u.unfoldMode == 3 || u.unfoldMode == 4 || u.unfoldMode == 5 || u.unfoldMode == 6 || u.unfoldMode == 13) {
            float ndcX = (lx / lw) * 2.0 - 1.0;
            float ndcY = 1.0 - (ly / lh) * 2.0;
            float aspect = lw / max(lh, 1e-4);
            float t = tan(u.fovY * 0.5);
            cam = safeNorm(float3(ndcX * aspect * t, ndcY * t, 1.0));
        } else if (u.unfoldMode == 7 || u.unfoldMode == 12) {
            float horiz = u.unfoldMode == 12 ? (2.0 * PI) : u.panoramaHoriz;
            float vert = u.unfoldMode == 12 ? PI : u.panoramaVert;
            float lon = (lx / lw - 0.5) * horiz;
            float lat = (0.5 - ly / lh) * vert;
            if (lat < -PI * 0.5 || lat > PI * 0.5) return false;
            cam = float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
        } else if (u.unfoldMode == 8) {
            float cx = lw * 0.5, cy = lh * 0.5;
            float outer = min(lw, lh) * 0.5;
            float dx = lx - cx, dy = cy - ly;
            float r = length(float2(dx, dy));
            float inner = clamp(u.ringInner, 0.05, 0.95);
            float innerR = outer * inner;
            if (r < innerR || r > outer) return false;
            float t = (r - innerR) / max(outer - innerR, 1e-5);
            float lat = u.ringLat0 + t * u.ringLatSpan;
            if (lat < -PI * 0.5 || lat > PI * 0.5) return false;
            float lon = atan2(dx, dy);
            cam = float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
        } else if (u.unfoldMode == 9) {
            float ndcX = (lx / lw) * 2.0 - 1.0;
            float ndcY = 1.0 - (ly / lh) * 2.0;
            float lon = ndcX * u.magicHoriz * 0.5;
            float yv = ndcY * tan(u.magicVert * 0.5);
            cam = safeNorm(float3(sin(lon), yv, cos(lon)));
        } else if (u.unfoldMode == 10 || u.unfoldMode == 11) {
            float cx = lw * 0.5, cy = lh * 0.5;
            float radius = min(lw, lh) * 0.5;
            float dx = lx - cx, dy = cy - ly;
            float r = length(float2(dx, dy));
            if (r > radius) return false;
            float rho = (r / max(radius, 1e-5)) * u.planetScale;
            float theta = u.unfoldMode == 11 ? (PI - 2.0 * atan(rho)) : (2.0 * atan(rho));
            float phi = atan2(dy, dx);
            cam = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
        } else if (u.unfoldMode == 14) {
            float ndcX = (lx / lw) * 2.0 - 1.0;
            float ndcY = 1.0 - (ly / lh) * 2.0;
            float aspect = lw / max(lh, 1e-4);
            float px = ndcX * aspect, py = ndcY;
            float rho = length(float2(px, py)) * u.throwScale;
            float theta = 2.0 * atan(rho);
            float phi = atan2(py, px);
            cam = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
        } else {
            hit = false;
        }
        if (!hit) return false;
        direction = safeNorm(applyCamera(yaw, u.pitch, u.roll, cam));
        sourceUV = float2(-1.0, -1.0);
        return true;
    }

    float2 fisheyeScales(float radius, float width, float height) {
        float aspect = width / max(height, 1.0);
        return float2(radius * min(1.0, 1.0 / aspect), radius * min(aspect, 1.0));
    }

    bool fisheyeUV(float3 world, int mount, int userTurns,
                   float cx, float cy, float radius, float fov,
                   float lyaw, float lpitch, float lroll,
                   float width, float height, thread float2& uv, thread float& theta, thread float& maxTheta) {
        float3 r0, r1, r2;
        mountRows(mount, r0, r1, r2);
        float3 mountSpace = mulTranspose(r0, r1, r2, safeNorm(world));
        // Inverse of Ry(yaw) * Rx(pitch) * Rz(roll): Ry(-yaw) then Rx(-pitch) then Rz(-roll).
        float cyaw = cos(lyaw), syaw = sin(lyaw);
        float cp = cos(lpitch), sp = sin(lpitch);
        float cr = cos(lroll), sr = sin(lroll);
        float3 y = float3(cyaw * mountSpace.x - syaw * mountSpace.z, mountSpace.y, syaw * mountSpace.x + cyaw * mountSpace.z);
        float3 x = float3(y.x, cp * y.y - sp * y.z, sp * y.y + cp * y.z);
        float3 local = float3(cr * x.x + sr * x.y, -sr * x.x + cr * x.y, x.z);
        theta = acos(clamp(local.z, -1.0, 1.0));
        maxTheta = max(fov * 0.5, 1e-4);
        if (theta > maxTheta + 1e-4) return false;
        float rNorm = min(theta / maxTheta, 1.0);
        float phi = atan2(local.y, local.x);
        float2 scales = fisheyeScales(radius, width, height);
        float logicalU = cx + rNorm * scales.x * cos(phi);
        float logicalV = cy - rNorm * scales.y * sin(phi);
        uv = rotateUV(logicalU, logicalV, userTurns + extraTurns(mount));
        return true;
    }

    float lensWeight(float theta, float maxTheta, float blend) {
        if (theta > maxTheta) return 0.0;
        if (blend <= 1e-5) return 1.0;
        float inner = max(0.0, maxTheta - blend);
        if (theta <= inner) return 1.0;
        float t = (theta - inner) / max(maxTheta - inner, 1e-5);
        float smooth = t * t * (3.0 - 2.0 * t);
        return 1.0 - smooth;
    }

    float3 graded(float3 c, constant Uniforms& u) {
        c = (c - 0.5) * u.contrast + 0.5 + u.brightness;
        c = clamp(c, 0.0, 1.0);
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        return clamp(luma + (c - luma) * u.saturation, 0.0, 1.0);
    }

    float catmullWeight(float x) {
        float ax = abs(x);
        if (ax <= 1.0) return (1.5 * ax - 2.5) * ax * ax + 1.0;
        if (ax < 2.0) return ((-0.5 * ax + 2.5) * ax - 4.0) * ax + 2.0;
        return 0.0;
    }

    float4 sampleUV(texture2d<float, access::read> tex, float2 uv, bool wrapU) {
        float u = uv.x;
        float v = clamp(uv.y, 0.0, 1.0);
        if (wrapU) u = u - floor(u);
        else u = clamp(u, 0.0, 1.0);
        float w = max(float(tex.get_width()), 1.0);
        float h = max(float(tex.get_height()), 1.0);
        float2 coord = float2(u * w - 0.5, v * h - 0.5);
        float2 base = floor(coord);
        float2 f = coord - base;
        float4 color = float4(0.0);
        float weightSum = 0.0;
        for (int j = -1; j <= 2; j++) {
            float wy = catmullWeight(float(j) - f.y);
            int iy = clamp(int(base.y) + j, 0, int(h) - 1);
            for (int i = -1; i <= 2; i++) {
                float wx = catmullWeight(float(i) - f.x);
                int ix = int(base.x) + i;
                if (wrapU) {
                    int iw = int(w);
                    ix %= iw;
                    if (ix < 0) ix += iw;
                } else {
                    ix = clamp(ix, 0, int(w) - 1);
                }
                float weight = wx * wy;
                color += tex.read(uint2(uint(ix), uint(iy)), 0) * weight;
                weightSum += weight;
            }
        }
        return clamp(color / max(weightSum, 1e-5), 0.0, 1.0);
    }

    float4 shade(constant Uniforms& u, float2 pixel,
                 texture2d<float, access::read> source,
                 texture2d<float, access::read> back) {
        float3 direction;
        float2 src;
        if (!project(u, pixel.x, pixel.y, direction, src)) return float4(0, 0, 0, 1);
        float4 color;
        if (u.inputMode == 4 || u.unfoldMode == 0) {
            color = sampleUV(source, src, false);
            if (u.showCalibration > 0.5 && u.unfoldMode == 0) {
                float2 scales = fisheyeScales(u.lens0Radius, u.sourceWidth, u.sourceHeight);
                float nx = (src.x - u.lens0CX) / max(scales.x, 1e-5);
                float ny = (u.lens0CY - src.y) / max(scales.y, 1e-5);
                if (abs(length(float2(nx, ny)) - 1.0) < 0.02) color = float4(0.92, 0.18, 0.16, 1);
            }
        } else if (u.inputMode == 0) {
            float3 d = safeNorm(direction);
            float lon = atan2(d.x, d.z);
            float lat = asin(clamp(d.y, -1.0, 1.0));
            color = sampleUV(source, float2(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI), true);
        } else if (u.inputMode == 1) {
            float2 uv; float theta, maxTheta;
            if (!fisheyeUV(direction, u.mount, u.quarterTurns, u.lens0CX, u.lens0CY, u.lens0Radius, u.lens0FOV,
                           u.lens0Yaw, u.lens0Pitch, u.lens0Roll, u.sourceWidth, u.sourceHeight, uv, theta, maxTheta)) {
                return float4(0, 0, 0, 1);
            }
            color = sampleUV(source, uv, false);
        } else {
            float2 uv0; float t0, m0;
            float2 uv1; float t1, m1;
            bool a = fisheyeUV(direction, u.mount, u.quarterTurns, u.lens0CX, u.lens0CY, u.lens0Radius, u.lens0FOV,
                               u.lens0Yaw, u.lens0Pitch, u.lens0Roll, u.sourceWidth, u.sourceHeight, uv0, t0, m0);
            bool twoFiles = u.inputMode == 3 && u.hasBack != 0;
            float bw = twoFiles ? u.backWidth : u.sourceWidth;
            float bh = twoFiles ? u.backHeight : u.sourceHeight;
            bool b = fisheyeUV(direction, u.mount, u.quarterTurns, u.lens1CX, u.lens1CY, u.lens1Radius, u.lens1FOV,
                               u.lens1Yaw, u.lens1Pitch, u.lens1Roll, bw, bh, uv1, t1, m1);
            if (!a && !b) return float4(0, 0, 0, 1);
            float4 ca = a ? sampleUV(source, uv0, false) : float4(0);
            float4 cb = float4(0);
            if (b) cb = twoFiles ? sampleUV(back, uv1, false) : sampleUV(source, uv1, false);
            if (!a) color = cb;
            else if (!b) color = ca;
            else {
                float wa = lensWeight(t0, m0, u.blendWidth);
                float wb = lensWeight(t1, m1, u.blendWidth);
                float sum = wa + wb;
                color = sum < 1e-5 ? (ca + cb) * 0.5 : (ca * wa + cb * wb) / sum;
            }
        }
        color.rgb = graded(color.rgb, u);
        color.a = 1.0;
        return color;
    }

    fragment float4 fs_main(VSOut in [[stage_in]],
                            constant Uniforms& u [[buffer(0)]],
                            texture2d<float, access::read> source [[texture(0)]],
                            texture2d<float, access::read> back [[texture(1)]]) {
        float2 p = in.position.xy;
        float4 color = shade(u, p, source, back);
        if (u.sharpnessOn != 0) {
            float4 blur = shade(u, p + float2(-1, 0), source, back)
                        + shade(u, p + float2(1, 0), source, back)
                        + shade(u, p + float2(0, -1), source, back)
                        + shade(u, p + float2(0, 1), source, back);
            blur *= 0.25;
            color.rgb = clamp(color.rgb + u.sharpness * (color.rgb - blur.rgb), 0.0, 1.0);
        }
        return color;
    }
    """

    /// Catches Metal compile failures that only show up on a Mac, using the
    /// source text alone: `half` is a reserved type, and `hypot` is not MSL.
    public static func lintProblems() -> [String] {
        var problems: [String] = []
        if metal.contains("hypot(") {
            problems.append("hypot() is not Metal Shading Language; use length(float2)")
        }
        if metal.range(of: #"\bfloat\s+half\b"#, options: .regularExpression) != nil
            || metal.range(of: #"\bhalf\s*="#, options: .regularExpression) != nil {
            problems.append("a variable is named half, which is a reserved Metal type; rename it (halfW)")
        }
        if !metal.contains("float halfW") {
            problems.append("segment split should use halfW so the name cannot collide with the half type")
        }
        if !metal.contains("catmullWeight") {
            problems.append("sampleUV should be Catmull-Rom (catmullWeight), not a hardware bilinear fetch")
        }
        return problems
    }
}
