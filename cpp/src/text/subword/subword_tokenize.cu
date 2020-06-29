/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/get_value.cuh>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/utilities/error.hpp>
#include <nvtext/detail/load_hash_file.hpp>
#include <nvtext/subword_tokenize.hpp>
#include <text/subword/detail/wordpiece_tokenizer.hpp>

#include <device_launch_parameters.h>
#include <thrust/for_each.h>
#include <thrust/transform_scan.h>
#include <fstream>
#include <iostream>
#include <vector>

namespace nvtext {
namespace detail {
namespace {

__global__ void kernel_compute_tensor_metadata(
  // input
  uint32_t const* token_ids,
  uint32_t const* offsets,
  uint32_t const* row2log,
  uint32_t const* row2row_within_log,
  uint32_t max_sequence_length,
  uint32_t stride,
  bool do_truncate,
  // output
  uint32_t* final_tensor,
  uint32_t* attn_mask,
  uint32_t* metadata)
{
  uint32_t absolute_row_id      = blockIdx.x;
  uint32_t log_id               = row2log[absolute_row_id];
  uint32_t row_within_log       = row2row_within_log[absolute_row_id];
  uint32_t offset_token_ids_log = offsets[log_id];
  uint32_t n_tokens_log         = offsets[log_id + 1] - offset_token_ids_log;
  bool last_row_of_log =
    (absolute_row_id == gridDim.x - 1) || (row2log[absolute_row_id + 1] != log_id);

  uint32_t row_offset_token_ids = offset_token_ids_log;
  if (row_within_log) row_offset_token_ids += max_sequence_length;
  for (int i = 1; i < row_within_log; i++) row_offset_token_ids += stride;

  if (row_within_log == 0) {
    if (threadIdx.x < n_tokens_log) {
      // copy token ids
      final_tensor[absolute_row_id * max_sequence_length + threadIdx.x] =
        token_ids[row_offset_token_ids + threadIdx.x];
      attn_mask[absolute_row_id * max_sequence_length + threadIdx.x] = 1;
    } else {
      // pad with 0
      final_tensor[absolute_row_id * max_sequence_length + threadIdx.x] = 0;
      attn_mask[absolute_row_id * max_sequence_length + threadIdx.x]    = 0;
    }
  } else {
    uint32_t n_replicates = max_sequence_length - stride;
    if ((row_offset_token_ids - n_replicates + threadIdx.x) <
        (offset_token_ids_log + n_tokens_log)) {
      // replicate elements or copy new tokens
      final_tensor[absolute_row_id * max_sequence_length + threadIdx.x] =
        token_ids[row_offset_token_ids - n_replicates + threadIdx.x];
      attn_mask[absolute_row_id * max_sequence_length + threadIdx.x] = 1;
    } else {
      // pad with 0
      final_tensor[absolute_row_id * max_sequence_length + threadIdx.x] = 0;
      attn_mask[absolute_row_id * max_sequence_length + threadIdx.x]    = 0;
    }
  }

  // write metadata
  if (threadIdx.x == 0) {
    metadata[absolute_row_id * 3] = log_id;
    if (row_within_log == 0)
      metadata[absolute_row_id * 3 + 1] = 0;
    else
      metadata[absolute_row_id * 3 + 1] = (max_sequence_length - stride) / 2;
    if (last_row_of_log) {
      if (n_tokens_log < max_sequence_length)
        metadata[absolute_row_id * 3 + 2] = n_tokens_log - 1;
      else {
        if (!do_truncate)
          metadata[absolute_row_id * 3 + 2] =
            (max_sequence_length - stride) + (n_tokens_log - max_sequence_length) % stride - 1;
        else
          // truncate
          metadata[absolute_row_id * 3 + 2] = (max_sequence_length - 1);
      }
    } else
      metadata[absolute_row_id * 3 + 2] =
        max_sequence_length - (max_sequence_length - stride) / 2 - 1;
  }
}

}  // namespace

tokenizer_result subword_tokenize(cudf::strings_column_view const& strings,
                                  hashed_vocabulary const& vocab_table,
                                  uint32_t max_sequence_length,
                                  uint32_t stride,
                                  bool do_lower,
                                  bool do_truncate,
                                  uint32_t max_num_strings,
                                  uint32_t max_num_chars,
                                  uint32_t max_rows_tensor,
                                  cudaStream_t stream,
                                  rmm::mr::device_memory_resource* mr)
{
  auto strings_count = strings.size();
  auto offsets       = strings.offsets();
  auto d_offsets     = offsets.data<uint32_t>() + strings.offset();
  auto offset        = cudf::detail::get_value<int32_t>(offsets, strings.offset(), stream);
  auto chars_bytes =
    cudf::detail::get_value<int32_t>(offsets, strings.offset() + strings_count, stream) - offset;
  auto d_chars = strings.chars().data<char>() + offset;

  // Create tokenizer
  nvtxRangePushA("create_tokenizer");
  wordpiece_tokenizer tokenizer(vocab_table,
                                max_num_strings,
                                max_num_chars,
                                max_rows_tensor,
                                max_sequence_length,
                                stride,
                                do_truncate,
                                do_lower,
                                stream);
  nvtxRangePop();

  // Run tokenizer
  auto tokens = tokenizer.tokenize(d_chars, d_offsets, strings_count, stream);
  // assign output components
  uint32_t const* device_token_ids = tokens.first;
  uint32_t const* device_offsets   = tokens.second;

  // Format output from tokenizer
  nvtx3::thread_range rt{"tokenizer_output"};
  // each string can create 1 or more log entries
  // compute the string-per-log offsets values by scanning over the number of tokens for each string
  rmm::device_uvector<uint32_t> offsets_per_log(strings_count + 1, stream);
  auto d_offsets_per_log = offsets_per_log.data();
  auto execpol           = rmm::exec_policy(stream);
  thrust::transform_exclusive_scan(
    execpol->on(stream),
    thrust::make_counting_iterator<cudf::size_type>(0),
    thrust::make_counting_iterator<cudf::size_type>(strings_count + 1),
    offsets_per_log.begin(),
    [device_offsets, do_truncate, max_sequence_length, stride] __device__(cudf::size_type idx) {
      uint32_t num_tokens = device_offsets[idx + 1] - device_offsets[idx];
      if (do_truncate || num_tokens <= max_sequence_length) return uint32_t{1};
      return 1 + ((num_tokens - max_sequence_length + stride - 1) / stride);
    },
    uint32_t{0},
    thrust::plus<uint32_t>());
  // last element is the total number of tokens
  uint32_t nrows_tensor_token_ids = offsets_per_log.element(strings_count, stream);

  // compute global_row to log, and global_row to within_log_row correspondence
  rmm::device_uvector<uint32_t> row2log(nrows_tensor_token_ids, stream);
  auto d_row2log = row2log.data();
  rmm::device_uvector<uint32_t> row2row_within_log(nrows_tensor_token_ids, stream);
  auto d_row2row_within_log = row2row_within_log.data();
  thrust::for_each_n(execpol->on(stream),
                     thrust::make_counting_iterator<uint32_t>(0),
                     strings_count,
                     [d_offsets_per_log, d_row2log, d_row2row_within_log] __device__(auto idx) {
                       uint32_t offset = d_offsets_per_log[idx];
                       uint32_t nrows  = d_offsets_per_log[idx + 1] - offset;
                       for (uint32_t jdx = 0; jdx < nrows; ++jdx) {
                         d_row2log[jdx + offset]            = idx;
                         d_row2row_within_log[jdx + offset] = jdx;
                       }
                     });

  // create output data columns
  auto tensor_token_ids = cudf::make_numeric_column(cudf::data_type{cudf::type_id::UINT32},
                                                    nrows_tensor_token_ids * max_sequence_length,
                                                    cudf::mask_state::UNALLOCATED,
                                                    stream,
                                                    mr);
  auto tensor_attention_mask =
    cudf::make_numeric_column(cudf::data_type{cudf::type_id::UINT32},
                              nrows_tensor_token_ids * max_sequence_length,
                              cudf::mask_state::UNALLOCATED,
                              stream,
                              mr);
  auto tensor_metadata = cudf::make_numeric_column(cudf::data_type{cudf::type_id::UINT32},
                                                   nrows_tensor_token_ids * 3,
                                                   cudf::mask_state::UNALLOCATED,
                                                   stream,
                                                   mr);

  // compute final-tensor, mask, and metadata
  kernel_compute_tensor_metadata<<<nrows_tensor_token_ids, max_sequence_length, 0, stream>>>(
    device_token_ids,
    device_offsets,
    d_row2log,
    d_row2row_within_log,
    max_sequence_length,
    stride,
    do_truncate,
    tensor_token_ids->mutable_view().data<uint32_t>(),
    tensor_attention_mask->mutable_view().data<uint32_t>(),
    tensor_metadata->mutable_view().data<uint32_t>());

  return tokenizer_result{nrows_tensor_token_ids,
                          max_sequence_length,
                          std::move(tensor_token_ids),
                          std::move(tensor_attention_mask),
                          std::move(tensor_metadata)};
}

}  // namespace detail

tokenizer_result subword_tokenize(cudf::strings_column_view const& strings,
                                  std::string const& filename_hashed_vocabulary,
                                  uint32_t max_sequence_length,
                                  uint32_t stride,
                                  bool do_lower,
                                  bool do_truncate,
                                  uint32_t max_num_strings,
                                  uint32_t max_num_chars,
                                  uint32_t max_rows_tensor,
                                  rmm::mr::device_memory_resource* mr)
{
  nvtxRangePushA("load_hash");
  hashed_vocabulary vocab_table = load_vocabulary_file(filename_hashed_vocabulary, mr);
  nvtxRangePop();
  // CUDF_FUNC_RANGE();
  return detail::subword_tokenize(strings,
                                  vocab_table,
                                  max_sequence_length,
                                  stride,
                                  do_lower,
                                  do_truncate,
                                  max_num_strings,
                                  max_num_chars,
                                  max_rows_tensor,
                                  0,
                                  mr);
}

tokenizer_result subword_tokenize(cudf::strings_column_view const& strings,
                                  hashed_vocabulary const& vocabulary_table,
                                  uint32_t max_sequence_length,
                                  uint32_t stride,
                                  bool do_lower,
                                  bool do_truncate,
                                  uint32_t max_num_strings,
                                  uint32_t max_num_chars,
                                  uint32_t max_rows_tensor,
                                  rmm::mr::device_memory_resource* mr)
{
  // CUDF_FUNC_RANGE();
  return detail::subword_tokenize(strings,
                                  vocabulary_table,
                                  max_sequence_length,
                                  stride,
                                  do_lower,
                                  do_truncate,
                                  max_num_strings,
                                  max_num_chars,
                                  max_rows_tensor,
                                  0,
                                  mr);
}

}  // namespace nvtext
