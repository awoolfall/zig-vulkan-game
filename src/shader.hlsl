cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

struct instance_data
{
    row_major float4x4 model_matrix;
    float time;
    unsigned int entity_id;
    unsigned int flags;
};
#define IS_SELECTED_BIT 0x1

cbuffer instance_data_array : register(b1)
{
    instance_data instance_data_array[128];
}

cbuffer bone_data : register(b2)
{
    row_major float4x4 bone_matricies[1024];
}

cbuffer instance_idx : register(b3)
{
    unsigned int instance_idx;
    unsigned int start_bone_idx;
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
    float4 colour : POS;
    float2 tex_coord : TEXCOORD0;
    float3 sun_dir : SUN_DIR;
};

float4x4 construct_tbn(float3 normal, float3 tangent, float3 binormal) {
    return float4x4(
            float4(tangent, 0.0), 
            float4(binormal, 0.0), 
            float4(normal, 0.0), 
            float4(0.0, 0.0, 0.0, 1.0)
            );
}

vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    const instance_data id = instance_data_array[instance_idx];

    vs_out output = (vs_out) 0;

    float4x4 vp = mul(view, projection);
    float4x4 mvp = mul(id.model_matrix, vp);
    
    float4x4 bone_mat = bone_matricies[input.bone_ids[0] + start_bone_idx] * input.bone_weights[0];
    bone_mat         += bone_matricies[input.bone_ids[1] + start_bone_idx] * input.bone_weights[1];
    bone_mat         += bone_matricies[input.bone_ids[2] + start_bone_idx] * input.bone_weights[2];
    bone_mat         += bone_matricies[input.bone_ids[3] + start_bone_idx] * input.bone_weights[3];

    output.position = mul(float4(input.pos, 1.0), bone_mat);
    output.position = mul(output.position, mvp);

    float4 colour = float4(vertId == 0, vertId == 1, vertId == 2, 1.0);

    output.normal = input.normals.xyz;

    float3 normals = mul(float4(input.normals, 0.0), id.model_matrix).xyz;
    float3 tangents = mul(float4(input.tangents, 0.0), id.model_matrix).xyz;
    float3 bitangents = mul(float4(input.bitangents, 0.0), id.model_matrix).xyz;

    float3x3 tbn = float3x3(tangents, bitangents, normals);
    float3 sun_direction = normalize(float3(0.0, 1.0, 0.0));
    output.sun_dir = normalize(mul(tbn, sun_direction));

    output.colour = float4(input.normals, 0.0);

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
    const instance_data id = instance_data_array[instance_idx];

    ps_out output = (ps_out) 0;

    float diffuse = max(dot(float3(0.0, 0.0, 1.0), input.sun_dir.xyz), 0.1);
    float4 diffuse_colour = diffuse_texture.Sample(diffuse_sampler, input.tex_coord);

    output.colour = float4(diffuse_colour.rgb * diffuse, 1.0);

    output.entity_id = id.entity_id;

    if (id.flags & IS_SELECTED_BIT) {
        output.colour = lerp(output.colour, float4(0.1, 1.0, 0.2, 1.0), step(0.5, sin(id.time * 10.0 + (input.position.x + input.position.y) * 0.05)));
    }

    return output;
}
