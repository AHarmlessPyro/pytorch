//  Copyright © 2022 Apple Inc.

#define TORCH_ASSERT_ONLY_METHOD_OPERATORS
#include <ATen/mps/MPSProfiler.h>
#include <ATen/native/LinearAlgebraUtils.h>
#include <ATen/native/Resize.h>
#include <ATen/native/mps/OperationUtils.h>

#ifndef AT_PER_OPERATOR_HEADERS
#include <ATen/Functions.h>
#include <ATen/NativeFunctions.h>
#else
#include <ATen/ops/addbmm_native.h>
#include <ATen/ops/addmm_native.h>
#include <ATen/ops/addr_native.h>
#include <ATen/ops/baddbmm_native.h>
#include <ATen/ops/bmm_native.h>
#include <ATen/ops/linalg_solve_triangular_native.h>
#include <ATen/ops/mm_native.h>
#include <ATen/ops/triangular_solve_native.h>
#endif

namespace at::native {
namespace mps {
namespace {
static const char* METAL_LINALG = R"MATMUL_METAL(
#include <metal_array>

using namespace metal;
template<typename T>
T dot_product(constant T *v1, constant T* v2, ulong2 strides, uint32_t size) {
  T rc = 0.0;
  for (uint32_t i = 0; i < size; ++i) {
    rc += v1[i * strides.x] * v2[i * strides.y];
  }
  return rc;
}

template<typename T>
kernel void naive_matmul(
    constant T                 * mat1Data      [[buffer(0)]],
    constant T                 * mat2Data      [[buffer(1)]],
    device   T                 * outputData    [[buffer(2)]],
    constant array<ulong2, 3>  & strides       [[buffer(3)]],
    constant uint3             & sizes         [[buffer(4)]],
    uint                         thread_index [[thread_position_in_grid]]) {
    uint y = thread_index / sizes.x;
    uint x = thread_index % sizes.x;
    if (x >= sizes.x || y >= sizes.z) {
        return;
    }
    auto rc = dot_product(mat1Data + x * strides[0].x,
                          mat2Data + y * strides[1].y,
                          ulong2(strides[0].y, strides[1].x),
                          sizes.y);
    outputData[x * strides[2].x + y * strides[2].y] = rc;
}

#define INSTANTIATE_NAIVE_MM(DTYPE)                                        \
template                                                                   \
[[host_name("naive_matmul_" #DTYPE)]]                                      \
kernel void naive_matmul<DTYPE>(                                           \
    constant DTYPE             * mat1Data      [[buffer(0)]],              \
    constant DTYPE             * mat2Data      [[buffer(1)]],              \
    device   DTYPE             * outputData    [[buffer(2)]],              \
    constant array<ulong2, 3>  & strides       [[buffer(3)]],              \
    constant uint3             & sizes         [[buffer(4)]],              \
    uint                         thread_index [[thread_position_in_grid]])

INSTANTIATE_NAIVE_MM(float);
INSTANTIATE_NAIVE_MM(half);
)MATMUL_METAL";

id<MTLLibrary> compileLinalgOpLibrary(id<MTLDevice> device) {
  static id<MTLLibrary> linalgLibrary = nil;
  if (linalgLibrary) {
    return linalgLibrary;
  }

  NSError* error = nil;
  MTLCompileOptions* options = [[MTLCompileOptions new] autorelease];
  [options setLanguageVersion:MTLLanguageVersion2_3];
  linalgLibrary = [device newLibraryWithSource:[NSString stringWithCString:METAL_LINALG encoding:NSASCIIStringEncoding]
                                       options:options
                                         error:&error];
  TORCH_CHECK(linalgLibrary, "Failed to create metal linalg library, error: ", [[error description] UTF8String]);
  return linalgLibrary;
}

id<MTLComputePipelineState> matmulPipelineState(id<MTLDevice> device, ScalarType scalar_type) {
  std::string kernel = "naive_matmul_" + mps::scalarToMetalTypeString(scalar_type);
  static std::unordered_map<std::string, id<MTLComputePipelineState>> psoCache;
  id<MTLComputePipelineState> pso = psoCache[kernel];
  if (pso) {
    return pso;
  }

  NSError* error = nil;
  id<MTLLibrary> linalgLib = compileLinalgOpLibrary(device);
  id<MTLFunction> matmulFunc = [linalgLib newFunctionWithName:[NSString stringWithUTF8String:kernel.c_str()]];
  TORCH_CHECK(matmulFunc, "Failed to create function state object for: ", kernel);
  pso = [device newComputePipelineStateWithFunction:matmulFunc error:&error];
  TORCH_CHECK(pso, "Failed to created pipeline state object, error: ", [[error description] UTF8String]);

  psoCache[kernel] = pso;
  return pso;
}

Tensor& do_metal_mm(const Tensor& self, const Tensor& other, Tensor& output) {
  auto stream = getCurrentMPSStream();
  auto device = MPSDevice::getInstance()->device();
  auto matmulPSO = matmulPipelineState(device, output.scalar_type());
  dispatch_sync_with_rethrow(stream->queue(), ^() {
    @autoreleasepool {
      getMPSProfiler().beginProfileKernel(matmulPSO, "naive_matmul", {self, other});
      auto computeEncoder = stream->commandEncoder();
      [computeEncoder setComputePipelineState:matmulPSO];
      std::array<uint32_t, 3> sizes = {static_cast<uint32_t>(self.size(0)),
                                       static_cast<uint32_t>(self.size(1)),
                                       static_cast<uint32_t>(output.size(1))};
      std::array<int64_t, 6> strides = {
          self.stride(0), self.stride(1), other.stride(0), other.stride(1), output.stride(0), output.stride(1)};
      mtl_setBuffer(computeEncoder, self, 0);
      mtl_setBuffer(computeEncoder, other, 1);
      mtl_setBuffer(computeEncoder, output, 2);
      [computeEncoder setBytes:strides.data() length:sizeof(uint64_t) * strides.size() atIndex:3];
      [computeEncoder setBytes:sizes.data() length:sizeof(uint32_t) * sizes.size() atIndex:4];
      mtl_dispatch1DJob(computeEncoder, matmulPSO, output.numel());
      getMPSProfiler().endProfileKernel(matmulPSO);
    }
  });
  return output;
}

std::tuple<MPSGraphTensor*, MPSGraphTensor*, MPSGraphTensor*> do_mm(MPSGraph* graph,
                                                                    const Tensor& self,
                                                                    const Tensor& other) {
  if (self.numel() == 0 || other.numel() == 0) {
    auto output = [graph constantWithScalar:0.0
                                      shape:getMPSShape({self.size(0), other.size(1)})
                                   dataType:getMPSDataType(self)];
    return {nil, nil, output};
  }
  auto selfTensor = mpsGraphRankedPlaceHolder(graph, self);
  auto otherTensor = mpsGraphRankedPlaceHolder(graph, other);
  auto output = [graph matrixMultiplicationWithPrimaryTensor:selfTensor secondaryTensor:otherTensor name:nil];
  return {selfTensor, otherTensor, output};
}

bool use_metal_mm(const Tensor& self, const Tensor& other, const Tensor& output) {
  static bool always_use_metal = std::getenv("PYTORCH_MPS_PREFER_METAL") != nullptr;
  constexpr auto max_stride_size = 32768;
  return always_use_metal || self.stride(0) > max_stride_size || self.stride(1) > max_stride_size ||
      self.size(0) > max_stride_size || self.size(1) > max_stride_size || other.stride(0) > max_stride_size ||
      other.stride(1) > max_stride_size || other.size(0) > max_stride_size || other.size(1) > max_stride_size;
}

} // anonymous namespace

static Tensor& mm_out_mps_impl(const Tensor& self, const Tensor& other, Tensor& output) {
  using namespace mps;
  using CachedGraph = MPSBinaryCachedGraph;
  TORCH_CHECK(self.dim() == 2 && other.dim() == 2, "tensors must be 2-D");
  TORCH_CHECK(self.scalar_type() == ScalarType::Double || self.scalar_type() == ScalarType::Float ||
                  self.scalar_type() == ScalarType::Half,
              "MPS device does not support mm for non-float inputs");

  TensorArg args[]{{output, "out", 0}, {self, "mat1", 1}, {other, "mat2", 2}};
  checkAllSameGPU("mm", args);

  TORCH_CHECK(output.is_mps());

  // Transpose inputs if needed
  if (output.numel() == 0) {
    return output;
  }

  // MPS matmul returns silently incorrect results if one of the matrix dimensions is greater than 2**15
  // And crashes if its a view of matrix with dimensions larger than 2**15
  // See https://github.com/pytorch/pytorch/issues/116769#issuecomment-1888302095
  // In such cases, fallback to naive but accurate metal shader
  if (use_metal_mm(self, other, output)) {
    return do_metal_mm(self, other, output);
  }

  @autoreleasepool {
    string key = "mm_out_mps_impl" + getTensorsStringKey({self, other});

    auto cachedGraph = LookUpOrCreateCachedGraph<CachedGraph>(key, [&](auto mpsGraph, auto newCachedGraph) {
      std::tie(newCachedGraph->inputTensor_, newCachedGraph->otherTensor_, newCachedGraph->outputTensor_) =
          do_mm(mpsGraph, self, other);
    });
    auto selfPlaceholder = self.numel() != 0 ? Placeholder(cachedGraph->inputTensor_, self) : Placeholder();
    auto otherPlaceholder = other.numel() != 0 ? Placeholder(cachedGraph->otherTensor_, other) : Placeholder();
    auto outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output);

    auto feeds = self.numel() != 0 ? dictionaryFromPlaceholders(selfPlaceholder, otherPlaceholder) : nil;
    runMPSGraph(getCurrentMPSStream(), cachedGraph->graph(), feeds, outputPlaceholder);
  }

  return output;
}

enum LinearAlgebraOpType { ADDBMM_OP_TYPE, BADDBMM_OP_TYPE };

static Tensor& addbmm_or_baddbmm_out_mps_impl(const Tensor& input,
                                              const Tensor& batch1,
                                              const Tensor& batch2,
                                              const Scalar& beta,
                                              const Scalar& alpha,
                                              Tensor& result,
                                              LinearAlgebraOpType opType) {
  using namespace mps;

  TORCH_CHECK(input.is_mps());
  TORCH_CHECK(batch1.is_mps());
  TORCH_CHECK(batch2.is_mps());
  TORCH_CHECK(result.is_mps());

  TORCH_CHECK(batch1.scalar_type() == ScalarType::Double || batch1.scalar_type() == ScalarType::Float ||
                  batch1.scalar_type() == ScalarType::Half,
              "MPS device does not support addbmm or baddbmm for non-float inputs");

  TORCH_CHECK(batch1.dim() == 3, "batch1 must be a 3D tensor");
  TORCH_CHECK(batch2.dim() == 3, "batch2 must be a 3D tensor");
  TORCH_CHECK(batch1.size(0) == batch2.size(0),
              "batch1 and batch2 must have same number of batches, got ",
              batch1.size(0),
              " and ",
              batch2.size(0));
  TORCH_CHECK(batch1.size(2) == batch2.size(1),
              "Incompatible matrix sizes for bmm (",
              batch1.size(1),
              "x",
              batch1.size(2),
              " and ",
              batch2.size(1),
              "x",
              batch2.size(2),
              ")");

  if (opType == ADDBMM_OP_TYPE) {
    result.resize_as_(input);

    const int64_t num_batches = batch1.size(0);

    if (num_batches == 0) {
      result.zero_();
      return result;
    }
  }

  MPSStream* stream = getCurrentMPSStream();

  struct CachedGraph : public mps::MPSCachedGraph {
    CachedGraph(MPSGraph* graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor* inputTensor_ = nil;
    MPSGraphTensor* batch1Tensor_ = nil;
    MPSGraphTensor* batch2Tensor_ = nil;
    MPSGraphTensor* outputTensor_ = nil;
  };

  @autoreleasepool {
    string key = (opType == ADDBMM_OP_TYPE) ? ("addbmm_out_mps_impl") : ("baddbmm_out_mps_impl");
    key += getTensorsStringKey({batch1, batch2, input}) + ":" + to_string(beta.toDouble()) + ":" +
        to_string(alpha.toDouble());

    auto cachedGraph = LookUpOrCreateCachedGraph<CachedGraph>(key, [&](auto mpsGraph, auto newCachedGraph) {
      MPSGraphTensor* inputTensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, input);
      MPSGraphTensor* batch1Tensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, batch1);
      MPSGraphTensor* batch2Tensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, batch2);

      // Intermediates for beta and alpha
      MPSGraphTensor* betaTensor = [mpsGraph constantWithScalar:beta.toDouble()
                                                       dataType:getMPSScalarType(input.scalar_type())];
      MPSGraphTensor* alphaTensor = [mpsGraph constantWithScalar:alpha.toDouble()
                                                        dataType:getMPSScalarType(batch1.scalar_type())];

      MPSGraphTensor* productTensor = [mpsGraph matrixMultiplicationWithPrimaryTensor:batch1Tensor
                                                                      secondaryTensor:batch2Tensor
                                                                                 name:@"(batch1@batch2)"];

      MPSGraphTensor* reductionSumTensor = productTensor;
      if (opType == ADDBMM_OP_TYPE) {
        reductionSumTensor = [mpsGraph reductionSumWithTensor:productTensor axis:0 name:@"reductionSum(batch1@batch2)"];
      }

      // Intermediates for multiplying by beta and alpha
      MPSGraphTensor* reductionSumTimesAlphaTensor =
          [mpsGraph multiplicationWithPrimaryTensor:reductionSumTensor
                                    secondaryTensor:alphaTensor
                                               name:@"alpha*(batch1@batch2)"];
      MPSGraphTensor* biasTimesBetaTensor = [mpsGraph multiplicationWithPrimaryTensor:inputTensor
                                                                      secondaryTensor:betaTensor
                                                                                 name:@"beta*input"];

      MPSGraphTensor* outputTensor = [mpsGraph additionWithPrimaryTensor:reductionSumTimesAlphaTensor
                                                         secondaryTensor:biasTimesBetaTensor
                                                                    name:@"beta*input + alpha*(batch1@batch2)"];

      newCachedGraph->inputTensor_ = inputTensor;
      newCachedGraph->batch1Tensor_ = batch1Tensor;
      newCachedGraph->batch2Tensor_ = batch2Tensor;
      newCachedGraph->outputTensor_ = outputTensor;
    });

    Placeholder inputPlaceholder = Placeholder(cachedGraph->inputTensor_, input);
    Placeholder batch1Placeholder = Placeholder(cachedGraph->batch1Tensor_, batch1);
    Placeholder batch2Placeholder = Placeholder(cachedGraph->batch2Tensor_, batch2);
    Placeholder outputPlaceholder = Placeholder(cachedGraph->outputTensor_, result);

    auto feeds = dictionaryFromPlaceholders(inputPlaceholder, batch1Placeholder, batch2Placeholder);
    runMPSGraph(stream, cachedGraph->graph(), feeds, outputPlaceholder);
  }

  return result;
}

static Tensor& addmm_out_mps_impl(const Tensor& bias,
                                  const Tensor& self, // input
                                  const Tensor& other, // weight
                                  const Scalar& beta,
                                  const Scalar& alpha,
                                  Tensor& output) {
  using namespace mps;

  TORCH_CHECK(output.is_mps());
  TORCH_CHECK(self.dim() == 2 && other.dim() == 2, "tensors must be 2-D");
  TORCH_CHECK(self.scalar_type() == ScalarType::Double || self.scalar_type() == ScalarType::Float ||
                  self.scalar_type() == ScalarType::Half,
              "MPS device does not support addmm for non-float input");

  TensorArg args[]{{output, "out", 0}, {bias, "self", 1}, {self, "mat1", 2}, {other, "mat2", 3}};
  checkAllSameGPU(__func__, args);

  IntArrayRef mat1_sizes = self.sizes();
  IntArrayRef mat2_sizes = other.sizes();
  IntArrayRef bias_sizes;
  c10::MaybeOwned<Tensor> bias_;
  if (&output != &bias) {
    bias_ = expand_size(bias, {mat1_sizes[0], mat2_sizes[1]}, "addmm");
    bias_sizes = bias_->sizes();
  } else {
    bias_ = c10::MaybeOwned<Tensor>::borrowed(bias);
    bias_sizes = bias_->sizes();
    TORCH_CHECK(output.dim() == 2, "tensors must be 2-D");
    TORCH_CHECK(bias_sizes[0] == mat1_sizes[0], "self_ dim 0 must match mat1 dim 0");
    TORCH_CHECK(bias_sizes[1] == mat2_sizes[1], "self_ dim 1 must match mat2 dim 1");
  }

  if (&output != &self) {
    output.resize_(bias_sizes);
  }
  if (output.numel() == 0) {
    return output;
  }

  bool is_beta_non_zero = beta.toDouble() != 0.0;

  struct CachedGraph : public mps::MPSCachedGraph {
    CachedGraph(MPSGraph* graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor* selfTensor_ = nil;
    MPSGraphTensor* otherTensor_ = nil;
    MPSGraphTensor* biasTensor_ = nil;
    MPSGraphTensor* outputTensor_ = nil;
  };

  @autoreleasepool {
    string key = "addmm_out_mps_impl" + getTensorsStringKey({self, other, *bias_}) + ":" + to_string(beta.toDouble()) +
        ":" + to_string(alpha.toDouble());
    auto cachedGraph = LookUpOrCreateCachedGraph<CachedGraph>(key, [&](auto mpsGraph, auto newCachedGraph) {
      MPSGraphTensor* selfTensor = nil;
      MPSGraphTensor* otherTensor = nil;
      MPSGraphTensor* productTensor = nil;
      MPSGraphTensor* biasTensor = mpsGraphRankedPlaceHolder(mpsGraph, *bias_);

      // TODO: Use alpha and beta here with fill_.Scalar and mul
      std::tie(selfTensor, otherTensor, productTensor) = do_mm(mpsGraph, self, other);

      auto productTimesAlphaTensor = productTensor;
      if (alpha.toDouble() != 1.0) {
        auto alphaTensor = [mpsGraph constantWithScalar:alpha.toDouble() dataType:getMPSScalarType(self.scalar_type())];

        productTimesAlphaTensor = [mpsGraph multiplicationWithPrimaryTensor:productTensor
                                                            secondaryTensor:alphaTensor
                                                                       name:@"MM/alpha*(mat1@mat2)"];
      }
      auto biasTimesBetaTensor = biasTensor;
      if (is_beta_non_zero && beta.toDouble() != 1.0) {
        auto betaTensor = [mpsGraph constantWithScalar:beta.toDouble()
                                              dataType:getMPSScalarType((*bias_).scalar_type())];
        biasTimesBetaTensor = [mpsGraph multiplicationWithPrimaryTensor:biasTensor
                                                        secondaryTensor:betaTensor
                                                                   name:@"MM/beta*input"];
      }

      MPSGraphTensor* outputTensor = productTimesAlphaTensor;
      if (is_beta_non_zero) {
        outputTensor = [mpsGraph additionWithPrimaryTensor:productTimesAlphaTensor
                                           secondaryTensor:biasTimesBetaTensor
                                                      name:@"MM/beta*input + alpha*(mat1@mat2)"];
      }

      newCachedGraph->selfTensor_ = selfTensor;
      newCachedGraph->otherTensor_ = otherTensor;
      newCachedGraph->biasTensor_ = biasTensor;
      newCachedGraph->outputTensor_ = outputTensor;
    });

    Placeholder selfPlaceholder = self.numel() != 0 ? Placeholder(cachedGraph->selfTensor_, self) : Placeholder();
    Placeholder otherPlaceholder = other.numel() != 0 ? Placeholder(cachedGraph->otherTensor_, other) : Placeholder();
    Placeholder biasPlaceholder = Placeholder(cachedGraph->biasTensor_, *bias_);
    Placeholder outputPlaceholder = Placeholder(cachedGraph->outputTensor_, output);

    auto feeds = self.numel() != 0 ? dictionaryFromPlaceholders(selfPlaceholder, otherPlaceholder, biasPlaceholder)
                                   : dictionaryFromPlaceholders(biasPlaceholder);
    runMPSGraph(getCurrentMPSStream(), cachedGraph->graph(), feeds, outputPlaceholder);
  }

  return output;
}

static Tensor& bmm_out_mps_impl(const Tensor& batch1, const Tensor& batch2, Tensor& result) {
  using namespace mps;

  TORCH_CHECK(batch1.scalar_type() == ScalarType::Double || batch1.scalar_type() == ScalarType::Float ||
                  batch1.scalar_type() == ScalarType::Half,
              "MPS device does not support bmm for non-float inputs");

  if (batch1.numel() == 0 || batch2.numel() == 0) {
    result.zero_();
    return result;
  }

  MPSStream* stream = getCurrentMPSStream();

  struct CachedGraph : public mps::MPSCachedGraph {
    CachedGraph(MPSGraph* graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor* batch1Tensor_ = nil;
    MPSGraphTensor* batch2Tensor_ = nil;
    MPSGraphTensor* outputTensor_ = nil;
  };

  @autoreleasepool {
    string key = "bmm_out_mps_impl" + getTensorsStringKey({batch1, batch2});

    auto cachedGraph = LookUpOrCreateCachedGraph<CachedGraph>(key, [&](auto mpsGraph, auto newCachedGraph) {
      MPSGraphTensor* batch1Tensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, batch1);
      MPSGraphTensor* batch2Tensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, batch2);

      MPSGraphTensor* productTensor = [mpsGraph matrixMultiplicationWithPrimaryTensor:batch1Tensor
                                                                      secondaryTensor:batch2Tensor
                                                                                 name:@"MM/(batch1@batch2)"];

      newCachedGraph->batch1Tensor_ = batch1Tensor;
      newCachedGraph->batch2Tensor_ = batch2Tensor;
      newCachedGraph->outputTensor_ = productTensor;
    });
    Placeholder batch1Placeholder = Placeholder(cachedGraph->batch1Tensor_, batch1);
    Placeholder batch2Placeholder = Placeholder(cachedGraph->batch2Tensor_, batch2);
    Placeholder outputPlaceholder = Placeholder(cachedGraph->outputTensor_, result);

    auto feeds = dictionaryFromPlaceholders(batch1Placeholder, batch2Placeholder);
    runMPSGraph(stream, cachedGraph->graph(), feeds, outputPlaceholder);
  }

  return result;
}

static Tensor& linalg_solve_triangular_mps_impl(const Tensor& A,
                                                const Tensor& B,
                                                bool upper,
                                                bool transpose,
                                                bool left,
                                                bool unitriangular,
                                                Tensor& out) {
  using namespace mps;

  checkInputsSolver(A, B, left, "linalg.solve_triangular");
  TORCH_CHECK(!A.is_complex() && !B.is_complex(), "linalg.solve.triangular(); Not supported for complex yet!");
  Tensor A_t, B_t;
  std::tie(B_t, A_t) = _linalg_broadcast_batch_dims(B, A, /*don't check errors*/ nullptr);
  at::native::resize_output(out, B_t.sizes());

  if (A.numel() == 0 || B.numel() == 0 || out.numel() == 0) {
    out.zero_();
    return out;
  }

  Tensor A_ = A_t;
  Tensor B_ = B_t;
  if (!A_t.is_contiguous()) {
    A_ = A_t.clone(at::MemoryFormat::Contiguous);
  }
  if (!B_t.is_contiguous()) {
    B_ = B_t.clone(at::MemoryFormat::Contiguous);
  }
  id<MTLBuffer> aBuffer = getMTLBufferStorage(A_);
  id<MTLBuffer> bBuffer = getMTLBufferStorage(B_);
  id<MTLBuffer> outBuffer = getMTLBufferStorage(out);
  MPSStream* mpsStream = getCurrentMPSStream();
  id<MTLDevice> device = MPSDevice::getInstance()->device();

  dispatch_sync_with_rethrow(mpsStream->queue(), ^() {
    @autoreleasepool {
      mpsStream->endKernelCoalescing();
      id<MTLCommandBuffer> commandBuffer = mpsStream->commandBuffer();
      uint64_t batchSize = A_.sizes().size() > 2 ? A_.size(0) : 1;
      uint64_t aRows = A_.size(-2);
      uint64_t bRows = B_.size(-2);
      uint64_t aCols = A_.size(-1);
      uint64_t bCols = B_.size(-1);
      uint64_t aElemSize = A_.element_size();
      uint64_t bElemSize = B_.element_size();

      MPSMatrixSolveTriangular* filter = [[[MPSMatrixSolveTriangular alloc] initWithDevice:device
                                                                                     right:!left
                                                                                     upper:upper
                                                                                 transpose:transpose
                                                                                      unit:unitriangular
                                                                                     order:left ? bRows : bCols
                                                                    numberOfRightHandSides:left ? bCols : bRows
                                                                                     alpha:1.0f] autorelease];
      // this function call is a no-op if MPS Profiler is not enabled
      getMPSProfiler().beginProfileKernel(filter, " solve_triangular_mps", {A_, B_});

      MPSMatrixDescriptor* sourceMatrixDesc = [MPSMatrixDescriptor matrixDescriptorWithRows:aRows
                                                                                    columns:aCols
                                                                                   matrices:batchSize
                                                                                   rowBytes:aCols * aElemSize
                                                                                matrixBytes:aRows * aCols * aElemSize
                                                                                   dataType:getMPSDataType(A_)];
      MPSMatrixDescriptor* rightHandSideMatrixDesc =
          [MPSMatrixDescriptor matrixDescriptorWithRows:bRows
                                                columns:bCols
                                               matrices:batchSize
                                               rowBytes:bCols * bElemSize
                                            matrixBytes:bRows * bCols * bElemSize
                                               dataType:getMPSDataType(B_)];
      for (const auto i : c10::irange(batchSize)) {
        const uint64_t aBatchOffset = i * aRows * aCols;
        const uint64_t bBatchOffset = i * bRows * bCols;
        MPSMatrix* sourceMatrix = [[[MPSMatrix alloc] initWithBuffer:aBuffer
                                                              offset:(A_t.storage_offset() + aBatchOffset) * aElemSize
                                                          descriptor:sourceMatrixDesc] autorelease];
        MPSMatrix* rightHandSideMatrix =
            [[[MPSMatrix alloc] initWithBuffer:bBuffer
                                        offset:(B_t.storage_offset() + bBatchOffset) * bElemSize
                                    descriptor:rightHandSideMatrixDesc] autorelease];
        MPSMatrix* solutionMatrix = [[[MPSMatrix alloc] initWithBuffer:outBuffer
                                                                offset:(out.storage_offset() + bBatchOffset) * bElemSize
                                                            descriptor:rightHandSideMatrixDesc] autorelease];

        [filter encodeToCommandBuffer:commandBuffer
                         sourceMatrix:sourceMatrix
                  rightHandSideMatrix:rightHandSideMatrix
                       solutionMatrix:solutionMatrix];
      }
      getMPSProfiler().endProfileKernel(filter);
    }
  });
  return out;
}

} // namespace mps

Tensor addr_mps(const Tensor& self, const Tensor& vec1, const Tensor& vec2, const Scalar& beta, const Scalar& alpha) {
  Tensor result = at::empty({0}, self.options());
  addr_out_mps(self, vec1, vec2, beta, alpha, result);
  return result;
}

Tensor& addr_out_mps(const Tensor& self,
                     const Tensor& vec1,
                     const Tensor& vec2,
                     const Scalar& beta,
                     const Scalar& alpha,
                     Tensor& result) {
  using namespace mps;

  TORCH_CHECK(result.is_mps());
  TORCH_CHECK(vec1.dim() == 1 && vec2.dim() == 1, "tensors must be 1-D");
  TORCH_CHECK(vec1.scalar_type() == ScalarType::Double || vec1.scalar_type() == ScalarType::Float ||
                  vec1.scalar_type() == ScalarType::Half,
              "MPS device does not support addr for non-float input");

  TensorArg args[]{{result, "out", 0}, {self, "self", 1}, {vec1, "vec1", 2}, {vec2, "vec2", 3}};
  checkAllSameGPU(__func__, args);

  IntArrayRef vec1_sizes = vec1.sizes();
  IntArrayRef vec2_sizes = vec2.sizes();
  IntArrayRef self_sizes;

  c10::MaybeOwned<Tensor> self_;
  if (&result != &self) {
    self_ = expand_size(self, {vec1_sizes[0], vec2_sizes[0]}, "addr");
    self_sizes = self_->sizes();
  } else {
    self_ = c10::MaybeOwned<Tensor>::borrowed(self);
    self_sizes = self_->sizes();
    TORCH_CHECK(result.dim() == 2, "tensors must be 2-D");
    TORCH_CHECK(self_sizes[0] == vec1_sizes[0], "vec1_ dim 0 must match vec1 dim 0");
    TORCH_CHECK(self_sizes[1] == vec2_sizes[0], "vec1_ dim 1 must match vec2 dim 0");
  }

  if (&result != &vec1) {
    result.resize_(self_sizes);
    if (beta.toComplexDouble() != 0.0) {
      result.copy_(*self_);
    }
  }

  IntArrayRef result_sizes = result.sizes();
  if ((result_sizes[0] == 0) || (result_sizes[1] == 0)) {
    return result;
  }

  MPSStream* stream = getCurrentMPSStream();
  bool is_beta_non_zero = beta.toDouble() != 0.0;
  MPSShape* inputShape = @[ @(vec1.numel()), @(1) ];
  MPSShape* otherShape = @[ @(1), @(vec2.numel()) ];

  struct CachedGraph : public mps::MPSCachedGraph {
    CachedGraph(MPSGraph* graph) : MPSCachedGraph(graph) {}
    MPSGraphTensor* vec1Tensor_ = nil;
    MPSGraphTensor* vec2Tensor_ = nil;
    MPSGraphTensor* selfTensor_ = nil;
    MPSGraphTensor* resultTensor_ = nil;
  };

  @autoreleasepool {
    string key = "addr_out_mps_impl" + getTensorsStringKey({vec1, vec2, *self_}) + ":" + to_string(beta.toDouble()) +
        ":" + to_string(alpha.toDouble());
    auto cachedGraph = LookUpOrCreateCachedGraph<CachedGraph>(key, [&](auto mpsGraph, auto newCachedGraph) {
      MPSGraphTensor* t1 = mps::mpsGraphRankedPlaceHolder(mpsGraph, getMPSDataType(vec1), inputShape);
      MPSGraphTensor* t2 = mps::mpsGraphRankedPlaceHolder(mpsGraph, getMPSDataType(vec2), otherShape);
      MPSGraphTensor* selfTensor = mps::mpsGraphRankedPlaceHolder(mpsGraph, *self_);

      // Intermediate as placeholder
      MPSGraphTensor* productTensor = [mpsGraph matrixMultiplicationWithPrimaryTensor:t1
                                                                      secondaryTensor:t2
                                                                                 name:@"MM/(vec1Xvec2)"];

      // Intermediates for beta and alpha
      MPSGraphTensor* betaTensor = [mpsGraph constantWithScalar:beta.toDouble()
                                                       dataType:getMPSScalarType((*self_).scalar_type())];
      MPSGraphTensor* alphaTensor = [mpsGraph constantWithScalar:alpha.toDouble()
                                                        dataType:getMPSScalarType(vec1.scalar_type())];

      // Intermediates for multiplying by beta and alpha
      MPSGraphTensor* productTimesAlphaTensor = [mpsGraph multiplicationWithPrimaryTensor:productTensor
                                                                          secondaryTensor:alphaTensor
                                                                                     name:@"MM/alpha*(vec1Xvec2)"];
      MPSGraphTensor* selfTimesBetaTensor = selfTensor;
      if (is_beta_non_zero) {
        selfTimesBetaTensor = [mpsGraph multiplicationWithPrimaryTensor:selfTensor
                                                        secondaryTensor:betaTensor
                                                                   name:@"MM/beta*input"];
      }

      MPSGraphTensor* resultTensor = productTimesAlphaTensor;
      if (is_beta_non_zero) {
        resultTensor = [mpsGraph additionWithPrimaryTensor:productTimesAlphaTensor
                                           secondaryTensor:selfTimesBetaTensor
                                                      name:@"MM/beta*input+alpha*(vec1@vec2)"];
      }

      newCachedGraph->vec1Tensor_ = t1;
      newCachedGraph->vec2Tensor_ = t2;
      newCachedGraph->selfTensor_ = selfTensor;
      newCachedGraph->resultTensor_ = resultTensor;
    });

    Placeholder vec1Placeholder = Placeholder(cachedGraph->vec1Tensor_, vec1, inputShape);
    Placeholder vec2Placeholder = Placeholder(cachedGraph->vec2Tensor_, vec2, otherShape);
    Placeholder selfPlaceholder = Placeholder(cachedGraph->selfTensor_, *self_);
    Placeholder resultPlaceholder = Placeholder(cachedGraph->resultTensor_, result);

    auto feeds = dictionaryFromPlaceholders(vec1Placeholder, vec2Placeholder, selfPlaceholder);
    runMPSGraph(stream, cachedGraph->graph(), feeds, resultPlaceholder);
  }

  return result;
}

TORCH_IMPL_FUNC(mm_out_mps)(const Tensor& self, const Tensor& mat2, const Tensor& result) {
  mps::mm_out_mps_impl(self, mat2, const_cast<Tensor&>(result));
}

TORCH_IMPL_FUNC(addmm_out_mps)
(const Tensor& self,
 const Tensor& mat1,
 const Tensor& mat2,
 const Scalar& beta,
 const Scalar& alpha,
 const Tensor& result) {
  mps::addmm_out_mps_impl(self, mat1, mat2, beta, alpha, const_cast<Tensor&>(result));
}

TORCH_IMPL_FUNC(bmm_out_mps)(const Tensor& batch1, const Tensor& batch2, const Tensor& result) {
  mps::bmm_out_mps_impl(batch1, batch2, const_cast<Tensor&>(result));
}

TORCH_IMPL_FUNC(baddbmm_out_mps)
(const Tensor& self,
 const Tensor& batch1,
 const Tensor& batch2,
 const Scalar& beta,
 const Scalar& alpha,
 const Tensor& result) {
  mps::addbmm_or_baddbmm_out_mps_impl(
      self, batch1, batch2, beta, alpha, const_cast<Tensor&>(result), mps::BADDBMM_OP_TYPE);
}

Tensor& addbmm_out_mps(const Tensor& self,
                       const Tensor& batch1,
                       const Tensor& batch2,
                       const Scalar& beta,
                       const Scalar& alpha,
                       Tensor& result) {
  auto b_self = expand_size(self, {batch1.size(1), batch2.size(2)}, "addbmm_out");

  mps::addbmm_or_baddbmm_out_mps_impl(*b_self, batch1, batch2, beta, alpha, result, mps::ADDBMM_OP_TYPE);
  return result;
}

Tensor addbmm_mps(const Tensor& self,
                  const Tensor& batch1,
                  const Tensor& batch2,
                  const Scalar& beta,
                  const Scalar& alpha) {
  Tensor result = at::empty({0}, self.options());
  return addbmm_out_mps(self, batch1, batch2, beta, alpha, result);
}

Tensor& addbmm_mps_(Tensor& self, const Tensor& batch1, const Tensor& batch2, const Scalar& beta, const Scalar& alpha) {
  return addbmm_out_mps(self, batch1, batch2, beta, alpha, self);
}

Tensor& linalg_solve_triangular_mps_out(const Tensor& A,
                                        const Tensor& B,
                                        bool upper,
                                        bool left,
                                        bool unitriangular,
                                        Tensor& out) {
  return mps::linalg_solve_triangular_mps_impl(A, B, upper, /*transpose=*/false, left, unitriangular, out);
}

Tensor linalg_solve_triangular_mps(const Tensor& A, const Tensor& B, bool upper, bool left, bool unitriangular) {
  Tensor out = at::empty({0}, A.scalar_type(), c10::nullopt, kMPS, c10::nullopt, MemoryFormat::Contiguous);
  mps::linalg_solve_triangular_mps_impl(A, B, upper, /*transpose=*/false, left, unitriangular, out);
  return out;
}

TORCH_IMPL_FUNC(triangular_solve_mps_out)
(const Tensor& self,
 const Tensor& A,
 bool upper,
 bool transpose,
 bool unitriangular,
 const Tensor& result,
 const Tensor& clone_A) {
  clone_A.copy_(A);
  Tensor out = at::empty({0}, A.scalar_type(), c10::nullopt, kMPS, c10::nullopt, MemoryFormat::Contiguous);
  mps::linalg_solve_triangular_mps_impl(A, self, upper, transpose, /*left=*/true, unitriangular, out);
  result.resize_(out.sizes());
  result.copy_(out);
}

} // namespace at::native
