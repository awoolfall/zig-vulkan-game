cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
    float4 camera_position;
    float time;
}

cbuffer instance_data : register(b1)
{
    row_major float4x4 model_matrix;
    unsigned int entity_id;
    unsigned int flags;
    unsigned int start_bone_idx;
};
#define IS_SELECTED_BIT 0x1
#define IS_UNLIT_BIT 0x2

cbuffer bone_data : register(b2)
{
    row_major float4x4 bone_matricies[1024];
}

struct light
{
    float4 position;
    float4 colour;
    float intensity;
    unsigned int type;
};
#define LIGHT_TYPE_DIRECTIONAL 0
#define LIGHT_TYPE_POINT 1
#define LIGHT_TYPE_SPOT 2

#define MAX_LIGHTS 4
cbuffer lights_data : register(b3)
{
    light lights[MAX_LIGHTS];
}

Texture2D diffuse_texture;
SamplerState diffuse_sampler;

struct vs_in
{
    float3 pos : POS;
    float3 normals : NORMAL;
    float3 tangents : TANGENT;
    float3 bitangents : BITANGENT;
    float2 tex_coord : TEXCOORD0;
    int4 bone_ids : TEXCOORD1;
    float4 bone_weights : TEXCOORD2;
};

struct vs_out
{
    float4 position : SV_POSITION;
    float3 normal : NORMAL;
    float3 tangent : TANGENT;
    float4 world_pos : POS;
    float2 tex_coord : TEXCOORD0;
};

vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;

    float4x4 bone_mat = bone_matricies[input.bone_ids[0] + start_bone_idx] * input.bone_weights[0];
    bone_mat         += bone_matricies[input.bone_ids[1] + start_bone_idx] * input.bone_weights[1];
    bone_mat         += bone_matricies[input.bone_ids[2] + start_bone_idx] * input.bone_weights[2];
    bone_mat         += bone_matricies[input.bone_ids[3] + start_bone_idx] * input.bone_weights[3];

    output.position = mul(float4(input.pos, 1.0), bone_mat);
    output.position = mul(output.position, model_matrix);

    output.world_pos = float4(output.position.xyz, 0.0);

    float4x4 vp = mul(view, projection);
    output.position = mul(output.position, vp);

    output.normal = mul(input.normals.xyz, model_matrix);
    output.tangent = mul(input.tangents.xyz, model_matrix);

    output.tex_coord = input.tex_coord;
    output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
    unsigned int entity_id : SV_TARGET1;
};

ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out) 0;

    float diffuse = 1.0;
    if (~flags & IS_UNLIT_BIT) {
        float3 normals = normalize(input.normal);
        float3 tangents = normalize(input.tangent);
        float3 bitangents = normalize(cross(tangents, normals));
        float3x3 tbn = float3x3(tangents, bitangents, normals);

        float3 sun_direction = normalize(float3(0.0, 1.0, 0.0));
        diffuse = clamp(dot(normalize(input.normal), sun_direction), 0.1, 0.4);
    }
    float4 diffuse_colour = diffuse_texture.Sample(diffuse_sampler, input.tex_coord);

    output.colour = float4(diffuse_colour.rgb * diffuse, 1.0);

    output.entity_id = entity_id;

    if (flags & IS_SELECTED_BIT) {
        output.colour = lerp(output.colour, float4(0.1, 1.0, 0.2, 1.0), smoothstep(0.95, 0.99, sin(time * 5.0 + (-input.world_pos.y) * 2.0)));
    }

    const float fresnel0 = 0.04;
    float3 view_dir = normalize(input.world_pos.xyz - camera_position.xyz);
    float fresnel = clamp(dot(normalize(input.normal), -view_dir), 0.0, 1.0);
    fresnel = pow(1.0 - fresnel, 5.0);
    fresnel = fresnel0 + (1.0 - fresnel0) * fresnel;
    //output.colour = 1.0 - fresnel;
    //if (output.colour.r > 1.0) {
    //    output.colour = float4(1.0, 0.0, 0.0, 1.0);
    //}

    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (lights[i].intensity < 0.05) { continue; }

        if (lights[i].type == LIGHT_TYPE_DIRECTIONAL) {
            output.colour = lights[i].colour;
            return output;
            //float3 light_dir = normalize(lights[i].position.xyz - input.world_pos.xyz);
            //float diffuse = clamp(dot(normalize(input.normal), light_dir), 0.1, 1.0);
            //output.colour += lights[i].colour * diffuse * lights[i].intensity;
        }
        else if (lights[i].type == LIGHT_TYPE_POINT) {
            float3 light_dir = normalize(lights[i].position.xyz - input.world_pos.xyz);
            float dist = length(input.world_pos.xyz - lights[i].position.xyz);
            float attenuation = 1.0 / (1.0 + dist * dist);
            output.colour.rgb += saturate(dot(light_dir, normalize(input.normal))) * lights[i].colour.rgb * attenuation * lights[i].intensity;
        }
    }
    output.colour.a = 1.0;

    //output.colour = lerp(output.colour, float4(1.0, 1.0, 1.0, 1.0), fresnel);
    //output.colour = float4(fresnel, fresnel, fresnel, 1.0);
    //output.colour = float4(input.view_dir, 1.0);
    //output.colour = dot(normalize(input.view_dir), float3(0.0, 0.0, 1.0));

    return output;
}
