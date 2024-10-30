/*
 * SPDX-FileCopyrightText: Copyright (c) 1993-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <numeric>
#include <stdexcept>

#include "multiscaleDeformableAttnPlugin.h"
#include "multiscaleDeformableAttn.h"

#include "NvInfer.h"
#include <cassert>
#include <iostream>

using namespace nvinfer1;
namespace torch2trt_plugins {
    
MultiscaleDeformableAttnPlugin::MultiscaleDeformableAttnPlugin()
{
}

MultiscaleDeformableAttnPlugin::MultiscaleDeformableAttnPlugin(void const* data, size_t length)
{
}

nvinfer1::IPluginV2DynamicExt* MultiscaleDeformableAttnPlugin::clone() const PLUGIN_NOEXCEPT
{
    try
    {
        MultiscaleDeformableAttnPlugin* plugin = new MultiscaleDeformableAttnPlugin();
        plugin->setPluginNamespace(getPluginNamespace());
        return plugin;
    }
    catch (const std::exception& e)
    {
        std::cerr << e.what() << std::endl;
//        return nullptr;
    }
    return nullptr;
}

nvinfer1::DimsExprs MultiscaleDeformableAttnPlugin::getOutputDimensions(int32_t outputIndex,
    nvinfer1::DimsExprs const* inputs, int32_t nbInputs, nvinfer1::IExprBuilder& exprBuilder) PLUGIN_NOEXCEPT
{
    nvinfer1::DimsExprs ret;
    ret.nbDims = 4;
    ret.d[0] = inputs[0].d[0];
    ret.d[1] = inputs[3].d[1];
    ret.d[2] = inputs[0].d[2];
    ret.d[3] = inputs[0].d[3];

    return ret;
}

bool MultiscaleDeformableAttnPlugin::supportsFormatCombination(
    int32_t pos, nvinfer1::PluginTensorDesc const* inOut, int32_t nbInputs, int32_t nbOutputs) PLUGIN_NOEXCEPT
{

    assert(nbInputs == 5 && "nbInputs not equal 5");
    assert(nbOutputs == 1 && "nbOutputs not equal 1");


    if(nbInputs != 5)return false;

    if(nbOutputs != 1)return false;

    if (inOut[pos].format == nvinfer1::TensorFormat::kLINEAR)
    {
        if ((pos == 1) || (pos == 2))
        {
            return (inOut[pos].type == nvinfer1::DataType::kINT32);
        }
        else
        {
            return ((inOut[pos].type == inOut[0].type) &&
                  ((inOut[pos].type == nvinfer1::DataType::kFLOAT) || (inOut[pos].type == nvinfer1::DataType::kHALF)));
        }
    }
    else
    {
        return false;
    }
}

void MultiscaleDeformableAttnPlugin::configurePlugin(nvinfer1::DynamicPluginTensorDesc const* inputs, int32_t nbInputs,
    nvinfer1::DynamicPluginTensorDesc const* outputs, int32_t nbOutputs) PLUGIN_NOEXCEPT
{
    // Check for valid input dimensions
    assert(inputs[0].desc.dims.nbDims == 4 && "value nbDims not equal 4");
    assert(inputs[1].desc.dims.nbDims == 2 && "spatial_shape nbDims not equal 2");
    assert(inputs[2].desc.dims.nbDims == 1 && "level_start_index nbDims not equal 1");
    assert(inputs[3].desc.dims.nbDims == 6 && "sampling_location nbDims not equal 6");
    assert(inputs[4].desc.dims.nbDims == 5 && "atten_weight nbDims not equal 5");

    // Check M dimensions consistency
    assert(inputs[0].desc.dims.d[2] == inputs[3].desc.dims.d[2] && "value d2 not equal sampling_location d2");
    assert(inputs[0].desc.dims.d[2] == inputs[4].desc.dims.d[2] && "value d2 not equal atten_weight d2");

    // Check L dimensions consistency
    assert(inputs[1].desc.dims.d[0] == inputs[2].desc.dims.d[0] && "spatial_shape d0 not equal level_start_index d3");
    assert(inputs[1].desc.dims.d[0] == inputs[3].desc.dims.d[3] && "spatial_shape d0 not equal sampling_location d3");
    assert(inputs[1].desc.dims.d[0] == inputs[4].desc.dims.d[3] && "spatial_shape d0 not equal atten_weight d3");

    // Check P dimensions consistency
    assert(inputs[3].desc.dims.d[4] == inputs[4].desc.dims.d[4] && "sampling_location d4 not equal atten_weight d4");

    // Check Lq dimensions consistency
    assert(inputs[3].desc.dims.d[1] == inputs[4].desc.dims.d[1] && "sampling_location d1 not equal atten_weight d1");
}

size_t MultiscaleDeformableAttnPlugin::getWorkspaceSize(nvinfer1::PluginTensorDesc const* inputs, int32_t nbInputs,
    nvinfer1::PluginTensorDesc const* outputs, int32_t nbOutputs) const PLUGIN_NOEXCEPT
{
    return 0;
}

int32_t MultiscaleDeformableAttnPlugin::enqueue(nvinfer1::PluginTensorDesc const* inputDesc,
    nvinfer1::PluginTensorDesc const* outputDesc, void const* const* inputs, void* const* outputs, void* workSpace,
    cudaStream_t stream) PLUGIN_NOEXCEPT
{
    int32_t const batch = inputDesc[0].dims.d[0];   
    int32_t spatial_size = inputDesc[0].dims.d[1];
    int32_t num_heads = inputDesc[0].dims.d[2];
    int32_t channels = inputDesc[0].dims.d[3];
    int32_t num_levels = inputDesc[1].dims.d[0];
    int32_t num_query = inputDesc[3].dims.d[1];
    int32_t num_point = inputDesc[3].dims.d[4];
    int32_t rc = 0;
    if (inputDesc[0].type == nvinfer1::DataType::kFLOAT)
    {
        float const* value = static_cast<float const*>(inputs[0]);
        int32_t const* spatialShapes = static_cast<int32_t const*>(inputs[1]);
        int32_t const* levelStartIndex = static_cast<int32_t const*>(inputs[2]);
        float const* samplingLoc = static_cast<float const*>(inputs[3]);
        float const* attnWeight = static_cast<float const*>(inputs[4]);
        float* output = static_cast<float*>(outputs[0]);

        rc = ms_deform_attn_cuda_forward(stream, value, spatialShapes, levelStartIndex, samplingLoc, attnWeight, output,
            batch, spatial_size, num_heads, channels, num_levels, num_query, num_point);
    }
    else if (inputDesc[0].type == nvinfer1::DataType::kHALF)
    {
        const __half* value = static_cast<const __half*>(inputs[0]);
        int32_t const* spatialShapes = static_cast<int32_t const*>(inputs[1]);
        int32_t const* levelStartIndex = static_cast<int32_t const*>(inputs[2]);
        const __half* samplingLoc = static_cast<const __half*>(inputs[3]);
        const __half* attnWeight = static_cast<const __half*>(inputs[4]);
        __half* output = static_cast<__half*>(outputs[0]);
        
        rc = ms_deform_attn_cuda_forward(stream, value, spatialShapes, levelStartIndex, samplingLoc, attnWeight, output,
            batch, spatial_size, num_heads, channels, num_levels, num_query, num_point);
    }

    return rc;
}

void MultiscaleDeformableAttnPlugin::attachToContext(
    cudnnContext* cudnnContext, cublasContext* cublasContext, nvinfer1::IGpuAllocator* gpuAllocator) PLUGIN_NOEXCEPT
{
}

void MultiscaleDeformableAttnPlugin::detachFromContext() PLUGIN_NOEXCEPT {}

// IPluginV2Ext Methods
nvinfer1::DataType MultiscaleDeformableAttnPlugin::getOutputDataType(
    int32_t index, nvinfer1::DataType const* inputTypes, int32_t nbInputs) const PLUGIN_NOEXCEPT
{
    return inputTypes[0];
}

// IPluginV2 Methods
char const* MultiscaleDeformableAttnPlugin::getPluginType() const PLUGIN_NOEXCEPT
{
    return "MultiscaleDeformableAttnPlugin_TRT";
}

char const* MultiscaleDeformableAttnPlugin::getPluginVersion() const PLUGIN_NOEXCEPT
{
    return "1";
}

int32_t MultiscaleDeformableAttnPlugin::getNbOutputs() const PLUGIN_NOEXCEPT
{
    return 1;
}

int32_t MultiscaleDeformableAttnPlugin::initialize() PLUGIN_NOEXCEPT
{
    return 0;
}

void MultiscaleDeformableAttnPlugin::terminate() PLUGIN_NOEXCEPT {}

size_t MultiscaleDeformableAttnPlugin::getSerializationSize() const PLUGIN_NOEXCEPT
{
    return 0;
}

void MultiscaleDeformableAttnPlugin::serialize(void* buffer) const PLUGIN_NOEXCEPT
{
}

void MultiscaleDeformableAttnPlugin::destroy() PLUGIN_NOEXCEPT
{
    delete this;
}

void MultiscaleDeformableAttnPlugin::setPluginNamespace(char const* pluginNamespace) PLUGIN_NOEXCEPT
{
    mNamespace = pluginNamespace;
}
char const* MultiscaleDeformableAttnPlugin::getPluginNamespace() const PLUGIN_NOEXCEPT
{
    return mNamespace.c_str();
}

// Pluginv1 Creator

MultiscaleDeformableAttnPluginCreator::MultiscaleDeformableAttnPluginCreator()
{
    mPluginAttributes.clear();
    mFC.nbFields = mPluginAttributes.size();
    mFC.fields = mPluginAttributes.data();
}

char const* MultiscaleDeformableAttnPluginCreator::getPluginName() const PLUGIN_NOEXCEPT
{
    return "MultiscaleDeformableAttnPlugin_TRT";
}

char const* MultiscaleDeformableAttnPluginCreator::getPluginVersion() const PLUGIN_NOEXCEPT
{
    return "1";
}


nvinfer1::PluginFieldCollection const* MultiscaleDeformableAttnPluginCreator::getFieldNames() PLUGIN_NOEXCEPT
{
    return &mFC;
}

IPluginV2* MultiscaleDeformableAttnPluginCreator::createPlugin(
    char const* name, PluginFieldCollection const* fc) PLUGIN_NOEXCEPT
{
    try
    {
        MultiscaleDeformableAttnPlugin* plugin = new MultiscaleDeformableAttnPlugin();
        return plugin;
    }
    catch (const std::exception& e)
    {
        //caughtError(e);
        std::cerr << e.what() << std::endl;
//        return nullptr;
    }
    return nullptr;
}

IPluginV2* MultiscaleDeformableAttnPluginCreator::deserializePlugin(
    char const* name, void const* serialData, size_t serialLength) PLUGIN_NOEXCEPT
{
    try
    {
        auto plugin = new MultiscaleDeformableAttnPlugin(serialData, serialLength);
        plugin->setPluginNamespace(getPluginNamespace());
        return plugin;
    }
    catch (const std::exception& e)
    {
        std::cerr << e.what() << std::endl;
//        return nullptr;
    }
    return nullptr;
}

void MultiscaleDeformableAttnPluginCreator::setPluginNamespace(char const* pluginNamespace) PLUGIN_NOEXCEPT
{
    mNamespace = pluginNamespace;
}

char const* MultiscaleDeformableAttnPluginCreator::getPluginNamespace() const PLUGIN_NOEXCEPT
{
    return mNamespace.c_str();
}

REGISTER_TENSORRT_PLUGIN(MultiscaleDeformableAttnPluginCreator);
}
