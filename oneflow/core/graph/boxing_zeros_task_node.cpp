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
#include "oneflow/core/framework/to_string.h"
#include "oneflow/core/graph/boxing_zeros_task_node.h"
#include "oneflow/core/graph/boxing_task_graph.pb.h"

namespace oneflow {

void BoxingZerosTaskNode::Init(int64_t machine_id, int64_t thrd_id, const LogicalBlobId& lbi,
                               const Shape& shape, DataType data_type, const Shape& time_shape) {
  set_machine_id(machine_id);
  set_thrd_id(thrd_id);
  set_lbi(lbi);
  shape_ = shape;
  data_type_ = data_type;
  time_shape_ = time_shape;
}

void BoxingZerosTaskNode::ProduceAllRegstsAndBindEdges() {
  std::shared_ptr<RegstDesc> out_regst = ProduceRegst("out", false, 1, 1);
  this->ForEachOutDataEdge([&](TaskEdge* out_dege) { out_dege->AddRegst("out", out_regst); });
}

void BoxingZerosTaskNode::ConsumeAllRegsts() {
  // do nothing
}

void BoxingZerosTaskNode::BuildExecGphAndRegst() {
  ExecNode* node = mut_exec_gph().NewNode();
  OperatorConf op_conf;
  op_conf.set_name("System-Boxing-Zeros-" + NewUniqueId());
  op_conf.set_device_tag(*CHECK_JUST(DeviceTag4DeviceType(this->device_type())));
  *op_conf.mutable_boxing_zeros_conf()->mutable_lbi() = lbi();
  shape_.ToProto(op_conf.mutable_boxing_zeros_conf()->mutable_shape());
  op_conf.mutable_boxing_zeros_conf()->set_data_type(data_type_);
  std::shared_ptr<Operator> sole_op = CHECK_JUST(ConstructOp(op_conf));
  node->mut_op() = sole_op;
  std::shared_ptr<RegstDesc> out_regst = GetProducedRegst("out");
  out_regst->AddLbi(sole_op->BnInOp2Lbi(sole_op->SoleObn()));
  node->BindBnWithRegst(sole_op->SoleObn(), out_regst);
  (node->*GetInferBlobDescsMethod())(nullptr);
}

void BoxingZerosTaskNode::InferProducedDataRegstTimeShape() {
  GetProducedRegst("out")->mut_data_regst_time_shape()->reset(new Shape(time_shape_));
}
Maybe<void> BoxingZerosTaskNode::InitTransportTaskFromProto(
    const TransportTaskProto& transport_task_proto, const TaskGraphRebuildCtx& ctx) {
  CHECK_OR_RETURN(transport_task_proto.has_boxing_zeros_task())
      << "not a serialized BoxingZerosTaskNode. debug string: "
      << transport_task_proto.DebugString();
  const auto& proto = transport_task_proto.boxing_zeros_task();
  shape_ = Shape(proto.shape());
  data_type_ = proto.data_type();
  time_shape_ = Shape(proto.time_shape());
  return Maybe<void>::Ok();
}

void BoxingZerosTaskNode::ToTransportTaskProto(TransportTaskProto* transport_task_proto) const {
  ToProto(transport_task_proto->mutable_task_proto(), /*check=*/false);
  auto* proto = transport_task_proto->mutable_boxing_zeros_task();
  shape_.ToProto(proto->mutable_shape());
  proto->set_data_type(data_type_);
  time_shape_.ToProto(proto->mutable_time_shape());
}

}  // namespace oneflow
