/**
 * Copyright 2023, XGBoost Contributors
 */
#pragma once

#ifdef XGBOOST_USE_NCCL
#include "nccl.h"
#endif  // XGBOOST_USE_NCCL

#include <utility>  // for move

#include "../common/device_helpers.cuh"
#include "coll.h"
#include "comm.h"
#include "nccl_stub.h"  // for NcclStub
#include "xgboost/context.h"

namespace xgboost::collective {

inline Result GetCUDAResult(cudaError rc) {
  if (rc == cudaSuccess) {
    return Success();
  }
  std::string msg = thrust::system_error(rc, thrust::cuda_category()).what();
  return Fail(msg);
}

#if defined(XGBOOST_USE_NCCL)
class NCCLComm : public Comm {
  ncclComm_t nccl_comm_{nullptr};
  std::shared_ptr<NcclStub> stub_;
  ncclUniqueId nccl_unique_id_{};
  dh::CUDAStreamView stream_;
  std::string nccl_path_;

 public:
  [[nodiscard]] ncclComm_t Handle() const { return nccl_comm_; }
  auto Stub() const { return stub_; }

  explicit NCCLComm(Context const* ctx, Comm const& root, std::shared_ptr<Coll> pimpl,
                    StringView nccl_path);
  [[nodiscard]] Result LogTracker(std::string) const override {
    LOG(FATAL) << "Device comm is used for logging.";
    return Fail("Undefined.");
  }
  ~NCCLComm() override;
  [[nodiscard]] bool IsFederated() const override { return false; }
  [[nodiscard]] dh::CUDAStreamView Stream() const { return stream_; }
  [[nodiscard]] Result Block() const override {
    auto rc = this->Stream().Sync(false);
    return GetCUDAResult(rc);
  }
};

inline Result GetNCCLResult(std::shared_ptr<NcclStub> stub, ncclResult_t code) {
  if (code == ncclSuccess) {
    return Success();
  }

  std::stringstream ss;
  ss << "NCCL failure: " << stub->GetErrorString(code) << ".";
  if (code == ncclUnhandledCudaError) {
    // nccl usually preserves the last error so we can get more details.
    auto err = cudaPeekAtLastError();
    ss << "  CUDA error: " << thrust::system_error(err, thrust::cuda_category()).what() << "\n";
  } else if (code == ncclSystemError) {
    ss << "  This might be caused by a network configuration issue. Please consider specifying "
          "the network interface for NCCL via environment variables listed in its reference: "
          "`https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html`.\n";
  }
  return Fail(ss.str());
}

class NCCLChannel : public Channel {
  std::int32_t rank_{-1};
  ncclComm_t nccl_comm_{};
  std::shared_ptr<NcclStub> stub_;
  dh::CUDAStreamView stream_;

 public:
  explicit NCCLChannel(Comm const& comm, std::int32_t rank, ncclComm_t nccl_comm,
                       std::shared_ptr<NcclStub> stub, dh::CUDAStreamView stream)
      : rank_{rank},
        nccl_comm_{nccl_comm},
        stub_{std::move(stub)},
        Channel{comm, nullptr},
        stream_{stream} {}

  void SendAll(std::int8_t const* ptr, std::size_t n) override {
    auto rc = GetNCCLResult(stub_, stub_->Send(ptr, n, ncclInt8, rank_, nccl_comm_, stream_));
    CHECK(rc.OK()) << rc.Report();
  }
  void RecvAll(std::int8_t* ptr, std::size_t n) override {
    auto rc = GetNCCLResult(stub_, stub_->Recv(ptr, n, ncclInt8, rank_, nccl_comm_, stream_));
    CHECK(rc.OK()) << rc.Report();
  }
  [[nodiscard]] Result Block() override {
    auto rc = stream_.Sync(false);
    return GetCUDAResult(rc);
  }
};

#endif  //  defined(XGBOOST_USE_NCCL)
}  // namespace xgboost::collective
