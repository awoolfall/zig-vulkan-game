#include "gfx/common.slang"

#ifndef MAX_OBJECTS_PER_INSTANCE_BUFFER
#define MAX_OBJECTS_PER_INSTANCE_BUFFER 64
#endif

#ifndef MAX_LIGHTS_DATA_PER_BUFFER
#define MAX_LIGHTS_DATA_PER_BUFFER 64
#endif

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

struct CameraData
{
    float4x4 projection;
    float4x4 view;
    float4 position;
    float time;
};

[[vk::binding(0, 0)]]
ConstantBuffer<CameraData> camera_data : register(b0);

struct InstanceData
{
    float4x4 model_matrix;
    uint entity_id;
    uint flags;
};
#define IS_SELECTED_BIT 0x1
#define IS_UNLIT_BIT 0x2

[[vk::binding(0, 1)]]
ConstantBuffer<InstanceData[MAX_OBJECTS_PER_INSTANCE_BUFFER]> instance_data : register(b1);

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(0, 2)]]
ConstantBuffer<LightsData[MAX_LIGHTS_DATA_PER_BUFFER]> lights_data : register(b2);

#ifdef SKELETAL_RENDERING
struct BoneData
{
    float4x4 bone_matricies[1024];
};

[[vk::binding(0, 4)]]
ConstantBuffer<BoneData> bone_data : register(b3);
#endif

[[vk::binding(0, 3)]]
Texture2D diffuse_texture;
[[vk::binding(1, 3)]]
SamplerState diffuse_sampler;

struct PushConstants
{
    uint32_t instance_index;   
    uint32_t lights_index;
    uint32_t start_bone_idx;
    uint32_t __pad;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

struct vs_in
{
    float3 pos : POS;
    float3 normals : NORMAL;
    float3 tangents : TANGENT;
    float3 bitangents : BITANGENT;
    float2 tex_coord : TEXCOORD0;
#ifdef SKELETAL_RENDERING
    int4 bone_ids : BONE_IDS;
    float4 bone_weights : BONE_WEIGHTS;
#endif
};

struct vs_out
{
    float4 position : SV_POSITION;
    float3 normal : NORMAL;
    float3 tangent : TANGENT;
    float4 world_pos : POS;
    float2 tex_coord : TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    InstanceData data = instance_data[push_constants.instance_index];

    vs_out output = (vs_out) 0;

    output.position = float4(input.pos, 1.0);

#ifdef SKELETAL_RENDERING
    float4x4 bone_mat = bone_data.bone_matricies[input.bone_ids[0] + push_constants.start_bone_idx] * input.bone_weights[0];
    bone_mat         += bone_data.bone_matricies[input.bone_ids[1] + push_constants.start_bone_idx] * input.bone_weights[1];
    bone_mat         += bone_data.bone_matricies[input.bone_ids[2] + push_constants.start_bone_idx] * input.bone_weights[2];
    bone_mat         += bone_data.bone_matricies[input.bone_ids[3] + push_constants.start_bone_idx] * input.bone_weights[3];

    output.position = mul(output.position, bone_mat);
#endif

    output.position = mul(output.position, data.model_matrix);

    output.world_pos = float4(output.position.xyz, 0.0);

    float4x4 vp = mul(camera_data.view, camera_data.projection);
    output.position = mul(output.position, vp);

    output.normal = mul(float4(input.normals.xyz, 0.0), data.model_matrix).xyz;
    output.tangent = mul(float4(input.tangents.xyz, 0.0), data.model_matrix).xyz;

    output.tex_coord = input.tex_coord;
    output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
#ifdef RENDER_ENTITY_ID_BUFFER
    uint entity_id : SV_TARGET1;
#endif
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    InstanceData data = instance_data[push_constants.instance_index];
    LightsData ldata = lights_data[push_constants.lights_index];

    ps_out output = (ps_out) 0;

    float3 normals = normalize(input.normal);
    float3 tangents = normalize(input.tangent);
    float3 bitangents = normalize(cross(tangents, normals));
    float3x3 tbn = float3x3(tangents, bitangents, normals);

    float4 diffuse_colour = diffuse_texture.Sample(diffuse_sampler, input.tex_coord);

    // TODO better ambient model
    float3 ambient_colour = float3(1.0, 1.0, 1.0);
    float ambient_intensity = 0.04;
    output.colour.rgb = diffuse_colour.rgb * ambient_colour * ambient_intensity;

    float3 view_dir = normalize(camera_data.position.xyz - input.world_pos.xyz);
    float roughness = 0.5;

    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = ldata.lights[i];

        float3 light_diffuse = calculate_light_diffuse(
            light,
            view_dir,
            input.world_pos.xyz,
            input.normal,
            roughness
        );

        output.colour.rgb += light_diffuse * diffuse_colour.rgb;
    }

    if ((data.flags & IS_UNLIT_BIT) != 0) {
        output.colour = diffuse_colour;
    }

    if ((data.flags & IS_SELECTED_BIT) != 0) {
        output.colour = lerp(output.colour, float4(0.1, 1.0, 0.2, 1.0), smoothstep(0.95, 0.99, sin(camera_data.time * 5.0 + (-input.world_pos.y) * 2.0)));
    }

    output.colour.a = 1.0;

    //output.colour = float4((normalize(input.normal) + 1.0) / 2.0 , 1.0);

#ifdef RENDER_ENTITY_ID_BUFFER
    output.entity_id = data.entity_id;
#endif

    return output;
}
