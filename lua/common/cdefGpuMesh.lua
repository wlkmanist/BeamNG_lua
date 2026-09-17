-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

if ffi then
  ffi.cdef[[
  typedef struct gpuPrimitive_t {
    uint32_t startIndex;
    uint32_t indexCount;
    uint32_t materialId;
  } gpuPrimitive_t;
  ]]

  --[[ not needed anymore, but may be useful for reference
  typedef struct gpuFlexMesh_t {
    const char* meshName;
    uint32_t primitivesCount;
    const gpuPrimitive_t* primitives;
  } gpuFlexMesh_t;

  typedef struct gpuPropMesh_t {
    const char* meshName;
    float position[3];
    float rotation[4];

    uint32_t indicesCount;
    const uint32_t* indices;

    uint32_t verticesCount;
    const float* vertices;

    uint32_t normalsCount;
    const float* normals;

    uint32_t tangentsCount;
    const float* tangents;

    uint32_t uv1Count;
    const float* uv1; // Vector2

    uint32_t uv2Count;
    const float* uv2; // Vector2

    uint32_t vertColorsCount;
    const uint32_t* vertColors; // RGB packed

    uint32_t primitivesCount;
    const gpuPrimitive_t* primitives;
  } gpuPropMesh_t;

  typedef struct gpuMesh_t {
    uint32_t indicesCount;
    const uint32_t* indices;

    uint32_t verticesCount;
    const float* vertices;

    uint32_t normalsCount;
    const float* normals;

    uint32_t tangentsCount;
    const float* tangents;

    uint32_t uv1Count;
    const float* uv1;

    uint32_t uv2Count;
    const float* uv2;

    uint32_t vertColorsCount;
    const uint32_t* vertColors;

    uint32_t flexmeshesCount;
    const gpuFlexMesh_t* flexmeshes;

    uint32_t propmeshesCount;
    const gpuPropMesh_t* propmeshes;

    bool dataIsReady;
  } gpuMesh_t;
  ]]--
end
