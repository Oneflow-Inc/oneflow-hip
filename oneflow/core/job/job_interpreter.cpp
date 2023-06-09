/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/common/container_util.h"
#include "oneflow/core/framework/nn_graph.h"
#include "oneflow/core/framework/op_builder.h"
#include "oneflow/core/framework/op_interpreter.h"
#include "oneflow/core/functional/functional_api.yaml.h"
#include "oneflow/core/job/job.pb.h"
#include "oneflow/core/profiler/profiler.h"
#include "oneflow/core/framework/local_tensor_infer_cache.h"
#include "oneflow/core/framework/global_tensor_infer_cache.h"
#include "oneflow/core/boxing/eager_boxing_interpreter_mgr.h"
#include "oneflow/core/framework/tensor_global_id.h"
#include "oneflow/core/common/decorator.h"
#include "oneflow/core/boxing/eager_boxing_logger.h"

namespace oneflow {
namespace one {

using Env = std::map<std::string, std::shared_ptr<Tensor>>;
using NameToParallelDescMap = std::map<std::string, Symbol<ParallelDesc>>;

Maybe<Env> InitEnv(const one::TensorTuple& graph_inputs, const std::shared_ptr<NNGraph>& graph) {
  Env env;
  for (const auto& [name, tensor] : graph->variable_op_name2tensor()) {
    env.emplace(name + "/out", tensor);
  }
  for (size_t i = 0; i < graph->inputs_op_names().size(); ++i) {
    const auto& name = graph->inputs_op_names()[i];
    env.emplace(name + "/out", JUST(VectorAt(graph_inputs, i)));
  }
  return env;
}

Maybe<UserOpExpr> OpConfToUserOpExpr(const OperatorConf& op_conf) {
  CHECK_OR_RETURN(op_conf.has_user_conf());
  const auto& user_conf = op_conf.user_conf();
  auto builder = OpBuilder(user_conf.op_type_name());
  for (const auto& pair : user_conf.attr()) { builder.Attr(pair.first, pair.second); }
  for (const auto& pair : user_conf.input()) {
    // ignore "UserSourceOpTickInput"
    if (pair.first == "UserSourceOpTickInput") { continue; }
    builder.Input(pair.first, pair.second.s_size());
  }
  for (const auto& pair : user_conf.output()) { builder.Output(pair.first, pair.second.s_size()); }
  return JUST(builder.Build());
}

template<typename Func>
Maybe<std::pair<TensorTuple, OpArgsVector<std::string>>> GetInputTensors(
    const UserOpConf& user_conf, const Env& env, const Func& preprocess) {
  TensorTuple inputs;
  OpArgsVector<std::string> ibns;
  for (const auto& [ibn, ibs] : user_conf.input()) {
    if (ibn == "UserSourceOpTickInput") { continue; }
    const auto& tensor_names = ibs.s();
    for (int i = 0; i < tensor_names.size(); ++i) {
      inputs.emplace_back(preprocess(JUST(MapAt(env, tensor_names[i]))));
      ibns.emplace_back(ibn + '_' + std::to_string(i));
    }
  }
  return std::make_pair(inputs, ibns);
}

OpArgsVector<std::string> GetOutputNamesOfOp(const UserOpConf& user_conf) {
  OpArgsVector<std::string> output_names;
  for (const auto& pair : user_conf.output()) {
    for (const auto& name : pair.second.s()) { output_names.emplace_back(name); }
  }
  return output_names;
}

// Only support a limited subset of view ops for now
bool IsViewOp(const std::shared_ptr<UserOpExpr>& op) {
  return op->op_type_name() == "reshape" || op->op_type_name() == "expand_dims";
}

Maybe<void> RunViewOp(const std::shared_ptr<UserOpExpr>& op, Env& env, const TensorTuple& inputs,
                      const OpArgsVector<std::string>& output_names) {
  // eliminate the memcpy of view ops
  CHECK_OR_RETURN(IsViewOp(op));
  const std::shared_ptr<const LocalTensorInferResult> result =
      JUST([&]() -> Maybe<const LocalTensorInferResult> {
        LocalTensorMetaInferArgs infer_args;
        JUST(infer_args.Init(op->base_attrs(), JUST(inputs[0]->device()), inputs));
        return JUST(op->mut_local_tensor_infer_cache()->GetOrInfer(infer_args));
      }());
  const auto& output_shape = result->output_tensor_metas()[0]->shape();
  const auto output =
      JUST(view::BasicView(inputs[0], output_shape, JUST(inputs[0]->storage_offset())));
  env.emplace(output_names[0], output);
  return Maybe<void>::Ok();
}

namespace {

Maybe<void> RawRunGlobalNormalOp(const std::shared_ptr<UserOpExpr>& op, TensorTuple& inputs,
                                 TensorTuple* outputs, Env& env,
                                 const OpArgsVector<std::string>& ibns,
                                 const OpArgsVector<std::string>& output_names,
                                 const NdSbpSignature& ndsbp_signature,
                                 const Symbol<ParallelDesc>& op_parallel_desc) {
  Optional<int64_t> parallel_id;
  const auto& tensor_device =
      JUST(GetTensorDevice4CurrentProcessCtx(op_parallel_desc, &parallel_id));
  const auto* mgr = Singleton<EagerBoxingInterpreterManager>::Get();
  CHECK_OR_RETURN(inputs.size() == ibns.size()) << "inputs size != ibns size";
  for (int i = 0; i < inputs.size(); ++i) {
    std::shared_ptr<Tensor> input_tensor = inputs[i];
    std::string lbn = JUST(VectorAt(ibns, i));
    const auto& logical_shape = input_tensor->shape();
    CHECK_OR_RETURN(logical_shape->elem_cnt() > 0) << "tensor logical element empty";
    const auto& in_nd_sbp = JUST(input_tensor->nd_sbp());
    const auto& out_nd_sbp = SymbolOf(JUST(MapAt(ndsbp_signature.bn_in_op2nd_sbp(), lbn)));
    const auto& in_parallel_desc = JUST(input_tensor->parallel_desc());
    const auto& out_parallel_desc = op_parallel_desc;
    CHECK_OR_RETURN(in_parallel_desc == out_parallel_desc) << "input placement != output placement";
    if (in_parallel_desc->parallel_num() != 1 && in_nd_sbp != out_nd_sbp) {
      const auto& boxing_interpreter = JUST(mgr->GetEagerBoxingInterpreter(
          in_nd_sbp, out_nd_sbp, in_parallel_desc, out_parallel_desc, *logical_shape));
      Singleton<const EagerBoxingLogger>::Get()->Log(
          *JUST(boxing_interpreter->boxing_interpreter_status()), /* prefix */ "");
      if (parallel_id.has_value()) {
        inputs.at(i) = JUST(boxing_interpreter->Interpret(input_tensor, in_nd_sbp, out_nd_sbp,
                                                          in_parallel_desc, out_parallel_desc));
      }
    }
  }
  static EagerGlobalInterpreter it;
  static OpExprInterpContext ctx =
      OpExprInterpContext(AttrMap{}, op_parallel_desc,
                          SymbolOf(JUST(MapAt(ndsbp_signature.bn_in_op2nd_sbp(), "out_0"))));
  JUST(it.Apply(*op, inputs, outputs, ctx));
  for (size_t i = 0; i < output_names.size(); ++i) {
    env.emplace(output_names[i], JUST(VectorAt(*outputs, i)));
  }
  return Maybe<void>::Ok();
}

auto* RunGlobalNormalOpThenInitGlobalId = DECORATE(&RawRunGlobalNormalOp, NonRecursiveInitGlobalId);

}  // namespace

Maybe<void> RunGlobalNormalOp(const std::shared_ptr<UserOpExpr>& op, TensorTuple& inputs, Env& env,
                              const OpArgsVector<std::string>& ibns,
                              const OpArgsVector<std::string>& output_names,
                              const NdSbpSignature& ndsbp_signature,
                              const Symbol<ParallelDesc>& op_parallel_desc) {
  TensorTuple outputs(output_names.size());
  return RunGlobalNormalOpThenInitGlobalId(op, inputs, &outputs, env, ibns, output_names,
                                           ndsbp_signature, op_parallel_desc);
}

Maybe<void> RunNormalOp(const std::shared_ptr<UserOpExpr>& op, Env& env, const TensorTuple& inputs,
                        const OpArgsVector<std::string>& output_names) {
  TensorTuple outputs(output_names.size());
  static EagerLocalInterpreter it;
  static AttrMap empty_attr_map;
  JUST(it.Apply(*op, inputs, &outputs, empty_attr_map));
  for (size_t i = 0; i < output_names.size(); ++i) {
    env.emplace(output_names[i], JUST(VectorAt(outputs, i)));
  }
  return Maybe<void>::Ok();
}

// tensors in outdated_tensors_after_op[i] will not be accessed any more after i-th op
// so they can be released once i-th op's execution finishes.
std::vector<std::vector<std::string>> GetOutdatedTensorsAfterOp(const Job& job) {
  std::vector<std::vector<std::string>> outdated_tensors_after_op(job.net().op_size());
  std::set<std::string> visited;
  for (int i = job.net().op_size() - 1; i >= 0; --i) {
    const auto& op_conf = job.net().op(i);
    // do not release the graph output tensors
    if (op_conf.has_output_conf()) {
      const auto& output_conf = op_conf.output_conf();
      visited.insert(output_conf.in());
    } else if (op_conf.has_user_conf()) {
      const auto& user_conf = op_conf.user_conf();
      for (const auto& pair : user_conf.input()) {
        if (pair.first == "UserSourceOpTickInput") { continue; }
        for (const auto& name : pair.second.s()) {
          if (visited.find(name) == visited.end()) {
            outdated_tensors_after_op[i].push_back(name);
            visited.insert(name);
          }
        }
      }
    }
  }
  return outdated_tensors_after_op;
}

Maybe<void> InitOpExprs(const std::shared_ptr<NNGraph>& graph) {
  CHECK_OR_RETURN(graph->cached_op_exprs.empty());

  const auto& job = graph->job();
  for (int i = 0; i < job.net().op_size(); i++) {
    const auto& op_conf = job.net().op(i);
    if (op_conf.has_user_conf()) {
      const auto op_expr = JUST(OpConfToUserOpExpr(op_conf));
      graph->cached_op_exprs.push_back(op_expr);
    } else {
      graph->cached_op_exprs.push_back(nullptr);
    }
  }
  return Maybe<void>::Ok();
}

Maybe<one::TensorTuple> InterpretJob(const one::TensorTuple& graph_inputs,
                                     const std::shared_ptr<NNGraph>& graph) {
  if (graph->cached_op_exprs.empty()) { JUST(InitOpExprs(graph)); }

  const auto& job = graph->job();
  auto env = *JUST(InitEnv(graph_inputs, graph));

  // See comments above GetOutdatedTensorsAfterOp's definition for more details
  const auto outdated_tensors_after_op = GetOutdatedTensorsAfterOp(job);

  CHECK_OR_RETURN(job.has_placement()) << "no job placement";
  const auto& job_placement = job.placement();
  NameToParallelDescMap op2paralleldesc;
  for (const auto& blob_placement_group : job_placement.blob_placement_group()) {
    const auto parallel_desc = SymbolOf(ParallelDesc(blob_placement_group.parallel_conf()));
    for (const auto& logical_blob_id : blob_placement_group.lbi()) {
      op2paralleldesc.emplace(logical_blob_id.op_name(), parallel_desc);
    }
  }
  CHECK_OR_RETURN(job.has_job_parallel_view_conf()) << "no job parallel conf";
  const auto& op_name2nd_sbp_signature_conf =
      job.job_parallel_view_conf().op_name2nd_sbp_signature_conf();

  one::TensorTuple graph_outputs;
  for (int i = 0; i < job.net().op_size(); i++) {
    const auto& op_conf = job.net().op(i);
    if (op_conf.has_user_conf()) {
      auto op = CHECK_NOTNULL(graph->cached_op_exprs[i]);
      const auto& user_conf = op_conf.user_conf();
      OF_PROFILER_RANGE_GUARD(user_conf.op_type_name());
      auto [inputs, ibns] =
          *JUST(GetInputTensors(user_conf, env, [&op_conf](const std::shared_ptr<Tensor>& tensor) {
            return CHECK_JUST(functional::To(tensor, op_conf.device_tag()));
          }));
      OpArgsVector<std::string> output_names = GetOutputNamesOfOp(user_conf);
      if (!inputs.empty()
          && inputs[0]->is_local()) {  // All tensors maintain the same properties of is_local
        if (IsViewOp(op)) {
          JUST(RunViewOp(op, env, inputs, output_names));
        } else {
          JUST(RunNormalOp(op, env, inputs, output_names));
        }
      } else {
        const auto& op_parallel_desc = JUST(MapAt(op2paralleldesc, op_conf.name()));
        const auto& nd_sbp_signature_conf =
            JUST(MapAt(op_name2nd_sbp_signature_conf, op_conf.name()));
        JUST(RunGlobalNormalOp(op, inputs, env, ibns, output_names, nd_sbp_signature_conf,
                               op_parallel_desc));
      }
      for (const auto& name : outdated_tensors_after_op[i]) {
        CHECK_EQ_OR_RETURN(env.erase(name), 1);
      }
    } else if (op_conf.has_learning_rate_schedule_conf()) {
      // FIXME(daquexian):
      // It is a temporary hack to support learning_rate_schedule op.
      // Only the naive sgd without any lr decay is supported.
      const auto& lr_conf = op_conf.learning_rate_schedule_conf();
      env.emplace(
          op_conf.name() + "/" + lr_conf.out(),
          JUST(functional::Constant({1}, lr_conf.learning_rate(), DType::Float(), NullOpt)));
    } else if (op_conf.has_identity_conf()) {
      const auto& identity_conf = op_conf.identity_conf();
      const auto& in = identity_conf.in();
      const auto& out = op_conf.name() + "/" + identity_conf.out();
      env.emplace(out, JUST(functional::Identity(JUST(MapAt(env, in)))));
    } else if (op_conf.has_output_conf()) {
      const auto& output_conf = op_conf.output_conf();
      graph_outputs.emplace_back(JUST(MapAt(env, output_conf.in())));
    }
  }
  return graph_outputs;
}
}  // namespace one
}  // namespace oneflow
