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
#include "oneflow/core/graph/compute_task_node.h"
#include "oneflow/core/graph/task_stream_index_manager.h"

namespace oneflow {

class AccCtrlTickCompTaskNode final : public CompTaskNode {
 public:
  OF_DISALLOW_COPY_AND_MOVE(AccCtrlTickCompTaskNode);
  AccCtrlTickCompTaskNode() = default;
  ~AccCtrlTickCompTaskNode() = default;
  TaskType GetTaskType() const override { return TaskType::kAccCtrlTick; }
  void ProduceAllRegstsAndBindEdges() override;
  void ConsumeAllRegsts() override;
  void BuildExecGphAndRegst() override;
  void ConsumeFakeRegsts() override;
};

void AccCtrlTickCompTaskNode::ProduceAllRegstsAndBindEdges() {
  std::shared_ptr<RegstDesc> regst = ProduceRegst("out", false);
  ForEachOutDataEdge([&](TaskEdge* edge) { edge->AddRegst("out", regst); });
}

void AccCtrlTickCompTaskNode::ConsumeAllRegsts() {
  ConsumeRegst("in", SoleInDataEdge()->GetSoleRegst());
}

void AccCtrlTickCompTaskNode::ConsumeFakeRegsts() { ConsumeFakeRegst("in"); }

void AccCtrlTickCompTaskNode::BuildExecGphAndRegst() {
  std::shared_ptr<RegstDesc> in_regst = GetSoleConsumedRegst("in");
  std::shared_ptr<RegstDesc> out_regst = GetProducedRegst("out");
  std::shared_ptr<const Operator> op = this->op();
  ExecNode* exec_node = mut_exec_gph().NewNode();
  exec_node->mut_op() = op;
  exec_node->BindBnWithRegst(op->SoleIbn(), in_regst);
  out_regst->AddLbi(op->BnInOp2Lbi(op->SoleObn()));
  exec_node->BindBnWithRegst(op->SoleObn(), out_regst);
  (exec_node->*GetInferBlobDescsMethod())(parallel_ctx());
}

REGISTER_COMP_TASK_STREAM_INDEX_GETTER(TaskType::kAccCtrlTick);

REGISTER_USER_OP_COMP_TASK_NODE_TYPE("acc_ctrl_tick", AccCtrlTickCompTaskNode);

}  // namespace oneflow
