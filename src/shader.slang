#ifndef MAX_OBJECTS_PER_INSTANCE_BUFFER
#define MAX_OBJECTS_PER_INSTANCE_BUFFER 512
#endif

#ifndef MAX_LIGHTS_DATA_PER_BUFFER
#define MAX_LIGHTS_DATA_PER_BUFFER 512
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

struct Light
{
    float4 position;
    float4 direction;
    float4 colour;
    float intensity;
    float umbra;
    float penumbra;
    uint type;
};
#define LIGHT_TYPE_DIRECTIONAL 0
#define LIGHT_TYPE_POINT 1
#define LIGHT_TYPE_SPOT 2

struct LightsData
{
    Light lights[MAX_LIGHTS];
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

float calculate_diffuse(float3 light_vector, float3 view_vector, float3 normal_vector, float roughness) {
    light_vector = normalize(light_vector);
    view_vector = normalize(view_vector);
    normal_vector = normalize(normal_vector);

    float cos_theta_l = saturate(dot(normal_vector, light_vector));
    float cos_theta_v = saturate(dot(normal_vector, view_vector));

    float3 half_vector = normalize(light_vector + view_vector);
    float cos_theta_d = saturate(dot(light_vector, half_vector));

    float FD90 = 0.5 + (2.0 * roughness * cos_theta_d * cos_theta_d);
    return 
        cos_theta_l *
        (1.0 / 3.14159) * 
        (1.0 + (FD90 - 1.0) * pow((1.0 - cos_theta_l), 5)) * 
        (1.0 + (FD90 - 1.0) * pow((1.0 - cos_theta_v), 5));
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

    float3 view_dir = normalize(camera_data.position.xyz - input.world_pos.xyz);
    float roughness = 0.5;

    float diffuse = 1.0;
    if ((~data.flags & IS_UNLIT_BIT) != 0) {
        float3 normals = normalize(input.normal);
        float3 tangents = normalize(input.tangent);
        float3 bitangents = normalize(cross(tangents, normals));
        float3x3 tbn = float3x3(tangents, bitangents, normals);

        float3 sun_direction = normalize(float3(0.0, 1.0, 0.0));
        //diffuse = clamp(dot(normalize(input.normal), sun_direction), 0.1, 0.4);
        diffuse = calculate_diffuse(
            sun_direction, 
            view_dir,
            input.normal,
            roughness
        );
    }
    float4 diffuse_colour = diffuse_texture.Sample(diffuse_sampler, input.tex_coord);

    output.colour = float4(diffuse_colour.rgb * diffuse, 1.0);

    // TODO better ambient model
    float3 ambient_colour = float3(1.0, 1.0, 1.0);
    float ambient_intensity = 0.04;
    output.colour.rgb += diffuse_colour.rgb * ambient_colour * ambient_intensity;

    if ((data.flags & IS_SELECTED_BIT) != 0) {
        output.colour = lerp(output.colour, float4(0.1, 1.0, 0.2, 1.0), smoothstep(0.95, 0.99, sin(camera_data.time * 5.0 + (-input.world_pos.y) * 2.0)));
    }

    const float fresnel0 = 0.04;
    float fresnel = clamp(dot(normalize(input.normal), -view_dir), 0.0, 1.0);
    fresnel = pow(1.0 - fresnel, 5.0);
    fresnel = fresnel0 + (1.0 - fresnel0) * fresnel;
    //output.colour = 1.0 - fresnel;
    //if (output.colour.r > 1.0) {
    //    output.colour = float4(1.0, 0.0, 0.0, 1.0);
    //}

    for (int i = 0; i < MAX_LIGHTS; i++) {
        Light light = ldata.lights[i];

        if (light.intensity < 0.05) { continue; }

        float3 light_dir;
        float3 light_colour;

        // TODO: distance max, smoothstep to zero, cull lights
        if (light.type == LIGHT_TYPE_DIRECTIONAL) {
            light_colour = light.colour.rgb * light.intensity;
            light_dir = light.direction.xyz;
        }
        else if (light.type == LIGHT_TYPE_POINT) {
            light_dir = normalize(light.position.xyz - input.world_pos.xyz);

            float dist = length(light.position.xyz - input.world_pos.xyz);
            dist = max(dist, 0.01);
            float attenuation = (light.intensity * light.intensity) / (dist * dist);
            light_colour = light.colour.rgb * attenuation;
        }
        else if (light.type == LIGHT_TYPE_SPOT) {
            light_dir = normalize(light.position.xyz - input.world_pos.xyz);

            float dist = length(light.position.xyz - input.world_pos.xyz);
            float attenuation = (light.intensity * light.intensity) / (dist * dist);

            float ts = dot(light_dir, normalize(light.direction.xyz));
            float tu = cos(light.umbra);
            float t = saturate((ts - tu) / (cos(light.umbra - light.penumbra) - tu));
            float fdir = t * t;

            light_colour = light.colour.rgb * fdir * attenuation;
        } else {
            continue;
        }

        float light_diffuse = calculate_diffuse(
            light_dir,
            view_dir,
            input.normal,
            roughness
        );

        output.colour.rgb += light_colour * diffuse_colour.rgb * light_diffuse;
    }
    //output.colour = float4(diffuse, diffuse, diffuse, 1.0);
    output.colour.a = 1.0;

    //output.colour = float4((normalize(input.normal) + 1.0) / 2.0 , 1.0);
    //output.colour = lerp(output.colour, float4(1.0, 1.0, 1.0, 1.0), fresnel);
    //output.colour = float4(fresnel, fresnel, fresnel, 1.0);
    //output.colour = float4(input.view_dir, 1.0);
    //output.colour = dot(normalize(input.view_dir), float3(0.0, 0.0, 1.0));

#ifdef RENDER_ENTITY_ID_BUFFER
    output.entity_id = data.entity_id;
#endif

    return output;
}
