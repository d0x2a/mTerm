enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Must match Renderer.CellInstance byte for byte:
    // glyphPos @0, atlasPos @8, atlasSize @12, fgColor @16, flags @20, size 24.
    struct CellInstance {
        float2 glyphPos;
        ushort2 atlasPos;
        ushort2 atlasSize;
        uint fgColor;
        uint flags;
    };

    struct FlatInstance {
        float2 pos;
        float2 size;
        float4 color;
    };

    struct Uniforms {
        float2 viewportSize;
        float2 atlasSize;
        float2 colorAtlasSize;
    };

    struct VOutGlyph {
        float4 position [[position]];
        float2 atlasUV;
        float4 color;
        float isColor;
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
        // The quad on screen and its rect in the atlas are the same size, so a
        // single extent drives both.
        float2 extent = float2(inst.atlasSize);
        float2 pixelPos = inst.glyphPos + corner * extent;

        float2 atlasPx = float2(inst.atlasPos) + corner * extent;
        bool isColor = (inst.flags & 1u) != 0u;
        float2 sheet = isColor ? uniforms.colorAtlasSize : uniforms.atlasSize;

        VOutGlyph out;
        out.position = float4(pixelToNDC(pixelPos, uniforms.viewportSize), 0.0, 1.0);
        out.atlasUV = atlasPx / sheet;
        out.color = unpack_unorm4x8_to_float(inst.fgColor);
        out.isColor = isColor ? 1.0 : 0.0;
        return out;
    }

    fragment float4 gridFragment(VOutGlyph in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]],
                                 texture2d<float> colorAtlas [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
        if (in.isColor > 0.5) {
            // CoreText rasterizes color glyphs premultiplied, but the pipeline
            // blends with straight alpha (sourceAlpha / oneMinusSourceAlpha),
            // so undo the premultiply rather than double-applying it.
            float4 texel = colorAtlas.sample(s, in.atlasUV);
            float3 rgb = texel.a > 0.0 ? texel.rgb / texel.a : texel.rgb;
            return float4(rgb, texel.a * in.color.a);
        }
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
