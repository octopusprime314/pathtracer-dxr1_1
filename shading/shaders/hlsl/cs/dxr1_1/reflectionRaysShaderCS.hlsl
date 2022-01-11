#include "../../include/structs.hlsl"
#include "../../include/dxr1_1_defines.hlsl"

RaytracingAccelerationStructure             rtAS                             : register(t0, space0);
Texture2D                                   diffuseTexture[]                 : register(t1, space1);
StructuredBuffer<CompressedAttribute>       vertexBuffer[]                   : register(t2, space2);
Buffer<uint>                                indexBuffer[]                    : register(t3, space3);
//Texture2D                                   albedoSRV                        : register(t4, space0);
//Texture2D                                   normalSRV                        : register(t5, space0);
//Texture2D                                   positionSRV                      : register(t6, space0);
Buffer<uint>                                instanceIndexToMaterialMapping   : register(t4, space0);
Buffer<uint>                                instanceIndexToAttributesMapping : register(t5, space0);
Buffer<float>                               instanceNormalMatrixTransforms   : register(t6, space0);
StructuredBuffer<UniformMaterial>           uniformMaterials                 : register(t7, space0);
StructuredBuffer<AlignedHemisphereSample3D> sampleSets                       : register(t8, space0);
Texture2D                                   viewZSRV                         : register(t9, space0);
TextureCube                                 skyboxTexture                    : register(t10, space0);

RWTexture2D<float4> indirectLightRaysUAV : register(u0);
RWTexture2D<float4> indirectSpecularLightRaysUAV : register(u1);
RWTexture2D<float4> diffusePrimarySurfaceModulation : register(u2);

SamplerState bilinearWrap : register(s0);

#define USE_SANITIZATION 1

cbuffer globalData : register(b0)
{
    float4x4 inverseView;
    float4x4 viewTransform;

    float4 lightColors[MAX_LIGHTS];
    float4 lightPositions[MAX_LIGHTS];
    float4  lightRanges[MAX_LIGHTS/4];
    uint   isPointLight[MAX_LIGHTS];
    uint   numLights;

    float2 screenSize;

    uint seed;
    uint numSamplesPerSet;
    uint numSampleSets;
    uint numPixelsPerDimPerSet;
    uint texturesPerMaterial;

    uint resetHistoryBuffer;
    uint frameNumber;
}

#include "../../include/sunLightCommon.hlsl"
#include "../../include/utils.hlsl"

static float reflectionIndex = 0.5;
static float refractionIndex = 1.0 - reflectionIndex;

#define RNG_BRDF_X(bounce) (4 + 4 + 9 * bounce)
#define RNG_BRDF_Y(bounce) (4 + 5 + 9 * bounce)

float3 LinearToYCoCg(float3 color)
{
    float Co = color.x - color.z;
    float t  = color.z + Co * 0.5;
    float Cg = color.y - t;
    float Y  = t + Cg * 0.5;

    // TODO: useful, but not needed in many cases
    Y = max(Y, 0.0);

    return float3(Y, Co, Cg);
}

float3 YCoCgToLinear(float3 color)
{
    // TODO: useful, but not needed in many cases
    color.x = max(color.x, 0.0);

    float  t   = color.x - color.z * 0.5;
    float  g   = color.z + t;
    float  b   = t - color.y * 0.5;
    float  r   = b + color.y;
    float3 res = float3(r, g, b);

    return res;
}

[numthreads(8, 8, 1)]

void main(int3 threadId            : SV_DispatchThreadID,
          int3 threadGroupThreadId : SV_GroupThreadID)
{

    uint   bounceIndex = 0;

    //class enum RenderVariant
    //{
    //    ONLY_DIFFUSE = 0,
    //    ONLY_SPECULAR = 1,
    //    BOTH_DIFFUSE_AND_SPECULAR = 2
    //};

    
    float4 diffHitDistParams = float4(3.0f, 0.1f, 10.0f, -25.0f);
    float4 specHitDistParams = float4(3.0f, 0.1f, 10.0f, -25.0f);

    int renderVariant = 2;

    float4 nrdDiffuse  = float4(0.0, 0.0, 0.0, 0.0);
    float4 nrdSpecular = float4(0.0, 0.0, 0.0, 0.0);

    float3 indirectDiffuse   = float3(0.0, 0.0, 0.0);
    float3 indirectSpecular = float3(0.0, 0.0, 0.0);

    float3 indirectPos    = float3(0.0, 0.0, 0.0);
    float3 indirectNormal = float3(0.0, 0.0, 0.0);

    float3 indirectSpecularLightEnergy = float3(1.0, 1.0, 1.0);
    float3 indirectDiffuseLightEnergy = float3(1.0, 1.0, 1.0);

    float  indirecDiffusetHitDistance = 0.0;
    float indirectHitDistanceSpecular = 0.0;

    int i = 0;

    float3 albedo      = float3(0.0, 0.0, 0.0);

    float transmittance = 0.0;
    float metallic      = 0.0;
    float3 emissiveColor = float3(0.0, 0.0, 0.0);
    float roughness     = 0.0;

    float3 previousPosition = float3(0.0, 0.0, 0.0);

    float3 diffuseAlbedoDemodulation = float3(0.0, 0.0, 0.0);
    float3 specularAlbedoDemodulation = float3(0.0, 0.0, 0.0);

    float3 rayDir = float3(0.0, 0.0, 0.0);

    float3 skyboxContribution = float3(0.0, 0.0, 0.0);

    float roughnessAccumulation = 0.0;

    for (i = 0; i < 10; i++)
    {
        indirectNormal = normalize(-indirectNormal);

        // First ray is directional and perfect mirror from camera eye so specular it is
        bool diffuseRay = false;

        if (i == 0)
        {
            GenerateCameraRay(threadId.xy, indirectPos, rayDir, viewTransform);
        }
        else
        {
            float2 rng3 = GetRandomSample(threadId.xy, screenSize, indirectPos).xy;
            
            if (rng3.x < 0.0 || rng3.y < 0.0)
            {
                diffuseRay = true;
                // Punch through ray with zero reflection
                if (transmittance > 0.0)
                {
                    rayDir = RefractionRay(-indirectNormal, rayDir);
                }
                // Opaque materials make a reflected ray
                else
                {
                    rayDir = normalize(GetRandomRayDirection(threadId.xy, indirectNormal, screenSize, 0, indirectPos));
                }
            }
            else
            {
                diffuseRay = false;

                // Specular
                float3x3 basis = orthoNormalBasis(indirectNormal);

                // Sampling of normal distribution function to compute the reflected ray.
                // See the paper "Sampling the GGX Distribution of Visible Normals" by E. Heitz,
                // Journal of Computer Graphics Techniques Vol. 7, No. 4, 2018.
                // http://jcgt.org/published/0007/04/01/paper.pdf
                
                float3 viewVector = normalize(indirectPos - previousPosition);

                float2 rng3 = GetRandomSample(threadId.xy, screenSize, indirectPos).xy;

                float3 N = indirectNormal;
                float3 V = viewVector;
                float3 H = ImportanceSampleGGX_VNDF(rng3, roughness, V, basis);

                // Punch through ray with zero reflection
                if (transmittance > 0.0)
                {
                    rayDir = RefractionRay(-indirectNormal, rayDir);
                }
                // Opaque materials make a reflected ray
                else
                {
                    rayDir = reflect(V, H);
                }

                float NoV = max(0, -dot(indirectNormal, viewVector));
                float NoL = max(0, dot(N, rayDir));
                float NoH = max(0, dot(N, H));
                float VoH = max(0, -dot(V, H));
            }
        }
        // See the Heitz paper referenced above for the estimator explanation.
        //   (BRDF / PDF) = F * G2(V, L) / G1(V)
        // The Fresnel term F is already embedded into "primary_specular" by
        // direct_lighting.rgen. Assume G2 = G1(V) * G1(L) here and simplify that
        // expression to just G1(L).

        // float G1_NoL = G1_Smith(primary_roughness, NoL);
        //
        // bounce_throughput *= G1_NoL;
        //
        // bounce_throughput *= 1 / specular_pdf;
        // is_specular_ray  = true;

        float3 rayDirection = float3(0.0, 0.0, 0.0);
        //if (i == 0)
        //{
            rayDirection = normalize(rayDir);
        //}
        //else
        //{
        //    float3 viewVector = normalize(indirectPos - previousPosition);
        //    rayDirection = normalize(viewVector - (2.0f * dot(viewVector, indirectNormal) * indirectNormal));
        //}

        previousPosition = indirectPos;

        RayDesc ray;
        ray.TMin = MIN_RAY_LENGTH;
        ray.TMax = MAX_RAY_LENGTH;

        //if (transmittance > 0.0)
        //{
        //    ray.Origin = indirectPos + (specularRayDirection * -0.001);
        //}
        //else
        //{
            //ray.Origin = indirectPos + (indirectNormal * 0.001);
            ray.Origin = indirectPos + (rayDirection * 0.001);
        //}
        ray.Direction = rayDirection;

        RayQuery<RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> rayQuery;
        rayQuery.TraceRayInline(rtAS, RAY_FLAG_NONE, ~0, ray);

        rayQuery.Proceed();

        if (rayQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
        {
            RayTraversalData rayData;
            rayData.worldRayOrigin    = rayQuery.WorldRayOrigin();
            rayData.closestRayT       = rayQuery.CommittedRayT();
            rayData.worldRayDirection = rayQuery.WorldRayDirection();
            rayData.geometryIndex     = rayQuery.CommittedGeometryIndex();
            rayData.primitiveIndex    = rayQuery.CommittedPrimitiveIndex();
            rayData.instanceIndex     = rayQuery.CommittedInstanceIndex();
            rayData.barycentrics      = rayQuery.CommittedTriangleBarycentrics();
            rayData.objectToWorld     = rayQuery.CommittedObjectToWorld4x3();
            rayData.uvIsValid         = false;

            ProcessOpaqueTriangle(rayData, albedo, roughness, metallic, indirectNormal, indirectPos,
                                  transmittance, emissiveColor);

            emissiveColor *= 10.0;

            if (rayQuery.CommittedTriangleFrontFace() == false && transmittance == 0.0)
            {
                indirectNormal = -indirectNormal;
            }

            float3 accumulatedLightRadiance = float3(0.0, 0.0, 0.0);
            float3 accumulatedDiffuseRadiance = float3(0.0, 0.0, 0.0);
            float3 accumulatedSpecularRadiance = float3(0.0, 0.0, 0.0);

            for (int lightIndex = 0; lightIndex < numLights; lightIndex++)
            {
                float3 lightRadiance            = float3(0.0, 0.0, 0.0);
                float3 indirectDiffuseRadiance  = float3(0.0, 0.0, 0.0);
                float3 indirectSpecularRadiance = float3(0.0, 0.0, 0.0);

                float3 indirectLighting = GetBRDFLight(albedo, indirectNormal, indirectPos, roughness, metallic, threadId.xy, previousPosition,
                                 lightPositions[lightIndex].xyz, isPointLight[lightIndex], lightRanges[lightIndex/4][lightIndex%4], lightColors[lightIndex].xyz,
                                 indirectDiffuseRadiance, indirectSpecularRadiance, lightRadiance);

                // bug fix for light leaking
                if (length(lightRadiance) > 0.0)
                {
                    accumulatedLightRadiance += lightRadiance;
                    accumulatedDiffuseRadiance += indirectDiffuseRadiance;
                    accumulatedSpecularRadiance += indirectSpecularRadiance;
                }

                if (/*length(lightRadiance) > 0.0 &&*/ /*roughnessAccumulation < 0.25*/ i == 0)
                {
                    diffuseAlbedoDemodulation += indirectDiffuseRadiance;
                }

                //if (i == 1 )
                //{
                //    specularAlbedoDemodulation += indirectDiffuseRadiance/* + indirectSpecularRadiance*/;
                //}
            }

            roughnessAccumulation += roughness;

            if (diffuseRay == true)
            {
                float3 light = accumulatedLightRadiance * indirectDiffuseLightEnergy;
                if (length(emissiveColor) > 0.0)
                {
                    // Account for emissive surfaces
                    light += indirectDiffuseLightEnergy * emissiveColor;
                }
                indirecDiffusetHitDistance += rayQuery.CommittedRayT();

                indirectDiffuse += light;

                float normDist = REBLUR_FrontEnd_GetNormHitDist(rayQuery.CommittedRayT(), viewZSRV[threadId.xy].x, diffHitDistParams,
                                                                roughness);

                nrdDiffuse += REBLUR_FrontEnd_PackRadiance(light, normDist, USE_SANITIZATION);

            }
            else
            {
                float3 light = (accumulatedSpecularRadiance + accumulatedDiffuseRadiance) *
                               accumulatedLightRadiance * indirectSpecularLightEnergy;
                if (length(emissiveColor) > 0.0)
                {
                    // Account for emissive surfaces
                    light += indirectSpecularLightEnergy * emissiveColor;
                }

                indirectHitDistanceSpecular += rayQuery.CommittedRayT();

                indirectSpecular += light;

                float normDist = REBLUR_FrontEnd_GetNormHitDist(rayQuery.CommittedRayT(), viewZSRV[threadId.xy].x, specHitDistParams,
                                                                roughness);

                nrdSpecular += REBLUR_FrontEnd_PackRadiance(light, normDist, USE_SANITIZATION);
            }

            // Specular
            float2   rng3 = GetRandomSample(threadId.xy, screenSize, indirectPos).xy;
            float3x3 basis = orthoNormalBasis(indirectNormal);
            float3 N = indirectNormal;
            float3 V = ray.Direction;
            float3 H = ImportanceSampleGGX_VNDF(rng3, roughness, V, basis);
            float3 reflectedRay = reflect(V, H);

            float3 lightVector = normalize(indirectPos - previousPosition);

            float3 F0 = float3(0.04f, 0.04f, 0.04f);
            F0        = lerp(F0, albedo, metallic);

            // calculate per-light radiance
            float3 halfVector = normalize(lightVector + reflectedRay);

            // Cook-Torrance BRDF for specular lighting calculations
            float  NDF = DistributionGGX(indirectNormal, halfVector, roughness);
            float  G   = GeometrySmith(indirectNormal, lightVector, halfVector, roughness);
            float3 F   = FresnelSchlick(max(dot(halfVector, lightVector), 0.0), F0);

            float3 numerator = NDF * G * F;

            float3 specularWeight = G * F;
            indirectSpecularLightEnergy *= specularWeight;

            float3 diffuseWeight = albedo * (1.0 - metallic);
            indirectDiffuseLightEnergy *= diffuseWeight;
        }
        else
        {
            float3 sampleVector = normalize(ray.Direction);
            float4 dayColor     = skyboxTexture.SampleLevel(bilinearWrap, float3(sampleVector.x, sampleVector.y, sampleVector.z), 0);

            if (i == 0)
            {
                float3 light = dayColor.xyz * indirectDiffuseLightEnergy;
                skyboxContribution = light;

                diffuseAlbedoDemodulation += skyboxContribution;
                nrdDiffuse = float4(1.0, 1.0, 1.0, 1.0);
            }
            else
            {
                if (diffuseRay == true)
                {
                    float normDist = REBLUR_FrontEnd_GetNormHitDist(1e5, viewZSRV[threadId.xy].x,
                                                                    diffHitDistParams, 1.0);

                    float3 light    = dayColor.xyz * indirectDiffuseLightEnergy;
                    indirectDiffuse += light;
                    nrdDiffuse += REBLUR_FrontEnd_PackRadiance(light, normDist,
                                                               USE_SANITIZATION);
                }
                else
                {
                    float normDist = REBLUR_FrontEnd_GetNormHitDist(1e5, viewZSRV[threadId.xy].x,
                                                                    specHitDistParams, 1.0);
                    float3 light = dayColor.xyz * indirectSpecularLightEnergy;
                    indirectSpecular += light;
                    nrdSpecular += REBLUR_FrontEnd_PackRadiance(light, normDist,
                                                                USE_SANITIZATION);
                }
            }
            break;
        }
    }

    if (renderVariant == 1 || renderVariant == 2)
    {
        indirectSpecularLightRaysUAV[threadId.xy] = nrdSpecular;
    }

    if (renderVariant == 0 || renderVariant == 2)
    {
        indirectLightRaysUAV[threadId.xy] = nrdDiffuse;
    }

    diffusePrimarySurfaceModulation[threadId.xy] = float4(diffuseAlbedoDemodulation.xyz, 1.0);
}