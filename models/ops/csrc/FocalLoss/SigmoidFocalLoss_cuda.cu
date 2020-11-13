// modified from
// https://github.com/pytorch/pytorch/blob/master/modules/detectron/sigmoid_focal_loss_op.cu

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>

#include <cfloat>

// TODO make it in a common file
#define CUDA_1D_KERNEL_LOOP(i, n)                            \
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; \
       i += blockDim.x * gridDim.x)

template <typename T>
__global__ void SigmoidFocalLossForward(
    const int nthreads,
    const T* logits,
    const int64_t* targets,
    const int num_classes,
    const T gamma,
    const T alpha,
    const int num,
    T* losses) {
  CUDA_1D_KERNEL_LOOP(i, nthreads) {
    int n = i / num_classes;
    int d = i % num_classes; // current class[0~79];
    int64_t t = targets[n]; // target class [0~79];

    // Decide it is positive or negative case.
    T c1 = (t == d);
    T c2 = (t >= 0 & t != d);

    // p = 1. / 1. + expf(-x); p = sigmoid(x)
    T  p = (T)1. / ((T)1. + exp(-logits[i]));

    // (1-p)**gamma * log(p) where
    T term1 = pow(((T)1. - p), gamma) * log(max(p, (T)FLT_MIN));

    // p**gamma * log(1-p)
    // T term2 = pow(p, gamma) * log(max((T)1. - p, (T)FLT_MIN));
    T term2 = pow(p, gamma) *
        ((T)-1. * logits[i] * (logits[i] >= (T)0.) -
         log((T)1. + exp(logits[i] - (T)2. * logits[i] * (logits[i] >= (T)0.))));

    losses[i] = (T)0.;
    losses[i] += -c1 * term1 * alpha;
    losses[i] += -c2 * term2 * ((T)1. - alpha);
  } // CUDA_1D_KERNEL_LOOP
} // SigmoidFocalLossForward


template <typename T>
__global__ void SigmoidFocalLossBackward(
    const int nthreads,
    const T* logits,
    const int64_t* targets,
    const T* d_losses,
    const int num_classes,
    const T gamma,
    const T alpha,
    const int num,
    T* d_logits) {
  CUDA_1D_KERNEL_LOOP(i, nthreads) {

    int n = i / num_classes;
    int d = i % num_classes; // current class[0~79];
    int64_t t = targets[n]; // target class [0~79], 80 is background;

    // Decide it is positive or negative case.
    T c1 = (t == d);
    T c2 = (t >= 0 & t != d);

    // p = 1. / 1. + exp(-x); p = sigmoid(x)
    T  p = (T)1. / ((T)1. + exp(-logits[i]));

    // (1-p)**g * (1 - p - g*p*log(p)
    T term1 = pow(((T)1. - p), gamma) *
        ((T)1. - p - (p * gamma * log(max(p, (T)FLT_MIN))));

    // (p**g) * (g*(1-p)*log(1-p) - p)
    // T term_n = pow(p, gamma) *
    // (gamma * ((T)1. - p) * log(max((T)1. - p, (T)FLT_MIN)) - p);
    T term2 = pow(p, gamma) *
        (((T)-1. * logits[i] * (logits[i] >= (T)0.) -
         log((T)1. + exp(logits[i] - (T)2. * logits[i] * (logits[i] >= (T)0.)))) *
         ((T)1. - p) * gamma - p);

    d_logits[i] = (T)0.;
    d_logits[i] += -c1 * term1 * alpha;
    d_logits[i] += -c2 * term2 * ((T)1. - alpha);
    d_logits[i] = d_logits[i] * d_losses[i];
  } // CUDA_1D_KERNEL_LOOP
} // SigmoidFocalLossBackward

namespace pet {

at::Tensor SigmoidFocalLoss_forward_cuda(
		const at::Tensor& logits,
    const at::Tensor& targets,
		const int num_classes,
		const float gamma,
		const float alpha) {
  AT_ASSERTM(logits.device().is_cuda(), "logits must be a CUDA tensor");
  AT_ASSERTM(targets.device().is_cuda(), "targets must be a CUDA tensor");
  AT_ASSERTM(logits.dim() == 2, "logits should be NxClass");

  const int num_samples = logits.size(0);
  auto losses = at::empty({num_samples, logits.size(1)}, logits.options());
  auto losses_size = num_samples * logits.size(1);

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(
    at::cuda::ATenCeilDiv(
        static_cast<int64_t>(losses_size), static_cast<int64_t>(512)),
    static_cast<int64_t>(4096)));
  dim3 block(512);

  if (losses.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return losses;
  }

  AT_DISPATCH_FLOATING_TYPES(logits.scalar_type(), "SigmoidFocalLoss_forward", [&] {
    SigmoidFocalLossForward<scalar_t><<<grid, block, 0, stream>>>(
        losses_size,
        logits.contiguous().data_ptr<scalar_t>(),
	      targets.contiguous().data_ptr<int64_t>(),
        num_classes,
	      gamma,
	      alpha,
	      num_samples,
        losses.data_ptr<scalar_t>());
  });
  cudaDeviceSynchronize();
  AT_CUDA_CHECK(cudaGetLastError());
  return losses;
}

at::Tensor SigmoidFocalLoss_backward_cuda(
		const at::Tensor& logits,
    const at::Tensor& targets,
		const at::Tensor& d_losses,
		const int num_classes,
		const float gamma,
		const float alpha) {
  AT_ASSERTM(logits.device().is_cuda(), "logits must be a CUDA tensor");
  AT_ASSERTM(targets.device().is_cuda(), "targets must be a CUDA tensor");
  AT_ASSERTM(d_losses.device().is_cuda(), "d_losses must be a CUDA tensor");
  AT_ASSERTM(logits.dim() == 2, "logits should be NxClass");

  const int num_samples = logits.size(0);
  AT_ASSERTM(logits.size(1) == num_classes, "logits.size(1) should be num_classes");

  auto d_logits = at::zeros({num_samples, num_classes}, logits.options());
  auto d_logits_size = num_samples * logits.size(1);

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(
    at::cuda::ATenCeilDiv(
        static_cast<int64_t>(d_logits_size), static_cast<int64_t>(512)),
    static_cast<int64_t>(4096)));
  dim3 block(512);

  if (d_logits.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return d_logits;
  }

  AT_DISPATCH_FLOATING_TYPES(logits.scalar_type(), "SigmoidFocalLoss_backward", [&] {
    SigmoidFocalLossBackward<scalar_t><<<grid, block, 0, stream>>>(
        d_logits_size,
        logits.contiguous().data_ptr<scalar_t>(),
	      targets.contiguous().data_ptr<int64_t>(),
	      d_losses.contiguous().data_ptr<scalar_t>(),
        num_classes,
	      gamma,
	      alpha,
	      num_samples,
        d_logits.data_ptr<scalar_t>());
  });
  AT_CUDA_CHECK(cudaGetLastError());
  return d_logits;
}

} // namespace pet