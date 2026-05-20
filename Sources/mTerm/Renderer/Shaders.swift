enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float2 glyphPos;
        float2 glyphSize;
        float2 atlasPos;
        float2 atlasSize;
        float4 fgColor;
    };

    struct FlatInstance {
        float2 pos;
        float2 size;
        float4 color;
    };

    struct Uniforms {
        float2 viewportSize;
        float2 atlasSize;
    };

    struct VOutGlyph {
        float4 position [[position]];
        float2 atlasUV;
        float4 color;
    };

    struct VOutFlat {
        float4 position [[position]];
        float4 color;
    };

    static inline float2 unitCorner(uint vid) {
        return float2(float(vid & 1u), float((vid >> 1) & 1u));
    }

    static inline float2 pixelToNDC(float2 pixel, float2 viewport) {
        return float2(
            (pixel.x / viewport.x) * 2.0 - 1.0,
            1.0 - (pixel.y / viewport.y) * 2.0
        );
    }

    vertex VOutGlyph gridVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant CellInstance *instances [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
        CellInstance inst = instances[iid];
        float2 corner = unitCorner(vid);
        float2 pixelPos = inst.glyphPos + corner * inst.glyphSize;

        float2 atlasPx = inst.atlasPos + corner * inst.atlasSize;

        VOutGlyph out;
        out.position = float4(pixelToNDC(pixelPos, uniforms.viewportSize), 0.0, 1.0);
        out.atlasUV = atlasPx / uniforms.atlasSize;
        out.color = inst.fgColor;
        return out;
    }

    fragment float4 gridFragment(VOutGlyph in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
        float coverage = atlas.sample(s, in.atlasUV).r;
        return float4(in.color.rgb, in.color.a * coverage);
    }

    vertex VOutFlat flatVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               constant FlatInstance *instances [[buffer(0)]],
                               constant Uniforms &uniforms [[buffer(1)]]) {
        FlatInstance inst = instances[iid];
        float2 corner = unitCorner(vid);
        float2 pixelPos = inst.pos + corner * inst.size;

        VOutFlat out;
        out.position = float4(pixelToNDC(pixelPos, uniforms.viewportSize), 0.0, 1.0);
        out.color = inst.color;
        return out;
    }

    fragment float4 flatFragment(VOutFlat in [[stage_in]]) {
        return in.color;
    }
    """
}
