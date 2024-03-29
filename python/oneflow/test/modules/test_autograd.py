"""
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
"""

import unittest
from collections import OrderedDict

import torch as original_torch
import numpy as np
import oneflow as flow
import oneflow.unittest
from oneflow.test_utils.automated_test_util import *
from oneflow.test_utils.test_util import GenArgList


def _test_autograd_backward(test_case, shape, device):
    np_input = np.random.rand(*shape)
    of_input = flow.tensor(
        np_input, dtype=flow.float32, device=flow.device(device), requires_grad=True
    )
    of_out = of_input ** 2
    of_out_sum = of_out.sum()
    of_out_sum.backward()
    test_case.assertTrue(
        np.allclose(of_input.grad.numpy(), np_input * 2, 0.0001, 0.0001)
    )
    of_input = flow.tensor(
        np_input, dtype=flow.float32, device=flow.device(device), requires_grad=True
    )
    of_out = of_input ** 2
    of_out_sum = of_out.sum()
    of_out_sum.backward(flow.ones_like(of_out_sum) * 3)
    test_case.assertTrue(
        np.allclose(of_input.grad.numpy(), np_input * 6, 0.0001, 0.0001)
    )
    of_input = flow.tensor(
        np_input, dtype=flow.float32, device=flow.device(device), requires_grad=True
    )
    of_out = of_input ** 2
    of_out_sum = of_out.sum()
    of_out_sum.backward(retain_graph=True)
    of_out_sum.backward(retain_graph=True)
    test_case.assertTrue(
        np.allclose(of_input.grad.numpy(), np_input * 4, 0.0001, 0.0001)
    )


def _test_autograd_grad(test_case, shape, device):
    np_input = np.random.rand(*shape)
    of_input = flow.tensor(
        np_input, dtype=flow.float32, device=flow.device(device), requires_grad=True
    )
    of_out = of_input ** 2
    of_out_sum = of_out.sum()
    grad = flow.autograd.grad(of_out_sum, of_input)[0]
    test_case.assertTrue(of_input.grad is None)
    test_case.assertTrue(np.allclose(grad.numpy(), np_input * 2, 0.0001, 0.0001))
    of_input = flow.tensor(
        np_input, dtype=flow.float32, device=flow.device(device), requires_grad=True
    )
    of_out = of_input ** 2
    of_out_sum = of_out.sum()
    grad = flow.autograd.grad(of_out_sum, of_input, flow.ones_like(of_out_sum) * 3)[0]
    test_case.assertTrue(np.allclose(grad.numpy(), np_input * 6, 0.0001, 0.0001))


@flow.unittest.skip_unless_1n1d()
class TestAutograd(flow.unittest.TestCase):
    def test_autograd_interface(test_case):
        arg_dict = OrderedDict()
        arg_dict["case"] = [_test_autograd_backward, _test_autograd_grad]
        arg_dict["shape"] = [(2, 3), (2, 3, 4, 5)]
        arg_dict["device"] = ["cpu", "cuda"]
        for arg in GenArgList(arg_dict):
            arg[0](test_case, *arg[1:])

    @autotest(n=10, auto_backward=True, rtol=1e-3, atol=1e-3, check_graph=True)
    def test_accumulate_grad(test_case):
        device = random_device()
        ndim = random(1, 4).to(int)
        x = random_tensor(ndim=ndim, requires_grad=True).to(device)
        y = random_tensor(ndim=ndim, requires_grad=True).to(device)
        return x / (x + y)

    @autotest(n=10, auto_backward=True, rtol=1e-3, atol=1e-3, check_graph=True)
    def test_0dim_accumulate_grad(test_case):
        device = random_device()
        ndim = 0
        x = random_tensor(ndim=ndim, requires_grad=True).to(device)
        y = random_tensor(ndim=ndim, requires_grad=True).to(device)
        return x / (x + y)

    @autotest(n=10, auto_backward=True, rtol=1e-3, atol=1e-3, check_graph=True)
    def test_scalar_leaf_tensor_backward(test_case):
        device = random_device()
        ndim = 0
        x = random_tensor(ndim=ndim, requires_grad=True).to(device)
        return x

    @autotest(n=1, auto_backward=False, check_graph=False)
    def test_out_grad_with_different_dtype(test_case):
        x = random_tensor(ndim=2, requires_grad=True)
        y = x.sum()
        y.backward(torch.tensor(False))
        return x.grad

    @autotest(n=10, auto_backward=False, check_graph=False)
    def test_grad_grad(test_case):
        device = random_device()
        ndim = random(1, 4).to(int)
        x = random_tensor(ndim=ndim, requires_grad=True).to(device)
        y = x * x * x
        x_grad = torch.autograd.grad(
            outputs=y,
            inputs=x,
            grad_outputs=torch.ones_like(y),
            create_graph=True,
            retain_graph=True,
        )[0]
        x_grad_grad = torch.autograd.grad(
            outputs=x_grad, inputs=x, grad_outputs=torch.ones_like(x_grad)
        )[0]
        return x_grad_grad

    @autotest(n=10, auto_backward=False, rtol=1e-3, atol=1e-3, check_graph=False)
    def test_autograd_multiple_times(test_case):
        device = random_device()
        ndim = random(1, 4).to(int).value()
        dims = [random(0, 10).to(int) for _ in range(ndim)]
        x = random_tensor(ndim, *dims, requires_grad=True)
        x1 = x.to(device)
        y = random_tensor(ndim, *dims, requires_grad=True)
        y1 = y.to(device)
        z = x1 + y1

        for _ in range(10):
            z.sum().backward()
        return (x.grad, y.grad)

    def test_autograd_set_acc_grad_and_backward(test_case):
        for _ in range(5):
            ndim = 2
            dims = [random(1, 5).to(int).value() for _ in range(ndim)]
            x = torch.randn(*dims).requires_grad_()
            np_arr = np.random.rand(*dims)
            init_grad = torch.tensor(np_arr).to(x.dtype)
            x.pytorch.grad = init_grad.pytorch
            x.oneflow.grad = init_grad.oneflow

            x.sum().backward()
            test_case.assertTrue(
                np.allclose(
                    x.grad.oneflow.numpy(), x.grad.pytorch.cpu().detach().numpy()
                )
            )

    @autotest(n=1, check_graph=False)
    def test_requires_grad_tensor_inplace_and_backward(test_case):
        random_shape = [random(1, 10).to(int) for _ in range(4)]
        x = random_tensor(4, *random_shape, requires_grad=False)
        y = random_tensor(4, *random_shape, requires_grad=True)
        x += y
        return x

    @autotest(n=1, check_graph=False)
    def test_retain_grad_for_leaf_tensor(test_case):
        random_shape = [random(1, 10).to(int) for _ in range(4)]
        x = random_tensor(4, *random_shape, requires_grad=True)
        y = x * 2
        x.retain_grad()
        return y

    @autotest(n=1, auto_backward=False, check_graph=False)
    def test_run_backward_and_grad_for_same_tensor(test_case):
        random_shape = [random(1, 10).to(int) for _ in range(4)]
        x = random_tensor(4, *random_shape, requires_grad=True)
        y = x ** 2
        y.sum().backward()
        test_case.assertTrue(
            np.allclose(x.grad.oneflow.numpy(), x.grad.pytorch.numpy())
        )

        y = x ** 2
        x_grad = torch.autograd.grad(y.sum(), x)[0]
        test_case.assertTrue(
            np.allclose(x_grad.oneflow.numpy(), x_grad.pytorch.numpy())
        )
        test_case.assertTrue(
            np.allclose(x.grad.oneflow.numpy(), x_grad.oneflow.numpy())
        )

    @autotest(n=1, auto_backward=False, check_graph=False)
    def test_no_grad_domain_call_backward(test_case):
        random_shape = [random(1, 10).to(int).value() for _ in range(4)]
        with flow.no_grad():
            x = flow.rand(*random_shape).requires_grad_()
            with flow.enable_grad():
                y = x * 2
            flow.autograd.backward(y, flow.ones_like(y))
        test_case.assertTrue(np.array_equal(x.grad.numpy(), np.full(random_shape, 2.0)))

    @autotest(n=1, auto_backward=False, check_graph=False)
    def test_acc_grad_inplace_update(test_case):
        random_shape = [random(1, 5).to(int).value() for _ in range(4)]
        x = flow.rand(*random_shape).requires_grad_()
        y = flow.rand(*random_shape).requires_grad_()

        z = x / (x + y)
        z.sum().backward()
        id_x_grad = id(x.grad)
        id_y_grad = id(y.grad)

        z = x / (x + y)
        z.sum().backward()
        test_case.assertEqual(id_x_grad, id(x.grad))
        test_case.assertEqual(id_y_grad, id(y.grad))

    def test_autograd_grad_allow_unused(test_case):
        shape = [random(1, 10).to(int) for _ in range(4)]
        shape = [2, 4]
        device = random_device()
        x = random_tensor(len(shape), *shape, requires_grad=True).to(device)
        z = random_tensor(len(shape), *shape, requires_grad=True).to(device)
        y = x * x

        np_arr = np.random.rand(*y.oneflow.shape)
        init_grad = torch.tensor(np_arr).requires_grad_().to(device)
        dx_and_dz = torch.autograd.grad(
            y,
            [x, z],
            init_grad,
            retain_graph=True,
            create_graph=True,
            allow_unused=True,
        )
        test_case.assertTrue(
            np.allclose(
                dx_and_dz[0].oneflow.detach().numpy(),
                dx_and_dz[0].pytorch.detach().cpu().numpy(),
            )
        )
        test_case.assertTrue(
            dx_and_dz[1].oneflow is None and dx_and_dz[1].pytorch is None
        )

        np_arr = np.random.rand(*y.oneflow.shape)
        init_grad_grad = torch.tensor(np_arr).requires_grad_().to(device)
        ddx = torch.autograd.grad(
            dx_and_dz[0],
            x,
            init_grad_grad,
            retain_graph=True,
            create_graph=True,
            allow_unused=True,
        )[0]
        test_case.assertTrue(
            np.allclose(
                ddx.oneflow.detach().numpy(), ddx.pytorch.detach().cpu().numpy(),
            )
        )

        np_arr = np.random.rand(*y.oneflow.shape)
        init_grad_grad_grad = torch.tensor(np_arr).requires_grad_().to(device)
        dddx = torch.autograd.grad(
            ddx,
            x,
            init_grad_grad_grad,
            retain_graph=True,
            create_graph=True,
            allow_unused=True,
        )[0]
        test_case.assertTrue(dddx.oneflow is None and dddx.pytorch is None)

    def test_autograd_is_grads_batched(test_case):
        x = flow.randn(2, 2, requires_grad=True)

        out = x.clone()  # Size([2, 2])
        batched_grad = flow.arange(3).expand(2, 2, 3).transpose(0, 2)  # Size([3, 2, 2])
        (grad,) = flow.autograd.grad(out, (x,), (batched_grad,), is_grads_batched=True)
        test_case.assertTrue(
            np.array_equal(
                grad.cpu().detach().numpy(),
                flow.arange(3)
                .expand(2, 2, 3)
                .transpose(0, 2)
                .to(dtype=grad.dtype)
                .numpy(),
            )
        )

        # Detect shape mismatch
        grad_out = flow.ones(2, 2)
        with test_case.assertRaisesRegex(
            RuntimeError, "If `is_grads_batched=True`, we interpret the first"
        ):
            flow.autograd.grad(
                outputs=out,
                grad_outputs=(grad_out,),
                inputs=(x,),
                is_grads_batched=True,
            )

        # TODO: ReduceSum backward not support broadcast grad with shape (3, ) to (3, 2, 2)
        #  # Scalar outputs
        #  out = x.sum()  # Size([])
        #  batched_grad = flow.arange(3)  # Size([3])
        #  (grad,) = flow.autograd.grad(out, (x,), (batched_grad,), is_grads_batched=True)
        #  test_case.assertTrue(
        #      np.array_equal(
        #          grad.cpu().detach().numpy(),
        #          flow.arange(3).expand(2, 2, 3).transpose(0, 2).to(dtype=grad.dtype).numpy(),
        #      )
        #  )

        # We consider scalar and sized-1 to be a mismatch. This is consistent with current non-batched behavior.
        grad_out = flow.ones(2).unsqueeze(1)
        with test_case.assertRaisesRegex(
            RuntimeError, "If `is_grads_batched=True`, we interpret the first"
        ):
            flow.autograd.grad(
                outputs=out,
                grad_outputs=(grad_out,),
                inputs=(x,),
                is_grads_batched=True,
            )

    def test_autograd_grad_none_list(test_case):
        x = flow.randn(10, 10, requires_grad=True)
        y = flow.randn(10, 10, requires_grad=True)
        merge = flow.cat([x, y], dim=0)
        s_x, s_y = flow.split(merge, 10, dim=0)
        s_x_sum = s_x.sum()
        s_y_sum = s_y.sum()

        (grad_x, grad_y) = flow.autograd.grad((s_x_sum, s_y_sum), (x, y), (None, None))
        test_case.assertTrue(
            np.array_equal(grad_x.numpy(), np.ones(x.shape).astype(np.float32),)
        )
        test_case.assertTrue(
            np.array_equal(grad_y.numpy(), np.ones(y.shape).astype(np.float32),)
        )


if __name__ == "__main__":
    unittest.main()
