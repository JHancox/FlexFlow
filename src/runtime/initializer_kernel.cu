/* Copyright 2019 Stanford
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "initializer.h"
#include "accessor.h"
#include "model.h"
#include "cuda_helper.h"
#include <curand.h>
#include <random>
#include <ctime>

void UniformInitializer::init_task(const Task* task,
                                   const std::vector<PhysicalRegion>& regions,
                                   Context ctx, Runtime* runtime)
{
  assert(regions.size() == 1);
  assert(task->regions.size() == 1);
  TensorAccessorW<float, 2> accW(regions[0], task->regions[0],
      FID_DATA, ctx, runtime, false/*readOutput*/);
  int inputDim = accW.rect.hi[0] - accW.rect.lo[0] + 1;
  int outputDim = accW.rect.hi[1] - accW.rect.lo[1] + 1;
  UniformInitializer* initializer = (UniformInitializer*) task->args;
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  //fprintf(stderr, "seed = %d\n", initializer->seed);
  curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
  checkCUDA(curandGenerateUniform(gen, accW.ptr, accW.rect.volume()));
  scale_kernel<<<GET_BLOCKS(accW.rect.volume()), CUDA_NUM_THREADS>>>(
      accW.ptr, accW.rect.volume(), initializer->min_val, initializer->max_val);
  checkCUDA(cudaDeviceSynchronize());
  curandDestroyGenerator(gen);
}

void GlorotUniform::init_task(const Task* task,
                              const std::vector<PhysicalRegion>& regions,
                              Context ctx, Runtime* runtime)
{
  assert(regions.size() == 1);
  assert(task->regions.size() == 1);
  TensorAccessorW<float, 2> accW(regions[0], task->regions[0],
      FID_DATA, ctx, runtime, false/*readOutput*/);
  int inputDim = accW.rect.hi[0] - accW.rect.lo[0] + 1;
  int outputDim = accW.rect.hi[1] - accW.rect.lo[1] + 1;
  float scale = sqrt(6.0 / (inputDim + outputDim));
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  GlorotUniform* initializer = (GlorotUniform*) task->args;
  curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
  fprintf(stderr, "seed = %d\n", initializer->seed);
  checkCUDA(curandGenerateUniform(gen, accW.ptr, accW.rect.volume()));
  scale_kernel<<<GET_BLOCKS(accW.rect.volume()), CUDA_NUM_THREADS>>>(
      accW.ptr, accW.rect.volume(), -scale, scale);
  checkCUDA(cudaDeviceSynchronize());
  curandDestroyGenerator(gen);
}


void NormInitializer::init_task(const Task* task,
                                const std::vector<PhysicalRegion>& regions,
                                Context ctx, Runtime* runtime)
{
  assert(regions.size() == 1);
  assert(task->regions.size() == 1);
  Domain domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  float* w;
  switch (domain.get_dim()) {
    case 1:
    {
      TensorAccessorW<float, 1> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      break;
    }
    case 2:
    {
      TensorAccessorW<float, 2> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      break;
    }
    case 3:
    {
      TensorAccessorW<float, 3> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      break;
    }
    default:
      assert(false);
  }
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  NormInitializer* initializer = (NormInitializer*) task->args;
  //fprintf(stderr, "seed = %d\n", initializer->seed);
  curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
  fprintf(stderr, "domain.volume() = %zu mean(%.4lf) var(%.4lf)\n",
      domain.get_volume(), initializer->mean, initializer->stddev);
  // FIXME: it seems curand has an internal bug with volume < 4
  // double check this later
  if (domain.get_volume() < 4) {
    std::default_random_engine generator;
    std::normal_distribution<float> distribution(
        initializer->mean, initializer->stddev);
    float* w_dram = (float*) malloc(domain.get_volume() * sizeof(float));
    for (size_t i = 0; i < domain.get_volume(); i++)
      w_dram[i] = distribution(generator);
    checkCUDA(cudaMemcpy(w, w_dram, sizeof(float) * domain.get_volume(),
                         cudaMemcpyHostToDevice));
    checkCUDA(cudaDeviceSynchronize());
    free(w_dram);
  } else {
    checkCUDA(curandGenerateNormal(gen, w, domain.get_volume(),
        initializer->mean, initializer->stddev));
    checkCUDA(cudaDeviceSynchronize());
  }
  curandDestroyGenerator(gen);
}

void ZeroInitializer::init_task(const Task* task,
                                const std::vector<PhysicalRegion>& regions,
                                Context ctx, Runtime* runtime)
{
  assert(regions.size() == task->regions.size());
  for (size_t i = 0; i < regions.size(); i++) {
    Domain domain = runtime->get_index_space_domain(
        ctx, task->regions[i].region.get_index_space());
    float* w;
    switch (domain.get_dim()) {
      case 0:
      {
        // Do not support 0-dim parameters
        assert(false);
        break;
      }
      case 1:
      {
        TensorAccessorW<float, 1> accW(
            regions[i], task->regions[i], FID_DATA, ctx, runtime, false/*readOutput*/);
        w = accW.ptr;
        break;
      }
      case 2:
      {
        TensorAccessorW<float, 2> accW(
            regions[i], task->regions[i], FID_DATA, ctx, runtime, false/*readOutput*/);
        w = accW.ptr;
        break;
      }
      case 3:
      {
        TensorAccessorW<float, 3> accW(
            regions[i], task->regions[i], FID_DATA, ctx, runtime, false/*readOutput*/);
        w = accW.ptr;
        break;
      }
      default:
      {
         assert(false);
         break;
      }
    }
    assign_kernel<<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS>>>(
        w, domain.get_volume(), 0.0f);
  }
  checkCUDA(cudaDeviceSynchronize());
}
